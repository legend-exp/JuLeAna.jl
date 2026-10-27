# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    abstract type ControllerCommand

Supertype of the commands that [`dispatch!`](@ref) applies to a [`DataflowController`](@ref).
"""
abstract type ControllerCommand end

"""
    LoadSession()

Set up the session from the controller's command line options with
[`setup_session`](@ref): read the config and the LEGEND data and start the workers. Runs
in the background; the controller is `:loading` until it is `:ready`. Allowed when the
controller is `:idle`.
"""
struct LoadSession <: ControllerCommand end

"""
    ReloadConfig()

Read the processing config file again with the original command line options, keeping
the log directory, and reset the selection to the config's periods, runs and enabled
processors. Drops all kwarg overrides. Runs in the background like [`LoadSession`](@ref).
"""
struct ReloadConfig <: ControllerCommand end

"""
    SelectPeriods(periods)

Select the periods to process, given as `DataPeriod`s or anything `DataPeriod` accepts.
Every period must be in the runinfo of the dataset. Periods that stay selected keep their runs.
"""
struct SelectPeriods <: ControllerCommand
    periods::Vector{DataPeriod}
    SelectPeriods(periods) = new(DataPeriod[DataPeriod(p) for p in periods])
end

"""
    SelectRuns(runs)

Select the runs to process.

- `nothing` selects all runs of the selected periods.
- A vector of `DataRun`s (or anything `DataRun` accepts) selects the same runs in every
  selected period; every run must be available in at least one selected period.
- A dict of period => runs (keys and values as `DataPeriod` and `DataRun` accept)
  selects exactly these periods, each with its runs, where `nothing` stands for all runs
  of the period. Every period and every run of it must be in the dataset.
"""
struct SelectRuns <: ControllerCommand
    runs::Union{Nothing,Vector{DataRun},Dict{DataPeriod,Union{Nothing,Vector{DataRun}}}}
    SelectRuns(::Nothing) = new(nothing)
    function SelectRuns(runs::AbstractDict)
        return new(Dict{DataPeriod,Union{Nothing,Vector{DataRun}}}(DataPeriod(p) =>
                                                                       (isnothing(r) ? nothing : DataRun[DataRun(x) for x in r])
                                                                   for (p, r) in runs))
    end
    SelectRuns(runs) = new(DataRun[DataRun(r) for r in runs])
end

"""
    SelectSteps(run_steps, partition_steps)

Select the run-level and partition-level processors to run, by name. Every name must be
a processor of that level in the config, enabled or not. The steps run in the order of
their dependencies, see [`run_processing`](@ref).
"""
struct SelectSteps <: ControllerCommand
    run_steps::Vector{Symbol}
    partition_steps::Vector{Symbol}
    function SelectSteps(run_steps, partition_steps)
        return new(Symbol.(run_steps), Symbol.(partition_steps))
    end
end

"""
    SetReprocess(reprocess::Union{Nothing,Bool})

Set the `reprocess` keyword passed to every processor: `true` or `false` override the
config, `nothing` keeps the configured values.
"""
struct SetReprocess <: ControllerCommand
    reprocess::Union{Nothing,Bool}
end

"""
    SetProcessorLogLevel(level::Union{Nothing,Logging.LogLevel})

Set the level at which the records of every processor are written to the log files,
for example `Logging.Debug`, replacing the `log_level` of each processor entry.
`nothing` keeps the levels of the processor entries. The level starts as
`processor_log_level` of the config.
"""
struct SetProcessorLogLevel <: ControllerCommand
    level::Union{Nothing,LogLevel}
end

"""
    SetProcessorPlotLevel(level::Union{Nothing,Symbol})

Set the plot level of every processor, `:info` or `:debug`, replacing the `plot_level` of
each processor entry. `nothing` keeps the levels of the processor entries. The level
starts as `processor_plot_level` of the config.
"""
struct SetProcessorPlotLevel <: ControllerCommand
    level::Union{Nothing,Symbol}
end

"""
    SetCheckDependencies(check::Bool)

Choose whether a processing run rebuilds the dependency graph for the selected steps and
waits for their dependencies (`true`), or runs the selected steps on the current graph
without waiting (`false`).
"""
struct SetCheckDependencies <: ControllerCommand
    check::Bool
end

"""
    SetAnalysisRunsOnly(only::Bool)

Choose whether processing skips the runs that are not analysis runs (`true`) or processes
every run in the run info (`false`), instead of the setting of the config.
"""
struct SetAnalysisRunsOnly <: ControllerCommand
    only::Bool
end

"""
    SetRunmode(runmode::Symbol)

Use the run mode `runmode`, `:local` or `:slurm`, instead of the one of the config, for the
next worker allocations; running allocations are not changed.
"""
struct SetRunmode <: ControllerCommand
    runmode::Symbol
    function SetRunmode(runmode)
        runmode in (:local, :slurm) || throw(ArgumentError("SetRunmode: runmode must be :local or :slurm, got $(repr(runmode))"))
        return new(runmode)
    end
end

"""
    SetRunmodeSettings(; local_n = nothing, local_julia_settings = nothing,
        slurm_flags = nothing, slurm_julia_settings = nothing)

Use the given settings of the run modes instead of those of the config, for the next
worker allocations and the start script; running allocations are not changed. Also
possible during a processing run, which keeps its config. Each argument that is `nothing`
keeps the setting in effect. `local_n` is the number of local workers and must be
positive; `local_julia_settings`, `slurm_flags` and `slurm_julia_settings` are vectors of
strings, the extra options of the local Julia processes, the flags of the SLURM job and
the options of the Julia processes it starts.
"""
struct SetRunmodeSettings <: ControllerCommand
    local_n::Union{Nothing,Int}
    local_julia_settings::Union{Nothing,Vector{String}}
    slurm_flags::Union{Nothing,Vector{String}}
    slurm_julia_settings::Union{Nothing,Vector{String}}
    function SetRunmodeSettings(; local_n = nothing, local_julia_settings = nothing, slurm_flags = nothing, slurm_julia_settings = nothing)
        isnothing(local_n) || local_n > 0 || throw(ArgumentError("SetRunmodeSettings: local_n must be positive, got $local_n"))
        return new(local_n, local_julia_settings, slurm_flags, slurm_julia_settings)
    end
end

"""
    SetKwarg(step, key, value)

Override the keyword argument `key` of the processor `step` for this session. The
processor function must accept `key`.
"""
struct SetKwarg <: ControllerCommand
    step::Symbol
    key::Symbol
    value::Any
    SetKwarg(step, key, value) = new(Symbol(step), Symbol(key), value)
end

"""
    SetStepLevel(step, key, value)

