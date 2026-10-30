"""
    ProcessingStopped()

Exception thrown by [`parallel`](@ref) when processing was stopped while the batch ran:
items that had not started are not run, and the processor that called `parallel` ends
without writing results.
"""
struct ProcessingStopped <: Exception end

function Base.showerror(io::IO, ::ProcessingStopped)
    return print(io, "ProcessingStopped: processing was stopped")
end

# Stop flag of the current processing run, set by `run_processing`; `nothing` outside of it.
const PROCESSING_STOP = ScopedValue{Union{Nothing,Threads.Atomic{Bool}}}(nothing)

# Flag of the current processing run to stop waiting for running items; `nothing` outside of it.
const PROCESSING_ABANDON = ScopedValue{Union{Nothing,Threads.Atomic{Bool}}}(nothing)

# Progress entry of the current processing step, set by `run_processing`; `nothing` outside of it.
const PROGRESS_STEP = ScopedValue{Union{Nothing,Tuple{ProgressStore,ProgressKey}}}(nothing)

# Called by `StoppablePool` with each worker it hands out to the current item of `parallel`.
const ITEM_STARTED = ScopedValue{Any}(nothing)

# Worker pool that hands out no worker once `stop` is set: `take!` throws
# `ProcessingStopped` instead, also while it waits for a free worker. That keeps a stop
# from hanging when no worker will become free, e.g. after all workers were stopped.
struct StoppablePool{P<:AbstractWorkerPool} <: AbstractWorkerPool
    pool::P
    stop::Threads.Atomic{Bool}
end

function Base.take!(p::StoppablePool)
    p.stop[] && throw(ProcessingStopped())
    taker = Threads.@spawn take!(p.pool)
    while !istaskdone(taker)
        if p.stop[]
            # the worker the taker gets later goes back to the pool
            errormonitor(Threads.@spawn put!(p.pool, fetch(taker)))
            throw(ProcessingStopped())
        end
        sleep(0.2)
    end
    worker = fetch(taker)
    if p.stop[]
        put!(p.pool, worker)
        throw(ProcessingStopped())
    end
    started = ITEM_STARTED[]
    isnothing(started) || started(worker)
    return worker
end

Base.put!(p::StoppablePool, worker::Int) = put!(p.pool, worker)

# An item that waits in a `WorkerQueue`; `result` is the worker it gets or the exception
# that ended the wait.
mutable struct QueuedItem
    const key::Any
    const seq::Int
    const ready::Threads.Event
    result::Any
end

"""
    JuLeAna.WorkerQueue()

Order in which the waiting items of [`parallel`](@ref) get free workers. [`run_processing`](@ref)
sets one queue for all steps of a run. A free worker goes to the waiting item with the
smallest key, and among equal keys to the item that came first. The key of an item is the
priority of its step in `run_processing` followed by the item's position, so the items of a
step get workers in their order.

Every waiting item adds one task that takes a worker from the pool, and that task hands the
worker to the item that is first at that moment. These tasks wait side by side, so the
initialization of new workers, which happens when a worker is taken, also runs side by side.
"""
mutable struct WorkerQueue
    const lock::ReentrantLock
    # sorted by `(key, seq)`
    const waiting::Vector{QueuedItem}
    seq::Int
end

WorkerQueue() = WorkerQueue(ReentrantLock(), QueuedItem[], 0)

# Worker queue of the current processing run, set by `run_processing`; `nothing` outside of it.
const WORKER_QUEUE = ScopedValue{Union{Nothing,WorkerQueue}}(nothing)

# Priority of the current processing step in its `WORKER_QUEUE`, set by `run_processing`.
const STEP_PRIORITY = ScopedValue{Any}(nothing)

# Worker pool of one item of `parallel` that gets its worker from `pool` through `queue`.
struct QueuedPool{P<:AbstractWorkerPool} <: AbstractWorkerPool
    pool::P
    queue::WorkerQueue
    key::Any
