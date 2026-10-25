# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Values of `plot_level` and of the entries of `plot_formats`.
const PLOT_LEVEL_VALUES = (:info, :debug)
const PLOT_FORMAT_VALUES = (:png, :jls)

"""
    struct ProcessorSpec

Settings of one processor from the `processors` (run level) or `p_processors`
(partition level) table of a processing config.

Fields:
- `name::Symbol`: name of the processor function.
- `level::Symbol`: `:run` for an entry of `processors`, `:partition` for an entry of
  `p_processors`.
- `enabled::Bool`: whether the processor is selected for execution by default.
- `category::Symbol`: data category the processor acts on, `:cal` or `:phy`.
- `rank::Int`: position in listings and tie rule: among processors that are ready to run,
  lower ranks start first.
- `dependencies::Vector{Symbol}`: processors of either level that must finish first.
- `kwargs::Dict{Symbol,Any}`: keyword arguments passed to the processor function.
- `error_plots::Bool`: whether a failed [`@process_step`](@ref) of the processor runs its
  `on_error` hook, which saves a debug plot; key `error_plots` of the processor entry,
  optional, `false` by default.
- `log_level::LogLevel`: level of the records of the processor in the log files; key
  `log_level` of the processor entry (`"debug"`, `"info"`, `"warn"` or `"error"`),
  required.
- `plot_level::Symbol`: `:info` saves the normal plots of the processor, `:debug` also its
  debug plots; key `plot_level` of the processor entry (`"info"` or `"debug"`), required.

The positional constructor takes the fields in the order listed above,
`ProcessorSpec(name, level, enabled, category, rank, dependencies, kwargs, error_plots, log_level, plot_level)`;
`ProcessorSpec(; name, level, category, rank, enabled=true, dependencies=Symbol[],
kwargs=Dict{Symbol,Any}(), error_plots=false, log_level=Logging.Info, plot_level=:info)` builds a spec from keywords. Every constructor throws an `ArgumentError` when `level` is not `:run` or
`:partition`, `category` is not `:cal` or `:phy`, or the processor depends on itself.
"""
struct ProcessorSpec
    name::Symbol
    level::Symbol
    enabled::Bool
    category::Symbol
    rank::Int
    dependencies::Vector{Symbol}
    kwargs::Dict{Symbol,Any}
    error_plots::Bool
    log_level::LogLevel
    plot_level::Symbol

    function ProcessorSpec(name, level, enabled, category, rank, dependencies, kwargs, error_plots, log_level, plot_level)
        spec = new(name, level, enabled, category, rank, dependencies, kwargs, error_plots, log_level, plot_level)
        spec.level in (:run, :partition) ||
            throw(ArgumentError("processing_config: processor `$(spec.name)` has level $(repr(spec.level)), expected :run or :partition"))
        path = "$(spec.level === :run ? "processors" : "p_processors").$(spec.name)."
        spec.category in (:cal, :phy) ||
            throw(ArgumentError("processing_config: key `$(path)category` must be \"cal\" or \"phy\", got $(repr(spec.category))"))
        spec.name in spec.dependencies && throw(ArgumentError("processing_config: key `$(path)dependencies` names the processor itself"))
        return spec
    end
end

function ProcessorSpec(; name, level, category, rank, enabled = true, dependencies = Symbol[], kwargs = Dict{Symbol,Any}(),
                       error_plots = false, log_level = Logging.Info, plot_level = :info)
    return ProcessorSpec(name, level, enabled, category, rank, dependencies, kwargs, error_plots, log_level, plot_level)
end