Override the log level (`key = :log_level`, `value` a `LogLevel` or one of `"debug"`,
`"info"`, `"warn"` and `"error"`) or the plot level (`key = :plot_level`, `value` `:info` or
`:debug`) of the processor `step` for this session. A level set for all processors with
[`SetProcessorLogLevel`](@ref) or [`SetProcessorPlotLevel`](@ref) takes precedence.
"""
struct SetStepLevel <: ControllerCommand
    step::Symbol
    key::Symbol
    value::Union{LogLevel,Symbol}
    function SetStepLevel(step, key, value)
        key = Symbol(key)
        if key === :log_level
            value isa LogLevel ||
                haskey(LOG_LEVELS, string(value)) ||
                throw(ArgumentError("SetStepLevel: the log level must be \"debug\", \"info\", \"warn\" or \"error\", got $(repr(value))"))
            value = value isa LogLevel ? value : LOG_LEVELS[string(value)]
        elseif key === :plot_level
            value = Symbol(value)
            value in PLOT_LEVEL_VALUES || throw(ArgumentError("SetStepLevel: the plot level must be :info or :debug, got $(repr(value))"))
        else
            throw(ArgumentError("SetStepLevel: the key must be :log_level or :plot_level, got $(repr(key))"))
        end
        return new(Symbol(step), key, value)
    end
end

"""
    SetStepSetting(step, key, value)

Override a setting of the processor `step` for this session. The settings are
`:category` (`:cal` or `:phy`), `:rank` (an `Int`), `:dependencies` (a vector of processor
names), `:error_plots` (a `Bool`), `:detectors` (an `ljl_propfunc` expression as a
string, or `nothing` for none) and `:report_status` (a table as in
[`ProcessorSpec`](@ref), of which the unset entries take [`DEFAULT_REPORT_STATUS`](@ref)).
The command throws an `ArgumentError` and leaves the session unchanged when the value does not
fit the setting or the resulting processing config is invalid, for example for an
invalid detector expression, a dependency on an unknown processor or a dependency cycle.
Use [`SetKwarg`](@ref) for the keyword arguments, [`SetStepLevel`](@ref) for the log and the
plot level and [`SelectSteps`](@ref) for whether the processor is selected.
"""
struct SetStepSetting <: ControllerCommand
    step::Symbol
    key::Symbol
    value::Any
    function SetStepSetting(step, key, value)
        key = Symbol(key)
        key in STEP_SETTINGS ||
            throw(ArgumentError("SetStepSetting: the key must be one of $(join(STEP_SETTINGS, ", ")), got $(repr(key))"))
        if key === :category
            value isa Union{Symbol,AbstractString} ||
                throw(ArgumentError("SetStepSetting: `category` must be :cal or :phy, got $(repr(value))"))
            value = Symbol(value)
        elseif key === :rank
            value isa Int || throw(ArgumentError("SetStepSetting: `rank` must be an Int, got $(repr(value))"))
        elseif key === :error_plots
            value isa Bool || throw(ArgumentError("SetStepSetting: `error_plots` must be a Bool, got $(repr(value))"))
        elseif key === :dependencies
            value isa AbstractVector || throw(ArgumentError("SetStepSetting: `dependencies` must be a vector of names, got $(repr(value))"))
            value = Symbol[Symbol(v) for v in value]
        elseif key === :detectors
            isnothing(value) ||
                value isa AbstractString ||
                throw(ArgumentError("SetStepSetting: `detectors` must be a string or nothing, got $(repr(value))"))
            value = isnothing(value) ? nothing : String(value)
        else
            value isa AbstractDict || throw(ArgumentError("SetStepSetting: `report_status` must be a table, got $(repr(value))"))
            value = _report_status(value, "report_status")
        end
        return new(Symbol(step), key, value)
    end
end

"""
    ResetKwargs(step = nothing, key = nothing)

Drop the kwarg, level and setting overrides (see [`SetKwarg`](@ref), [`SetStepLevel`](@ref)
and [`SetStepSetting`](@ref)) of all processors, of the processor `step`, or only the
override of `key` (a kwarg, `:log_level`, `:plot_level` or a setting of `SetStepSetting`)
of the processor `step`. The command throws an `ArgumentError` and changes nothing when
the config without the dropped overrides is invalid, for example when a dependency cycle
would result.
"""
struct ResetKwargs <: ControllerCommand
    step::Union{Nothing,Symbol}
    key::Union{Nothing,Symbol}
    function ResetKwargs(step = nothing, key = nothing)
        isnothing(step) && !isnothing(key) && throw(ArgumentError("ResetKwargs: a key needs a processor"))
        return new(isnothing(step) ? nothing : Symbol(step), isnothing(key) ? nothing : Symbol(key))
    end
end

"""
    ResetDependencyGraph()

Mark the selected steps as unfinished for the selected periods and runs.
"""
struct ResetDependencyGraph <: ControllerCommand end

"""
    StartProcessing()

Run the selected steps over the selected periods and runs in the background with
[`run_processing`](@ref), using the config with the session's kwarg overrides. The
controller is `:running` until the run ends; the outcome is `:finished`, `:failed` or
`:stopped`. [`progress`](@ref) shows the progress of the run. When the run ends, its
steps are added to the processing history of the data production (see
[`JuLeAna.append_history`](@ref) and [`JuLeAna.history_path`](@ref)). Throws an `ArgumentError` when no step is selected or a selected processor
does not accept its keyword arguments.
"""
struct StartProcessing <: ControllerCommand end

"""
    StopProcessing(; force::Bool = false)

Stop the processing run: no further step or item starts, items running on workers
finish, and the run ends as `:stopped`. With `force = true`, the run ends without waiting
for the running items. They count as not run, go on in the background and keep their
workers busy until they end; [`busy_workers`](@ref) lists them as abandoned. No worker is
stopped.
"""
struct StopProcessing <: ControllerCommand
    force::Bool
end
StopProcessing(; force::Bool = false) = StopProcessing(force)

"""
    WriteConfig(path::AbstractString)
    WriteConfig()

Write the processing config file of the session to `path` with the current settings of
the session: the kwarg, level and setting overrides are applied to the processor entries, every processor
is `enabled` exactly when it is selected, and `processing.analysis_runs_only` is the
setting in effect. Without `path`, the file is `processing_config.yaml` in the
[`JuLeAna.production_config_dir`](@ref), which is created if needed. An existing file
at the path is first copied to `path * ".bak"`. The file is written as YAML from the parsed config, so comments and the formatting of the
original file are not kept, and the keys are not in the order of the original file. The written file becomes the config file of the session, which
[`ReloadConfig`](@ref) reads.
"""
struct WriteConfig <: ControllerCommand
    path::Union{Nothing,String}
end

WriteConfig() = WriteConfig(nothing)

"""
    AddWorkers()

Start a worker allocation: run the worker start script of the session in the background
(see [`JuLeAna.add_workers!`](@ref)). The workers join the worker pool when they have
started.
"""
struct AddWorkers <: ControllerCommand end

"""
    CancelAllocation(id::Integer)

Cancel the worker allocation `id` (see [`JuLeAna.cancel_allocation!`](@ref)): its workers end
and items running on them fail.
"""
struct CancelAllocation <: ControllerCommand
    id::Int
end

"""
    CancelAll()

Cancel every running worker allocation of the session (see [`JuLeAna.cancel_all!`](@ref)).
"""
struct CancelAll <: ControllerCommand end

"""
    CreateProduction(spec::ProductionSpec)

Create the data production `spec` describes with [`JuLeAna.create_production`](@ref) in the
background and switch the session to it: cancel all worker allocations (their workers use
the data of the previous production), set `LEGEND_DATA_CONFIG` of this process to the new
`config.yaml`, and load a session with the [`JuLeAna.install_default_config`](@ref) file of the new
production and a new log folder. The lines of the creation are kept for
[`production_log`](@ref JuLeAna.production_log). Possible while no session is loaded or
no processing runs; the controller is `:loading` meanwhile and returns to its previous
state if the creation or the load fails.
"""
struct CreateProduction <: ControllerCommand
    spec::ProductionSpec
end

"""
    SelectProduction(path::AbstractString)

