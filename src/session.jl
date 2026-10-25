# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Completion flags of the run steps: `status[period][step][run]`. Only the scheduler loop of
# `run_processing` writes them, so they need no lock.
const RunStatus = Dict{DataPeriod,Dict{Symbol,Dict{DataRun,Bool}}}
# Completion flags of the partition steps: `status[period][step]`.
const PartitionStatus = Dict{DataPeriod,Dict{Symbol,Bool}}

"""
    mutable struct DataflowSession

State of a dataflow session, as returned by [`JuLeAna.setup_session`](@ref): the processing
config, the LEGEND data and the selection and dependency graph that
[`run_processing`](@ref) works on. A [`DataflowController`](@ref) holds the session of the
terminal user interface.

Fields:
- `args::Dict{String,Any}`: parsed command line options, used to reload the config.
- `l200::LegendData`: the LEGEND data the session processes.
- `config::ProcessingConfig`: the validated processing config.
- `periods::Vector{DataPeriod}`: selected periods.
- `runs`: selected runs: `nothing` selects all runs of each period, a
  `Vector{DataRun}` the same runs in every period, and a `Dict{DataPeriod,Vector{DataRun}}`
  the runs per period, where a period without an entry keeps all its runs.
- `run_steps::Vector{Symbol}`, `partition_steps::Vector{Symbol}`: run and
  partition steps scheduled by default, sorted by rank.
- `run_status`, `partition_status`: completion flags of the dependency graph,
  `run_status[period][step][run]::Bool` for every run step and
  `partition_status[period][step]::Bool` for every partition step of the config. A
  step that is not scheduled starts as `true`, so steps that depend on it do not wait.

`DataflowSession(; args, l200, config, periods, runs=config.runs, run_steps,
partition_steps, run_status, partition_status)` builds a session from keywords.
"""
mutable struct DataflowSession
    const args::Dict{String,Any}
    l200::LegendData
    config::ProcessingConfig
    periods::Vector{DataPeriod}
    runs::Union{Nothing,Vector{DataRun},Dict{DataPeriod,Vector{DataRun}}}
    run_steps::Vector{Symbol}
    partition_steps::Vector{Symbol}
    run_status::RunStatus
    partition_status::PartitionStatus
end

function DataflowSession(; args, l200, config, periods, runs = config.runs, run_steps, partition_steps, run_status, partition_status)
    return DataflowSession(args, l200, config, periods, runs, run_steps, partition_steps, run_status, partition_status)
end

"""
    run_processing(session::DataflowSession; kwargs...)

Run the session's scheduled steps over its periods and update its status flags, as
`run_processing(session.config, session.l200, session.periods, session.run_steps,
session.partition_steps, session.run_status, session.partition_status; kwargs...)`.
The keywords are those of that method. Return `nothing`.
"""
function run_processing(session::DataflowSession; kwargs...)
    return run_processing(session.config, session.l200, session.periods, session.run_steps, session.partition_steps, session.run_status,
                          session.partition_status; kwargs...)
end

function Base.show(io::IO, session::DataflowSession)
    return print(io, "DataflowSession(", length(session.periods), " period(s), ",
                 isnothing(session.runs) ? "all runs" : "$(length(session.runs)) run(s)", ", ", length(session.run_steps), " run and ",
                 length(session.partition_steps), " partition steps)")
end

# Enabled steps sorted by rank. With `only_runs`/`only_partitions` the other level is
# not scheduled, so its steps start as finished in the dependency graph.
function selected_steps(cfg::ProcessingConfig)
    return (cfg.only_partitions ? Symbol[] : run_steps(cfg), cfg.only_runs ? Symbol[] : partition_steps(cfg))
end

function reset_dependency_graph!(session::DataflowSession)
    session.periods, session.run_status, session.partition_status = setup_dependency_graph(session.l200, session.config, session.periods,
                                                                                           session.runs, session.run_steps,
                                                                                           session.partition_steps)
    return session
end

# The run selection of a session for the command line options `parsed_args`: the
# per-period runs of `--periods`, else the runs of `config`.
function session_runs(parsed_args::AbstractDict, config::ProcessingConfig)
    _, runs = parse_period_runs(parsed_args["periods"], parsed_args["runs"])
    return runs isa AbstractDict ? runs : config.runs
end

# ParallelProcessingTools run mode that starts the workers configured in `cfg`. Workers
# start without the user's `startup.jl`, whose packages need not be in the workers'
# environment; the configured Julia flags come after it and can override it. Local workers
# without `--threads`/`-t` in their settings share the CPU threads of the host: otherwise
# each would get the thread count of this process and the host would be oversubscribed.
function runprocs_mode(cfg::ProcessingConfig)
    if cfg.runmode == :local
        threads = any(f -> startswith(f, "--threads") || startswith(f, "-t"), cfg.local_julia_settings) ? `` :
                  `--threads=$(local_worker_threads(cfg.local_n))`
        return OnLocalhost(n = cfg.local_n, julia_flags = `--startup-file=no $threads $(cfg.local_julia_settings)`, env = cfg.env_variables)
    elseif cfg.runmode == :slurm
        return OnSlurm(slurm_flags = Cmd(cfg.slurm_flags), julia_flags = `--startup-file=no $(cfg.slurm_julia_settings)`,
                       # the workers' output reaches this process with their worker IDs, like for local workers
                       redirect_output = true, env = cfg.env_variables)
    else
        throw(ArgumentError("unsupported runmode $(repr(cfg.runmode))"))
    end
end

# Julia threads of each of `n` local workers so that together they use every CPU thread
# of the host once.
local_worker_threads(n::Integer) = max(1, Sys.CPU_THREADS ÷ n)