"""
    struct ProcessingConfig

Validated processing settings, built from a processing config file and the command
line options of the dataflow driver.

Fields:
- `runmode::Symbol`: `:local` or `:slurm`.
- `submit_jobs::Bool`: whether the driver starts the workers itself.
- `local_n::Int`: number of local workers (`config.runmode_settings.local.n`).
- `local_julia_settings::Vector{String}`: Julia flags for local workers.
- `slurm_flags::Vector{String}`: SLURM flags for SLURM workers.
- `slurm_julia_settings::Vector{String}`: Julia flags for SLURM workers.
- `env_variables::Dict{String,String}`: environment variables for the driver and workers.
- `periods::Union{Nothing,Vector{DataPeriod}}`: selected periods; `nothing` selects all.
- `runs::Union{Nothing,Vector{DataRun}}`: selected runs; `nothing` selects all.
- `analysis_runs_only::Bool`: process only runs marked as analysis runs.
- `only_partitions::Bool`: process only partition-level processors.
- `only_runs::Bool`: process only run-level processors.
- `max_parallel_steps::Int`: maximum number of steps that run at the same time; `0`
  sets no limit.
- `log_path::String`: directory for log files; `""` when not resolved.
- `log_level::LogLevel`: level of the records written to the log files.
- `processor_log_level::Union{Nothing,LogLevel}`: level at which the processors' own
  records are written to the log files; `nothing` takes `log_level`.
- `processor_plot_level::Union{Nothing,Symbol}`: `:info` or `:debug`, the plot level of all
  processors; `nothing` takes the `plot_level` of each processor.
- `plot_formats::Vector{Symbol}`: formats in which plots are saved, `:png` and `:jls`; `:jls`
  also saves the Makie figure with `Serialization` next to the PNG, under the same name
  with the extension `.jls`. The file can be read again by a session with the same package
  versions.
- `idle_timeout_minutes::Float64`: minutes without processing after which the worker
  allocations started by the interface are cancelled; `0` never cancels them.
- `processors::Dict{Symbol,ProcessorSpec}`: run-level processors.
- `p_processors::Dict{Symbol,ProcessorSpec}`: partition-level processors.

Besides the positional constructor and the config-file constructors documented below,
`ProcessingConfig(; processors, p_processors, runmode=:local, ...)` builds a config from
keywords named like the fields. Every field except the two processor tables has a
default: empty flag and settings lists, no environment variables, `periods` and `runs`
of `nothing`, all `Bool` fields `false`, `max_parallel_steps = 0`, `local_n = 1`, `log_path = ""`,
`log_level = Logging.Info`, `processor_log_level = nothing`, `processor_plot_level = nothing`,
`plot_formats = [:png]` and `idle_timeout_minutes = 20`. Every
constructor throws an `ArgumentError` when `runmode` is not `:local` or `:slurm`,
`processor_plot_level` is not `nothing`, `:info` or `:debug`, `plot_formats` is empty, repeats
an entry or holds anything but `:png` and `:jls`, `local_n < 1`, `max_parallel_steps < 0`, `idle_timeout_minutes` is negative or not finite, both `only_runs` and `only_partitions` are set, a table key differs from
its spec's name or level, a name appears in both tables, a dependency names an unknown
processor, or the dependencies form a cycle (see [`processor_graph`](@ref)).

See [`run_steps`](@ref), [`partition_steps`](@ref) and [`check_processor_kwargs`](@ref).
"""
struct ProcessingConfig
    runmode::Symbol
    submit_jobs::Bool
    local_n::Int
    local_julia_settings::Vector{String}
    slurm_flags::Vector{String}
    slurm_julia_settings::Vector{String}
    env_variables::Dict{String,String}
    periods::Union{Nothing,Vector{DataPeriod}}
    runs::Union{Nothing,Vector{DataRun}}
    analysis_runs_only::Bool
    only_partitions::Bool
    only_runs::Bool
    max_parallel_steps::Int
    log_path::String
    log_level::LogLevel
    processor_log_level::Union{Nothing,LogLevel}
    processor_plot_level::Union{Nothing,Symbol}
    plot_formats::Vector{Symbol}
    idle_timeout_minutes::Float64
    processors::Dict{Symbol,ProcessorSpec}
    p_processors::Dict{Symbol,ProcessorSpec}

    function ProcessingConfig(runmode, submit_jobs, local_n, local_julia_settings, slurm_flags, slurm_julia_settings, env_variables,
                              periods, runs, analysis_runs_only, only_partitions, only_runs, max_parallel_steps, log_path, log_level,
                              processor_log_level, processor_plot_level, plot_formats, idle_timeout_minutes, processors, p_processors)
        cfg = new(runmode, submit_jobs, local_n, local_julia_settings, slurm_flags, slurm_julia_settings, env_variables, periods, runs,
                  analysis_runs_only, only_partitions, only_runs, max_parallel_steps, log_path, log_level, processor_log_level,
                  processor_plot_level, plot_formats, idle_timeout_minutes, processors, p_processors)
        cfg.runmode in (:local, :slurm) ||
            throw(ArgumentError("processing_config: runmode must be \"local\" or \"slurm\", got $(repr(cfg.runmode))"))
        isnothing(cfg.processor_plot_level) ||
            cfg.processor_plot_level in PLOT_LEVEL_VALUES ||
            throw(ArgumentError("processing_config: key `config.processor_plot_level` must be \"info\" or \"debug\", got $(repr(cfg.processor_plot_level))"))
        isempty(cfg.plot_formats) &&
            throw(ArgumentError("processing_config: key `config.plot_formats` must list at least one of \"png\" or \"jls\""))
        all(in(PLOT_FORMAT_VALUES), cfg.plot_formats) ||
            throw(ArgumentError("processing_config: key `config.plot_formats` must list only \"png\" or \"jls\", got $(repr(string.(cfg.plot_formats)))"))
        allunique(cfg.plot_formats) ||
            throw(ArgumentError("processing_config: key `config.plot_formats` lists a format twice: $(repr(string.(cfg.plot_formats)))"))
        cfg.max_parallel_steps >= 0 ||
            throw(ArgumentError("processing_config: key `processing.max_parallel_steps` must be zero or positive, got $(cfg.max_parallel_steps)"))
        cfg.local_n > 0 ||
            throw(ArgumentError("processing_config: key `config.runmode_settings.local.n` must be positive, got $(cfg.local_n)"))
        isfinite(cfg.idle_timeout_minutes) && cfg.idle_timeout_minutes >= 0 ||
            throw(ArgumentError("processing_config: key `config.idle_timeout_minutes` must be zero or positive, got $(cfg.idle_timeout_minutes)"))
        cfg.only_runs &&
            cfg.only_partitions &&
            throw(ArgumentError("processing_config: only one of `only_partitions` or `only_runs` can be set"))
        for (section, level, specs) in (("processors", :run, cfg.processors), ("p_processors", :partition, cfg.p_processors)),
            (name, spec) in specs

            name === spec.name || throw(ArgumentError("processing_config: `$section` entry `$name` holds the spec of `$(spec.name)`"))
            spec.level === level ||
                throw(ArgumentError("processing_config: `$section.$name` has level $(repr(spec.level)), expected $(repr(level))"))
        end
        duplicates = intersect(keys(cfg.processors), keys(cfg.p_processors))
        isempty(duplicates) ||
            throw(ArgumentError("processing_config: processor names in both `processors` and `p_processors`: $(join(duplicates, ", "))"))
        for (section, specs) in (("processors", cfg.processors), ("p_processors", cfg.p_processors)), spec in values(specs),
            dep in spec.dependencies

            haskey(cfg.processors, dep) ||
                haskey(cfg.p_processors, dep) ||
                throw(ArgumentError("processing_config: key `$section.$(spec.name).dependencies` names unknown processor `$dep`"))
        end
        # dependencies that form a cycle would make processing wait forever
        processor_graph(cfg)
        return cfg
    end