Switch the session to the existing data production in the folder `path`, which must hold a
`config.json` or `config.yaml` (`config.json` if both exist): cancel all worker allocations,
set `LEGEND_DATA_CONFIG` of this process to that file, reset the dataset to `default`, and load a session with the
[`JuLeAna.install_default_config`](@ref) file of the production and a new log folder.
Possible while no session is loaded or no processing runs; the controller is `:loading`
meanwhile and is `:idle` without a session if the load fails.
"""
struct SelectProduction <: ControllerCommand
    path::String
    SelectProduction(path) = new(abspath(path))
end

"""
    SelectDataset(dataset::Symbol)

Reload the session for the dataset `dataset`, a name in the metadata `datasets/runlists` of the
data production or `:default` (every run), and cancel all worker allocations. The dataset is
the `--dataset` option. Possible while no session is loaded or no processing runs; a dataset
that is not in the metadata makes the load fail, leaving the controller `:idle` without a
session.
"""
struct SelectDataset <: ControllerCommand
    dataset::Symbol
end

"""
    PostponeIdleCancel()

Restart the idle time after which the worker allocations are cancelled (see
[`JuLeAna.check_idle!`](@ref)) from now.
"""
struct PostponeIdleCancel <: ControllerCommand end

"""
    EditStartScript(text::AbstractString)

Replace the worker start script of the session by `text` for the next allocations (see
[`JuLeAna.edit_start_script!`](@ref)).
"""
struct EditStartScript <: ControllerCommand
    text::String
end

"""
    mutable struct DataflowController

Headless state of an interactive dataflow session. All changes go through
[`dispatch!`](@ref) with a [`ControllerCommand`](@ref); [`snapshot`](@ref) returns a
read-only view of the state and [`progress`](@ref) the progress of the current or last
processing run. Commands may be sent from any task; long-running ones
(loading the session, reloading the config, processing) run in the background.

The controller is in one of the states
- `:idle`: no session loaded yet,
- `:loading`: the session or config is being loaded,
- `:ready`: a session is loaded and no processing runs,
- `:running`: processing runs,
- `:stopping`: processing was asked to stop and runs until the running items finish.

Constructors:
- `DataflowController(args::AbstractDict; processors = PROCESSORS, console = true)`
  starts `:idle` with the parsed command line options `args`; [`LoadSession`](@ref)
  sets up the session, with terminal log output of this process only if `console`.
- `DataflowController(session::DataflowSession; processors = PROCESSORS)` starts
  `:ready` with an existing session.

`processors` maps processor names to their functions. Both constructors take the keyword
`workers`, the [`JuLeAna.WorkerManager`](@ref) of the worker allocations, and
`record_software`: whether each processing run first records the software of this process
in the `setup/software` folder of the production (see [`JuLeAna.record_software`](@ref)), and
`record_metadata`: whether it records the metadata and the config files (the data config
files and the processing config `args["config"]`) in its `setup/metadata` folder (see
[`JuLeAna.record_metadata`](@ref)). A run fails if a record fails.
"""
mutable struct DataflowController
    const args::Dict{String,Any}
    const processors::AbstractDict{Symbol}
    const loader::Any
    const lock::ReentrantLock
    const stop::Threads.Atomic{Bool}
    const abandon::Threads.Atomic{Bool}
    const progress::ProgressStore
    const workers::WorkerManager
    const record_software::Bool
    const record_metadata::Bool
    # lines of the last production creation
    const production_lines::Vector{String}
    # subfolders of `setup/software` and `setup/metadata` recorded for the current or last
    # processing run
    software_snapshot::Union{Nothing,String}
    metadata_record::Union{Nothing,String}
    state::Symbol
    session::Union{Nothing,DataflowSession}
    # selected periods, including those without runs to process
    periods::Vector{DataPeriod}
    available_periods::Vector{DataPeriod}
    available_runs::Dict{DataPeriod,Vector{DataRun}}
    reprocess::Union{Nothing,Bool}
    processor_log_level::Union{Nothing,LogLevel}
    processor_plot_level::Union{Nothing,Symbol}
    analysis_runs_only::Union{Nothing,Bool}
    runmode::Union{Nothing,Symbol}
    # `local_n`, `local_julia_settings`, `slurm_flags` and `slurm_julia_settings` set by `SetRunmodeSettings`
    runmode_settings::Dict{Symbol,Any}
    check_dependencies::Bool
    kwarg_overrides::Dict{Symbol,Dict{Symbol,Any}}
    # `:log_level` and `:plot_level` set by `SetStepLevel`, per processor
    level_overrides::Dict{Symbol,Dict{Symbol,Any}}
    # settings in `STEP_SETTINGS` set by `SetStepSetting`, per processor
    setting_overrides::Dict{Symbol,Dict{Symbol,Any}}
    task::Union{Nothing,Task}
    outcome::Union{Nothing,Symbol}
    last_error::Union{Nothing,String}
    started::Union{Nothing,DateTime}
    finished::Union{Nothing,DateTime}
end

function DataflowController(args::AbstractDict; processors::AbstractDict{Symbol} = PROCESSORS, console::Bool = true,
                            loader = parsed_args -> setup_session(parsed_args; console), workers::WorkerManager = WorkerManager(),
                            record_software::Bool = true, record_metadata::Bool = true)
    return DataflowController(Dict{String,Any}(args), processors, loader, ReentrantLock(), Threads.Atomic{Bool}(false),
                              Threads.Atomic{Bool}(false), ProgressStore(), workers, record_software, record_metadata, String[], nothing,
                              nothing, :idle, nothing, DataPeriod[], DataPeriod[], Dict{DataPeriod,Vector{DataRun}}(), nothing, nothing,
                              nothing, nothing, nothing, Dict{Symbol,Any}(), true, Dict{Symbol,Dict{Symbol,Any}}(),
                              Dict{Symbol,Dict{Symbol,Any}}(), Dict{Symbol,Dict{Symbol,Any}}(), nothing, nothing, nothing, nothing,
                              nothing)
end

function DataflowController(session::DataflowSession; processors::AbstractDict{Symbol} = PROCESSORS,
                            workers::WorkerManager = WorkerManager(), record_software::Bool = true, record_metadata::Bool = true)
    ctrl = DataflowController(session.args; processors, loader = nothing, workers, record_software, record_metadata)
    install_session!(ctrl, session)
    return ctrl
end

function Base.show(io::IO, ctrl::DataflowController)
    print(io, "DataflowController(", repr(ctrl.state))
    isnothing(ctrl.session) || print(io, ", ", ctrl.session)
    return print(io, ")")
end

# Take over `session` and list the periods and runs of its dataset; the caller holds the lock.
function install_session!(ctrl::DataflowController, session::DataflowSession)
    ctrl.session = session
    ctrl.processor_log_level = session.config.processor_log_level
    ctrl.processor_plot_level = session.config.processor_plot_level
    ctrl.periods = copy(session.periods)
    ctrl.available_periods = available_periods(session.l200)
    ctrl.available_runs = Dict(p => available_runs(session.l200, p) for p in ctrl.available_periods)
    set_worker_config!(ctrl.workers, effective_config(ctrl))
    ctrl.state = :ready
    return ctrl
end

# Run `f` in the background with the controller `:loading`; an error is kept as
# `last_error` and the controller returns to `fallback`, a state or a function of the
# controller that returns it, called with the lock held.
function load_in_background!(f, ctrl::DataflowController, fallback)
    ctrl.state = :loading
    ctrl.last_error = nothing
    ctrl.task = Threads.@spawn try
        f()
    catch e
        @error "Loading the session failed" exception = (e, catch_backtrace())
        @lock ctrl.lock begin
            ctrl.last_error = truncate_error(e)
            ctrl.state = fallback isa Symbol ? fallback : fallback(ctrl)
        end
    end
    return nothing
end

function require_state(ctrl::DataflowController, cmd::ControllerCommand, states::Symbol...)
    ctrl.state in states || throw(ArgumentError("$(nameof(typeof(cmd))) is not possible while the controller is $(repr(ctrl.state))"))
    return nothing
end

# Processor specs of `specs` with the session's kwarg overrides merged into their kwargs, its
# level overrides replacing their log and plot levels and its setting overrides replacing the
# other settings.
function with_overrides(specs::AbstractDict{Symbol,ProcessorSpec}, overrides::AbstractDict, levels::AbstractDict, settings::AbstractDict)
    return Dict{Symbol,ProcessorSpec}(name =>
                                          !haskey(overrides, name) && !haskey(levels, name) && !haskey(settings, name) ? spec :
                                          ProcessorSpec(spec.name, spec.level, spec.enabled,
                                                        get(get(settings, name, Dict{Symbol,Any}()), :category, spec.category),
                                                        get(get(settings, name, Dict{Symbol,Any}()), :rank, spec.rank),
                                                        get(get(settings, name, Dict{Symbol,Any}()), :dependencies, spec.dependencies),
                                                        merge(spec.kwargs, get(overrides, name, Dict{Symbol,Any}())),
                                                        get(get(settings, name, Dict{Symbol,Any}()), :error_plots, spec.error_plots),
                                                        get(get(levels, name, Dict{Symbol,Any}()), :log_level, spec.log_level),
                                                        get(get(levels, name, Dict{Symbol,Any}()), :plot_level, spec.plot_level),
                                                        get(get(settings, name, Dict{Symbol,Any}()), :detectors, spec.detectors),
                                                        get(get(settings, name, Dict{Symbol,Any}()), :report_status, spec.report_status))
                                      for (name, spec) in specs)
end

"""
    effective_config(ctrl::DataflowController)

