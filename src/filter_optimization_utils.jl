# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Shared per-detector flow of process_filter_optimization and p_process_filter_optimization.

# The Tl-208 SEP and DEP lie one and two electron masses below the FEP.
const ELECTRON_MASS_ENERGY = 510.999u"keV"

# DEP fit window below and above the line: the Bi-212 FEP at 1620.7 keV, 28 keV above the DEP,
# stays outside.
const DEP_WINDOW = (15.0u"keV", 12.0u"keV")

const DEP_PEAKNAME = :Tl208DEP_Bi212FEP
const SEP_PEAKNAME = :Tl208SEP

"""
    single_site_aoe_cut(a::AbstractVector, e::AbstractVector; aoe_cut_sigma::Real)

Coarse in-situ single-site selection on the A/E values `a ./ e` (units stripped). A truncated
Gaussian is fitted to the high side of the A/E peak with `fit_half_trunc_gauss`, and events
above `μ - aoe_cut_sigma * σ` are kept. This is not the calibrated A/E cut.

Returns the selection mask, which has the axes of `a`, and the report
`(h, f_fit, μ, σ, cut_value, n_sigma, sf)`, where `sf` is the kept fraction.
"""
function single_site_aoe_cut(a::AbstractVector, e::AbstractVector; aoe_cut_sigma::Real)
    axes(a) == axes(e) || throw(DimensionMismatch("a and e must share axes: $(axes(a)) vs $(axes(e))"))
    aoe = ustrip.(a) ./ ustrip.(e)
    aoe_valid = collect(filter(x -> isfinite(x) && x > 0, aoe))
    length(aoe_valid) >= 100 || throw(ArgumentError("The A/E selection needs at least 100 finite positive A/E values, got $(length(aoe_valid))"))
    cuts = cut_single_peak(aoe_valid, quantile(aoe_valid, 0.01), quantile(aoe_valid, 0.995); relative_cut = 0.5)
    (; result, report) = fit_half_trunc_gauss(aoe_valid, cuts; left = false, uncertainty = false)
    μ, σ = mvalue(result.μ), mvalue(result.σ)
    cut_value = μ - aoe_cut_sigma * σ
    mask = map(x -> isfinite(x) && x > cut_value, aoe)
    return mask, (h = report.h, f_fit = report.f_fit, μ = μ, σ = σ, cut_value = cut_value, n_sigma = aoe_cut_sigma, sf = count(mask) / length(mask))
end


"""
    crosscheck_warning(legacy::NamedTuple, new::NamedTuple; max_shift_sigma::Real)

Warning text for a new optimum that moves the reconstruction relative to the legacy optimum,
`""` if nothing is flagged. Both arguments carry `shifts`, a NamedTuple of `(shift, σ)` per
crosscheck peak (the fitted position relative to its FEP-calibrated expectation, and the peak
width), and `slow_mean_residual`, the mean FEP residual in units of σ of the slowest five
percent of events by `t90 - t10`.

A peak is flagged when its shift changes by more than `max_shift_sigma` times its σ at the new
optimum, or when it is missing at one of the two optima; the slow-pulse class is flagged when
its mean residual changes by more than `max_shift_sigma`.
"""
function crosscheck_warning(legacy::NamedTuple, new::NamedTuple; max_shift_sigma::Real)
    warnings = String[]
    for peak in union(keys(legacy.shifts), keys(new.shifts))
        if !(haskey(legacy.shifts, peak) && haskey(new.shifts, peak))
            push!(warnings, "$peak crosscheck missing at the $(haskey(new.shifts, peak) ? "legacy" : "new") optimum")
            continue
        end
        Δ = new.shifts[peak].shift - legacy.shifts[peak].shift
        abs(Δ) > max_shift_sigma * new.shifts[peak].σ && push!(warnings, "$peak shift changed by $(round(u"keV", Δ, digits = 2))")
    end
    Δslow = new.slow_mean_residual - legacy.slow_mean_residual
    abs(Δslow) > max_shift_sigma && push!(warnings, "slow-pulse residual changed by $(round(Δslow, digits = 2))σ")
    return join(warnings, "; ")
end


"""
    write_fltopt_tables(path::AbstractString, tables::NamedTuple)

Write every entry of `tables` (anything `TypedTables.Table` accepts) to the LH5 file `path`
under its name. Symbol and string columns are stored as strings, `Measurement` values as
their central values.
"""
function write_fltopt_tables(path::AbstractString, tables::NamedTuple)
    lh5open(path, "w") do h
        for (name, t) in pairs(tables)
            h[string(name)] = Table(map(c -> map(x -> x isa Union{Symbol, AbstractString} ? String(x) : mvalue(x), c), columns(Table(t))))
        end
    end
    return path
end