end

function ProcessingConfig(; processors, p_processors, runmode = :local, submit_jobs = false, local_n = 1, local_julia_settings = String[],
                          slurm_flags = String[], slurm_julia_settings = String[], env_variables = Dict{String,String}(), periods = nothing,
                          runs = nothing, analysis_runs_only = false, only_partitions = false, only_runs = false, max_parallel_steps = 0,
                          log_path = "", log_level = Logging.Info, processor_log_level = nothing, processor_plot_level = nothing,
                          plot_formats = [:png], idle_timeout_minutes = 20)
    return ProcessingConfig(runmode, submit_jobs, local_n, local_julia_settings, slurm_flags, slurm_julia_settings, env_variables, periods,
                            runs, analysis_runs_only, only_partitions, only_runs, max_parallel_steps, log_path, log_level,
                            processor_log_level, processor_plot_level, plot_formats, idle_timeout_minutes, processors, p_processors)
end

# Recursively convert nested dictionaries to `Dict{Symbol,Any}`.
_symbolkeys(x) = x
function _symbolkeys(d::AbstractDict)
    return Dict{Symbol,Any}(Symbol(k) => _symbolkeys(v) for (k, v) in d)
end

# Throw unless `d` has exactly the keys `required`; `path` is the key path of `d`.
function _check_keys(d::AbstractDict, required, path::AbstractString; optional = ())
    for k in required
        haskey(d, k) || throw(ArgumentError("processing_config: missing key `$path$k`"))
    end
    for k in keys(d)
        k in required || k in optional || throw(ArgumentError("processing_config: unknown key `$path$k`"))
    end