Return the session's [`ProcessingConfig`](@ref) with the kwarg overrides of the
controller merged into the processor kwargs, its level overrides (see
[`SetStepLevel`](@ref)) and setting overrides (see [`SetStepSetting`](@ref)) applied to the processors, and its `analysis_runs_only`, `runmode` and
run mode settings (see [`SetRunmodeSettings`](@ref)) applied.
"""
function effective_config(ctrl::DataflowController)
    cfg = ctrl.session.config
    settings = ctrl.runmode_settings
    return ProcessingConfig(something(ctrl.runmode, cfg.runmode), cfg.submit_jobs, get(settings, :local_n, cfg.local_n),
                            get(settings, :local_julia_settings, cfg.local_julia_settings), get(settings, :slurm_flags, cfg.slurm_flags),
                            get(settings, :slurm_julia_settings, cfg.slurm_julia_settings), cfg.env_variables, cfg.periods, cfg.runs,
                            something(ctrl.analysis_runs_only, cfg.analysis_runs_only), cfg.only_partitions, cfg.only_runs,
                            cfg.max_parallel_steps, cfg.log_path, cfg.log_level, cfg.processor_log_level, cfg.processor_plot_level,
                            cfg.plot_formats, cfg.idle_timeout_minutes,
                            with_overrides(cfg.processors, ctrl.kwarg_overrides, ctrl.level_overrides, ctrl.setting_overrides),
                            with_overrides(cfg.p_processors, ctrl.kwarg_overrides, ctrl.level_overrides, ctrl.setting_overrides))
end

function processor_spec(cfg::ProcessingConfig, step::Symbol)
    return haskey(cfg.processors, step) ? cfg.processors[step] :
           haskey(cfg.p_processors, step) ? cfg.p_processors[step] : throw(ArgumentError("unknown processor `$step`"))
end

"""
    dispatch!(ctrl::DataflowController, cmd::ControllerCommand)

