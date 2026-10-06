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


"""
    load_peak_waveforms(l200::LegendData, filekey::FileKey, det, peakname::Symbol, max_wvfs::Integer)
    load_peak_waveforms(l200::LegendData, partinfo_det, det, peakname::Symbol, max_wvfs::Integer; n_evts::Integer)

Presummed and windowed waveforms and presum rates of the `peakname` events of detector `det`
from the jlpks tier: of the run of `filekey`, or of all runs of the partition `partinfo_det`
with `n_evts` events per run. See `limit_peak_waveforms` for sets above `max_wvfs` events.
"""
function load_peak_waveforms(l200::LegendData, filekey::FileKey, det, peakname::Symbol, max_wvfs::Integer)
    limit_peak_waveforms(read_ldata(peakname, l200, DataTier(:jlpks), filekey, det), peakname, max_wvfs)
end

function load_peak_waveforms(l200::LegendData, partinfo_det, det, peakname::Symbol, max_wvfs::Integer; n_evts::Integer)
    limit_peak_waveforms(read_ldata(peakname, l200, DataTier(:jlpks), :cal, partinfo_det, det; n_evts), peakname, max_wvfs)
end


"""
    limit_peak_waveforms(peak_data, peakname::Symbol, max_wvfs::Integer)

`(wvfs_pre, wvfs_wdw, presum_rate)` of `peak_data`. A set with more than `max_wvfs` events is
reduced to `max_wvfs` indices drawn with replacement from the first `max_wvfs` events.
"""
function limit_peak_waveforms(peak_data, peakname::Symbol, max_wvfs::Integer)
    wvfs_pre, wvfs_wdw, presum_rate = peak_data.waveform_presummed, peak_data.waveform_windowed, peak_data.presum_rate
    if length(wvfs_pre) > max_wvfs
        @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
        sel = rand(1:max_wvfs, max_wvfs)
        wvfs_pre, wvfs_wdw, presum_rate = wvfs_pre[sel], wvfs_wdw[sel], presum_rate[sel]
    end
    return (; wvfs_pre, wvfs_wdw, presum_rate)
end


"""
    prepare_peak_set(wvfs::NamedTuple, dsp_config::DSPConfig, τ::Unitful.Time, f_evaluate_qc, qc_string::AbstractString)

Apply the QC selection `qc_string` to the waveforms of one peak as returned by
`load_peak_waveforms`, compute qdrift from the windowed waveforms and prepare the presummed
waveforms once with `dsp_flt_optimization_prepare`.

Returns `(wvfs_pre, prep, qdrift)` of the events passing the QC.
"""
function prepare_peak_set(wvfs::NamedTuple, dsp_config::DSPConfig, τ::Unitful.Time, f_evaluate_qc, qc_string::AbstractString)
    dsp_qc = dsp_qc_flt_optimization_compressed(wvfs.wvfs_pre, dsp_config, τ, f_evaluate_qc)
    qc = findall(ljl_propfunc(qc_string).(dsp_qc))
    isempty(qc) && throw(ErrorException("No event passes the QC selection $qc_string"))
    @debug "QC survival fraction: $(round(length(qc) / length(dsp_qc) * 100, digits = 2))%"
    wvfs_pre = wvfs.wvfs_pre[qc]
    qdrift = dsp_qdrift_flt_optimization(wvfs.wvfs_wdw[qc], (dsp_qc.blmean ./ wvfs.presum_rate)[qc], dsp_config, τ)
    return (; wvfs_pre, prep = dsp_flt_optimization_prepare(wvfs_pre, dsp_config, τ), qdrift)
end