end

# Return `d[k]` after checking that it is a `T`.
function _typed(d::AbstractDict, k::Symbol, ::Type{T}, path::AbstractString) where {T}
    v = d[k]
    v isa T || throw(ArgumentError("processing_config: key `$path$k` must be a $T, got $(repr(v))"))
    return v
end

function _strings(d::AbstractDict, k::Symbol, path::AbstractString)
    v = _typed(d, k, AbstractVector, path)
    all(x -> x isa AbstractString, v) || throw(ArgumentError("processing_config: key `$path$k` must be a list of strings, got $(repr(v))"))
    return String[x for x in v]
end

# `"all"` selects everything (`nothing`), a list selects the given periods or runs.
function _selection(::Type{T}, d::AbstractDict, k::Symbol) where {T}
    v = d[k]
    v == "all" && return nothing
    v isa AbstractVector || throw(ArgumentError("processing_config: key `processing.$k` must be \"all\" or a list, got $(repr(v))"))
    return T[T(x) for x in v]
end

"""
    RENAMED_PROCESSORS::Dict{Symbol,Symbol}

Former processor names mapped to their current names. A processing config that uses a
former name as a key of `processors` or `p_processors`, or in a `dependencies` list,
is read as if it used the current name.
"""
const RENAMED_PROCESSORS = Dict{Symbol,Symbol}(:process_peak_split => :process_peak_split_cal,
                                               :process_decay_time => :process_decay_time_cal,
                                               :process_filter_optimization => :process_filter_optimization_cal,
                                               :process_aoe_optimization => :process_aoe_optimization_cal,
                                               :process_ct_correction => :process_ct_correction_cal,
                                               :process_energy_calibration => :process_energy_calibration_cal,
                                               :process_aoe_calibration_cut => :process_aoe_calibration_cut_cal,
                                               :process_lq_calibration_cut => :process_lq_calibration_cut_cal,
                                               :process_psd_efficiencies => :process_psd_efficiencies_cal,
                                               :p_process_decay_time => :p_process_decay_time_cal,
                                               :p_process_filter_optimization => :p_process_filter_optimization_cal,
                                               :p_process_aoe_optimization => :p_process_aoe_optimization_cal,
                                               :p_process_energy => :p_process_energy_cal,
                                               :p_process_aoe_calibration_cut => :p_process_aoe_calibration_cut_cal,
                                               :p_process_aoe_cut => :p_process_aoe_cut_cal,
                                               :p_process_lq_calibration_cut => :p_process_lq_calibration_cut_cal,
                                               :p_process_psd_efficiencies => :p_process_psd_efficiencies_cal)

# Replace former processor names in the keys and the `dependencies` of the processor
# tables by the current names and warn once per former name found. Throws when a table
# holds both names of one processor.
function _current_names(tables::Tuple)
    found = Set{Symbol}()
    current(name) = begin
        new = get(RENAMED_PROCESSORS, name, name)
        new === name || push!(found, name)
        new
    end
    renamed = map(tables) do table
        out = Dict{Symbol,Any}()
        for (name, entry) in table
            new = current(name)
            haskey(table, new) &&
                new !== name &&
                throw(ArgumentError("processing_config: the config has both `$name` and `$new`, which are the same processor; keep `$new`"))
            if entry isa AbstractDict && get(entry, :dependencies, nothing) isa AbstractVector
                deps = entry[:dependencies]
                entry = merge(entry, Dict(:dependencies => [x isa AbstractString ? string(current(Symbol(x))) : x for x in deps]))
            end
            out[new] = entry
        end
        return out
    end
    for name in sort!(collect(found))
        @warn "processing_config: processor `$name` is now named `$(RENAMED_PROCESSORS[name])`; update the config"
    end
    return renamed
end