Apply `cmd` to `ctrl` and return `nothing`. Throw an `ArgumentError` that explains why
when the command is not possible in the controller's state or its arguments are invalid;
the controller is then unchanged. Commands that run in the background return as soon as
they are started; see [`snapshot`](@ref) for their state and `wait(ctrl)` to block
until they are done.
"""
function dispatch! end

function dispatch!(ctrl::DataflowController, cmd::ControllerCommand)
    @lock ctrl.lock apply!(ctrl, cmd)
end

function apply!(ctrl::DataflowController, cmd::LoadSession)
    require_state(ctrl, cmd, :idle)
    isnothing(get(ctrl.args, "config", nothing)) &&
        throw(ArgumentError("LoadSession: no processing config: give one with --config or select a data production with LEGEND_DATA_CONFIG"))
    load_in_background!(ctrl, :idle) do
        session = ctrl.loader(ctrl.args)
        @lock ctrl.lock install_session!(ctrl, session)
    end
end

function apply!(ctrl::DataflowController, cmd::ReloadConfig)
    require_state(ctrl, cmd, :ready)
    load_in_background!(ctrl, :ready) do
        session = ctrl.session
        l200, config, periods = setup_processing(session.args)
        check_processor_kwargs(config; ctrl.processors)
        @lock ctrl.lock begin
            session.l200, session.config, session.periods, session.runs = l200, config, periods, session_runs(session.args, config)
            session.run_steps, session.partition_steps = selected_steps(config)
            empty!(ctrl.kwarg_overrides)
            empty!(ctrl.level_overrides)
            empty!(ctrl.setting_overrides)
            reset_dependency_graph!(session)
            install_session!(ctrl, session)
        end
        @info "Reloaded processing config"
    end
end

function check_available_periods(ctrl::DataflowController, periods)
    unknown = setdiff(periods, ctrl.available_periods)
    isempty(unknown) || throw(ArgumentError("periods not in the dataset: $(join(string.(unknown), ", "))"))
    return nothing
end

# Rebuild the dependency graph for the selected periods; periods without runs to process
# stay selected in the controller.
function select_periods!(ctrl::DataflowController, periods)
    ctrl.periods = sort(unique(periods))
    ctrl.session.periods = copy(ctrl.periods)
    reset_dependency_graph!(ctrl.session)
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SelectPeriods)
    require_state(ctrl, cmd, :ready)
    check_available_periods(ctrl, cmd.periods)
    runs = ctrl.session.runs
    if runs isa AbstractDict
        filter!(((p, _),) -> p in cmd.periods, runs)
        isempty(runs) && (ctrl.session.runs = nothing)
    end
    return select_periods!(ctrl, cmd.periods)
end

function apply!(ctrl::DataflowController, cmd::SelectRuns)
    require_state(ctrl, cmd, :ready)
    session = ctrl.session
    if cmd.runs isa AbstractDict
        check_available_periods(ctrl, keys(cmd.runs))
        for (period, runs) in cmd.runs
            unknown = isnothing(runs) ? DataRun[] : setdiff(runs, ctrl.available_runs[period])
            isempty(unknown) || throw(ArgumentError("runs not available in $period: $(join(string.(unknown), ", "))"))
        end
        explicit = Dict{DataPeriod,Vector{DataRun}}(p => sort(unique(r)) for (p, r) in cmd.runs if !isnothing(r))
        session.runs = isempty(explicit) ? nothing : explicit
        select_periods!(ctrl, collect(keys(cmd.runs)))
    else
        if !isnothing(cmd.runs)
            selectable = reduce(union, (ctrl.available_runs[p] for p in ctrl.periods); init = DataRun[])
            unknown = setdiff(cmd.runs, selectable)
            isempty(unknown) || throw(ArgumentError("runs not available in the selected periods: $(join(string.(unknown), ", "))"))
        end
        session.runs = isnothing(cmd.runs) ? nothing : sort(unique(cmd.runs))
        select_periods!(ctrl, ctrl.periods)
    end
end

function apply!(ctrl::DataflowController, cmd::SelectSteps)
    require_state(ctrl, cmd, :ready)
    cfg = ctrl.session.config
    for (steps, specs, section) in ((cmd.run_steps, cfg.processors, "processors"), (cmd.partition_steps, cfg.p_processors, "p_processors"))
        unknown = filter(!in(keys(specs)), steps)
        isempty(unknown) || throw(ArgumentError("not in `$section` of the config: $(join(unknown, ", "))"))
    end
    ctrl.session.run_steps = filter(in(cmd.run_steps), run_steps(cfg; enabled_only = false))
    ctrl.session.partition_steps = filter(in(cmd.partition_steps), partition_steps(cfg; enabled_only = false))
    reset_dependency_graph!(ctrl.session)
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetReprocess)
    require_state(ctrl, cmd, :idle, :ready)
    ctrl.reprocess = cmd.reprocess
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetProcessorLogLevel)
    require_state(ctrl, cmd, :idle, :ready)
    ctrl.processor_log_level = cmd.level
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetProcessorPlotLevel)
    require_state(ctrl, cmd, :idle, :ready)
    isnothing(cmd.level) ||
        cmd.level in PLOT_LEVEL_VALUES ||
        throw(ArgumentError("the plot level is $(repr(cmd.level)), expected :info or :debug"))
    ctrl.processor_plot_level = cmd.level
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetAnalysisRunsOnly)
    require_state(ctrl, cmd, :idle, :ready)
    ctrl.analysis_runs_only = cmd.only
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetRunmode)
    require_state(ctrl, cmd, :ready)
    ctrl.runmode = cmd.runmode
    set_worker_config!(ctrl.workers, effective_config(ctrl))
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetRunmodeSettings)
    # a processing run keeps the config it started with; only new allocations use the settings
    require_state(ctrl, cmd, :ready, :running, :stopping)
    for name in fieldnames(SetRunmodeSettings)
        value = getfield(cmd, name)
        isnothing(value) || (ctrl.runmode_settings[name] = value)
    end
    set_worker_config!(ctrl.workers, effective_config(ctrl))
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetCheckDependencies)
    require_state(ctrl, cmd, :idle, :ready)
    ctrl.check_dependencies = cmd.check
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetKwarg)
    require_state(ctrl, cmd, :ready)
    spec = processor_spec(ctrl.session.config, cmd.step)
    overrides = merge(get(ctrl.kwarg_overrides, cmd.step, Dict{Symbol,Any}()), Dict{Symbol,Any}(cmd.key => cmd.value))
    candidate = ProcessorSpec(spec.name, spec.level, spec.enabled, spec.category, spec.rank, spec.dependencies,
                              merge(spec.kwargs, overrides), spec.error_plots, spec.log_level, spec.plot_level,
                              spec.detectors, spec.report_status)
    problem = processor_kwargs_problem(candidate, ctrl.processors)
    isnothing(problem) || throw(ArgumentError(problem))
    ctrl.kwarg_overrides[cmd.step] = overrides
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetStepLevel)
    require_state(ctrl, cmd, :ready)
    processor_spec(ctrl.session.config, cmd.step)
    get!(Dict{Symbol,Any}, ctrl.level_overrides, cmd.step)[cmd.key] = cmd.value
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetStepSetting)
    require_state(ctrl, cmd, :ready)
    processor_spec(ctrl.session.config, cmd.step)
    with_valid_overrides(ctrl) do
        return get!(Dict{Symbol,Any}, ctrl.setting_overrides, cmd.step)[cmd.key] = cmd.value
    end
    return nothing
end

# Run `change()`, which edits the overrides of `ctrl`, and restore the overrides and rethrow
# when the changed overrides make an invalid processing config.
function with_valid_overrides(change, ctrl::DataflowController)
    saved = map(deepcopy, (ctrl.kwarg_overrides, ctrl.level_overrides, ctrl.setting_overrides))
    try
        change()
        effective_config(ctrl)
    catch
        for (overrides, old) in zip((ctrl.kwarg_overrides, ctrl.level_overrides, ctrl.setting_overrides), saved)
            empty!(overrides)
            merge!(overrides, old)
        end
        rethrow()
    end
    return nothing
end

function apply!(ctrl::DataflowController, cmd::ResetKwargs)
    require_state(ctrl, cmd, :ready)
    with_valid_overrides(ctrl) do
        for overrides in (ctrl.kwarg_overrides, ctrl.level_overrides, ctrl.setting_overrides)
            if isnothing(cmd.step)
                empty!(overrides)
            elseif isnothing(cmd.key)
                delete!(overrides, cmd.step)
            elseif haskey(overrides, cmd.step)
                delete!(overrides[cmd.step], cmd.key)
                isempty(overrides[cmd.step]) && delete!(overrides, cmd.step)
            end
        end
    end
    return nothing
end

function apply!(ctrl::DataflowController, cmd::ResetDependencyGraph)
    require_state(ctrl, cmd, :ready)
    reset_dependency_graph!(ctrl.session)
    return nothing
end

function apply!(ctrl::DataflowController, cmd::StartProcessing)
    require_state(ctrl, cmd, :ready)
    session = ctrl.session
    steps, p_steps = copy(session.run_steps), copy(session.partition_steps)
    isempty(steps) &&
        isempty(p_steps) &&
        throw(ArgumentError("no processing steps selected: enable processors in the config file or select them on the Setup page"))
    isempty(ctrl.periods) && throw(ArgumentError("no periods selected"))
    cfg = effective_config(ctrl)
    problems = filter(!isnothing, [processor_kwargs_problem(processor_spec(cfg, step), ctrl.processors) for step in vcat(steps, p_steps)])
    isempty(problems) || throw(ArgumentError("processor kwargs mismatch:\n  " * join(problems, "\n  ")))
    if ctrl.check_dependencies
        session.periods, session.run_status, session.partition_status = setup_dependency_graph(session.l200, cfg, ctrl.periods,
                                                                                               session.runs, steps, p_steps)
    end
    ctrl.stop[], ctrl.abandon[] = false, false
    # no progress of the last run is shown until `run_processing` registers the new steps
    reset_progress!(ctrl.progress, ProgressKey[])
    ctrl.state, ctrl.outcome, ctrl.last_error = :running, nothing, nothing
    ctrl.software_snapshot, ctrl.metadata_record = nothing, nothing
    ctrl.started, ctrl.finished = now(UTC), nothing
    (; l200, periods, run_status, partition_status) = session
    check_dependencies, reprocess, processor_log_level, processor_plot_level = ctrl.check_dependencies, ctrl.reprocess,
                                                                               ctrl.processor_log_level, ctrl.processor_plot_level
    ctrl.task = Threads.@spawn begin
        outcome, err = try
            if ctrl.record_software || ctrl.record_metadata
                configs = data_config_files()
                production = dirname(abspath(last(configs)))
                ctrl.record_software && (ctrl.software_snapshot = record_software(production))
                processing_config = get(ctrl.args, "config", nothing)
                isnothing(processing_config) || push!(configs, processing_config)
                ctrl.record_metadata && (ctrl.metadata_record = record_metadata(production, data_path(l200, "metadata"); configs))
            end
            run_processing(cfg, l200, periods, steps, p_steps, run_status, partition_status; processors = ctrl.processors,
                           check_dependencies, reprocess, processor_log_level, processor_plot_level, ctrl.stop, ctrl.abandon,
                           progress_store = ctrl.progress)
            :finished, nothing
        catch e
            ctrl.stop[] ? (:stopped, nothing) : (:failed, e)
        end
        isnothing(err) || @error "Processing failed" exception = err
        @info "Processing $outcome"
        finished = now(UTC)
        write_history(ctrl, cfg, l200, outcome, finished)
        @lock ctrl.lock begin
            ctrl.state, ctrl.outcome, ctrl.finished = :ready, outcome, finished
            ctrl.last_error = isnothing(err) ? nothing : truncate_error(err)
            mark_activity!(ctrl.workers, finished)
        end
    end
    return nothing
end

# Append the steps of the processing run that ended with `outcome` to the processing
# history of `l200`; an error is logged and does not change the outcome.
function write_history(ctrl::DataflowController, cfg::ProcessingConfig, l200, outcome::Symbol, finished::DateTime)
    try
        steps = map(progress(ctrl).steps) do e
            (; level, category) = processor_spec(cfg, e.step)
            return (; process = e.step, level, category, e.period, e.run, outcome = e.state, e.started, e.finished, e.done, e.failed,
                    e.notrun)
        end
        path = append_history(history_path(l200),
                              (; ctrl.started, finished, user = get(ENV, "USER", "unknown"), host = gethostname(), outcome, cfg.log_path,
                               software = software_version(ctrl.software_snapshot),
                               metadata = isnothing(ctrl.metadata_record) ? nothing : "setup/metadata/$(ctrl.metadata_record)", steps))
        @info "Added the processing run to the history in $path"
    catch e
        @error "Writing the processing history failed" exception = (e, catch_backtrace())
    end
    return nothing
end

function apply!(ctrl::DataflowController, cmd::StopProcessing)
    require_state(ctrl, cmd, :running, :stopping)
    cmd.force && (ctrl.abandon[] = true)
    ctrl.stop[] = true
    ctrl.state = :stopping
    cmd.force && @warn "Stopping without waiting for the running items; their workers stay busy until the items end"
    return nothing
end

function apply!(ctrl::DataflowController, cmd::WriteConfig)
    require_state(ctrl, cmd, :ready, :running, :stopping)
    session = ctrl.session
    props = readlprops(ctrl.args["config"])
    for (step, overrides) in ctrl.kwarg_overrides
        spec = processor_spec(session.config, step)
        entry = props[spec.level === :run ? :processors : :p_processors][step]
        for (key, value) in overrides
            # the config stores symbol lists as strings
            entry.kwargs[key] = value isa AbstractVector{Symbol} ? string.(value) : value
        end
    end
    for (step, levels) in ctrl.level_overrides
        spec = processor_spec(session.config, step)
        entry = props[spec.level === :run ? :processors : :p_processors][step]
        haskey(levels, :log_level) && (entry.log_level = only(name for (name, level) in LOG_LEVELS if level == levels[:log_level]))
        haskey(levels, :plot_level) && (entry.plot_level = string(levels[:plot_level]))
    end
    for (step, settings) in ctrl.setting_overrides
        spec = processor_spec(session.config, step)
        entry = props[spec.level === :run ? :processors : :p_processors][step]
        for (key, value) in settings
            if key === :category
                entry.category = string(value)
            elseif key === :dependencies
                entry.dependencies = string.(value)
            elseif key === :detectors
                isnothing(value) ? delete!(entry, :detectors) : (entry.detectors = value)
            elseif key === :report_status
                # only the entries that differ from the default are written
                changed = Dict(u => Dict(r => string(v) for (r, v) in rows if v !== DEFAULT_REPORT_STATUS[u][r]) for (u, rows) in value)
                filter!(!isempty ∘ last, changed)
                isempty(changed) ? delete!(entry, :report_status) : (entry.report_status = changed)
            else
                entry[key] = value
            end
        end
    end
    selected = union(session.run_steps, session.partition_steps)
    for section in (:processors, :p_processors), (name, entry) in props[section]

        entry.enabled = name in selected
    end
    props.processing.analysis_runs_only = effective_config(ctrl).analysis_runs_only
    props.config.runmode = string(effective_config(ctrl).runmode)
    if isnothing(ctrl.processor_log_level)
        delete!(props.config, :processor_log_level)
    else
        props.config.processor_log_level = only(name for (name, level) in LOG_LEVELS if level == ctrl.processor_log_level)
    end
    if isnothing(ctrl.processor_plot_level)
        delete!(props.config, :processor_plot_level)
    else
        props.config.processor_plot_level = string(ctrl.processor_plot_level)
    end
    settings = props.config.runmode_settings
    for (name, value) in ctrl.runmode_settings
        name === :local_n && (settings.local.n = value)
        name === :local_julia_settings && (settings.local.julia_settings = value)
        name === :slurm_flags && (settings.slurm.flags = value)
        name === :slurm_julia_settings && (settings.slurm.julia_settings = value)
    end
    path = isnothing(cmd.path) ? joinpath(mkpath(production_config_dir()), "processing_config.yaml") : cmd.path
    isfile(path) && cp(path, path * ".bak"; force = true)
    writelprops(path, props)
    ctrl.args["config"] = path
    @info "Wrote processing config to $path"
    return nothing
end

function apply!(ctrl::DataflowController, cmd::AddWorkers)
    require_state(ctrl, cmd, :ready, :running, :stopping)
    add_workers!(ctrl.workers)
    return nothing
end

function apply!(ctrl::DataflowController, cmd::CancelAllocation)
    return (cancel_allocation!(ctrl.workers, cmd.id); nothing)
end

apply!(ctrl::DataflowController, ::CancelAll) = (cancel_all!(ctrl.workers); nothing)

function apply!(ctrl::DataflowController, cmd::CreateProduction)
    require_state(ctrl, cmd, :idle, :ready)
    check_production(cmd.spec)
    empty!(ctrl.production_lines)
    log(line) = (@lock ctrl.lock push!(ctrl.production_lines, line); @info line)
    # after a failure the session is that of the previous production, or none once switched
    load_in_background!(ctrl, c -> isnothing(c.session) ? :idle : :ready) do
        config = create_production(cmd.spec; log)
        cancel_all!(ctrl.workers)
        ENV["LEGEND_DATA_CONFIG"] = with_production_config(config)
        @lock ctrl.lock begin
            ctrl.session = nothing
            ctrl.args["config"], ctrl.args["log_path"] = install_default_config(), ""
        end
        log("Loading the new production $(dirname(config))")
        session = ctrl.loader(ctrl.args)
        @lock ctrl.lock install_session!(ctrl, session)
    end
end

# Cancel the workers and load a session with `ctrl.args` as changed by `prepare`, which runs
# in the background task. The session is dropped first, so a failed load leaves none.
function reload_session!(prepare, ctrl::DataflowController)
    load_in_background!(ctrl, c -> isnothing(c.session) ? :idle : :ready) do
        cancel_all!(ctrl.workers)
        prepare()
        @lock ctrl.lock ctrl.session = nothing
        session = ctrl.loader(ctrl.args)
        @lock ctrl.lock install_session!(ctrl, session)
    end
end

function apply!(ctrl::DataflowController, cmd::SelectProduction)
    require_state(ctrl, cmd, :idle, :ready)
    configs = [joinpath(cmd.path, f) for f in ("config.json", "config.yaml")]
    i = findfirst(isfile, configs)
    isnothing(i) && throw(ArgumentError("$(cmd.path) is not a data production: it has no config.json or config.yaml"))
    config = configs[i]
    reload_session!(ctrl) do
        ENV["LEGEND_DATA_CONFIG"] = with_production_config(config)
        @lock ctrl.lock begin
            ctrl.args["config"], ctrl.args["log_path"], ctrl.args["dataset"] = install_default_config(), "", "default"
        end
        @info "Loading the data production $(cmd.path)"
    end
end

function apply!(ctrl::DataflowController, cmd::SelectDataset)
    require_state(ctrl, cmd, :idle, :ready)
    reload_session!(ctrl) do
        @lock ctrl.lock begin
            ctrl.args["log_path"], ctrl.args["dataset"] = "", string(cmd.dataset)
        end
        @info "Loading the dataset $(cmd.dataset)"
    end
end

"""
    JuLeAna.production_log(ctrl::DataflowController)

