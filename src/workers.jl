# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Lines of output kept per allocation.
const ALLOCATION_OUTPUT_LINES = 1000

# The SLURM job name in a start script; every allocation gets its own.
const SLURM_JOB_NAME = r"--job-name=julia-\d+-\d+"

# Signal number of SIGTERM and error number of ESRCH (no such process), the same on Linux
# and macOS.
const SIGTERM_SIGNAL = 15
const ESRCH_ERRNO = 3

"""
    WorkerAllocation

One run of the worker start script, started by [`JuLeAna.add_workers!`](@ref). Fields:

- `id::Int`: number of the allocation, counted from 1 per [`JuLeAna.WorkerManager`](@ref).
- `backend::Symbol`: `:local` or `:slurm`.
- `job_name`: the SLURM job name of the allocation's workers, `nothing` for `:local`.
- `started`, `finished`: UTC times; `finished` is `nothing` while the script runs.
- `process`: the `Base.Process` of the shell that runs the script, the leader of its own process
  group.
- `state::Symbol`: `:running`, `:ended` (the script exited with code 0), `:failed` (any
  other exit) or `:cancelled`.
- `exit_code`: the exit code of the script, `nothing` while it runs.
- `job_ids::Vector{String}`: the SLURM job IDs of the allocation at the last query.
- `output::Vector{String}`: the last 1000 lines of the standard and error output of the
  script.
"""
mutable struct WorkerAllocation
    const id::Int
    const backend::Symbol
    const job_name::Union{Nothing,String}
    const started::DateTime
    const process
    state::Symbol
    exit_code::Union{Nothing,Int}
    finished::Union{Nothing,DateTime}
    job_ids::Vector{String}
    const output::Vector{String}
end

"""
    WorkerManager(; squeue::Cmd = `squeue`, scancel::Cmd = `scancel`, sinfo::Cmd = `sinfo`)

The worker allocations of this process and the worker start script they run.

The start script is generated from the processing config of the session by
[`JuLeAna.start_script!`](@ref) and saved as `startjlworkers.sh` in the
[`JuLeAna.production_config_dir`](@ref). It holds the cluster cookie and the address of this
process, so it is generated anew for every config ([`JuLeAna.set_worker_config!`](@ref))
and can be edited for the rest of the session ([`JuLeAna.edit_start_script!`](@ref)).
[`JuLeAna.add_workers!`](@ref) runs it as a new allocation, [`JuLeAna.cancel_allocation!`](@ref)
and [`JuLeAna.cancel_all!`](@ref) end allocations, [`JuLeAna.allocations`](@ref) lists them.

Running allocations are cancelled when nothing has used them for the
`idle_timeout_minutes` of the config: see [`JuLeAna.idle_deadline`](@ref) and
[`JuLeAna.check_idle!`](@ref).

`squeue`, `scancel` and `sinfo` are the SLURM commands, without arguments; SLURM counts as
available when the program of `squeue` is found. [`JuLeAna.workers_overview`](@ref) collects
everything the Workers page shows. All functions may be called from any task.
"""
mutable struct WorkerManager
    const lock::ReentrantLock
    const squeue::Cmd
    const scancel::Cmd
    const sinfo::Cmd
    # host names of the workers, by process ID
    const hosts::Dict{Int,String}
    const allocations::Vector{WorkerAllocation}
    config::Union{Nothing,ProcessingConfig}
    script_path::Union{Nothing,String}
    script::Union{Nothing,String}
    # number of the last SLURM job name handed out
    jobs::Int
    # UTC time of the last processing run, new allocation or postponement
    last_activity::DateTime
end

function WorkerManager(; squeue::Cmd = `squeue`, scancel::Cmd = `scancel`, sinfo::Cmd = `sinfo`)
    return WorkerManager(ReentrantLock(), squeue, scancel, sinfo, Dict{Int,String}(), WorkerAllocation[], nothing, nothing, nothing, 0,
                         now(UTC))
end

"""
    JuLeAna.set_worker_config!(mgr::WorkerManager, config::ProcessingConfig)

Use the run mode of `config` for the next allocations of `mgr`. The start script is generated
anew on its next use; running allocations are not changed.
"""
function set_worker_config!(mgr::WorkerManager, config::ProcessingConfig)
    @lock mgr.lock begin
        mgr.config, mgr.script_path, mgr.script = config, nothing, nothing
    end
    return mgr
end