"""
    rank_order_dependencies(specs::AbstractDict{Symbol,ProcessorSpec})

Return a copy of the processor table `specs` (one level) in which every processor also
depends on the processor before it in the order of rank, then name. The dependencies
then express that the processors run one after another in rank order.
"""
function rank_order_dependencies(specs::AbstractDict{Symbol,ProcessorSpec})
    order = sort!(collect(keys(specs)); by = n -> (specs[n].rank, n))
    out = Dict{Symbol,ProcessorSpec}()
    for (k, name) in pairs(order)
        s = specs[name]
        deps = k == firstindex(order) || order[k - 1] in s.dependencies ? copy(s.dependencies) : vcat(s.dependencies, order[k - 1])
        out[name] = ProcessorSpec(s.name, s.level, s.enabled, s.category, s.rank, deps, s.kwargs, s.error_plots, s.log_level, s.plot_level)
    end
    return out
end

# The log level named by `section[key]`; `path` is the key path of `section`.
function _log_level(section::AbstractDict, key::Symbol, path::AbstractString)
    level = _typed(section, key, AbstractString, path)
    haskey(LOG_LEVELS, level) ||
        throw(ArgumentError("processing_config: key `$path$key` must be one of \"debug\", \"info\", \"warn\" or \"error\", got $(repr(level))"))
    return LOG_LEVELS[level]
end

# The plot level named by `section[key]`; `path` is the key path of `section`.
function _plot_level(section::AbstractDict, key::Symbol, path::AbstractString)
    level = _typed(section, key, AbstractString, path)
    Symbol(level) in PLOT_LEVEL_VALUES ||
        throw(ArgumentError("processing_config: key `$path$key` must be one of \"info\" or \"debug\", got $(repr(level))"))
    return Symbol(level)
end

function _processor_specs(table::AbstractDict, level::Symbol, section::Symbol, reprocess::Bool)
    specs = Dict{Symbol,ProcessorSpec}()
    for (name, entry) in table
        path = "$section.$name."
        entry isa AbstractDict || throw(ArgumentError("processing_config: key `$section.$name` must be a table, got $(repr(entry))"))
        _check_keys(entry, (:enabled, :category, :rank, :kwargs, :dependencies, :log_level, :plot_level), path; optional = (:error_plots,))
        category = _typed(entry, :category, AbstractString, path)
        kwargs = Dict{Symbol,Any}()
        for (k, v) in _typed(entry, :kwargs, AbstractDict, path)
            # String lists become Symbol lists, an untyped empty list becomes `Symbol[]`.
            kwargs[k] = v isa AbstractVector && all(x -> x isa AbstractString, v) ? Symbol[Symbol(x) for x in v] : v
        end
        reprocess && (kwargs[:reprocess] = true)
        specs[name] = ProcessorSpec(name, level, _typed(entry, :enabled, Bool, path), Symbol(category), _typed(entry, :rank, Int, path),
                                    Symbol.(_strings(entry, :dependencies, path)), kwargs,
                                    haskey(entry, :error_plots) && _typed(entry, :error_plots, Bool, path),
                                    _log_level(entry, :log_level, path), _plot_level(entry, :plot_level, path))
    end
    return specs
end

