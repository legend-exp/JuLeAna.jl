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
    register_processor!(f; output_tiers = Symbol[], detector_selection::Bool = true)

Add the processor function `f` to [`PROCESSORS`](@ref) under `nameof(f)` and return `f`.
`output_tiers` are the data tiers the processor writes, for example `[:jldsp]`;
`detector_selection` is `false` for a processor that does not process the detectors
[`redo_detector`](@ref) names again. Both go to [`PROCESSOR_TRAITS`](@ref) for
[`run_step`](@ref). Throw an `ArgumentError` when a processor of that name is already
registered.
"""
function register_processor!(f; output_tiers = Symbol[], detector_selection::Bool = true)
    name = nameof(f)
    haskey(PROCESSORS, name) && throw(ArgumentError("register_processor!: processor `$name` is already registered"))
    PROCESSORS[name] = f
    PROCESSOR_TRAITS[name] = (output_tiers = Symbol.(collect(output_tiers)), detector_selection)
    return f
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
