# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Plots of the PMT 1 p.e. calibration (`process_pmts_calibration_cal`), in the style of the
# muon-veto operations calibration (mvcal.py): `pmt_spe_grid` and `pmt_spe_mu1_overview`.
#
# `panels` is a vector of NamedTuples, one per PMT, with precomputed arrays (no refitting):
#   (det::Symbol, place::String, edges, counts, popt::Vector (empty if no fit), x_min,
#    mu1, mu1_err, sig1, chi2ndf, status::Symbol, error::String)
# status ∈ (:ok, :bad_fit, :fit_failed, :error)

const _OV_DEEP_COVE = Makie.RGBf(0x1A / 255, 0x2A / 255, 0x5B / 255)   # legendstyles colors
const _OV_ACHAT_BLUE = Makie.RGBf(0x07 / 255, 0xA9 / 255, 0xFF / 255)
const _OV_DIAMOND_GREY = Makie.RGBf(0xCC / 255, 0xCC / 255, 0xCC / 255)
const _OV_LOCATION_COLORS = Dict("Floor" => Makie.RGBf(0x4a / 255, 0x7c / 255, 0x59 / 255),
                                 "Pillbox" => Makie.RGBf(0x8c / 255, 0x6d / 255, 0x46 / 255),
                                 "Wall" => Makie.RGBf(0x6a / 255, 0x5a / 255, 0x8c / 255))
const _OV_RED_BOX = (:red, 0.3)

_ov_pmtnum(det) = parse(Int, string(det)[4:end])
_ov_problem(p) = p.status != :ok
_ov_sorted(panels) = sort(collect(panels); by = p -> (p.place, _ov_pmtnum(p.det)))

# "PMT101  bad_fit" left (red box on problems), location right
function _ov_header!(gl, p; fontsize = 12)
    hl = gl[1, 1] = Makie.GridLayout()
    _ov_problem(p) && Makie.Box(hl[1, 1]; color = _OV_RED_BOX, strokevisible = false, cornerradius = 3)
    Makie.Label(hl[1, 1], "$(p.det)" * (_ov_problem(p) ? "  $(p.status)" : ""); fontsize = fontsize,
                padding = (3, 3, 1, 1), halign = :left)
    Makie.Label(hl[1, 3], p.place; fontsize = fontsize, halign = :right,
                color = get(_OV_LOCATION_COLORS, p.place, :black))
    Makie.colsize!(hl, 2, Makie.Auto(1))
    return Makie.rowgap!(gl, 2)
end

# data, fit and components, µ1 / 2µ1 lines, not-fitted range -- one axes
function _ov_spectrum!(ax, p; labelsize = 7, legend = true)
    edg = collect(Float64, p.edges)
    cen = edg[1:(end - 1)] .+ diff(edg) ./ 2
    cnt = Float64.(p.counts)
    Makie.stairs!(ax, cen, max.(cnt, 0.1); step = :center, color = _OV_DIAMOND_GREY, linewidth = 1.2, label = "data")
    if !isempty(p.popt)
        xx = collect(range(p.x_min, last(edg), length = 600))
        comps = LegendSpecFits.pmts_spe_components(xx, p.popt)
        # the exponential is part of the fit but not drawn (it only describes the last
        # bins of the pedestal tail and looks like an artefact on its own)
        Makie.lines!(ax, xx, max.(LegendSpecFits.pmts_spe_model(xx, p.popt), 0.1); color = _OV_DEEP_COVE, linewidth = 1.5, label = "fit")
        for (c, ls, lab) in ((comps.pe1, :dash, "1 p.e."), (comps.pe2, :dashdot, "2 p.e."))
            Makie.lines!(ax, xx, [y > 0.05 ? y : NaN for y in c]; color = _OV_ACHAT_BLUE, linestyle = ls, linewidth = 1.1, label = lab)
        end
        Makie.vlines!(ax, [p.mu1]; color = _OV_ACHAT_BLUE, linewidth = 0.9, linestyle = :dot,
                      label = "µ1 = $(round(p.mu1, digits = 2)) ± $(round(p.mu1_err, digits = 2)) LSB")
        Makie.vlines!(ax, [2 * p.mu1]; color = (_OV_ACHAT_BLUE, 0.7), linewidth = 0.7, linestyle = :dot)
        Makie.vspan!(ax, first(edg), p.x_min; color = (_OV_DIAMOND_GREY, 0.25), label = "not fitted")
    else
        Makie.text!(ax, 0.5, 0.5; text = isempty(p.error) ? "no fit" : p.error, space = :relative,
                    align = (:center, :center), color = :red, fontsize = labelsize + 2)
    end
    Makie.xlims!(ax, first(edg), last(edg))
    Makie.ylims!(ax, 0.5, max(maximum(cnt; init = 1.0), 1.0) * 3)
    if legend
        Makie.axislegend(ax; position = :rt, labelsize = labelsize, rowgap = -3, padding = (3, 3, 2, 2),
                         framevisible = true, backgroundcolor = (:white, 0.75), patchsize = (14, 8))
    elseif !isempty(p.popt)
        Makie.text!(ax, 0.97, 0.97; text = "µ1 = $(round(p.mu1, digits = 2)) ± $(round(p.mu1_err, digits = 2))",
                    space = :relative, align = (:right, :top), fontsize = labelsize + 3, color = _OV_DEEP_COVE)
    end