end

function Base.take!(p::QueuedPool)
    q = p.queue
    item = @lock q.lock begin
        item = QueuedItem(p.key, q.seq += 1, Threads.Event(), nothing)
        insert!(q.waiting, searchsortedfirst(q.waiting, item; by = i -> (i.key, i.seq)), item)
        item
    end
    # The worker may go to another item, so the task must not report it as this item's.
    errormonitor(Threads.@spawn with(() -> serve_first!(p), ITEM_STARTED => nothing))
    wait(item.ready)
    item.result isa Exception && throw(item.result)
    started = ITEM_STARTED[]
    isnothing(started) || started(item.result)
    return item.result::Int
end

Base.put!(p::QueuedPool, worker::Int) = put!(p.pool, worker)

# Take a worker from `p.pool`, or the exception that prevents it, and hand it to the first
# item of `p.queue`. Each waiting item adds one call, so the queue is not empty when it ends.
function serve_first!(p::QueuedPool)
    result = try
        take!(p.pool)
    catch e
        e
    end
    item = @lock p.queue.lock popfirst!(p.queue.waiting)
    item.result = result
    notify(item.ready)
    return nothing
end

"""
    failure_log(log_nt, itr, message::AbstractString)

Build the report row for an item of `parallel` that threw. `log_nt` is the processor's
`NamedTuple{names}` row type and `message` the truncated error text. The status column
is `ProcessStatus(0)` and every column without data is filled with `"-"`.

Methods exist for `FileKey` items, giving `(itr, status, "-"..., message)`, and for
`NamedTuple` items with `detector` and `usability` fields, giving
`(detector, usability, [psd_usability,] [partition,] status, "-"..., message)`; the
`psd_usability` column is present when `log_nt` has a `psd_usability` column and the
partition column when it has a `Partition` column. A new item type for [`parallel`](@ref)
needs its own `failure_log` method.
"""
function failure_log(log_nt::Type{<:NamedTuple}, itr::FileKey, message::AbstractString)
    return log_nt((itr, ProcessStatus(0), fill("-", length(fieldnames(log_nt)) - 3)..., message))
end

function failure_log(log_nt::Type{<:NamedTuple}, itr::NamedTuple, message::AbstractString)
    haskey(itr, :detector) && haskey(itr, :usability) ||
        throw(ArgumentError("failure_log needs `detector` and `usability` fields, got $(keys(itr))"))
    lead = (itr.detector, detector_status(itr.usability))
    :psd_usability in fieldnames(log_nt) && (lead = (lead..., detector_status(itr.psd_usability)))
    :Partition in fieldnames(log_nt) && (lead = (lead..., itr.partition))
    return log_nt((lead..., ProcessStatus(0), fill("-", length(fieldnames(log_nt)) - length(lead) - 2)..., message))
end

# Call `advance()` once for each task in `tasks` as it finishes, checking every `poll` seconds;
# return when all tasks are done.
function watch_tasks(advance, tasks::AbstractArray{Task}; poll::Real = 2)
    counted = fill!(similar(tasks, Bool), false)
    while !all(counted)
        for i in eachindex(tasks, counted)
            if !counted[i] && istaskdone(tasks[i])
                counted[i] = true
                advance()
            end
        end
        all(counted) || sleep(poll)
    end
    return nothing
end

