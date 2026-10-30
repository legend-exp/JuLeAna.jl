# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    partition_periods(l200::LegendData, period::DataPeriod)

Return the sorted periods that share a default `cal` or `phy` partition with `period`,
`period` included. The default partitions in `datasets.cal_groupings` and
`datasets.phy_groupings` are the widest: the partitions of single detectors lie within
them.
"""
function partition_periods(l200::LegendData, period::DataPeriod)
    periods = Set([period])
    for category in (:cal, :phy), periods_runs in values(l200.metadata.datasets[Symbol("$(category)_groupings")].default)

        partition = DataPeriod.(collect(keys(periods_runs)))
        period in partition && union!(periods, partition)
    end
    return sort!(collect(periods))
end

"""
    run_processing(cfg::ProcessingConfig, l200, periods, run_steps, partition_steps,
        run_status, partition_status; processors::AbstractDict{Symbol}=PROCESSORS,
        check_dependencies::Bool=true, reprocess::Union{Nothing,Bool}=nothing,
        processor_log_level::Union{Nothing,LogLevel}=cfg.processor_log_level,
        processor_plot_level::Union{Nothing,Symbol}=cfg.processor_plot_level,
        max_parallel_steps::Integer=cfg.max_parallel_steps, stop::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false),
        abandon::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false),
        progress_store::Union{Nothing,ProgressStore}=nothing)

Run the partition-level steps `partition_steps` for every period in `periods` and the
run-level steps `run_steps` for every period and every run listed in `run_status`.
Processor functions are looked up by name in `processors`. `l200` (usually a
`LegendData`) is passed to every processor and to the run-info checks `is_analysis_run`
and `is_lrun`. `run_status` lists the runs to process: every run of a period that has an
entry in the first step's table.

Each step of a period, and at run level of a run, starts as soon as the steps it waits for
have finished, so steps that do not wait for each other run at the same time. A step
waits for the steps that [`waited_processors`](@ref) returns for it in the
[`processor_graph`](@ref) of `cfg`, with `run_steps` and `partition_steps` as the
selected steps:
- a run step for the same run, or, when the graph reaches it through a partition step,
  for all runs of the periods given by [`partition_periods`](@ref) that are in `periods`;
- a run step that a partition step waits for, for all runs of the periods given by
  `partition_periods` that are in `periods`: a partition can contain runs of later
  periods;
- a partition step for the same period.
A partition step whose processor returns `true` finishes only when the same step has
finished for the previous period. Without `check_dependencies` a step waits only for the
steps of its own level, for the same run or period.

Steps that are ready start, and the items they hand to [`parallel`](@ref) get free
workers, in this order (see [`JuLeAna.waiting_chains`](@ref) and [`JuLeAna.WorkerQueue`](@ref)):
the step with the longest chain of selected steps that wait for it first, then the one
with the most selected steps that wait for it, then by rank, name, period and run. With
`max_parallel_steps > 0` at most that many steps run at the same time. A step that is
skipped because the run is not an analysis run (with `cfg.analysis_runs_only`) or not in
the run info counts as finished. `run_status[period][step][run]` and
`partition_status[period][step]` are set to `true` when a step finishes.

When a step throws, no further step starts, and once the running steps have ended a
`CompositeException` of the failures is thrown. Steps that wait for each other in a
circle throw an `ErrorException` that names them. Setting `stop[]` to `true` stops the
run: no further step starts, and [`parallel`](@ref) hands no further items to workers and
throws [`ProcessingStopped`](@ref) once its running items have finished. With `abandon[]`
also `true`, `parallel` throws without waiting for its running items, which go on in the
background. `reprocess`, when not `nothing`, overrides the `reprocess` keyword of every
processor, `processor_log_level`, when not `nothing`, the `log_level` of every
processor (a processor's log records are written at that level, see
[`ProcessorLevelLogger`](@ref)), and `processor_plot_level`, when not `nothing`, the
`plot_level` of every processor (see [`@debug_plot`](@ref)). Plots are saved in the
`plot_formats` of `cfg` (see [`save_plot`](@ref)). A step without an entry in `processors` throws an `ArgumentError` before any
work starts. Return `nothing`.