"""
    ProcessingConfig(dict::AbstractDict; runmode=nothing, submit_jobs=nothing,
        periods=nothing, runs=nothing, analysis_runs_only=nothing,
        only_partitions=nothing, only_runs=nothing, ignore_config=false,
        reprocess=false, log_path="")
    ProcessingConfig(filename::AbstractString; kwargs...)

Validate a parsed processing config `dict` (keys may be `Symbol`s or strings), combine
it with command line overrides and return the resulting [`ProcessingConfig`](@ref). The
second form reads `filename` (JSON or YAML) with `readlprops`.

The config must contain exactly these keys; a missing or unknown key throws an
`ArgumentError` that names the key path:

- `config`: `runmode` (`"local"` or `"slurm"`), `submit_jobs::Bool`,
  `runmode_settings.local.{n, julia_settings}`,
  `runmode_settings.slurm.{flags, julia_settings}`, `env_variables`, `log_level`
  (`"debug"`, `"info"`, `"warn"` or `"error"`), and optionally `processor_log_level`
  (same values, default `nothing`), `processor_plot_level` (`"info"` or `"debug"`, default
  `nothing`), `plot_formats` (a list of `"png"` and `"jls"`, default `["png"]`) and
  `idle_timeout_minutes` (a number, default 20)
- `processing`: `periods` and `runs` (each `"all"` or a list), `analysis_runs_only`,
  `only_partitions`, `only_runs` (all `Bool`), and optionally `order` (`"rank"`, the
  default, or `"dependencies"`) and `max_parallel_steps` (an `Int`, default 0: no limit)
- `processors`, `p_processors`: tables of processor name to
  `{enabled::Bool, category ("cal" or "phy"), rank::Int, kwargs, dependencies,
  log_level ("debug", "info", "warn" or "error"), plot_level ("info" or "debug")}`, and optionally `error_plots::Bool`

Processor names must be unique across both tables, every dependency must name a
configured processor of either level, and at least one processor must be enabled. String
lists in `kwargs` become `Vector{Symbol}`.

With `order = "dependencies"` the `dependencies` alone order the processors: processors
that do not depend on each other, directly or through others, run at the same time. With
`order = "rank"` the processors of each level also run one after another in the order of
rank, then name: every processor gets a dependency on the one before it (see
[`rank_order_dependencies`](@ref)), and a warning asks to change the config.

A key of `processors` or `p_processors`, or an entry of a `dependencies` list, that
is a name from [`RENAMED_PROCESSORS`](@ref) is read as the current name and logs a
warning naming both once per loaded config. A config that holds both the former and the
current name of one processor throws an `ArgumentError`.

Overrides:
- `analysis_runs_only`, `only_partitions`, `only_runs`, `submit_jobs`: with
  `ignore_config = true` the given value is used (`nothing` means `false`); otherwise
  `true` overrides the config and `nothing` or `false` keeps the config value.
  `only_runs` and `only_partitions` cannot both be `true`.
- `runmode`: replaces `config.runmode` when not `nothing`.
- `periods`, `runs`: lists of period and run numbers that replace the config
  selection. `periods` without `runs` selects all runs of those periods; `runs`
  without `periods` is an error.
- `reprocess = true` sets the `reprocess` keyword of every processor to `true`.
- `log_path` is stored as given.

# Examples
```jldoctest
julia> config = Dict(
           "config" => Dict("runmode" => "local", "submit_jobs" => false,
               "runmode_settings" => Dict(
                   "local" => Dict("n" => 4, "julia_settings" => []),
                   "slurm" => Dict("flags" => [], "julia_settings" => [])),
               "env_variables" => Dict(), "log_level" => "info"),
           "processing" => Dict("periods" => [3], "runs" => "all", "analysis_runs_only" => false,
               "only_partitions" => false, "only_runs" => false, "order" => "dependencies"),
           "processors" => Dict("process_energy_calibration_cal" => Dict("enabled" => true,
               "category" => "cal", "rank" => 1, "kwargs" => Dict(), "dependencies" => [],
               "log_level" => "info", "plot_level" => "info")),
           "p_processors" => Dict());

julia> cfg = ProcessingConfig(config; periods = [3, 4])
ProcessingConfig(runmode=:local, 1/1 run and 0/0 partition processors enabled)

julia> string.(cfg.periods)
2-element Vector{String}:
 "p03"
 "p04"
```
"""
function ProcessingConfig(dict::AbstractDict; runmode::Union{Nothing,AbstractString,Symbol} = nothing,
                          submit_jobs::Union{Nothing,Bool} = nothing, periods = nothing, runs = nothing,
                          analysis_runs_only::Union{Nothing,Bool} = nothing, only_partitions::Union{Nothing,Bool} = nothing,
                          only_runs::Union{Nothing,Bool} = nothing, ignore_config::Bool = false, reprocess::Bool = false,
                          log_path::AbstractString = "")
    d = _symbolkeys(dict)
    _check_keys(d, (:config, :processing, :processors, :p_processors), "")
    config = _typed(d, :config, AbstractDict, "")
    _check_keys(config, (:runmode, :submit_jobs, :runmode_settings, :env_variables, :log_level), "config.";
                optional = (:idle_timeout_minutes, :processor_log_level, :processor_plot_level, :plot_formats))
    settings = _typed(config, :runmode_settings, AbstractDict, "config.")
    _check_keys(settings, (:local, :slurm), "config.runmode_settings.")
    local_settings = _typed(settings, :local, AbstractDict, "config.runmode_settings.")
    _check_keys(local_settings, (:n, :julia_settings), "config.runmode_settings.local.")
    slurm_settings = _typed(settings, :slurm, AbstractDict, "config.runmode_settings.")
    _check_keys(slurm_settings, (:flags, :julia_settings), "config.runmode_settings.slurm.")
    processing = _typed(d, :processing, AbstractDict, "")
    _check_keys(processing, (:periods, :runs, :analysis_runs_only, :only_partitions, :only_runs), "processing.";
                optional = (:order, :max_parallel_steps))
    order = haskey(processing, :order) ? _typed(processing, :order, AbstractString, "processing.") : "rank"
    order in ("rank", "dependencies") ||
        throw(ArgumentError("processing_config: key `processing.order` must be \"rank\" or \"dependencies\", got $(repr(order))"))

    function flag(cli, section, key, path)
        value = _typed(section, key, Bool, path)
        return ignore_config ? something(cli, false) : (cli === true || value)
    end
    sel_submit_jobs = flag(submit_jobs, config, :submit_jobs, "config.")
    sel_analysis_runs_only = flag(analysis_runs_only, processing, :analysis_runs_only, "processing.")
    sel_only_partitions = flag(only_partitions, processing, :only_partitions, "processing.")
    sel_only_runs = flag(only_runs, processing, :only_runs, "processing.")
    sel_runmode = Symbol(something(runmode, _typed(config, :runmode, AbstractString, "config.")))
    n = _typed(local_settings, :n, Int, "config.runmode_settings.local.")

    env_variables = Dict{String,String}()
    for (k, v) in _typed(config, :env_variables, AbstractDict, "config.")
        v isa Union{AbstractString,Real} ||
            throw(ArgumentError("processing_config: key `config.env_variables.$k` must be a string or number, got $(repr(v))"))
        env_variables[string(k)] = string(v)
    end

    sel_periods, sel_runs = if !isnothing(periods)
        DataPeriod[DataPeriod(p) for p in periods], isnothing(runs) ? nothing : DataRun[DataRun(r) for r in runs]
    elseif !isnothing(runs)
        throw(ArgumentError("processing_config: runs without periods are not supported"))
    else
        _selection(DataPeriod, processing, :periods), _selection(DataRun, processing, :runs)
    end

    current_processors, current_p_processors = _current_names((_typed(d, :processors, AbstractDict, ""),
                                                               _typed(d, :p_processors, AbstractDict, "")))
    processors = _processor_specs(current_processors, :run, :processors, reprocess)
    p_processors = _processor_specs(current_p_processors, :partition, :p_processors, reprocess)
    if order == "rank"
        @warn "processing_config: the processors of a level run in rank order; set `processing.order` to \"dependencies\" and list the order in the `dependencies` of each processor"
        processors, p_processors = rank_order_dependencies(processors), rank_order_dependencies(p_processors)
    end

    return ProcessingConfig(sel_runmode, sel_submit_jobs, n, _strings(local_settings, :julia_settings, "config.runmode_settings.local."),
                            _strings(slurm_settings, :flags, "config.runmode_settings.slurm."),
                            _strings(slurm_settings, :julia_settings, "config.runmode_settings.slurm."), env_variables, sel_periods,
                            sel_runs, sel_analysis_runs_only, sel_only_partitions, sel_only_runs,
                            haskey(processing, :max_parallel_steps) ? _typed(processing, :max_parallel_steps, Int, "processing.") : 0,
                            log_path, parse_log_level(_typed(config, :log_level, AbstractString, "config.")),
                            haskey(config, :processor_log_level) ? _log_level(config, :processor_log_level, "config.") : nothing,
                            haskey(config, :processor_plot_level) ? _plot_level(config, :processor_plot_level, "config.") : nothing,
                            haskey(config, :plot_formats) ? Symbol.(_strings(config, :plot_formats, "config.")) : [:png],
                            haskey(config, :idle_timeout_minutes) ? _typed(config, :idle_timeout_minutes, Real, "config.") : 20, processors,
                            p_processors)