"""
    JuLeAna.start_script!(mgr::WorkerManager)

Return `(; path, text)` of the start script of `mgr`. The first call after
[`JuLeAna.set_worker_config!`](@ref) generates the script for the run mode of the config with
`ParallelProcessingTools.write_worker_start_script` and writes it to `startjlworkers.sh` in
the [`JuLeAna.production_config_dir`](@ref), keeping an existing file as
`startjlworkers.sh.bak`. Throws an `ArgumentError` if no config is set.
"""
function start_script!(mgr::WorkerManager)
    @lock mgr.lock begin
        isnothing(mgr.config) && throw(ArgumentError("start_script!: no processing config is set"))
        if isnothing(mgr.script)
            path = joinpath(mkpath(production_config_dir()), "startjlworkers.sh")
            isfile(path) && cp(path, path * ".bak"; force = true)
            write_worker_start_script(path, runprocs_mode(mgr.config))
            mgr.script_path, mgr.script = path, read(path, String)
        end
        return (; path = mgr.script_path, text = mgr.script)
    end
end

"""
    JuLeAna.edit_start_script!(mgr::WorkerManager, text::AbstractString)

Replace the start script of `mgr` by `text` and save it to the script file. For the
`slurm` run mode the script must name its SLURM job `--job-name=julia-<n>-<m>`: each
allocation replaces the name by its own, by which it finds and cancels its jobs. Throws
an `ArgumentError` for a SLURM script without such a name.
"""
function edit_start_script!(mgr::WorkerManager, text::AbstractString)
    @lock mgr.lock begin
        (; path) = start_script!(mgr)
        mgr.config.runmode === :slurm &&
            !occursin(SLURM_JOB_NAME, text) &&
            throw(ArgumentError("edit_start_script!: a SLURM start script must contain `--job-name=julia-<n>-<m>`, by which its jobs are found and cancelled"))
        write(path, text)
        mgr.script = String(text)
    end
    return mgr
end

"""
    JuLeAna.add_workers!(mgr::WorkerManager)

Run the start script of `mgr` (see [`JuLeAna.start_script!`](@ref)) with `bash` in the
background as a new allocation and return its [`JuLeAna.WorkerAllocation`](@ref). The shell
leads its own process group, so it keeps running when this process ends unless it is
cancelled. Its standard and error output are kept in the allocation. For the `slurm` run
mode, the job name of the script is replaced by `julia-<pid of this process>-<n>` with a new `n`.
The started workers connect to this process and join its worker pool.
"""
function add_workers!(mgr::WorkerManager)
    @lock mgr.lock begin
        (; text) = start_script!(mgr)
        backend = mgr.config.runmode
        job_name = nothing
        if backend === :slurm
            occursin(SLURM_JOB_NAME, text) ||
                throw(ArgumentError("add_workers!: the SLURM start script has no `--job-name=julia-<n>-<m>`, so its jobs could not be cancelled"))
            mgr.jobs += 1
            job_name = "julia-$(getpid())-$(mgr.jobs)"
            text = replace(text, SLURM_JOB_NAME => "--job-name=$job_name")
        end
        out = Pipe()
        process = run(pipeline(detach(Cmd(["bash", "-c", text])); stdout = out, stderr = out); wait = false)
        close(out.in)
        alloc = WorkerAllocation(length(mgr.allocations) + 1, backend, job_name, now(UTC), process, :running, nothing, nothing, String[],
                                 String[])
        push!(mgr.allocations, alloc)
        mgr.last_activity = alloc.started
        errormonitor(Threads.@spawn watch_allocation(mgr, alloc, out))
        @info "Started worker allocation $(alloc.id)" * (isnothing(job_name) ? "" : " as SLURM job $job_name")
        return alloc
    end
end

# Keep the output of the script of `alloc` and record its end.
function watch_allocation(mgr::WorkerManager, alloc::WorkerAllocation, out::Pipe)
    for line in eachline(out)
        @lock mgr.lock begin
            push!(alloc.output, line)
            length(alloc.output) > ALLOCATION_OUTPUT_LINES && popfirst!(alloc.output)
        end
    end
    wait(alloc.process)
    @lock mgr.lock begin
        alloc.finished = now(UTC)
        alloc.exit_code = alloc.process.exitcode
        alloc.state === :running && (alloc.state = alloc.exit_code == 0 ? :ended : :failed)
    end
    return nothing
end