Return a copy of the lines of the last [`CreateProduction`](@ref) of `ctrl`.
"""
production_log(ctrl::DataflowController) = @lock ctrl.lock copy(ctrl.production_lines)

function apply!(ctrl::DataflowController, ::PostponeIdleCancel)
    return (mark_activity!(ctrl.workers); nothing)
end

"""
    JuLeAna.check_idle!(ctrl::DataflowController)

Cancel the worker allocations of `ctrl` if they have been idle for the `idle_timeout_minutes`
of the config (see [`JuLeAna.check_idle!`](@ref)); allocations are never idle while processing
runs or is stopping. Return whether they were cancelled. The terminal user interface calls it
with every read of the controller state.
"""
function check_idle!(ctrl::DataflowController)
    @lock ctrl.lock check_idle!(ctrl.workers; processing = ctrl.state in (:running, :stopping))
end

function apply!(ctrl::DataflowController, cmd::EditStartScript)
    require_state(ctrl, cmd, :ready, :running, :stopping)
    edit_start_script!(ctrl.workers, cmd.text)
    return nothing
end

"""
    wait(ctrl::DataflowController)

Block until the background task of the last loading or processing command has ended.
"""
function Base.wait(ctrl::DataflowController)
    task = @lock ctrl.lock ctrl.task
    isnothing(task) || wait(task)
    return nothing
end

# Types of the value of `snapshot`. The field types are fixed, so that the interface code that
# shows the controller state is compiled once for every state.
const ProcessorInfo = @NamedTuple{name::Symbol, level::Symbol, category::Symbol, rank::Int, enabled::Bool, selected::Bool,
                                  dependencies::Vector{Symbol}, kwargs::Dict{Symbol,Any}, config_kwargs::Dict{Symbol,Any},
                                  accepted::Union{Nothing,Vector{Symbol}}, overridden::Vector{Symbol}, log_level::LogLevel,
                                  plot_level::Symbol, config_log_level::LogLevel, config_plot_level::Symbol,
                                  error_plots::Bool, detectors::Union{Nothing,String}, report_status::Dict{Symbol,Dict{Symbol,Symbol}},
                                  config_spec::ProcessorSpec}
const RunmodeSettings = @NamedTuple{local_n::Int, local_julia_settings::Vector{String}, slurm_flags::Vector{String},
                                    slurm_julia_settings::Vector{String}}
const ControllerSnapshot = @NamedTuple{state::Symbol, outcome::Union{Nothing,Symbol}, last_error::Union{Nothing,String},
                                       started::Union{Nothing,DateTime}, finished::Union{Nothing,DateTime},
                                       config_file::Union{Nothing,String}, log_path::Union{Nothing,String}, dataset::String,
                                       available_periods::Vector{DataPeriod}, available_runs::Dict{DataPeriod,Vector{DataRun}},
                                       periods::Vector{DataPeriod}, runs::Union{Nothing,Vector{DataRun},Dict{DataPeriod,Vector{DataRun}}},
                                       run_steps::Vector{Symbol}, partition_steps::Vector{Symbol}, processors::Vector{ProcessorInfo},
                                       reprocess::Union{Nothing,Bool}, processor_log_level::Union{Nothing,LogLevel},
                                       processor_plot_level::Union{Nothing,Symbol}, analysis_runs_only::Union{Nothing,Bool},
                                       runmode::Union{Nothing,Symbol}, runmode_settings::Union{Nothing,RunmodeSettings},
                                       check_dependencies::Bool, nworkers::Int, allocations::Vector{AllocationInfo},
                                       idle_deadline::Union{Nothing,DateTime}}

"""
    snapshot(ctrl::DataflowController)