end

function ProcessingConfig(filename::AbstractString; kwargs...)
    return ProcessingConfig(readlprops(filename); kwargs...)
end

function _sorted_steps(specs::AbstractDict, enabled_only::Bool)
    return sort!([s.name for s in values(specs) if s.enabled || !enabled_only]; by = n -> (specs[n].rank, n))
end

"""
    run_steps(cfg::ProcessingConfig; enabled_only::Bool=true)

Return the names of the run-level processors of `cfg` as a `Vector{Symbol}`, sorted by
rank (ties by name). With `enabled_only = false` the disabled processors are included.
"""
function run_steps(cfg::ProcessingConfig; enabled_only::Bool = true)
    return _sorted_steps(cfg.processors, enabled_only)
end

"""
    partition_steps(cfg::ProcessingConfig; enabled_only::Bool=true)

Return the names of the partition-level processors of `cfg` as a `Vector{Symbol}`,
sorted by rank (ties by name). With `enabled_only = false` the disabled processors are
included.
"""
function partition_steps(cfg::ProcessingConfig; enabled_only::Bool = true)
    return _sorted_steps(cfg.p_processors, enabled_only)
end

# Keyword arguments the processor function of `spec` declares besides those the dataflow
# passes itself, sorted; `nothing` when a method takes `kwargs...` or the processor is
# not registered.
function accepted_kwargs(processors::AbstractDict{Symbol}, spec::ProcessorSpec)
    haskey(processors, spec.name) || return nothing
    declared = reduce(vcat, (Base.kwarg_decl(m) for m in methods(processors[spec.name])); init = Symbol[])
    any(k -> endswith(string(k), "..."), declared) && return nothing
    return sort!(collect(setdiff(declared, (:reprocess, :only_first_period))))