"""
    fit_crosscheck_peak(e_cal::AbstractVector{<:Unitful.Energy}, line::Unitful.Energy, window::Tuple; containment::Real)

Fit the calibrated energies `e_cal` inside `line - window[1] .. line + window[2]` with
`fit_single_peak_th228` and compute `peak_width_metrics` of the fitted signal shape.

Returns `(μ, σ, fwhm, w90, asym, tail_fraction, tail_scale, centroid, n_events, h, f_fit)`;
energies carry keV units, the histogram `h` and the fit function `f_fit` (counts per keV) work
on unitless keV. Throws an `ArgumentError` with fewer than 100 events in the window.
"""
function fit_crosscheck_peak(e_cal::AbstractVector{<:Unitful.Energy}, line::Unitful.Energy, window::Tuple; containment::Real)
    x = ustrip.(u"keV", filter(e -> line - first(window) < e < line + last(window), e_cal))
    length(x) >= 100 || throw(ArgumentError("Only $(length(x)) events in the fit window around $line"))
    bin_width = 2 * StatsBase.iqr(x) / cbrt(length(x))
    h = StatsBase.fit(StatsBase.Histogram, x, minimum(x):bin_width:maximum(x))
    result, report = fit_single_peak_th228(h, estimate_single_peak_stats(h); uncertainty = false)
    v = (μ = mvalue(result.μ), σ = mvalue(result.σ), n = mvalue(result.n),
         skew_fraction = mvalue(result.skew_fraction), skew_width = mvalue(result.skew_width))
    m = peak_width_metrics(v; containment)
    return (μ = v.μ * u"keV", σ = v.σ * u"keV", fwhm = m.fwhm * u"keV", w90 = m.w90 * u"keV", asym = m.asym,
            tail_fraction = m.tail_fraction, tail_scale = m.tail_scale * u"keV", centroid = m.centroid * u"keV",
            n_events = length(x), h = h, f_fit = report.f_fit)
end