Return a `JuLeAna.ControllerSnapshot`, a `NamedTuple` with fixed field types, with a copy of
the controller state:

- `state`, `outcome` (`:finished`, `:failed`, `:stopped` or `nothing` of the last
  processing run), `last_error` (message or `nothing`), `started`, `finished` (UTC
  times of the last processing run or `nothing`);
- `config_file`, `log_path`, `dataset` (the name of the dataset, `"default"` for every run);
- `available_periods`, `available_runs` (`Dict` period => runs of the dataset), `periods`
  (selected periods), `runs` (selected runs: `nothing` for all runs, a vector for the
  same runs in every period, or a dict of runs per period where a period without an
  entry keeps all its runs), `run_steps`, `partition_steps` (selected steps in
  processing order);
- `processors`: one `NamedTuple` per configured processor, run level first and then by
  rank, with `name`, `level`, `category`, `rank`, `enabled`, `selected`,
  `dependencies`, `kwargs` (with the overrides applied), `config_kwargs` (as in the
  config), `accepted` (the keyword arguments the processor function accepts besides the
  ones the dataflow passes itself, `nothing` if it accepts any), `overridden` (names of
  the overridden kwargs, `:log_level` and `:plot_level`, and the settings of
  [`SetStepSetting`](@ref) that are overridden), `log_level`,
  `plot_level` (with the overrides of [`SetStepLevel`](@ref) applied),
  `config_log_level`, `config_plot_level` (as in the config), `error_plots`, `detectors`
  and `report_status` (with the overrides of [`SetStepSetting`](@ref) applied; `category`,
  `rank` and `dependencies` above are too), and `config_spec`, the [`ProcessorSpec`](@ref) of the config;
