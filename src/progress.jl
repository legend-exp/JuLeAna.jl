# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# States of a processing step, in the order they are shown; every state after `:running`
# is final.
const STEP_STATES = (:waiting, :running, :done, :failed, :skipped, :stopped, :cancelled)
const FINAL_STEP_STATES = STEP_STATES[3:end]

# A processing step of one period: `run` is the run of a run-level step and `nothing` for
# a partition-level step.
const ProgressKey = Tuple{DataPeriod,Union{Nothing,DataRun},Symbol}

# A message logged on this process while a step ran: `text` may span several lines.
const StepMessage = NamedTuple{(:level, :time, :text),Tuple{LogLevel,DateTime,String}}

# Number of messages kept per step; older ones are dropped.
const STEP_MESSAGE_CAPACITY = 500

const BusyItem = NamedTuple{(:worker, :item, :period, :run, :step, :since, :abandoned),
                            Tuple{Int,String,DataPeriod,Union{Nothing,DataRun},Symbol,DateTime,Bool}}

# Types of the value of `progress`. The field types are fixed, so that the interface code that
# shows the progress is compiled once for every state of a run.
const StepCounts = NamedTuple{STEP_STATES,NTuple{length(STEP_STATES),Int}}
const StepSummary = @NamedTuple{period::DataPeriod, run::Union{Nothing,DataRun}, step::Symbol, state::Symbol, total::Int, done::Int,
                                failed::Int, notrun::Int, workers::Vector{Int}, started::Union{Nothing,DateTime},
                                finished::Union{Nothing,DateTime}, error::Union{Nothing,String}, nmessages::Int, fraction::Float64,
                                rate::Union{Nothing,Float64}, eta::Union{Nothing,Float64}}
const GroupSummary = @NamedTuple{period::DataPeriod, run::Union{Nothing,DataRun}, nsteps::Int, counts::StepCounts, fraction::Float64}
const ProgressSummary = @NamedTuple{started::Union{Nothing,DateTime}, finished::Union{Nothing,DateTime}, fraction::Float64,
                                    eta::Union{Nothing,Float64}, counts::StepCounts, steps::Vector{StepSummary},
                                    groups::Vector{GroupSummary}}

mutable struct StepProgress
    state::Symbol
    total::Int
    done::Int
    failed::Int
    notrun::Int
    # item id => worker the item runs on
    const running::Dict{Int,Int}
    # ids of the items that have not finished yet
    const pending::Set{Int}
    started::Union{Nothing,DateTime}
    items_started::Union{Nothing,DateTime}
    finished::Union{Nothing,DateTime}
    const messages::Vector{StepMessage}
    # error message of a failed step
    error::Union{Nothing,String}
end

function StepProgress()
    return StepProgress(:waiting, 0, 0, 0, 0, Dict{Int,Int}(), Set{Int}(), nothing, nothing, nothing, StepMessage[], nothing)
end

"""
    ProgressStore()

Thread-safe record of the progress of a processing run, filled by
[`run_processing`](@ref) and [`parallel`](@ref) when `run_processing` is given the store
as `progress_store`. It holds one entry per scheduled step of a period (partition level)
or of a run (run level) with the step's state, the number of items handed to `parallel`
and how many of them finished, failed, were not run or are running on which worker.
Messages logged on this process while a step runs are kept with the step (see
[`step_messages`](@ref)) when the logger in use passes them to the store, as
[`JuLeAna.MessageBuffer`](@ref), the logger of the terminal user interface, does.

The store also records the busy workers: every item that a worker runs, from the moment
the item is handed to the worker until its call returns. This record is kept across
processing runs, so that items whose run was stopped without waiting for them stay listed
until their workers are free again.

[`progress`](@ref) returns a copy of the current state with the aggregated progress and
[`busy_workers`](@ref) the busy workers.
"""
mutable struct ProgressStore
    const lock::ReentrantLock
    const keys::Vector{ProgressKey}
    const steps::Dict{ProgressKey,StepProgress}
    # item id => busy worker record, kept across runs
    const busy::Dict{Int,BusyItem}
    # item ids are unique across runs
    next_item::Int
    started::Union{Nothing,DateTime}
    finished::Union{Nothing,DateTime}