# IDs of the SLURM jobs of this user named exactly `job_name`.
function slurm_job_ids(mgr::WorkerManager, job_name::AbstractString)
    listing = read(`$(mgr.squeue) -h -u $(get(ENV, "USER", "")) -o "%A %j"`, String)
    return [String(id)
            for (id, name) in (split(line; limit = 2) for line in eachline(IOBuffer(listing)) if !isempty(strip(line)))
            if strip(name) == job_name]
end

"""
    JuLeAna.update_job_ids!(mgr::WorkerManager)

Query `squeue` for the jobs of the running SLURM allocations of `mgr` and store their IDs
in the allocations. Does nothing without such allocations.
"""
function update_job_ids!(mgr::WorkerManager)
    running = @lock mgr.lock [a for a in mgr.allocations if a.state === :running && !isnothing(a.job_name)]
    for alloc in running
        ids = slurm_job_ids(mgr, alloc.job_name)
        @lock mgr.lock alloc.job_ids = ids
    end
    return mgr
end

"""
    JuLeAna.cancel_allocation!(mgr::WorkerManager, id::Integer)

End the allocation `id` of `mgr` if it is running: for a SLURM allocation, `scancel` the
jobs that `squeue` lists for this user under the allocation's job name (and no others),
then send `SIGTERM` to the process group of its script, which ends the local workers or
`srun`. The workers of the allocation leave the worker pool; items running on them fail.
Throws an `ArgumentError` for an unknown `id`.
"""
function cancel_allocation!(mgr::WorkerManager, id::Integer)
    alloc = @lock mgr.lock begin
        i = findfirst(a -> a.id == id, mgr.allocations)
        isnothing(i) && throw(ArgumentError("cancel_allocation!: there is no worker allocation $id"))
        a = mgr.allocations[i]
        a.state === :running || return mgr
        a.state = :cancelled
        a
    end
    if !isnothing(alloc.job_name)
        ids = slurm_job_ids(mgr, alloc.job_name)
        isempty(ids) || run(`$(mgr.scancel) $ids`)
        @lock mgr.lock alloc.job_ids = ids
    end
    # the shell leads its process group: a negative pid signals the whole group
    if ccall(:kill, Cint, (Cint, Cint), -getpid(alloc.process), SIGTERM_SIGNAL) != 0 && Libc.errno() != ESRCH_ERRNO
        throw(SystemError("cancel_allocation!: kill of the process group of allocation $id", Libc.errno()))
    end
    @info "Cancelled worker allocation $id"
    return mgr
end

"""
    JuLeAna.cancel_all!(mgr::WorkerManager)

Cancel every running allocation of `mgr` with [`JuLeAna.cancel_allocation!`](@ref).
"""
function cancel_all!(mgr::WorkerManager)
    ids = @lock mgr.lock [a.id for a in mgr.allocations if a.state === :running]
    foreach(id -> cancel_allocation!(mgr, id), ids)
    return mgr
end

# A copy of a worker allocation, without and with its output. The field types are fixed, so
# that the interface code that shows allocations is compiled once for every state.
const AllocationInfo = @NamedTuple{id::Int, backend::Symbol, job_name::Union{Nothing,String}, started::DateTime,
                                   finished::Union{Nothing,DateTime}, state::Symbol, exit_code::Union{Nothing,Int}, job_ids::Vector{String}}
const AllocationOutputInfo = @NamedTuple{id::Int, backend::Symbol, job_name::Union{Nothing,String}, started::DateTime,
                                         finished::Union{Nothing,DateTime}, state::Symbol, exit_code::Union{Nothing,Int},
                                         job_ids::Vector{String}, output::Vector{String}}

"""
    JuLeAna.allocations(mgr::WorkerManager; output::Bool = true)

Return a copy of the allocations of `mgr` as `NamedTuple`s with the fields of
[`JuLeAna.WorkerAllocation`](@ref) except `process`, and without `output` unless `output`:
a `Vector{JuLeAna.AllocationOutputInfo}`, or a `Vector{JuLeAna.AllocationInfo}` without output.
"""
function allocations(mgr::WorkerManager; output::Bool = true)
    @lock mgr.lock if output
        AllocationOutputInfo[(; a.id, a.backend, a.job_name, a.started, a.finished, a.state, a.exit_code, job_ids = copy(a.job_ids),
                              output = copy(a.output)) for a in mgr.allocations]
    else
        AllocationInfo[(; a.id, a.backend, a.job_name, a.started, a.finished, a.state, a.exit_code, job_ids = copy(a.job_ids))
                       for a in mgr.allocations]
    end
end