With a [`ProgressStore`](@ref) as `progress_store`, the store is reset to the scheduled
steps, every step's state is recorded there (`:skipped` for a run that is not processed,
`:failed` or `:stopped` for a step that threw) and `parallel` records the items of the
step that calls it. Steps that never finished are `:stopped` when the run was stopped and
`:cancelled` otherwise.
"""
function run_processing(cfg::ProcessingConfig, l200, periods::AbstractVector{DataPeriod}, run_steps::AbstractVector{Symbol},
                        partition_steps::AbstractVector{Symbol}, run_status::AbstractDict, partition_status::AbstractDict;
                        processors::AbstractDict{Symbol} = PROCESSORS, check_dependencies::Bool = true,
                        reprocess::Union{Nothing,Bool} = nothing, processor_log_level::Union{Nothing,LogLevel} = cfg.processor_log_level,
                        processor_plot_level::Union{Nothing,Symbol} = cfg.processor_plot_level,
                        max_parallel_steps::Integer = cfg.max_parallel_steps, stop::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false),
                        abandon::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false), progress_store::Union{Nothing,ProgressStore} = nothing)
    unregistered = filter(!in(keys(processors)), collect(Iterators.flatten((run_steps, partition_steps))))
    isempty(unregistered) || throw(ArgumentError("run_processing: unregistered processor(s) $(join(unregistered, ", "))"))
    max_parallel_steps >= 0 ||
        throw(ArgumentError("run_processing: max_parallel_steps must be zero (no limit) or positive, got $max_parallel_steps"))
    overrides = isnothing(reprocess) ? (;) : (; reprocess)
    # every step lists the same runs of the period
    period_runs = Dict(period => sort!(collect(keys(last(first(run_status[period]))))) for period in periods if !isempty(run_steps))
    spec(step) = haskey(cfg.processors, step) ? cfg.processors[step] : cfg.p_processors[step]
    # settings of the running processor, also seen by `parallel`
    step_scope(step) = (ERROR_PLOTS => spec(step).error_plots, PROCESSOR_LOG_LEVEL => something(processor_log_level, spec(step).log_level),
                        PLOT_LEVEL => something(processor_plot_level, spec(step).plot_level), PLOT_FORMATS => cfg.plot_formats)

    waits = waited_processors(processor_graph(cfg), Iterators.flatten((run_steps, partition_steps)))
    if !check_dependencies
        same_level(step, (u, same_run)) = spec(u).level === spec(step).level && (spec(step).level === :partition || same_run)
        waits = Dict(step => filter(w -> same_level(step, w), w_step) for (step, w_step) in waits)
    end
    chains = waiting_chains(waits)
    spans = Dict{DataPeriod,Vector{DataPeriod}}()
    span(period) = get!(() -> filter(in(periods), partition_periods(l200, period)), spans, period)
    # the steps that the step `node` waits for
    function predecessors((period, run, step))
        out = ProgressKey[]
        for (u, same_run) in waits[step]
            if spec(u).level === :partition
                push!(out, (period, nothing, u))
            elseif same_run
                push!(out, (period, run, u))
            else
                append!(out, ProgressKey[(q, r, u) for q in span(period) for r in period_runs[q]])
            end
        end
        return out
    end

    nodes = vcat(ProgressKey[(period, nothing, step) for period in periods for step in partition_steps],
                 ProgressKey[(period, run, step) for period in periods for run in get(period_runs, period, DataRun[]) for step in run_steps])
    isnothing(progress_store) || reset_progress!(progress_store, nodes)
    mark(key, state; error = nothing) = isnothing(progress_store) || set_step_state!(progress_store, key, state; error)
    blockers = Dict{ProgressKey,Set{ProgressKey}}(node => Set(predecessors(node)) for node in nodes)
    dependents = Dict{ProgressKey,Vector{ProgressKey}}(node => ProgressKey[] for node in nodes)
    for (node, preds) in blockers, pred in preds

        push!(dependents[pred], node)
    end
    priority((period, run, step)) = (-chains[step].chain, -chains[step].successors, spec(step).rank, step, period.no,
                                     isnothing(run) ? -1 : run.no)
    ready = sort!(ProgressKey[node for node in nodes if isempty(blockers[node])]; by = priority)

    # Run the step `node` and return whether it was skipped and, for a partition step,
    # whether it must wait for the same step of the previous period.
    function run_node((period, run, step))
        node = (period, run, step)
        if isnothing(run)
            only_first_period = DataPeriod(period.no - 1) in periods
            kwargs = merge(NamedTuple(spec(step).kwargs), (; only_first_period), overrides)
            @info "Process $step of $period"
            lower = tracked(node) do
                return with(() -> processors[step](cfg, l200, period; kwargs...), step_scope(step)..., STEP_PRIORITY => priority(node))
            end
            return (; skipped = false, lower = lower === true)
        end
        key = (period, run, spec(step).category)
        if cfg.analysis_runs_only && !is_analysis_run(l200, key)
            @warn "$period-$run-$(spec(step).category) is not an analysis run, skip $step"
        elseif !is_lrun(l200, key)
            @warn "$period-$run-$(spec(step).category) is not in runinfo, skip $step"
        else
            @info "Process $step of $period-$run"
            tracked(node) do
                with(step_scope(step)..., STEP_PRIORITY => priority(node)) do
                    return processors[step](cfg, l200, period, run; merge(NamedTuple(spec(step).kwargs), overrides)...)
                end
            end
            flush(stdout)
            return (; skipped = false, lower = false)
        end
        mark(node, :skipped)
        return (; skipped = true, lower = false)
    end
    # Run `f` as the step `key`, recording its state and making it the progress entry of `parallel`.
    function tracked(f, key)
        mark(key, :running)
        try
            return isnothing(progress_store) ? f() : with(f, PROGRESS_STEP => (progress_store, key))
        catch e
            e isa ProcessingStopped ? mark(key, :stopped) : mark(key, :failed; error = sprint(showerror, e))
            rethrow()
        end
    end

    finished = Set{ProgressKey}()
    # partition steps that finish when the same step of the previous period has finished
    after_previous = Dict{ProgressKey,Vector{ProgressKey}}()
    function finish!(node, skipped)
        push!(finished, node)
        period, run, step = node
        skipped || mark(node, :done)
        if isnothing(run)
            partition_status[period][step] = true
            @info "Finished $step of $period"
        else
            run_status[period][step][run] = true
            skipped || @info "Finished $step of $period-$run"
        end
        for d in dependents[node]
            delete!(blockers[d], node)
            isempty(blockers[d]) && insert!(ready, searchsortedfirst(ready, d; by = priority), d)
        end
        return foreach(n -> finish!(n, false), pop!(after_previous, node, ProgressKey[]))
    end

    done_nodes = Channel{ProgressKey}(Inf)
    tasks = Dict{ProgressKey,Task}()
    errors = Any[]
    try
        # `parallel` reads the stop flags and the worker queue from the scope; spawned tasks inherit it.
        with(PROCESSING_STOP => stop, PROCESSING_ABANDON => abandon, WORKER_QUEUE => WorkerQueue()) do
            while true
                while !isempty(ready) && isempty(errors) && !stop[] && (max_parallel_steps == 0 || length(tasks) < max_parallel_steps)
                    # local to the iteration: each task must report its own step
                    started = popfirst!(ready)
                    tasks[started] = Threads.@spawn try
                        run_node(started)
                    finally
                        put!(done_nodes, started)
                    end
                end
                isempty(tasks) && break
                node = take!(done_nodes)
                result = try
                    fetch(pop!(tasks, node))
                catch e
                    push!(errors, e)
                    continue
                end
                previous = (DataPeriod(node[1].no - 1), nothing, node[3])
                if result.lower && check_dependencies && !(previous in finished)
                    push!(get!(Vector{ProgressKey}, after_previous, previous), node)
                else
                    finish!(node, result.skipped)
                end
            end
        end
        if isempty(errors) && !stop[] && length(finished) < length(nodes)
            stuck = [join(filter(!isnothing, n), "-") for n in nodes if !(n in finished)]
            push!(errors, ErrorException("run_processing: these steps wait for each other in a circle: $(join(stuck, ", "))"))
        end
        stop[] && isempty(errors) && length(finished) < length(nodes) && push!(errors, ProcessingStopped())
    finally
        # steps that never finished: stopped by the user or cancelled by a failure
        isnothing(progress_store) || finish_progress!(progress_store, stop[] ? :stopped : :cancelled)
    end
    isempty(errors) || throw(CompositeException(errors))
    return nothing
end