end

function ProgressStore()
    return ProgressStore(ReentrantLock(), ProgressKey[], Dict{ProgressKey,StepProgress}(), Dict{Int,BusyItem}(), 0, nothing, nothing)
end

# Start a new processing run with the steps `keys`, all waiting.
function reset_progress!(store::ProgressStore, keys)
    @lock store.lock begin
        empty!(store.keys)
        empty!(store.steps)
        for key in keys
            haskey(store.steps, key) && throw(ArgumentError("progress: step $key is scheduled twice"))
            push!(store.keys, key)
            store.steps[key] = StepProgress()
        end
        store.started, store.finished = now(UTC), nothing
    end
    return store
end

# Set the state of step `key`; `error` is the error message of a failed step.
function set_step_state!(store::ProgressStore, key::ProgressKey, state::Symbol; error::Union{Nothing,AbstractString} = nothing)
    state in STEP_STATES || throw(ArgumentError("progress: unknown step state $(repr(state))"))
    @lock store.lock begin
        step = store.steps[key]
        state === :running && (step.started = now(UTC))
        state in FINAL_STEP_STATES && (step.finished = now(UTC))
        step.state = state
        isnothing(error) || (step.error = String(error))
    end
    return nothing
end

# Keep the message `text` of level `level` with step `key`; a step of an earlier run is
# ignored.
function step_message!(store::ProgressStore, key::ProgressKey, level::LogLevel, text::AbstractString)
    @lock store.lock begin
        step = get(store.steps, key, nothing)
        isnothing(step) && return nothing
        push!(step.messages, (; level, time = now(UTC), text = String(text)))
        length(step.messages) > STEP_MESSAGE_CAPACITY && popfirst!(step.messages)
    end
    return nothing
end

"""
    step_messages(store::ProgressStore, key)
    step_messages(ctrl::DataflowController, key)

Return a copy of the messages logged on this process while step `key` of the current or
last processing run ran, oldest first, as `NamedTuple`s with `level` (a
`Logging.LogLevel`), `time` (UTC) and `text` (possibly several lines). `key` is
`(period, run, step)` with `run = nothing` for a partition-level step. Only the last
$STEP_MESSAGE_CAPACITY messages of a step are kept. Returns an empty vector for a step
that is not part of the run.
"""
function step_messages(store::ProgressStore, key)
    @lock store.lock begin
        step = get(store.steps, key, nothing)
        return isnothing(step) ? StepMessage[] : copy(step.messages)
    end
end

# Set every step that has not reached a final state to `state` and close the run.
function finish_progress!(store::ProgressStore, state::Symbol)
    state in FINAL_STEP_STATES || throw(ArgumentError("progress: $(repr(state)) is not a final step state"))
    @lock store.lock begin
        for key in store.keys
            store.steps[key].state in FINAL_STEP_STATES || set_step_state!(store, key, state)
        end
        store.finished = now(UTC)
    end
    return nothing
end

# Add `n` items of a `parallel` batch to the step `key` and return the id of the first;
# the batch's items have the ids `first:first+n-1`.
function items_queued!(store::ProgressStore, key::ProgressKey, n::Integer)
    @lock store.lock begin
        step = store.steps[key]
        step.total += n
        isnothing(step.items_started) && (step.items_started = now(UTC))
        first = store.next_item + 1
        store.next_item += n
        union!(step.pending, first:store.next_item)
        return first
    end
end

# Item `id` of step `key`, labeled `label`, was handed to `worker`. A retried item moves to
# its new worker.
function item_started!(store::ProgressStore, key::ProgressKey, id::Integer, worker::Integer, label::AbstractString)
    @lock store.lock begin
        store.steps[key].running[id] = worker
        store.busy[id] = (; worker, item = String(label), period = key[1], run = key[2], step = key[3], since = now(UTC), abandoned = false)
    end
    return nothing
