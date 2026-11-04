# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Lines of output kept per allocation.
const ALLOCATION_OUTPUT_LINES = 1000

# The SLURM job name in a start script; every allocation gets its own.
const SLURM_JOB_NAME = r"--job-name=julia-\d+-\d+"

# Signal numbers of SIGTERM and SIGKILL and error number of ESRCH (no such process), the same
# on Linux and macOS.
const SIGTERM_SIGNAL = 15
const SIGKILL_SIGNAL = 9
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
    JuLeAna.WorkerAttributes

The attributes a worker process reports once (see [`JuLeAna.worker_attributes`](@ref)), a
`NamedTuple` with the fields

- `host::String`: the host name;
- `os_pid::Int`: the process ID on the host;
- `threads::Int`: the number of Julia threads;
- `memory::Int`: the bytes of memory the process may use, `Sys.total_memory()`: the limit of
  its control group, such as the memory of its SLURM job or step, else the memory of the host;
- `job`, `step`: the SLURM job and step ID, `""` outside SLURM;
- `tasks`: the number of tasks of the SLURM step (`SLURM_STEP_NUM_TASKS`), `""` outside SLURM;
- `cpus`: the CPUs per task of the SLURM step (`SLURM_CPUS_PER_TASK`), `""` if not set;
- `gpus`: the GPUs of the SLURM step (`SLURM_STEP_GPUS`), `""` without GPUs.
"""
const WorkerAttributes = @NamedTuple{host::String, os_pid::Int, threads::Int, memory::Int, job::String, step::String, tasks::String,
                                     cpus::String, gpus::String}

# Run on a worker with `include_string`: it needs nothing but Base, so it also works before
# the worker has loaded JuLeAna.
const WORKER_ATTRIBUTES_CODE = """
    (; host = gethostname(), os_pid = getpid(), threads = Threads.nthreads(), memory = Int(Sys.total_memory()),
     job = get(ENV, "SLURM_JOB_ID", ""), step = get(ENV, "SLURM_STEP_ID", ""), tasks = get(ENV, "SLURM_STEP_NUM_TASKS", ""),
     cpus = get(ENV, "SLURM_CPUS_PER_TASK", ""), gpus = get(ENV, "SLURM_STEP_GPUS", ""))
    """

# Attributes of the worker processes by process ID; Distributed never reuses a process ID.
const WORKER_ATTRIBUTES = Dict{Int,WorkerAttributes}()
const WORKER_ATTRIBUTES_LOCK = ReentrantLock()

"""
    JuLeAna.worker_attributes(pid::Integer)

Return the [`JuLeAna.WorkerAttributes`](@ref) of the worker process `pid`. The first call asks
the worker, later calls return the same attributes without asking. The worker must answer,
so the first call must come while it is not busy.
"""
function worker_attributes(pid::Integer)
    a = @lock WORKER_ATTRIBUTES_LOCK get(WORKER_ATTRIBUTES, pid, nothing)
    isnothing(a) || return a
    a = convert(WorkerAttributes, remotecall_fetch(include_string, pid, Main, WORKER_ATTRIBUTES_CODE))
    @lock WORKER_ATTRIBUTES_LOCK WORKER_ATTRIBUTES[pid] = a
    return a
end

"""
    JuLeAna.kill_worker(pid::Integer; scancel::Cmd = `scancel`)

End the process of the worker `pid` at once with SIGKILL, also while it computes and does not
answer: a worker that is the only task of a SLURM job step (other than the step of this
process) with `scancel --signal=KILL <job>.<step>`, a worker on this host with `kill -9`.
Its [`JuLeAna.worker_attributes`](@ref) must have been asked for before. Distributed then
removes the worker, and the calls running on it throw a `ProcessExitedException`.

Throws an `ArgumentError` for the main process, for a worker whose attributes are not known,
and for a worker on another host that is not the only task of its job step.
"""
function kill_worker(pid::Integer; scancel::Cmd = `scancel`)
    pid == myid() && throw(ArgumentError("kill_worker: process $pid is the main process"))
    a = @lock WORKER_ATTRIBUTES_LOCK get(WORKER_ATTRIBUTES, pid, nothing)
    isnothing(a) && throw(ArgumentError("kill_worker: the attributes of worker $pid are not known"))
    if !isempty(a.job) && a.tasks == "1" && (a.job, a.step) != (get(ENV, "SLURM_JOB_ID", ""), get(ENV, "SLURM_STEP_ID", ""))
        run(`$scancel --signal=KILL $(a.job).$(a.step)`)
    elseif a.host == gethostname()
        if ccall(:kill, Cint, (Cint, Cint), a.os_pid, SIGKILL_SIGNAL) != 0 && Libc.errno() != ESRCH_ERRNO
            throw(SystemError("kill_worker: kill of process $(a.os_pid) of worker $pid", Libc.errno()))
        end
    else
        throw(ArgumentError("kill_worker: worker $pid runs on $(a.host), not as the only task of a SLURM job step"))
    end
    return nothing
end

"""
    JuLeAna.StepInfo