"""
    init_process(log_path::AbstractString = "", log_level::LogLevel = Logging.Info; console::Bool = true)

Prepare the current process for processing: set the `LegendSpecFits` fit time limit to
180 s, install the global logger built by [`processing_logger`](@ref), and pin the Julia
threads with `ThreadPinning.pinthreads(AutoThreadPinning())` of ParallelProcessingTools:
to the CPUs of the affinity mask of the process if it has one, as in a SLURM job, else not
at all. The pinning is logged. A process inside a SLURM job (`SLURM_JOB_ID` is set) whose
job sets `JOB_SHMTMPDIR` uses that node-local shared-memory folder for `tempdir()`.

With a non-empty `log_path`, the process appends its records of level `log_level` to its
file in that directory (see [`process_log_file`](@ref)). The main process shows records
of level `Info` and above on the terminal unless `console = false`; a worker shows only
warnings and errors there. [`setup_session`](@ref) runs it on the head and on every
worker.
"""
function init_process(log_path::AbstractString = "", log_level::LogLevel = Logging.Info; console::Bool = true)
    set_timelimit(180.0)
    haskey(ENV, "SLURM_JOB_ID") && haskey(ENV, "JOB_SHMTMPDIR") && (ENV["TMPDIR"] = ENV["JOB_SHMTMPDIR"])
    log_file = isempty(log_path) ? nothing : process_log_file(log_path)
    console_level = myid() == 1 ? (console ? Logging.Info : nothing) : Logging.Warn
    global_logger(processing_logger(; log_file, log_level, console_level))
    # after the logger, so that the log file records how the threads were pinned
    ThreadPinning.pinthreads(AutoThreadPinning())
    return nothing
end

"""
    setup_session(args::AbstractVector{<:AbstractString})
    setup_session(parsed_args::AbstractDict; console::Bool = true, start_workers::Bool = true)

Set up a dataflow session from the command line options `args` (see `juleana --help`)
or from their parsed form, as returned by [`parse_commandline`](@ref).

Build the processing config and `LegendData(:l200)`, run [`init_process`](@ref) on
this process and register it for every worker, so that every process logs to its file in
the config's log directory at the config's `log_level` (`console = false` turns off the
terminal output of this process), and with `start_workers` start the workers of the
configured run mode: `local` workers are always started; `slurm` workers only with
`submit_jobs`, otherwise `startjlworkers.sh` is written to the
[`JuLeAna.production_config_dir`](@ref) for manual submission. Without `start_workers` the worker pool starts empty. Then check the processor keyword arguments with
[`check_processor_kwargs`](@ref) and build the dependency graph for the enabled steps.

Return the [`DataflowSession`](@ref), ready for [`run_processing`](@ref). Return `nothing` when `args` asks for `--help` or `--version` in an
interactive session.

# Examples
```julia
using JuLeAna
session = JuLeAna.setup_session(["--config", "config/processing_config.yaml", "--periods", "3"])
run_processing(session)
```
"""
function setup_session(args::AbstractVector{<:AbstractString})
    parsed_args = parse_commandline(args)
    isnothing(parsed_args) && return nothing
    return setup_session(parsed_args)
end

function setup_session(parsed_args::AbstractDict; console::Bool = true, start_workers::Bool = true)
    l200, config, periods = setup_processing(parsed_args)
    # a reload of the config writes to the same log directory
    parsed_args["log_path"] = config.log_path
    check_processor_kwargs(config)

    # runs `init_process` on this process now and on every worker when it starts
    log_path, log_level = config.log_path, config.log_level
    @always_everywhere begin
        using JuLeAna: JuLeAna
        JuLeAna.init_process($log_path, $log_level; console = $console)
    end
    @info "Start Data processing with config $(parsed_args["config"]), logging to $log_path"

    if start_workers
        mode = runprocs_mode(config)
        if config.runmode == :local
            errormonitor(@async runworkers(mode))
        else
            script = joinpath(mkpath(production_config_dir()), "startjlworkers.sh")
            @info "Write worker start script to $script"
            write_worker_start_script(script, mode)
            config.submit_jobs && errormonitor(@async runworkers(mode))
        end
    end
    ppt_worker_pool!(FlexWorkerPool(withmyid = false, label = "juleana"; maxoccupancy = 1))

    run_steps, partition_steps = selected_steps(config)
    runs = session_runs(parsed_args, config)
    periods, run_status, partition_status = setup_dependency_graph(l200, config, periods, runs, run_steps, partition_steps)
    session = DataflowSession(; args = parsed_args, l200, config, periods, runs, run_steps, partition_steps, run_status, partition_status)
    flush(stdout)
    return session
end

"""
    main(args::AbstractVector{<:AbstractString})

Entry point of the `juleana` app and of `julia -m JuLeAna`: parse the command line
options `args` (see `juleana --help`) and return the process exit code.

With `--no-tui`, run all enabled steps with [`run_no_tui`](@ref) and return its exit
code. Otherwise open the terminal user interface with [`run_tui`](@ref).

Install the app with `Pkg.Apps.add(path = "<path to JuLeAna.jl>")`; the `juleana`
command then starts Julia with `--threads=8,1`, `--gcthreads=8,1` and without the user's
`startup.jl` (`--startup-file=no`): packages loaded there are not in the app's environment. Julia
options placed before a `--` replace these defaults, e.g. `juleana --threads=16,1 -- -c config.json`.
"""
function (@main)(args::AbstractVector{<:AbstractString})
    parsed_args = parse_commandline(args)
    isnothing(parsed_args) && return 0
    parsed_args["no_tui"] && return run_no_tui(parsed_args)
    run_tui(parsed_args)
    return 0
end