"""
    JuLeAna.mark_activity!(mgr::WorkerManager, time::DateTime = now(UTC))

Record that the workers of `mgr` were used at `time` (UTC), such as by the end of a
processing run or a postponement: the idle time of [`JuLeAna.idle_deadline`](@ref) counts from
the latest such time.
"""
function mark_activity!(mgr::WorkerManager, time::DateTime = now(UTC))
    @lock mgr.lock mgr.last_activity = max(mgr.last_activity, time)
    return mgr
end

"""
    JuLeAna.idle_deadline(mgr::WorkerManager; processing::Bool)

Return the UTC time at which [`JuLeAna.check_idle!`](@ref) cancels the running allocations of
`mgr`: the last activity (see [`JuLeAna.mark_activity!`](@ref); a new allocation counts too)
plus the `idle_timeout_minutes` of the config. Return `nothing` while `processing`, if
no allocation runs, without a config, or if the timeout is `0`.
"""
function idle_deadline(mgr::WorkerManager; processing::Bool)
    @lock mgr.lock begin
        (processing || isnothing(mgr.config) || mgr.config.idle_timeout_minutes == 0 || !any(a -> a.state === :running, mgr.allocations)) &&
            return nothing
        return mgr.last_activity + Millisecond(round(Int, mgr.config.idle_timeout_minutes * 60_000))
    end
end

"""
    JuLeAna.check_idle!(mgr::WorkerManager; processing::Bool, time::DateTime = now(UTC))

Cancel all running allocations of `mgr` with [`JuLeAna.cancel_all!`](@ref) if `time` (UTC) has
reached the [`JuLeAna.idle_deadline`](@ref). Return whether they were cancelled.
"""
function check_idle!(mgr::WorkerManager; processing::Bool, time::DateTime = now(UTC))
    deadline = idle_deadline(mgr; processing)
    (isnothing(deadline) || time < deadline) && return false
    @warn "No processing for $(mgr.config.idle_timeout_minutes) minutes: cancelling all worker allocations"
    cancel_all!(mgr)
    return true
end

# Type of the value of `workers_overview`, with fixed field types.
const WorkersOverview = @NamedTuple{allocations::Vector{AllocationOutputInfo}, script::Union{String,@NamedTuple{path::String,text::String}},
                                    workers::Vector{@NamedTuple{pid::Int,host::Union{Nothing,String}}},
                                    slurm::Union{Nothing,@NamedTuple{queue::String,idle::String}}}

"""
    JuLeAna.workers_overview(mgr::WorkerManager)

Collect what the Workers page shows and return a `JuLeAna.WorkersOverview`
`(; allocations, script, workers, slurm)`:

- `allocations`: [`JuLeAna.allocations`](@ref) with their output, after
  [`JuLeAna.update_job_ids!`](@ref);
- `script`: the `(; path, text)` of [`JuLeAna.start_script!`](@ref), or the message of the
  error that kept it from being generated;
- `workers`: one `(; pid, host)` per worker process, `host` `nothing` until it is known;
  the host of a new worker is asked for in the background;
- `slurm`: `nothing` without SLURM, else `(; queue, idle)`, the output of
  `squeue -u <user>` and of `sinfo -t idle`.

Runs SLURM commands, so it can take a while; call it in the background.
"""
function workers_overview(mgr::WorkerManager)
    slurm_available = !isnothing(Sys.which(first(mgr.squeue.exec)))
    slurm_available && update_job_ids!(mgr)
    script = try
        start_script!(mgr)
    catch e
        String(first(split(sprint(showerror, e), '\n')))
    end
    pids = nprocs() > 1 ? workers() : Int[]
    workers_now = @lock mgr.lock begin
        for pid in pids
            haskey(mgr.hosts, pid) && continue
            # asked once per worker; a failed request is shown as "?"
            mgr.hosts[pid] = ""
            errormonitor(Threads.@spawn begin
                             host = try
                                 remotecall_fetch(gethostname, pid)
                             catch
                                 "?"
                             end
                             @lock mgr.lock mgr.hosts[pid] = host
                         end)
        end
        [(; pid, host = isempty(mgr.hosts[pid]) ? nothing : mgr.hosts[pid]) for pid in pids]
    end
    user = get(ENV, "USER", "")
    slurm = slurm_available ? (; queue = read(`$(mgr.squeue) -u $user`, String), idle = read(`$(mgr.sinfo) -t idle`, String)) : nothing
    return convert(WorkersOverview, (; allocations = allocations(mgr), script, workers = workers_now, slurm))
end