A SLURM job step of a worker allocation as `sacct` and `sstat` report it (see
[`JuLeAna.update_steps!`](@ref)), a `NamedTuple` with the fields

- `id::String`: `<job ID>.<step ID>`;
- `node::String`: the node of the step;
- `state::String`: the state, such as `RUNNING`, `COMPLETED`, `CANCELLED` or `OUT_OF_MEMORY`;
- `exit_code::String`: `<exit code>:<signal>`;
- `elapsed::String`: the run time as `sacct` prints it;
- `rss`: the resident memory in bytes at the last sample, `nothing` once the step ended;
- `max_rss`: the peak of the resident memory in bytes, `nothing` if not reported. SLURM
  samples the memory every few seconds, so a short peak can be missing.
"""
const StepInfo = @NamedTuple{id::String, node::String, state::String, exit_code::String, elapsed::String, rss::Union{Nothing,Int},
                             max_rss::Union{Nothing,Int}}

# Minimum time between two queries of the job steps; SLURM samples the memory of a step every
# 10 s (viper) to 30 s (raven).
const STEPS_READ_SECONDS = 10

"""
    WorkerManager(; squeue::Cmd = `squeue`, scancel::Cmd = `scancel`, sinfo::Cmd = `sinfo`,
                  sacct::Cmd = `sacct`, sstat::Cmd = `sstat`)

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

`squeue`, `scancel`, `sinfo`, `sacct` and `sstat` are the SLURM commands, without arguments; SLURM counts as
available when the program of `squeue` is found. [`JuLeAna.workers_overview`](@ref) collects
everything the Workers page shows. All functions may be called from any task.
"""
mutable struct WorkerManager
    const lock::ReentrantLock
    const squeue::Cmd
    const scancel::Cmd
    const sinfo::Cmd
    const sacct::Cmd
    const sstat::Cmd
    # attributes of the workers by process ID: `nothing` while asked for, `missing` if the request failed
    const attributes::Dict{Int,Union{Nothing,Missing,WorkerAttributes}}
    const allocations::Vector{WorkerAllocation}
    # job steps of the SLURM allocations by job ID, and the `time()` of their last query
    const steps::Dict{String,Vector{StepInfo}}
    steps_read::Float64
    config::Union{Nothing,ProcessingConfig}
    script_path::Union{Nothing,String}
    script::Union{Nothing,String}
    # number of the last SLURM job name handed out
    jobs::Int
    # UTC time of the last processing run, new allocation or postponement
    last_activity::DateTime
end

function WorkerManager(; squeue::Cmd = `squeue`, scancel::Cmd = `scancel`, sinfo::Cmd = `sinfo`, sacct::Cmd = `sacct`, sstat::Cmd = `sstat`)
    return WorkerManager(ReentrantLock(), squeue, scancel, sinfo, sacct, sstat, Dict{Int,Union{Nothing,Missing,WorkerAttributes}}(),
                         WorkerAllocation[], Dict{String,Vector{StepInfo}}(), -Inf, nothing, nothing, nothing, 0, now(UTC))
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

# Minutes after which the start scripts take this process as gone if it has not touched its
# heartbeat file, which it does every minute (see `start_heartbeat`).
const HEARTBEAT_MINUTES = 5

# File that this process touches every minute while it has worker allocations, in the folder of
# the start script, which the workers can read.
heartbeat_file() = joinpath(production_config_dir(), "juleana-$(gethostname())-$(getpid()).alive")

# Heartbeat tasks of this process by file.
const HEARTBEATS = Dict{String,Task}()
const HEARTBEATS_LOCK = ReentrantLock()

# Touch `path` now and every minute for the rest of this process, and remove it when the
# process exits; does nothing if that already happens.
function start_heartbeat(path::AbstractString)
    @lock HEARTBEATS_LOCK begin
        haskey(HEARTBEATS, path) && return HEARTBEATS[path]
        touch(path)
        atexit(() -> rm(path; force = true))
        return HEARTBEATS[path] = errormonitor(Threads.@spawn while true
                                                   sleep(60)
                                                   touch(path)
                                               end)
    end
end

# Bash lines that run `cmd` in `n` slots at the same time and start it again in its slot
# whenever it ends, as long as `heartbeat` was touched in the last `HEARTBEAT_MINUTES` minutes;
# otherwise they run `stop`, which ends the allocation.
function restart_loop(n::Integer, cmd::AbstractString, heartbeat::AbstractString, stop::AbstractString)
    return """
        for slot in \$(seq $n); do
          while true; do
            start=\$SECONDS
            $cmd
            echo "Worker slot \$slot: the worker ended after \$((SECONDS - start)) s"
            if [ -z "\$(find $(Base.shell_escape_posixly(heartbeat)) -mmin -$HEARTBEAT_MINUTES 2>/dev/null)" ]; then
              echo "JuLeAna has not touched $(Base.shell_escape_posixly(heartbeat)) for $HEARTBEAT_MINUTES minutes: ending the allocation"
              $stop
              exit
            fi
          done &
        done
        wait
        """
end

"""
    JuLeAna.worker_start_script(cfg::ProcessingConfig)