end

"""
    pmt_spe_grid(pagetitle, panels; ncol = 5) -> Makie.Figure

Spectra + 1 p.e. fits of all processed PMTs, one panel each, sorted by location and
PMT number (mvcal.py `plot_fits`). For a quick look.
"""
function pmt_spe_grid(pagetitle::AbstractString, panels::AbstractVector; ncol::Int = 5)
    panels = _ov_sorted(filter(p -> !isempty(p.counts), panels))
    isempty(panels) && error("no processed PMT to plot")
    nrow = cld(length(panels), ncol)
    S    = 330
    fig  = Makie.Figure(size = (ncol * S, nrow * S + 40), fontsize = 10)
    for (i, p) in enumerate(panels)
        r, c = fldmod1(i, ncol)
        gl = fig[r, c] = Makie.GridLayout()
        _ov_header!(gl, p)
        ax = Makie.Axis(gl[2, 1]; yscale = log10, xlabel = "pulse_height (LSB)", ylabel = "events / 1 LSB",
                        xgridcolor = (:black, 0.08), ygridcolor = (:black, 0.08))
        _ov_spectrum!(ax, p; labelsize = 8, legend = i == 1)   # legend once, µ1 as text elsewhere
    end
    nbad = count(_ov_problem, panels)
    Makie.Label(fig[0, :], "$pagetitle -- active PMTs ($(length(panels))" * (nbad > 0 ? ", $nbad fit problems" : "") * ")";
                fontsize = 15, font = :bold, tellwidth = false)
    return fig
end

"""
    pmt_spe_mu1_overview(pagetitle, panels; before = nothing) -> Makie.Figure

µ1 of all processed PMTs, grouped by location (mvcal.py `plot_overview`, without target band).
`before`: Dict(det => µ1) of the previous MVC file of the run (before the HV change),
drawn as open circles.
"""
function pmt_spe_mu1_overview(pagetitle::AbstractString, panels::AbstractVector;
                              before::Union{Nothing,AbstractDict} = nothing)
    act = _ov_sorted(filter(p -> !isempty(p.counts), panels))
    isempty(act) && error("no processed PMT to plot")
    x      = collect(1:length(act))
    mu     = [p.mu1 for p in act]
    ok     = [p.status == :ok for p in act]
    vals   = vcat(mu[isfinite.(mu)], before === nothing ? Float64[] : [v for v in values(before) if isfinite(v)])
    top    = isempty(vals) ? 30.0 : 1.1 * maximum(vals)
    bottom = isempty(vals) ? 0.0 : 0.9 * minimum(vals)

    fig = Makie.Figure(size = (1600, 520), fontsize = 12)
    ax  = Makie.Axis(fig[1, 1]; ylabel = "µ1 (LSB)", xticks = (x, string.(getproperty.(act, :det))),
    xticklabelrotation = π / 2, xgridvisible = false, ygridcolor = (:black, 0.1))
    if before !== nothing
        xb = [i for (i, p) in enumerate(act) if isfinite(get(before, p.det, NaN))]
        Makie.scatter!(ax, xb, [before[act[i].det] for i in xb]; marker = :circle, color = :transparent,
                       strokecolor = :dimgray, strokewidth = 1, markersize = 9, label = "before HV change")
    end
    Makie.errorbars!(ax, x[ok], mu[ok], [p.mu1_err for p in act[ok]]; color = :black, whiskerwidth = 4)
    Makie.scatter!(ax, x[ok], mu[ok]; color = :black, markersize = 7, label = "µ1 (fit)")
    if any(.!ok)
        yb = [isfinite(m) ? m : bottom + 0.05 * (top - bottom) for m in mu[.!ok]]
        Makie.scatter!(ax, x[.!ok], yb; color = :red, markersize = 10, label = "fit failed / bad fit")
    end
    # location groups: separators and names above the axes
    for loc in unique(getproperty.(act, :place))
        idx = findall(p -> p.place == loc, act)
        first(idx) > 1 && Makie.vlines!(ax, [first(idx) - 0.5]; color = :dimgray, linestyle = :dot)
        Makie.text!(ax, (first(idx) + last(idx)) / 2, top; text = loc, align = (:center, :bottom),
                    color = get(_OV_LOCATION_COLORS, loc, :black), fontsize = 13)
    end
    Makie.xlims!(ax, 0.5, length(act) + 0.5)
    Makie.ylims!(ax, bottom, top * 1.06)
    Makie.Legend(fig[1, 2], ax; labelsize = 11, framevisible = false)   # outside: never covers points
    Makie.Label(fig[0, :], "$pagetitle -- 1 p.e. position of $(length(act)) active PMTs ($(count(.!ok)) fit problems)";
                fontsize = 15, font = :bold, tellwidth = false)
    return fig
end
