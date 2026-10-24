# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Summary plots of the PMT 1 p.e. calibration (`process_pmts_calibration_cal`) for all PMTs of
# one MVC file. The plot of a single fit is the LegendMakie recipe of the `fit_pmt_spe` report.

const _PMT_LOCATION_COLORS = Dict(:floor => LegendMakie.CoaxGreen, :pillbox => LegendMakie.BEGeOrange, :wall => LegendMakie.AchatBlue)

# PMTs sorted by location and name
_pmt_sorted(chinfo) = sort(collect(chinfo); by = c -> (string(c.location), string(c.detector)))

# fit status of a PMT in the parameters, "missing" without parameters
function _pmt_status(pars_db, det, e_type::Symbol)
    haskey(pars_db, det) && haskey(pars_db[det], e_type) || return "missing"
    return string(pars_db[det][e_type].fit.status)
end

"""
    pmt_spe_grid(title, chinfo, reports::AbstractDict, pars_db, e_type::Symbol; ncol::Int = 5) -> Makie.Figure

The 1 p.e. fits (`fit_pmt_spe` reports by detector) of all PMTs in `chinfo`, one panel each,
sorted by location; PMTs whose fit is not `ok` in `pars_db` have their status in the title, and
PMTs without a report get an empty panel.
"""
function pmt_spe_grid(title, chinfo, reports::AbstractDict, pars_db, e_type::Symbol; ncol::Int = 5)
    pmts = _pmt_sorted(chinfo)
    nrow = cld(length(pmts), ncol)
    fig = Makie.Figure(; size = (ncol * 450, nrow * 330 + 60))
    Makie.current_figure!(fig)
    for (i, c) in enumerate(pmts)
        row, col = fldmod1(i, ncol)
        status = _pmt_status(pars_db, c.detector, e_type)
        panel_title = "$(c.detector) ($(c.location))" * (status == "ok" ? "" : "  $status")
        if haskey(reports, c.detector)
            LegendMakie.lplot!(reports[c.detector]; row, col, title = panel_title, titlesize = 14, show_residuals = false,
                               legend_position = i == 1 ? :rt : :none, watermark = false)
        else
            ax = Makie.Axis(fig[row, col]; title = panel_title, titlesize = 14)
            Makie.hidedecorations!(ax)
            Makie.text!(ax, 0.5, 0.5; text = "no fit", space = :relative, align = (:center, :center), color = :red)
        end
    end
    nbad = count(c -> _pmt_status(pars_db, c.detector, e_type) != "ok", pmts)
    Makie.Label(fig[0, :], "$title -- $e_type, $(length(pmts)) PMTs" * (nbad > 0 ? ", $nbad not ok" : ""); fontsize = 20, font = :bold,
                tellwidth = false)
    return fig
end

"""
    pmt_spe_mu1_overview(title, chinfo, pars_db, e_type::Symbol; before = nothing) -> Makie.Figure

The 1 p.e. positions `μ1` in `pars_db` of all PMTs in `chinfo`, grouped by location; fits that
are not `ok` in red. `before`: the parameters of the MVC file before a HV change, drawn as
open circles.
"""
function pmt_spe_mu1_overview(title, chinfo, pars_db, e_type::Symbol; before = nothing)
    pmts = _pmt_sorted(chinfo)
    x = collect(eachindex(pmts))
    μ1(pars, det) = haskey(pars, det) && haskey(pars[det], e_type) ? pars[det][e_type].fit.μ1 : NaN
    mu = [μ1(pars_db, c.detector) for c in pmts]
    ok = [_pmt_status(pars_db, c.detector, e_type) == "ok" for c in pmts]

    fig = Makie.Figure(; size = (1600, 520))
    ax = Makie.Axis(fig[1, 1]; ylabel = "µ1 (ADC)", xticks = (x, string.(getproperty.(pmts, :detector))), xticklabelrotation = π / 2,
                    xgridvisible = false)
    if !isnothing(before)
        mu_before = [mvalue(μ1(before, c.detector)) for c in pmts]
        Makie.scatter!(ax, x, mu_before; color = :transparent, strokecolor = :dimgray, strokewidth = 1, markersize = 9,
                       label = "before HV change")
    end
    Makie.errorbars!(ax, x[ok], mvalue.(mu[ok]), muncert.(mu[ok]); color = :black, whiskerwidth = 4)
    Makie.scatter!(ax, x[ok], mvalue.(mu[ok]); color = :black, markersize = 7, label = "µ1 (fit ok)")
    any(.!ok) && Makie.scatter!(ax, x[.!ok], mvalue.(mu[.!ok]); color = :red, markersize = 10, label = "fit not ok")

    # location groups: separators and names above the points
    values = filter(isfinite, vcat(mvalue.(mu), isnothing(before) ? Float64[] : mu_before))
    y_lo, y_hi = isempty(values) ? (0.0, 1.0) : extrema(values)
    y_top = y_hi + 0.15 * max(y_hi - y_lo, 1.0)
    for loc in unique(getproperty.(pmts, :location))
        idx = findall(c -> c.location == loc, pmts)
        first(idx) > 1 && Makie.vlines!(ax, [first(idx) - 0.5]; color = :dimgray, linestyle = :dot)
        Makie.text!(ax, (first(idx) + last(idx)) / 2, y_top; text = titlecase(string(loc)), align = (:center, :top),
                    color = get(_PMT_LOCATION_COLORS, loc, :black), fontsize = 13)
    end
    Makie.xlims!(ax, 0.5, length(pmts) + 0.5)
    Makie.ylims!(ax, y_lo - 0.1 * max(y_hi - y_lo, 1.0), y_top)
    Makie.Legend(fig[1, 2], ax; framevisible = false)
    Makie.Label(fig[0, :], "$title -- $e_type, 1 p.e. position of $(length(pmts)) PMTs ($(count(.!ok)) not ok)"; fontsize = 15,
                font = :bold, tellwidth = false)
    return fig
end