Return the text of the bash script that starts the workers of the run mode of `cfg` and
connects them to this process. A worker that ends is started again in its slot, so the script
runs until it is ended, as long as this process runs: when a worker ends and this process has
not touched its heartbeat file for 5 minutes (see [`JuLeAna.add_workers!`](@ref)), the script
ends the allocation, the local workers with SIGTERM to its process group, the SLURM job with
`scancel`.

In the `local` run mode the script starts `cfg.local_n` workers on the host it runs on.

In the `slurm` run mode it submits one job with `sbatch --wait`, the job name
`julia-<pid of this process>-0` (see [`JuLeAna.add_workers!`](@ref)) and the SLURM flags of
`cfg` except `--cpu-bind`, and prints the output of the job until the job ends (it is cancelled
or reaches its time limit); ended with
SIGTERM, it cancels the job by its name. The output goes
to `julia-workers-<pid of the script>.out` in the log directory of `cfg`, or in the current
directory if `cfg` has none. The job runs every worker as its own job step on one node, with the
CPUs per task and the `--cpu-bind` and `--mem-bind` flags of `cfg`. With
`cfg.slurm_worker_memory === :shared` the steps share the memory of the job; with `:fixed` each
step gets the memory of the job per worker. Throws an `ArgumentError` for `:fixed` without
`--mem` or `--mem-per-cpu` in the flags, and for a `--cpu-bind` or `--mem-bind` flag without `=`.
"""
function worker_start_script(cfg::ProcessingConfig)
    cmd, _, n = worker_start_command(runprocs_mode(cfg), ppt_cluster_manager())
    if cfg.runmode === :local
        return """
            #!/bin/bash
            # Starts $n Julia workers on this host. A worker that ends is started again.
            """ * restart_loop(n, Base.shell_escape_posixly(cmd), heartbeat_file(), "kill 0")
    end
    flags = cfg.slurm_flags
    any(in(("--cpu-bind", "--mem-bind")), flags) &&
        throw(ArgumentError("worker_start_script: write the SLURM flags `--cpu-bind` and `--mem-bind` as `--cpu-bind=<value>` and `--mem-bind=<value>`"))
    # `cmd` is `srun --job-name=… --chdir=… <flags> <worker command>`
    args, last_flag = collect(cmd), 3 + length(flags)
    first(args) == "srun" && args[4:last_flag] == flags ||
        error("worker_start_script: unexpected SLURM start command of ParallelProcessingTools: $cmd")
    # the CPUs and memory per task as ParallelProcessingTools reads them for the threads and heap size of the worker command
    tasks = ParallelProcessingTools._get_slurm_taskconf(Cmd(flags), ENV)
    memory = if cfg.slurm_worker_memory === :shared
        "0"
    else
        per_task = ParallelProcessingTools._slurm_mem_per_task(tasks)
        isnothing(per_task) &&
            throw(ArgumentError("worker_start_script: `worker_memory: fixed` needs `--mem` or `--mem-per-cpu` in the SLURM flags"))
        "$(div(per_task, 1024^2))M"
    end
    cpus = isnothing(tasks.cpus_per_task) ? `` : `--cpus-per-task=$(tasks.cpus_per_task)`
    binding = filter(f -> startswith(f, "--cpu-bind=") || startswith(f, "--mem-bind="), flags)
    step = `srun --nodes=1 --ntasks=1 --exact $cpus --mem=$memory $binding $(Cmd(args[(last_flag + 1):end]))`
    job_flags = filter(f -> !startswith(f, "--cpu-bind="), flags)
    output = joinpath(isempty(cfg.log_path) ? pwd() : cfg.log_path, "julia-workers-")
    return """
        #!/bin/bash
        # Submits a SLURM job that runs each of its $n Julia workers as its own job step, waits for
        # the job and prints its output. A worker that ends is started again in a new step.
        job_name=--job-name=julia-$(getpid())-0
        output=$(Base.shell_escape_posixly(output))\$\$.out
        # exists before the job starts, so that `tail` can follow it
        touch "\$output"
        # SIGTERM ends `sbatch --wait` but not the job
        trap 'scancel --user="\$USER" --name="\${job_name#--job-name=}"' TERM
        sbatch --wait "\$job_name" $(Base.shell_escape_posixly(Cmd(job_flags))) --output="\$output" <<'JOB' &
        #!/bin/bash
        # every step runs one task; the job's tasks per node would make `srun` warn at every start
        unset SLURM_NTASKS_PER_NODE
        $(restart_loop(n, Base.shell_escape_posixly(step), heartbeat_file(), "scancel \"\$SLURM_JOB_ID\""))JOB
        job=\$!
        tail -n +1 -F "\$output" 2>/dev/null &
        follow=\$!
        wait \$job
        status=\$?
        # time for `tail` to print the last lines
        sleep 2
        kill \$follow 2>/dev/null
        exit \$status
        """
end

"""
    JuLeAna.start_script!(mgr::WorkerManager)