"""
    crosscheck_optimum(sets::NamedTuple, pulse::NamedTuple, aoe::AbstractVector, aoe_mask,
                       dsp_config::DSPConfig, opt_config::PropDict, flt_config::PropDict,
                       flt::Symbol, rt::Unitful.Time, ft::Unitful.Time)

Reconstruction crosscheck of filter `flt` at `(rt, ft)`.

The FEP set is evaluated with `evaluate_energy_point`; its qdrift slope `fct` and simple
calibration `m_cal_simple` are applied unchanged to the DEP and SEP sets (present in `sets` if
enabled) and to the FEP events selected by `aoe_mask` (`nothing` disables this check). Every
peak is fitted with `fit_crosscheck_peak`. A failing FEP fit throws; failing DEP, SEP and
single-site FEP fits are recorded in the `status` of their row and left out of `fits` and
`shifts`.

Per-event FEP residuals `(e - μ) / σ` cover the events inside the FEP window with finite
`t10`, `t90` and A/E; `slow_mean` is their mean over the slowest five percent by `t90 - t10`.

Returns `(fep_row, fits, rows, shifts, slow_mean_residual, residuals, ctc_report)`:
- `fep_row`: `evaluate_energy_point` row of the FEP
- `fits`: `fit_crosscheck_peak` results by peak (`:FEP`, `:DEP`, `:SEP`, `:FEP_SSE`)
- `rows`: one crosscheck table row per attempted peak
- `shifts`: `(shift, σ)` of `:DEP` and `:SEP`, scaled so that the FEP sits at its line
- `residuals`: `(residual, qdrift, rise_time, aoe, slow_mean)`
- `ctc_report`: `ctc_energy` report of the FEP energies if `opt_config.apply_ctc`, else `nothing`
"""
function crosscheck_optimum(sets::NamedTuple, pulse::NamedTuple, aoe::AbstractVector, aoe_mask::Union{Nothing, AbstractVector{Bool}},
        dsp_config::DSPConfig, opt_config::PropDict, flt_config::PropDict, flt::Symbol, rt::Unitful.Time, ft::Unitful.Time)
    peak = opt_config.peak
    window = (opt_config.left_window_size, opt_config.right_window_size)
    containment = opt_config.containment

    e_fep = dsp_energy_rtft(sets.fep.prep, dsp_config, rt, ft, flt)
    fep_row = evaluate_energy_point(e_fep, sets.fep.qdrift, peak, window, flt_config.min_e_fep, flt_config.max_e_fep,
        flt_config.rel_cut_fit_e_fep; n_bins = flt_config.nbins_e_fep, apply_ctc = opt_config.apply_ctc, containment)
    calibrate(e, qdrift) = (e .+ fep_row.fct .* qdrift) .* fep_row.m_cal_simple
    e_cal_fep = calibrate(e_fep, sets.fep.qdrift)

    checks = NamedTuple[(name = :FEP, e_cal = e_cal_fep, line = peak, window = window)]
    if haskey(sets, :dep)
        push!(checks, (name = :DEP, e_cal = calibrate(dsp_energy_rtft(sets.dep.prep, dsp_config, rt, ft, flt), sets.dep.qdrift),
                       line = peak - 2 * ELECTRON_MASS_ENERGY, window = DEP_WINDOW))
    end
    if haskey(sets, :sep)
        push!(checks, (name = :SEP, e_cal = calibrate(dsp_energy_rtft(sets.sep.prep, dsp_config, rt, ft, flt), sets.sep.qdrift),
                       line = peak - ELECTRON_MASS_ENERGY, window = window))
    end
    isnothing(aoe_mask) || push!(checks, (name = :FEP_SSE, e_cal = e_cal_fep[aoe_mask], line = peak, window = window))

    fit_names, fit_values, statuses = Symbol[], NamedTuple[], String[]
    for c in checks
        fit, status = try
            fit_crosscheck_peak(c.e_cal, c.line, c.window; containment), "ok"
        catch e
            # every other crosscheck is calibrated with the FEP fit
            c.name == :FEP && rethrow()
            @warn "$(c.name) crosscheck of $flt at rt = $rt, ft = $ft failed: $(truncate_error(e))"
            nothing, "failed: $(truncate_error(e, 200))"
        end
        push!(statuses, status)
        isnothing(fit) || (push!(fit_names, c.name); push!(fit_values, fit))
    end
    fits = NamedTuple{Tuple(fit_names)}(Tuple(fit_values))
    k = peak / fits.FEP.μ

    rows = map(checks, statuses) do c, status
        f = get(fits, c.name, nothing)
        if isnothing(f)
            (peak = String(c.name), line = c.line, μ = NaN * u"keV", σ = NaN * u"keV", shift = NaN * u"keV",
             fwhm = NaN * u"keV", w90 = NaN * u"keV", asym = NaN, tail_fraction = NaN, tail_scale = NaN * u"keV",
             centroid = NaN * u"keV", n_events = 0, status = status)
        else
            (peak = String(c.name), line = c.line, μ = f.μ, σ = f.σ, shift = f.μ * k - c.line,
             fwhm = f.fwhm, w90 = f.w90, asym = f.asym, tail_fraction = f.tail_fraction, tail_scale = f.tail_scale,
             centroid = f.centroid, n_events = f.n_events, status = status)
        end
    end
    shift_peaks = Tuple(p for p in (:DEP, :SEP) if haskey(fits, p))
    line_of = Dict(c.name => c.line for c in checks)
    shifts = NamedTuple{shift_peaks}(map(p -> (shift = fits[p].μ * k - line_of[p], σ = fits[p].σ * k), shift_peaks))

    rise_time = pulse.t90 .- pulse.t10
    sel = [i for i in eachindex(e_cal_fep, rise_time, aoe, sets.fep.qdrift)
           if peak - first(window) < e_cal_fep[i] < peak + last(window) && isfinite(rise_time[i]) && isfinite(aoe[i])]
    residual = ustrip.(NoUnits, (e_cal_fep[sel] .- fits.FEP.μ) ./ fits.FEP.σ)
    slow = rise_time[sel] .>= quantile(rise_time[sel], 0.95)
    residuals = (residual = residual, qdrift = sets.fep.qdrift[sel], rise_time = rise_time[sel], aoe = aoe[sel], slow_mean = mean(residual[slow]))

    ctc_report = if opt_config.apply_ctc
        valid = [i for i in eachindex(e_fep, sets.fep.qdrift)
                 if isfinite(e_fep[i]) && isfinite(sets.fep.qdrift[i]) && e_fep[i] > 0 && sets.fep.qdrift[i] > 0]
        last(ctc_energy(e_fep[valid] .* fep_row.m_cal_simple, sets.fep.qdrift[valid], peak, window, fep_row.m_cal_simple))
    else
        nothing
    end

    return (; fep_row, fits, rows, shifts, slow_mean_residual = residuals.slow_mean, residuals, ctc_report)
end