"""
    parallel(f, iterator::AbstractArray, log_nt; timeout::Real=0, retry::Bool=false, process_name::AbstractString="")
    parallel(iterator::AbstractArray, log_nt; kwargs...) do itr
        ...
    end

Apply `f` to every element of `iterator` on the ParallelProcessingTools worker pool and
return an array of `itr => f(itr)` pairs with the same shape and axes as `iterator`.
The function comes first, as in `map`, so a `do`-block can supply it. Inside
[`run_processing`](@ref) with a [`ProgressStore`](@ref), each item's start, worker and
outcome are recorded for the current step; otherwise a progress bar labeled
`process_name` shows the finished items.

`log_nt` is the `NamedTuple` type of the processor's report rows. On success `f` returns a
`NamedTuple` with at least the fields `processed::Bool` and `log`, a row of type `log_nt`
(or a `Dict` of such rows), so that successful and failed items have the same shape for
[`master_status`](@ref) and the report.
An item whose result has `skipped = true`, which partition steps return for a detector
left to the step of an earlier period, counts as not run in the progress.

An item whose `f` throws, or exceeds `timeout` seconds when `timeout > 0`, does not abort
the batch: its pair is `itr => (processed = false, log = failure_log(log_nt, itr, msg))`.
A timed-out item's worker process is terminated and not replaced; an item on the main
process keeps running in the background. With `retry = true`, each item gets up to three
attempts after a worker loss or a timeout; an error thrown by `f` is not retried.

Element types without a [`failure_log`](@ref) method for `log_nt` are rejected with an
`ArgumentError` before any work starts.

Inside [`run_step`](@ref), `f` sees the detector selection of `run_step` also on the
workers (see [`redo_detector`](@ref)); with `outputs = :temp`, items whose `detector` is not
selected are not run and are missing from the result. For items with a `detector` field,
`parallel` throws an `ArgumentError` before any work starts if a chosen detector is not
among them.

Inside [`run_step`](@ref) with `debug = true`, the items run one after the other in the
calling task, without workers and without `timeout`.

Inside [`run_processing`](@ref), a stop of the processing run takes effect here: items that
have not been handed to a worker are not run, items already running finish, and `parallel`
then throws [`ProcessingStopped`](@ref) instead of returning. When the run is stopped without
waiting for running items, `parallel` throws right away and the running items go on in
the background; their workers return to the pool when the items end. The items of all
running steps get free workers in the order of the run's [`JuLeAna.WorkerQueue`](@ref).

# Examples
```julia
using LegendDataManagement: FileKey, ProcessStatus
Row = NamedTuple{(:Filekey, :Status, :Events, :Error)}
filekeys = [FileKey("l200-p03-r000-cal-20230311T235840Z")]
results = parallel(filekeys, Row; process_name = "count events") do fk
    (processed = true, log = Row((fk, ProcessStatus(1), 1000, "")))
end
master_status(results)  # process_succeeded
```
"""
function parallel(f, iterator::AbstractArray, log_nt::Type{<:NamedTuple}; timeout::Real = 0, retry::Bool = false,
                  process_name::AbstractString = "")
    for T in unique(typeof.(iterator))
        hasmethod(failure_log, Tuple{Type{log_nt},T,String}) || throw(ArgumentError("parallel: no failure_log method for items of type $T"))
    end
    # ScopedValues do not reach the workers: the item function sets those of `run_step` and the item again
    selection, write, error_plots, log_level, plot_level, plot_formats = DETECTOR_SELECTION[], WRITE_PARS[], ERROR_PLOTS[],
                                                                         PROCESSOR_LOG_LEVEL[], PLOT_LEVEL[], PLOT_FORMATS[]
    if !isnothing(selection) && all(itr -> hasproperty(itr, :detector), iterator)
        item_detectors = Set(string(itr.detector) for itr in iterator)
        unknown = setdiff(selection, item_detectors)
        isempty(unknown) || throw(ArgumentError("parallel: the detectors $(join(sort!(collect(unknown)), ", ")) chosen in " *
                                                "`run_step` are not among the items; the items have the detectors $(join(sort!(collect(item_detectors)), ", "))"))
    end
    if !isnothing(selection) && !write
        # `run_step` with temporary outputs: detectors that are not selected are not run
        iterator = filter(itr -> !hasproperty(itr, :detector) || string(itr.detector) in selection, vec(iterator))
    end
    run_item(itr) = with(() -> f(itr), DETECTOR_SELECTION => selection, WRITE_PARS => write, ERROR_PLOTS => error_plots,
                         PROCESSOR_LOG_LEVEL => log_level, PLOT_LEVEL => plot_level, PLOT_FORMATS => plot_formats, CURRENT_ITEM => itr)
    stop = PROCESSING_STOP[]
    pool = isnothing(stop) ? ppt_worker_pool() : StoppablePool(ppt_worker_pool(), stop)
    queue, step_priority = WORKER_QUEUE[], STEP_PRIORITY[]
    item_pool(id) = isnothing(queue) ? pool : QueuedPool(pool, queue, (step_priority, id))
    step = PROGRESS_STEP[]
    first_id = isnothing(step) ? 0 : items_queued!(step..., length(iterator))
    flush(stdout)
    # assign tasks to workers
    # Known Caveat: Split broadcasting over iterator and fetch of results in two separate lines, otherwise weird things with onworker going on
    failure_row(itr, e) = itr => (processed = false, log = failure_log(log_nt, itr, truncate_error(e)))
    # one progress id per item, with the axes of `iterator`
    ids = first_id .+ (LinearIndices(iterator) .- first(LinearIndices(iterator)))
    label(itr) = string(hasproperty(itr, :detector) ? itr.detector : itr)
    item_outcome(res) = res isa NamedTuple && get(res, :skipped, false) === true ? :notrun : :done
    if !isnothing(DEBUG_CAPTURE[])
        result = map(iterator, ids) do itr, id
            !isnothing(stop) && stop[] && throw(ProcessingStopped())
            isnothing(step) || item_started!(step..., id, myid(), label(itr))
            item_result, outcome = try
                res = run_item(itr)
                itr => res, item_outcome(res)
            catch e
                e isa InterruptException && rethrow()
                failure_row(itr, e), :failed
            end
            isnothing(step) || item_finished!(step..., id, outcome)
            return item_result
        end
        record = STEP_RECORD[]
        isnothing(record) || append!(record.results, vec(result))
        return result
    end
    tasks = broadcast(iterator, ids) do itr, id
        Threads.@spawn begin
            started = isnothing(step) ? nothing : worker -> item_started!(step..., id, worker, label(itr))
            result, outcome = try
                # Past `maxtime`, onworker terminates the worker (never the main process) and
                # counts the timeout as a failed try; the last failure lands in the catch below.
                with(ITEM_STARTED => started) do
                    onworker(; pool = item_pool(id), tries = retry ? 3 : 1, label = "$itr", maxtime = timeout) do
                        try
                            res = run_item(itr)
                            return itr => res, item_outcome(res)
                        catch e
                            # Caught here so that `retry` only covers worker loss and timeouts, not errors in `f`.
                            @debug "Write Error log for $(itr): $e"
                            return failure_row(itr, e), :failed
                        end
                    end
                end
            catch e
                e isa TaskFailedException && (e = e.task.exception)
                @debug "Worker call failed for $(itr): $e"
                failure_row(itr, e), e isa ProcessingStopped ? :notrun : :failed
            end
            isnothing(step) || item_finished!(step..., id, outcome)
            result
        end
    end
    if isnothing(step)
        p = Progress(length(iterator); desc = process_name, showspeed = true, dt = 0.5)
        update!(p)
        errormonitor(Threads.@spawn watch_tasks(() -> next!(p), tasks))
    end
    abandon = PROCESSING_ABANDON[]
    if !isnothing(abandon)
        while !abandon[] && !all(istaskdone, tasks)
            sleep(0.2)
        end
        if !all(istaskdone, tasks)
            # the running items go on in the background and free their workers when done
            isnothing(step) || items_abandoned!(step...)
            throw(ProcessingStopped())
        end
    end
    # fetch results
    result = fetch.(tasks)

    flush(stdout)
    !isnothing(stop) && stop[] && throw(ProcessingStopped())
    record = STEP_RECORD[]
    isnothing(record) || append!(record.results, vec(result))
    return result
end