Return `(; path, text)` of the start script of `mgr`. The first call after
[`JuLeAna.set_worker_config!`](@ref) generates the script for the run mode of the config with
[`JuLeAna.worker_start_script`](@ref) and writes it to `startjlworkers.sh` in the
[`JuLeAna.production_config_dir`](@ref), readable only by the user, keeping an existing file as
`startjlworkers.sh.bak`. Throws an `ArgumentError` if no config is set.
"""
function start_script!(mgr::WorkerManager)
    @lock mgr.lock begin
        isnothing(mgr.config) && throw(ArgumentError("start_script!: no processing config is set"))
        if isnothing(mgr.script)
            path = joinpath(mkpath(production_config_dir()), "startjlworkers.sh")
            isfile(path) && cp(path, path * ".bak"; force = true)
            text = worker_start_script(mgr.config)
            # the script holds the cluster cookie
            open(path, "w") do io
                chmod(path, 0o700)
                write(io, text)
            end
            mgr.script_path, mgr.script = path, text
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

From the first allocation on, this process touches its heartbeat file
`juleana-<host>-<pid>.alive` in the [`JuLeAna.production_config_dir`](@ref) every minute until
it exits; the start scripts end their allocation when the file has not been touched for 5
minutes (see [`JuLeAna.worker_start_script`](@ref)).
"""
function add_workers!(mgr::WorkerManager)
    @lock mgr.lock begin
        (; text) = start_script!(mgr)
        start_heartbeat(heartbeat_file())
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

const SLURM_MEMORY_UNITS = Dict("" => 1, "K" => 1024, "M" => 1024^2, "G" => 1024^3, "T" => 1024^4)

# Bytes of a memory size as `sacct` and `sstat` print it, such as `36812K`; `nothing` for an empty field.
function slurm_bytes(text::AbstractString)
    isempty(text) && return nothing
    m = match(r"^(\d+(?:\.\d+)?)([KMGT]?)$", text)
    isnothing(m) && throw(ArgumentError("slurm_bytes: unexpected memory size $(repr(text))"))
    return round(Int, parse(Float64, m[1]) * SLURM_MEMORY_UNITS[m[2]])
end

