# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    PROCESSORS::Dict{Symbol,Function}

Registry of the processor functions of the dataflow, keyed by processor name. The
names are the keys of the `processors` and `p_processors` tables of a processing
config. Every file in `src/processors/` adds its processor with
[`register_processor!`](@ref) when the module is defined.
"""
const PROCESSORS = Dict{Symbol,Function}()

"""
    register_processor!(f; output_tiers = Symbol[], detector_selection::Bool = true, items = nothing)

Add the processor function `f` to [`PROCESSORS`](@ref) under `nameof(f)` and return `f`.
`output_tiers` are the data tiers the processor writes, for example `[:jldsp]`;
`detector_selection` is `false` for a processor that does not process the detectors
[`redo_detector`](@ref) names again. `items`, when not `nothing`, is a function
`(processing_config, l200, period, run)` that returns the items the processor hands to
[`parallel`](@ref) for a run (`run` is `nothing` for a partition processor); it must
read them the same way the processor does. All three go to [`PROCESSOR_TRAITS`](@ref).
Throw an `ArgumentError` when a processor of that name is already registered.
"""
function register_processor!(f; output_tiers = Symbol[], detector_selection::Bool = true, items = nothing)
    name = nameof(f)
    haskey(PROCESSORS, name) && throw(ArgumentError("register_processor!: processor `$name` is already registered"))
    PROCESSORS[name] = f
    PROCESSOR_TRAITS[name] = (output_tiers = Symbol.(collect(output_tiers)), detector_selection, items)
    return f
end

"""
    JuLeAna.run_filekeys(l200, period::DataPeriod, run::DataRun, category)

Return the filekeys of `category` of the run listed in the runinfo, except the filekeys
marked unprocessable in `bad_filekeys`.
"""
function run_filekeys(l200, period::DataPeriod, run::DataRun, category)
    return filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, category)).keys))
end

"""
    display_name(name::Symbol) -> String

The name of the processor `name` as the terminal interface shows it: without the
`process_` or `p_process_` prefix and without the category suffix `_cal` or `_phy`, for
example `"decay_time"` for `:process_decay_time_cal`. The category is shown separately.
A name without the prefix, such as a report name, loses only the suffix.
"""
function display_name(name::Symbol)
    s = chopprefix(chopprefix(string(name), "p_process_"), "process_")
    return String(chopsuffix(chopsuffix(s, "_cal"), "_phy"))
end

# The LegendDSP function `name` that the dataprod config key `config_key` selects.
function legend_dsp_function(name, config_key::AbstractString)
    sym = Symbol(name)
    isdefined(LegendDSP, sym) || throw(ArgumentError("dataprod config key `$config_key` selects `$sym`, which LegendDSP does not define"))
    return getglobal(LegendDSP, sym)
end