- `reprocess`, `processor_log_level`, `processor_plot_level`, `analysis_runs_only` and `runmode` (the settings in effect), `runmode_settings`
  (`local_n`, `local_julia_settings`, `slurm_flags` and `slurm_julia_settings` in effect, or
  `nothing` without a session), `check_dependencies`,
  `nworkers` (workers in the pool), `allocations` (the worker allocations, see
  [`JuLeAna.allocations`](@ref), without their output), `idle_deadline` (UTC time at which
  idle allocations are cancelled, or `nothing`, see [`JuLeAna.idle_deadline`](@ref)).
"""
function snapshot(ctrl::DataflowController)
    @lock ctrl.lock begin
        session = ctrl.session
        processors = if isnothing(session)
            ProcessorInfo[]
        else
            cfg = effective_config(ctrl)
            selected = union(session.run_steps, session.partition_steps)
            ProcessorInfo[(; name, spec.level, spec.category, spec.rank, spec.enabled, selected = name in selected,
                           dependencies = copy(spec.dependencies), kwargs = copy(spec.kwargs),
                           config_kwargs = copy(processor_spec(session.config, name).kwargs),
                           accepted = accepted_kwargs(ctrl.processors, spec),
                           overridden = sort!(collect(union(keys(get(ctrl.kwarg_overrides, name, Dict{Symbol,Any}())),
                                                            keys(get(ctrl.level_overrides, name, Dict{Symbol,Any}())),
                                                            keys(get(ctrl.setting_overrides, name, Dict{Symbol,Any}()))))), spec.log_level,
                           spec.plot_level, config_log_level = processor_spec(session.config, name).log_level,
                           config_plot_level = processor_spec(session.config, name).plot_level, spec.error_plots, spec.detectors,
                           report_status = deepcopy(spec.report_status), config_spec = deepcopy(processor_spec(session.config, name)))
                          for name in vcat(run_steps(cfg; enabled_only = false), partition_steps(cfg; enabled_only = false))
                          for spec in (processor_spec(cfg, name),)]
        end
        runmode_settings = if isnothing(session)
            nothing
        else
            cfg = effective_config(ctrl)
            (; cfg.local_n, local_julia_settings = copy(cfg.local_julia_settings), slurm_flags = copy(cfg.slurm_flags),
             slurm_julia_settings = copy(cfg.slurm_julia_settings))
        end
        return convert(ControllerSnapshot,
                       (; ctrl.state, ctrl.outcome, ctrl.last_error, ctrl.started, ctrl.finished,
                        config_file = get(ctrl.args, "config", nothing), log_path = isnothing(session) ? nothing : session.config.log_path,
                        dataset = string(get(ctrl.args, "dataset", "default")), available_periods = copy(ctrl.available_periods),
                        available_runs = Dict(p => copy(r) for (p, r) in ctrl.available_runs), periods = copy(ctrl.periods),
                        runs = isnothing(session) ? nothing : deepcopy(session.runs),
                        run_steps = isnothing(session) ? Symbol[] : copy(session.run_steps),
                        partition_steps = isnothing(session) ? Symbol[] : copy(session.partition_steps), processors, ctrl.reprocess,
                        ctrl.processor_log_level, ctrl.processor_plot_level,
                        analysis_runs_only = isnothing(session) ? ctrl.analysis_runs_only :
                                             something(ctrl.analysis_runs_only, session.config.analysis_runs_only),
                        runmode = isnothing(session) ? ctrl.runmode : something(ctrl.runmode, session.config.runmode), runmode_settings,
                        ctrl.check_dependencies, nworkers = nprocs() > 1 ? nworkers() : 0,
                        allocations = allocations(ctrl.workers; output = false),
                        idle_deadline = idle_deadline(ctrl.workers; processing = ctrl.state in (:running, :stopping))))
    end
end

progress(ctrl::DataflowController) = progress(ctrl.progress)
# An item whose worker has ended waits for a retry on another worker, so it is not busy.
function busy_workers(ctrl::DataflowController)
    return filter(b -> b.worker in procs(), busy_workers(ctrl.progress))
end
step_messages(ctrl::DataflowController, key) = step_messages(ctrl.progress, key)

"""
    report_index(ctrl::DataflowController)

Return the reports of the steps of the current or last processing run of `ctrl`: one row
per step, in schedule order, with the fields of the rows of
`report_index(jlrep, processors, period_runs)`. A step whose report does not exist has
the state `:missing`. Returns an empty vector before the first run. Throws an
`ArgumentError` when no session is loaded.
"""
function report_index(ctrl::DataflowController)
    l200, cfg = @lock ctrl.lock begin
        isnothing(ctrl.session) && throw(ArgumentError("report_index: no session is loaded"))
        ctrl.session.l200, effective_config(ctrl)
    end
    jlrep = l200.tier[:jlrep]
    return map(progress(ctrl).steps) do e
        (; level, category) = processor_spec(cfg, e.step)
        return (; process = e.step, level, category, e.period, e.run,
                read_report(report_path(jlrep, e.step, level, e.period, e.run, category))...)
    end
end

"""
    report_overview(ctrl::DataflowController)

Return the `report_overview(l200)` of all reports in the report
folder of the session of `ctrl`, sorted by the ranks of the processors of its config, whatever the current selection. Throws an
`ArgumentError` when no session is loaded.
"""
function report_overview(ctrl::DataflowController)
    session = @lock ctrl.lock ctrl.session
    isnothing(session) && throw(ArgumentError("report_overview: no session is loaded"))
    return report_overview(session.l200;
                           processors = vcat(collect(values(session.config.processors)), collect(values(session.config.p_processors))))
end

"""
    dataset_summary(ctrl::DataflowController)

Return the [`JuLeAna.dataset_summary`](@ref) of the runinfo of the session of `ctrl`.
Throws an `ArgumentError` when no session is loaded.
"""
function dataset_summary(ctrl::DataflowController)
    session = @lock ctrl.lock ctrl.session
    isnothing(session) && throw(ArgumentError("dataset_summary: no session is loaded"))
    return dataset_summary(session.l200)
end

"""
    history_grid(ctrl::DataflowController)

Return the [`JuLeAna.history_grid`](@ref) of the session of `ctrl`: every processor of the
processing config (run level, then partition level, each in rank order) against every
period and run of the runinfo, from all reports on disk and the processing history of the
data production. Throws an `ArgumentError` when no session is loaded.
"""
function history_grid(ctrl::DataflowController)
    l200, config = @lock ctrl.lock begin
        isnothing(ctrl.session) && throw(ArgumentError("history_grid: no session is loaded"))
        ctrl.session.l200, ctrl.session.config
    end
    processors = vcat(sort!(collect(values(config.processors)); by = s -> (s.rank, s.name)),
                      sort!(collect(values(config.p_processors)); by = s -> (s.rank, s.name)))
    info = runinfo(l200)
    period_runs = [period => sort!(unique(info.run[info.period .== period])) for period in sort!(unique(info.period))]
    return history_grid(processors, period_runs, report_overview(l200), read_history(history_path(l200)))
end