"""
    JuLeAna.update_steps!(mgr::WorkerManager; at::Real = time())

Query `sacct` and `sstat` for the job steps of the workers of the SLURM allocations of `mgr`
(not the `batch` and `extern` steps) and keep them as [`JuLeAna.StepInfo`](@ref)s by job ID.
Queries the jobs of the running allocations (see [`JuLeAna.update_job_ids!`](@ref)) and, until
their steps have ended, the jobs that had running steps at the previous query. Does nothing
less than $(STEPS_READ_SECONDS) seconds after the previous query (`at` is the current
`time()`) or without such jobs.
"""
function update_steps!(mgr::WorkerManager; at::Real = time())
    running, unfinished = @lock mgr.lock begin
        at - mgr.steps_read < STEPS_READ_SECONDS && return mgr
        mgr.steps_read = at
        ids = unique!([id for a in mgr.allocations if a.state === :running && a.backend === :slurm for id in a.job_ids])
        ids, [id for (id, steps) in mgr.steps if id ∉ ids && any(s -> s.state in ("RUNNING", "PENDING"), steps)]
    end
    jobs = [running; unfinished]
    isempty(jobs) && return mgr
    acct = read(`$(mgr.sacct) --noheader --parsable2 --jobs=$(join(jobs, ",")) --format=JobID,NodeList,State,ExitCode,Elapsed,MaxRSS`,
                String)
    # `sstat` fails for a job without running steps
    stat = isempty(running) ? "" :
           read(pipeline(ignorestatus(`$(mgr.sstat) --noheader --parsable2 --allsteps --jobs=$(join(running, ",")) --format=JobID,AveRSS,MaxRSS`);
                         stderr = devnull), String)
    live = Dict(String(f[1]) => (slurm_bytes(f[2]), slurm_bytes(f[3])) for f in split.(eachline(IOBuffer(stat)), '|') if length(f) == 3)
    steps = Dict(id => StepInfo[] for id in jobs)
    for f in split.(eachline(IOBuffer(acct)), '|')
        length(f) == 6 && occursin(r"^\d+\.\d+$", f[1]) || continue
        id = String(f[1])
        rss, max_rss = get(live, id, (nothing, nothing))
        # `CANCELLED by <user ID>`
        push!(get!(steps, first(split(id, '.')), StepInfo[]),
              (; id, node = String(f[2]), state = String(first(split(f[3]))), exit_code = String(f[4]), elapsed = String(f[5]), rss,
               max_rss = something(max_rss, slurm_bytes(f[6]), Some(nothing))))
    end
    @lock mgr.lock merge!(mgr.steps, steps)
    return mgr
end

"""
    JuLeAna.cancel_allocation!(mgr::WorkerManager, id::Integer)

End the allocation `id` of `mgr` if it is running: for a SLURM allocation, `scancel` the
jobs that `squeue` lists for this user under the allocation's job name (and no others),
then send `SIGTERM` to the process group of its script, which ends the local workers or
`sbatch`. The workers of the allocation leave the worker pool; items running on them fail.
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
                                    workers::Vector{@NamedTuple{pid::Int,attributes::Union{Nothing,Missing,WorkerAttributes}}},
                                    steps::Vector{StepInfo}, slurm::Union{Nothing,@NamedTuple{queue::String,idle::String}}}

"""
    JuLeAna.workers_overview(mgr::WorkerManager)

Collect what the Workers page shows and return a `JuLeAna.WorkersOverview`
`(; allocations, script, workers, steps, slurm)`:

- `allocations`: [`JuLeAna.allocations`](@ref) with their output, after
  [`JuLeAna.update_job_ids!`](@ref);
- `script`: the `(; path, text)` of [`JuLeAna.start_script!`](@ref), or the message of the
  error that kept it from being generated;
- `workers`: one `(; pid, attributes)` per worker process with its
  [`JuLeAna.WorkerAttributes`](@ref), `nothing` until they are known and `missing` if the
  worker did not answer; the attributes of a new worker are asked for in the background;
- `steps`: the [`JuLeAna.StepInfo`](@ref)s of the SLURM jobs, after
  [`JuLeAna.update_steps!`](@ref), by job and step ID;
- `slurm`: `nothing` without SLURM, else `(; queue, idle)`, the output of
  `squeue -u <user>` and of `sinfo -t idle`.

Runs SLURM commands, so it can take a while; call it in the background.
"""
function workers_overview(mgr::WorkerManager)
    slurm_available = !isnothing(Sys.which(first(mgr.squeue.exec)))
    slurm_available && (update_job_ids!(mgr); update_steps!(mgr))
    script = try
        start_script!(mgr)
    catch e
        String(first(split(sprint(showerror, e), '\n')))
    end
    pids = nprocs() > 1 ? workers() : Int[]
    workers_now = @lock mgr.lock begin
        for pid in pids
            haskey(mgr.attributes, pid) && continue
            # asked once per worker
            mgr.attributes[pid] = nothing
            errormonitor(Threads.@spawn begin
                             attributes = try
                                 worker_attributes(pid)
                             catch
                                 missing
                             end
                             @lock mgr.lock mgr.attributes[pid] = attributes
                         end)
        end
        [(; pid, attributes = mgr.attributes[pid]) for pid in pids]
    end
    step_number(s) = parse.(Int, split(s.id, '.'))
    steps = @lock mgr.lock sort!(reduce(vcat, values(mgr.steps); init = StepInfo[]); by = step_number)
    user = get(ENV, "USER", "")
    slurm = slurm_available ? (; queue = read(`$(mgr.squeue) -u $user`, String), idle = read(`$(mgr.sinfo) -t idle`, String)) : nothing
    return convert(WorkersOverview, (; allocations = allocations(mgr), script, workers = workers_now, steps, slurm))
end