end

# Item `id` of step `key` ended with `outcome`: `:done`, `:failed` or `:notrun`. An item
# that was abandoned before (see `items_abandoned!`) only frees its worker.
function item_finished!(store::ProgressStore, key::ProgressKey, id::Integer, outcome::Symbol)
    outcome in (:done, :failed, :notrun) || throw(ArgumentError("progress: unknown item outcome $(repr(outcome))"))
    @lock store.lock begin
        delete!(store.busy, id)
        step = get(store.steps, key, nothing)
        (isnothing(step) || !(id in step.pending)) && return nothing
        delete!(step.pending, id)
        delete!(step.running, id)
        if outcome === :done
            step.done += 1
        elseif outcome === :failed
            step.failed += 1
        else
            step.notrun += 1
        end
    end
    return nothing
end

# Stop waiting for the unfinished items of step `key`: they count as not run, and their
# workers stay listed as busy, marked abandoned, until the items' calls return.
function items_abandoned!(store::ProgressStore, key::ProgressKey)
    @lock store.lock begin
        step = store.steps[key]
        for id in step.pending
            step.notrun += 1
            haskey(store.busy, id) && (store.busy[id] = merge(store.busy[id], (; abandoned = true)))
        end
        empty!(step.pending)
        empty!(step.running)
    end
    return nothing
end

"""
    busy_workers(store::ProgressStore)
    busy_workers(ctrl::DataflowController)

Return the items that workers are running, oldest first, as `NamedTuple`s with `worker`,
`item` (the item's label), `period`, `run` (`nothing` for partition-level steps), `step`,
`since` (UTC time the worker got the item) and `abandoned`. An abandoned item belongs to a
processing run that was stopped without waiting for it; its worker stays busy until the
item's call returns, which for an unresponsive worker never happens. For a controller, the
items of workers that have ended are left out: they wait for a retry on another worker.
"""
function busy_workers(store::ProgressStore)
    @lock store.lock sort!(collect(values(store.busy)); by = b -> b.since)
end

# A running step counts its items plus one unit for the work after the last item, so it
# reaches 1 only when the step itself is final.
function step_fraction(step::StepProgress)
    step.state in FINAL_STEP_STATES && return 1.0
    step.state === :waiting && return 0.0
    return (step.done + step.failed + step.notrun) / (step.total + 1)
end

seconds_between(t0::DateTime, t1::DateTime) = (t1 - t0) / Millisecond(1000)

