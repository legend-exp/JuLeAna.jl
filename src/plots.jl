# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Plot level of the running processor, `:info` or `:debug`, set by `run_processing` and
# `run_step`. `parallel` sets it again on the workers.
const PLOT_LEVEL = ScopedValue{Symbol}(:info)

# Formats in which `save_plot` writes a figure, from `config.plot_formats`. `parallel` sets
# it again on the workers.
const PLOT_FORMATS = ScopedValue{Vector{Symbol}}([:png])

"""
    save_plot(fig::Makie.Figure, l200::LegendData, args...; cleanup::Bool = true)

Save `fig` at the plot path that `savelfig` of LegendDataManagement builds from `l200` and
`args`, e.g. `save_plot(fig, l200, filekey, det, :fwhm)` or
`save_plot(fig, l200, partition, filekey, det, :fwhm)`. The figure is written in each of the
`plot_formats` of the processing config (see [`ProcessingConfig`](@ref)): `png`, and `jls`,
the figure serialized with `Serialization` next to the PNG under the same name. A `jls` file
can be read only with the same package versions and holds the whole Makie theme, several
MB per figure.

With `cleanup = true` the figure is emptied after it is written, which releases its memory:
it cannot be shown or saved again. `cleanup = false` keeps it, e.g. to add it to a report
afterwards; the caller then empties it with `empty!(fig)` when done.
"""
function save_plot(fig::Makie.Figure, l200::LegendData, args...; cleanup::Bool = true)
    formats = PLOT_FORMATS[]
    savelfig(fig, l200, args...) do fig, file
        :jls in formats && serialize(first(splitext(file)) * ".jls", fig)
        :png in formats && LegendMakie.lsavefig(fig, file; cleanup = false)
        return cleanup && empty!(fig)
    end
    return nothing
end

"""
    @debug_plot block

Run `block`, which builds and saves a plot, only when the plot level of the running
processor is `debug` (see [`ProcessorSpec`](@ref) and [`run_step`](@ref)); otherwise skip it,
so that the figure is not built. Return the value of `block`, or `nothing` when it is
skipped.

# Examples
```julia
@debug_plot begin
    fig = LegendMakie.lplot(report_simple, title = get_plottitle(filekey, det, "Simple Calibration"))
    save_plot(fig, l200, filekey, det, :simple_calibration)
end
```
"""
macro debug_plot(block)
    return :(PLOT_LEVEL[] === :debug ? $(esc(block)) : nothing)
end