end

# Describe why the processor function of `spec` cannot be called with its kwargs, or
# return `nothing` when it can.
function processor_kwargs_problem(spec::ProcessorSpec, processors::AbstractDict{Symbol})
    haskey(processors, spec.name) || return "`$(spec.name)` is not a registered processor"
    declared = reduce(vcat, (Base.kwarg_decl(m) for m in methods(processors[spec.name])); init = Symbol[])
    # A method with `kwargs...` accepts every keyword.
    any(k -> endswith(string(k), "..."), declared) && return nothing
    implicit = spec.level === :partition ? (:reprocess, :only_first_period) : (:reprocess,)
    unsupported = sort!(collect(setdiff(union(keys(spec.kwargs), implicit), declared)))
    isempty(unsupported) && return nothing
    return "`$(spec.name)` does not accept keyword(s) $(join(unsupported, ", "))"
end

"""
    check_processor_kwargs(cfg::ProcessingConfig; processors::AbstractDict{Symbol} = PROCESSORS)

Check that every enabled processor of `cfg` is registered in `processors` and that its
function accepts all keyword arguments configured in its `kwargs`, plus the keywords
[`run_processing`](@ref) may pass on its own: `reprocess` for every processor and
`only_first_period` for partition processors. Throw an `ArgumentError` listing every
mismatch; return `nothing` otherwise.
"""
function check_processor_kwargs(cfg::ProcessingConfig; processors::AbstractDict{Symbol} = PROCESSORS)
    problems = String[]
    for specs in (cfg.processors, cfg.p_processors), spec in values(specs)

        spec.enabled || continue
        problem = processor_kwargs_problem(spec, processors)
        isnothing(problem) || push!(problems, problem)
    end
    isempty(problems) || throw(ArgumentError("processing_config: processor kwargs mismatch:\n  " * join(problems, "\n  ")))
    return nothing
end

function Base.show(io::IO, spec::ProcessorSpec)
    return print(io, "ProcessorSpec(", repr(spec.name), ", level=", repr(spec.level), ", category=", repr(spec.category), ", rank=",
                 spec.rank, ", enabled=", spec.enabled, ")")
end

function Base.show(io::IO, cfg::ProcessingConfig)
    return print(io, "ProcessingConfig(runmode=", repr(cfg.runmode), ", ", length(run_steps(cfg)), "/", length(cfg.processors), " run and ",
                 length(partition_steps(cfg)), "/", length(cfg.p_processors), " partition processors enabled)")
end