"""
    progress(store::ProgressStore)
    progress(ctrl::DataflowController)

Return a copy of the progress of the current or last processing run as a
`JuLeAna.ProgressSummary`, a `NamedTuple` with fixed field types:

- `started`, `finished`: UTC times of the run, `nothing` if not (yet) reached.
- `fraction`: overall progress in `[0, 1]`, the mean of the step fractions. A finished,
  failed, skipped, stopped or cancelled step counts as `1`; a waiting step as `0`; a
  running step as `(done + failed + notrun) / (total + 1)` of its items, so that the
  overall progress reaches `1` only after the last step has finished.
- `eta`: estimated seconds until the run finishes, from the elapsed time and `fraction`,
  or `nothing` before any progress or after the run.
- `counts`: number of steps per state, a `NamedTuple` with one field per state
  (`waiting`, `running`, `done`, `failed`, `skipped`, `stopped`, `cancelled`).
- `steps`: one `NamedTuple` per step in schedule order with `period`, `run` (`nothing`
  for partition-level steps), `step`, `state`, `total`, `done`, `failed`, `notrun`,
  `workers` (sorted workers of the running items), `started`, `finished`, `error` (the
  error message of a failed step, else `nothing`), `nmessages` (number of messages kept
  for the step, see [`step_messages`](@ref)), `fraction`,
  `rate` (items done or failed per second since the step queued its first item, up to
  the step's end; `nothing` before the first item ended) and `eta` (seconds for the
  remaining items of a running step at that rate, or `nothing`).
- `groups`: one `NamedTuple` per period (partition level) and per run, in schedule
  order, with `period`, `run`, `nsteps`, `counts` and `fraction` over its steps.
"""
function progress(store::ProgressStore)
    @lock store.lock begin
        t = now(UTC)
        steps = map(store.keys) do key
            s = store.steps[key]
            finished_items = s.done + s.failed + s.notrun
            rate = if !isnothing(s.items_started) && s.done + s.failed > 0
                (s.done + s.failed) / max(seconds_between(s.items_started, something(s.finished, t)), 1e-3)
            else
                nothing
            end
            eta = s.state === :running && !isnothing(rate) ? (s.total - finished_items) / rate : nothing
            (; period = key[1], run = key[2], step = key[3], s.state, s.total, s.done, s.failed, s.notrun,
             workers = sort!(collect(values(s.running))), s.started, s.finished, s.error, nmessages = length(s.messages),
             fraction = step_fraction(s), rate, eta)
        end
        count_states(entries) = NamedTuple{STEP_STATES}(map(st -> count(e -> e.state === st, entries), STEP_STATES))
        fraction = isempty(steps) ? 0.0 : sum(e -> e.fraction, steps) / length(steps)
        eta = if isnothing(store.started) || !isnothing(store.finished) || !(0 < fraction < 1)
            nothing
        else
            seconds_between(store.started, t) * (1 - fraction) / fraction
        end
        groups = map(unique(e -> (e.period, e.run), steps)) do first_entry
            entries = filter(e -> e.period == first_entry.period && e.run == first_entry.run, steps)
            (; first_entry.period, first_entry.run, nsteps = length(entries), counts = count_states(entries),
             fraction = sum(e -> e.fraction, entries) / length(entries))
        end
        return convert(ProgressSummary, (; store.started, store.finished, fraction, eta, counts = count_states(steps), steps, groups))
    end
end

function step_label(e)
    return isnothing(e.run) ? "$(e.period) $(e.step)" : "$(e.period)-$(e.run) $(e.step)"
end

"""
    show_progress(f, store::ProgressStore; interval::Real = 1)

Call `f()` and, while it runs, log the progress in `store` every `interval` seconds as
progress records of ProgressLogging: one bar for the overall progress and one below it for
each running step. A `TerminalLogger` draws these bars below the log messages and keeps
a line with the final state of each step whose bar it closes; other
loggers receive them as `Info` records whose message is a `ProgressLogging.Progress`.
All bars are closed when `f` returns or throws. Returns the value of `f()`.
"""
function show_progress(f, store::ProgressStore; interval::Real = 1)
    overall = uuid4()
    bars = Dict{ProgressKey,UUID}()
    done = Threads.Atomic{Bool}(false)
    function draw()
        p = progress(store)
        @info ProgressLogging.Progress(overall, p.fraction;
                                       name = "Processing: $(p.counts.done + p.counts.skipped)/$(length(p.steps)) steps done, $(p.counts.failed) failed")
        for e in p.steps
            key = (e.period, e.run, e.step)
            items = e.total == 0 ? "" : "$(e.done)/$(e.total) items" * (e.failed > 0 ? ", $(e.failed) failed" : "")
            if e.state === :running
                id = get!(uuid4, bars, key)
                @info ProgressLogging.Progress(id, e.fraction; parentid = overall,
                                               name = step_label(e) * (isempty(items) ? "" : ": " * items))
            elseif haskey(bars, key)
                # a closed bar stays in the terminal as one line with the step's final state
                @info ProgressLogging.Progress(pop!(bars, key), 1.0; parentid = overall, done = true,
                                               name = step_label(e) * ": $(e.state)" * (isempty(items) ? "" : ", " * items))
            end
        end
    end
    drawer = Threads.@spawn while !done[]
        draw()
        sleep(interval)
    end
    try
        return f()
    finally
        done[] = true
        wait(drawer)
        draw()
        for id in values(bars)
            @info ProgressLogging.Progress(id; parentid = overall, done = true)
        end
        @info ProgressLogging.Progress(overall; done = true)
    end
end
