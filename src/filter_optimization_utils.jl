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
    single_site_aoe_cut(a_fit::AbstractVector, e_fit::AbstractVector, a::AbstractVector, e::AbstractVector; aoe_cut_sigma::Real)

Coarse in-situ single-site selection. The single-site A/E band is fitted on the A/E values
`a_fit ./ e_fit` (units stripped) of a nearly pure single-site sample, the DEP: a truncated
Gaussian is fitted to the high side of its A/E peak with `fit_half_trunc_gauss`. Events of
`a ./ e`, the FEP, above `μ - aoe_cut_sigma * σ` are kept. The band is not energy-corrected
between the two samples, and this is not the calibrated A/E cut.

Returns the selection mask, which has the axes of `a`, and the report
`(h, f_fit, μ, σ, cut_value, n_sigma, sf)`, where `h` and `f_fit` describe the fitted
`a_fit ./ e_fit` distribution and `sf` is the kept fraction of the `a ./ e` events with finite
A/E. Throws an `ArgumentError` with fewer than 100 finite positive fit values, and an
`ErrorException` if the fit yields a non-finite `μ`, a non-positive or non-finite `σ`, or a
`μ` outside the range of the A/E peak given by `cut_single_peak`.
"""
function single_site_aoe_cut(a_fit::AbstractVector, e_fit::AbstractVector, a::AbstractVector, e::AbstractVector; aoe_cut_sigma::Real)
    axes(a_fit) == axes(e_fit) || throw(DimensionMismatch("a_fit and e_fit must share axes: $(axes(a_fit)) vs $(axes(e_fit))"))
    axes(a) == axes(e) || throw(DimensionMismatch("a and e must share axes: $(axes(a)) vs $(axes(e))"))
    aoe_fit = collect(filter(x -> isfinite(x) && x > 0, ustrip.(a_fit) ./ ustrip.(e_fit)))
    # At least 100 events keep the quantile bounds and the fit meaningful.
    length(aoe_fit) >= 100 || throw(ArgumentError("The A/E selection needs at least 100 finite positive A/E values to fit, got $(length(aoe_fit))"))
    # The 1% and 99.5% quantiles exclude the low-A/E multi-site tail and high outliers from the
    # fit range; relative_cut = 0.5 restricts the fit to the region above half the peak height.
    cuts = cut_single_peak(aoe_fit, quantile(aoe_fit, 0.01), quantile(aoe_fit, 0.995); relative_cut = 0.5)
    (; result, report) = fit_half_trunc_gauss(aoe_fit, cuts; left = false, uncertainty = false)
    μ, σ = mvalue(result.μ), mvalue(result.σ)
    isfinite(μ) && isfinite(σ) && σ > 0 || error("The A/E fit is degenerate: μ = $μ, σ = $σ")
    cuts.low <= μ <= cuts.high || error("The A/E fit is implausible: μ = $μ outside the fit range $(cuts.low) .. $(cuts.high)")
    cut_value = μ - aoe_cut_sigma * σ
    aoe = ustrip.(a) ./ ustrip.(e)
    mask = map(x -> isfinite(x) && x > cut_value, aoe)
    return mask, (h = report.h, f_fit = report.f_fit, μ = μ, σ = σ, cut_value = cut_value, n_sigma = aoe_cut_sigma, sf = count(mask) / count(isfinite, aoe))
end


"""
    crosscheck_warning(legacy::NamedTuple, new::NamedTuple; max_shift_sigma::Real)

Warning text for a new optimum that degrades the reconstruction relative to the legacy optimum,
`""` if nothing is flagged. Both arguments carry `shifts`, a NamedTuple of `(shift, σ)` per
crosscheck peak (the fitted position relative to its FEP-calibrated expectation, and the peak
width), and `slow_mean_residual`, the mean FEP residual in units of σ of the slowest five
percent of events by `t90 - t10`.

Only degradations are flagged: a peak when `abs(new shift) > abs(legacy shift) +
max_shift_sigma * σ` with σ at the new optimum, or when it is missing at one of the two optima;
the slow-pulse class when `abs(new residual) > abs(legacy residual) + max_shift_sigma` (in units
of σ). A non-finite shift, σ or residual is always flagged as "not finite".
"""
function crosscheck_warning(legacy::NamedTuple, new::NamedTuple; max_shift_sigma::Real)
    warnings = String[]
    for peak in union(keys(legacy.shifts), keys(new.shifts))
        if !(haskey(legacy.shifts, peak) && haskey(new.shifts, peak))
            push!(warnings, "$peak crosscheck missing at the $(haskey(new.shifts, peak) ? "legacy" : "new") optimum")
            continue
        end
        nonfinite = String[]
        for (label, x) in (("legacy shift", legacy.shifts[peak].shift), ("new shift", new.shifts[peak].shift), ("new σ", new.shifts[peak].σ))
            isfinite(x) || push!(nonfinite, label)
        end
        if !isempty(nonfinite)
            push!(warnings, "$peak $(join(nonfinite, ", ")) not finite")
            continue
        end
        s_legacy, s_new = legacy.shifts[peak].shift, new.shifts[peak].shift
        abs(s_new) > abs(s_legacy) + max_shift_sigma * new.shifts[peak].σ &&
            push!(warnings, "$peak shift grew from $(round(u"keV", s_legacy, digits = 2)) to $(round(u"keV", s_new, digits = 2))")
    end
    r_legacy, r_new = legacy.slow_mean_residual, new.slow_mean_residual
    if !(isfinite(r_legacy) && isfinite(r_new))
        push!(warnings, "slow-pulse residual not finite")
    elseif abs(r_new) > abs(r_legacy) + max_shift_sigma
        push!(warnings, "slow-pulse residual grew from $(round(r_legacy, digits = 2))σ to $(round(r_new, digits = 2))σ")
    end
    return join(warnings, "; ")
end


"""
    write_fltopt_tables(path::AbstractString, tables::NamedTuple)

Write every entry of `tables` (anything `TypedTables.Table` accepts) to the LH5 file `path`
under its name. Symbol and string columns are stored as strings, `Measurement` values as
their central values. An existing file at `path` is overwritten. Read string columns back with
`col[:]`; `collect` fails on LH5 string arrays.
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
with `n_evts` events per run. Sets above `max_wvfs` events are reduced with
`limit_peak_waveforms`, with an RNG seeded from the detector and the filekey (or the runs of
the partition), so that repeated runs select the same events.
"""
function load_peak_waveforms(l200::LegendData, filekey::FileKey, det, peakname::Symbol, max_wvfs::Integer)
    rng = MersenneTwister(hash((string(det), string(filekey))))
    limit_peak_waveforms(read_ldata(peakname, l200, DataTier(:jlpks), filekey, det), peakname, max_wvfs, rng)
end

function load_peak_waveforms(l200::LegendData, partinfo_det, det, peakname::Symbol, max_wvfs::Integer; n_evts::Integer)
    rng = MersenneTwister(hash((string(det), join(string.(partinfo_det.period, "-", partinfo_det.run), ","))))
    limit_peak_waveforms(read_ldata(peakname, l200, DataTier(:jlpks), :cal, partinfo_det, det; n_evts), peakname, max_wvfs, rng)
end


"""
    limit_peak_waveforms(peak_data, peakname::Symbol, max_wvfs::Integer, rng::AbstractRNG)

`(wvfs_pre, wvfs_wdw, presum_rate)` of `peak_data`. A set with more than `max_wvfs` events is
reduced to `max_wvfs` distinct events drawn with `rng` without replacement from all events,
kept in their original order.
"""
function limit_peak_waveforms(peak_data, peakname::Symbol, max_wvfs::Integer, rng::AbstractRNG)
    wvfs_pre, wvfs_wdw, presum_rate = peak_data.waveform_presummed, peak_data.waveform_windowed, peak_data.presum_rate
    if length(wvfs_pre) > max_wvfs
        @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
        idxs = collect(eachindex(wvfs_pre))
        sel = sort(shuffle(rng, idxs)[begin:begin+max_wvfs-1])
        wvfs_pre, wvfs_wdw, presum_rate = wvfs_pre[sel], wvfs_wdw[sel], presum_rate[sel]
    end
    return (; wvfs_pre, wvfs_wdw, presum_rate)
end


"""
    prepare_peak_set(wvfs::NamedTuple, dsp_config::DSPConfig, τ::Unitful.Time, f_evaluate_qc, qc_string::AbstractString)

Apply the QC selection `qc_string` to the waveforms of one peak as returned by
`load_peak_waveforms`, compute qdrift from the windowed waveforms and prepare the presummed
waveforms once with `dsp_flt_optimization_prepare`.

Returns `(wvfs_pre, prep, qdrift, wvfs_wdw_pz)` of the events passing the QC, where
`wvfs_wdw_pz` are the windowed waveforms, baseline-subtracted with the presummed baseline mean
divided by the presum rate and deconvolved with `InvCRFilter(τ)`.
"""
function prepare_peak_set(wvfs::NamedTuple, dsp_config::DSPConfig, τ::Unitful.Time, f_evaluate_qc, qc_string::AbstractString)
    dsp_qc = dsp_qc_flt_optimization_compressed(wvfs.wvfs_pre, dsp_config, τ, f_evaluate_qc)
    qc = findall(ljl_propfunc(qc_string).(dsp_qc))
    isempty(qc) && throw(ErrorException("No event passes the QC selection $qc_string"))
    @debug "QC survival fraction: $(round(length(qc) / length(dsp_qc) * 100, digits = 2))%"
    wvfs_pre, wvfs_wdw = wvfs.wvfs_pre[qc], wvfs.wvfs_wdw[qc]
    blmean_wdw = (dsp_qc.blmean ./ wvfs.presum_rate)[qc]
    qdrift = dsp_qdrift_flt_optimization(wvfs_wdw, blmean_wdw, dsp_config, τ)
    # Pulse shapes need the full sampling of the windowed waveforms: the SG window of the
    # current is shorter than one presummed sample. Baseline and deconvolution as in the dsp tier.
    wvfs_wdw_pz = InvCRFilter(τ).(shift_waveform.(wvfs_wdw, -blmean_wdw))
    return (; wvfs_pre, prep = dsp_flt_optimization_prepare(wvfs_pre, dsp_config, τ), qdrift, wvfs_wdw_pz)
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


"""
    snap_seed(rt0, ft0, rt_bounds, ft_bounds, lattice, feasible, flt)

Move the seed `(rt0, ft0)` of `optimize_rtft` onto the lattice `k * lattice`, inside the bounds
(which are snapped inward to lattice points) and into the region where `feasible(rt, ft)` holds,
by lowering `ft` in lattice steps. Returns the lattice-point seed `(rt, ft)`. Throws an
`ErrorException` naming the filter `flt` if no admissible seed exists.
"""
function snap_seed(rt0, ft0, rt_bounds, ft_bounds, lattice, feasible, flt)
    to_lattice(t) = uconvert(NoUnits, t / lattice)
    rt_range = ceil(Int, to_lattice(first(rt_bounds)) - 1e-6):floor(Int, to_lattice(last(rt_bounds)) + 1e-6)
    ft_range = ceil(Int, to_lattice(first(ft_bounds)) - 1e-6):floor(Int, to_lattice(last(ft_bounds)) + 1e-6)
    (isempty(rt_range) || isempty(ft_range)) && throw(ErrorException("Filter $flt: no lattice point inside the bounds $rt_bounds, $ft_bounds"))
    i = clamp(round(Int, to_lattice(rt0)), first(rt_range), last(rt_range))
    j = clamp(round(Int, to_lattice(ft0)), first(ft_range), last(ft_range))
    while j in ft_range && !feasible(i * lattice, j * lattice)
        j -= 1
    end
    j in ft_range || throw(ErrorException("Filter $flt: no feasible seed for (rt, ft) = ($rt0, $ft0) inside the bounds $rt_bounds, $ft_bounds"))
    return i * lattice, j * lattice
end


"""
    optimize_channel_filter(sets::NamedTuple, pulse::NamedTuple, flt::Symbol, dsp_config::DSPConfig,
                            opt_config::PropDict, τ::Unitful.Time, sg_wl::Unitful.Time, sg_wl_source::AbstractString;
                            f_title::Function, f_save::Function, f_tablepath::Function)

Optimization of energy filter `flt` of one detector on the prepared peak sets `sets` (see
`run_filter_optimization_channel`) and the FEP pulse shapes `pulse`:
1. noise scan with `dsp_<flt>_rt_optimization` and `fit_enc_sigmas`, giving `rt_enc`;
2. flat-top scan at `rt_enc` with `fit_fwhm_ft`, giving the seed `ft0` for the configured
   objective and the legacy optimum `(rt_enc, legacy_ft)`;
3. joint lattice search from `(rt_enc, ft0)` with `optimize_rtft`;
4. crosschecks at the legacy and the new optimum (`crosscheck_optimum`, `crosscheck_warning`),
   with the single-site A/E band fitted on the DEP and applied to the FEP, both with the
   energies at the new optimum; a failing A/E selection drops the FEP_SSE crosscheck and its
   figure and is reported in the warning;
5. figures through `f_save(fig, name)` with titles `f_title(label, flt)`, and tables written
   to `f_tablepath(flt)` with `write_fltopt_tables`.

Returns `(pars, log)`: the fltopt pars of the filter and the extra log table fields.
"""
function optimize_channel_filter(sets::NamedTuple, pulse::NamedTuple, flt::Symbol, dsp_config::DSPConfig, opt_config::PropDict,
        τ::Unitful.Time, sg_wl::Unitful.Time, sg_wl_source::AbstractString; f_title::Function, f_save::Function, f_tablepath::Function)
    flt_config = opt_config.e_filter[flt]
    objective = Symbol(opt_config.objective)
    e_grid_rt = getproperty(dsp_config, Symbol("e_grid_rt_$(flt)"))
    e_grid_ft = getproperty(dsp_config, Symbol("e_grid_ft_$(flt)"))
    window = (opt_config.left_window_size, opt_config.right_window_size)
    prep = sets.fep.prep

    # Every candidate must be readable in every FEP waveform: trap output exists from
    # t_first + 2rt + ft on and is read at t50 + rt + ft/2; CUSP and ZAC are read at
    # t50 + flt_length/2 and hold the flat top inside flt_length. Events without a finite t50
    # have no energy and do not constrain the window.
    t_first, t_last = extrema(first(prep.wvfs_pz).time)
    all(t -> extrema(t) == (t_first, t_last), prep.wvfs_pz.time) || throw(ArgumentError("The FEP waveforms do not share one time axis"))
    t50_min, t50_max = extrema(filter(isfinite, prep.t50))
    max_half_length = min(t50_min - t_first, t_last - t50_max) - dsp_config.kwargs_pars.sig_interpolation_length
    feasible = if flt == :trap
        (rt, ft) -> rt + ft / 2 <= max_half_length
    else
        flt_length = getproperty(dsp_config, Symbol("flt_length_$(flt)"))
        flt_length / 2 <= max_half_length || throw(ArgumentError("The $flt filter length $flt_length does not fit the FEP waveform window"))
        (rt, ft) -> ft < flt_length
    end

    # noise scan
    enc_grid = getfield(LegendDSP, Symbol("dsp_$(flt)_rt_optimization"))(sets.fep.wvfs_pre, dsp_config, τ; ft = flt_config.ft_fixed)
    result_rt, report_rt = fit_enc_sigmas(enc_grid, e_grid_rt, flt_config.min_enc, flt_config.max_enc,
        flt_config.nbins_enc_sigmas, flt_config.rel_cut_fit_enc_sigmas)
    rt_enc = mvalue(result_rt.rt)
    @debug "Filter $flt: ENC rise time $rt_enc"
    f_save(LegendMakie.lplot(report_rt, title = f_title("Noise Sweep", flt)), Symbol("noise_sweep_$(flt)"))

    # One dsp_energy_rtft call allocates about five (CUSP, ZAC) or two (trap) times the prepared
    # waveform set transiently, so the number of simultaneous calls is bounded per detector. The
    # ft grid below is computed serially; the bound matters for the threaded optimize_rtft batches.
    sem = Base.Semaphore(opt_config.max_concurrent_evals)
    f_energy = function (rt, ft)
        Base.acquire(sem)
        try
            dsp_energy_rtft(prep, dsp_config, rt, ft, flt)
        finally
            Base.release(sem)
        end
    end
    # flat-top scan at the ENC rise time
    e_grid = permutedims(reduce(hcat, [f_energy(rt_enc, ft) for ft in e_grid_ft]))
    result_ft, report_ft = fit_fwhm_ft(e_grid, e_grid_ft, sets.fep.qdrift, rt_enc, flt_config.min_e_fep, flt_config.max_e_fep,
        flt_config.rel_cut_fit_e_fep, opt_config.apply_ctc; n_bins = flt_config.nbins_e_fep, peak = opt_config.peak, window,
        objective, containment = opt_config.containment, rel_tol = opt_config.rel_tol, ft_fwhm_tol = opt_config.ft_fwhm_tol)
    e_grid = nothing
    enc_grid = nothing
    ft0, legacy_ft = mvalue(result_ft.ft), mvalue(result_ft.legacy_ft)
    @debug "Filter $flt: seed flat-top time $ft0, legacy flat-top time $legacy_ft"
    f_save(LegendMakie.lplot(report_ft, title = f_title("FEP FT Scan", flt), figsize = (600, 900)), Symbol("ft_scan_$(flt)"))

    # joint lattice search from the seed (rt_enc, ft0) moved onto the lattice, inside the bounds and into the feasible region
    rt_seed, ft_seed = snap_seed(rt_enc, ft0, extrema(e_grid_rt), extrema(e_grid_ft), prep.sampling_period, feasible, flt)
    result_rtft, report_rtft = optimize_rtft(f_energy, sets.fep.qdrift, rt_seed, ft_seed;
        rt_bounds = extrema(e_grid_rt), ft_bounds = extrema(e_grid_ft), feasible,
        step0 = (step(e_grid_rt), step(e_grid_ft)), lattice = prep.sampling_period,
        objective, rel_tol = opt_config.rel_tol, max_evals = opt_config.max_evals,
        peak = opt_config.peak, window, min_e = flt_config.min_e_fep, max_e = flt_config.max_e_fep,
        rel_cut_fit = flt_config.rel_cut_fit_e_fep, n_bins = flt_config.nbins_e_fep,
        apply_ctc = opt_config.apply_ctc, containment = opt_config.containment)
    rt_new, ft_new = uconvert(u"µs", mvalue(result_rtft.rt)), uconvert(u"µs", mvalue(result_rtft.ft))
    @debug "Filter $flt: optimum rt = $rt_new, ft = $ft_new after $(result_rtft.n_evals) evaluations"
    f_save(LegendMakie.lplot(report_rtft, legacy = (rt_enc, legacy_ft), title = f_title("RT-FT Search", flt), figsize = (700, 550)),
        Symbol("rtft_landscape_$(flt)"))

    # crosschecks at both optima; A/E and the single-site selection use the energies at the new optimum
    e_new = f_energy(rt_new, ft_new)
    aoe = ustrip.(pulse.a) ./ e_new
    # A failing A/E selection drops the FEP_SSE crosscheck and is reported in the crosscheck warning.
    aoe_mask, report_aoe, aoe_failure = if opt_config.crosscheck.aoe_cut
        try
            e_dep_new = dsp_energy_rtft(sets.dep.prep, dsp_config, rt_new, ft_new, flt)
            (single_site_aoe_cut(sets.dep.a, e_dep_new, pulse.a, e_new; aoe_cut_sigma = opt_config.crosscheck.aoe_cut_sigma)..., "")
        catch e
            e isa InterruptException && rethrow()
            @warn "Single-site A/E selection of $flt failed: $(truncate_error(e))"
            nothing, nothing, "A/E selection failed: $(truncate_error(e, 200))"
        end
    else
        nothing, nothing, ""
    end
    cc_legacy = crosscheck_optimum(sets, pulse, aoe, aoe_mask, dsp_config, opt_config, flt_config, flt, rt_enc, legacy_ft)
    cc_new = crosscheck_optimum(sets, pulse, aoe, aoe_mask, dsp_config, opt_config, flt_config, flt, rt_new, ft_new)
    warning = join(filter(!isempty, [crosscheck_warning(cc_legacy, cc_new; max_shift_sigma = opt_config.crosscheck.max_shift_sigma), aoe_failure]), "; ")
    isempty(warning) || @warn "Filter $flt crosscheck: $warning"

    if opt_config.apply_ctc
        f_save(LegendMakie.lplot(cc_legacy.ctc_report, figsize = (600, 600), title = f_title("CTC Legacy Optimum", flt)), Symbol("ctc_$(flt)_legacy"))
        f_save(LegendMakie.lplot(cc_new.ctc_report, figsize = (600, 600), title = f_title("CTC New Optimum", flt)), Symbol("ctc_$(flt)_new"))
    end
    peaks = [p for p in keys(cc_new.fits) if haskey(cc_legacy.fits, p)]
    f_save(LegendMakie.lplot((peaks = peaks, legacy = [cc_legacy.fits[p] for p in peaks], new = [cc_new.fits[p] for p in peaks]);
        figsize = (700, 300 * length(peaks)), title = f_title("Crosscheck Peaks", flt)), Symbol("peaks_$(flt)"))
    f_save(LegendMakie.lplot((legacy = cc_legacy.residuals, new = cc_new.residuals); figsize = (900, 900),
        title = f_title("FEP Residuals", flt)), Symbol("residuals_$(flt)"))
    isnothing(report_aoe) || f_save(LegendMakie.lplot(report_aoe, title = f_title("Single-Site A/E Selection", flt)), Symbol("aoe_cut_$(flt)"))

    # example waveforms: fastest, slowest and highest-A/E events
    n_class = opt_config.n_example_wvfs
    rise_time = pulse.t90 .- pulse.t10
    valid = [i for i in eachindex(rise_time, aoe) if isfinite(rise_time[i]) && isfinite(aoe[i])]
    idx = vcat(valid[partialsortperm(rise_time[valid], 1:n_class)],
               valid[partialsortperm(rise_time[valid], 1:n_class, rev = true)],
               valid[partialsortperm(aoe[valid], 1:n_class, rev = true)])
    wvfs = prep.wvfs_pz[idx]
    flt_legacy, flt_new = map(((rt_enc, legacy_ft), (rt_new, ft_new))) do (rt, ft)
        # the filters take all times in one type, as in dsp_energy_rtft
        flt_obj = if flt == :trap
            T = typeof(float(prep.sampling_period))
            TrapezoidalChargeFilter(convert(T, rt), convert(T, ft))
        else
            # CUSP and ZAC with the constants of dsp_energy_rtft
            flt_length = getproperty(dsp_config, Symbol("flt_length_$(flt)"))
            T = typeof(flt_length)
            (flt == :cusp ? CUSPChargeFilter : ZACChargeFilter)(convert(T, rt), convert(T, ft), convert(T, 10000000.0u"µs"),
                flt_length, ustrip(NoUnits, flt_length / prep.sampling_period))
        end
        flt_obj.(wvfs)
    end
    f_save(LegendMakie.lplot((classes = repeat([:fast, :slow, :high_aoe], inner = n_class), wvfs = wvfs, flt_legacy = flt_legacy, flt_new = flt_new);
        figsize = (1200, 600), title = f_title("Example Waveforms", flt)), Symbol("example_wvfs_$(flt)"))

    # tables: noise scan, ft scan and lattice rows share the columns of `evaluation`
    metric_columns(t) = (status = string.(t.status), enc = fill(NaN, length(t)),
        fwhm_before = uconvert.(u"keV", mvalue.(t.fwhm_before)), fwhm = uconvert.(u"keV", mvalue.(t.fwhm)),
        w90 = uconvert.(u"keV", mvalue.(t.w90)), asym = mvalue.(t.asym), tail_fraction = mvalue.(t.tail_fraction),
        tail_scale = uconvert.(u"keV", mvalue.(t.tail_scale)), centroid = uconvert.(u"keV", mvalue.(t.centroid)),
        fct = mvalue.(t.fct), m_cal_simple = uconvert.(u"keV", mvalue.(t.m_cal_simple)),
        ctc_converged = t.ctc_converged, n_events = t.n_events)
    n_rt, n_ft, n_lat = length(report_rt.enc), length(report_ft.table), length(report_rtft.table)
    evaluation = vcat(
        Table(scan = fill("noise", n_rt), rt = uconvert.(u"µs", collect(report_rt.enc_grid_rt)),
            ft = fill(uconvert(u"µs", flt_config.ft_fixed), n_rt), stage = fill("", n_rt),
            step_rt = fill(NaN * u"µs", n_rt), step_ft = fill(NaN * u"µs", n_rt), status = fill("ok", n_rt),
            enc = mvalue.(report_rt.enc), fwhm_before = fill(NaN * u"keV", n_rt), fwhm = fill(NaN * u"keV", n_rt),
            w90 = fill(NaN * u"keV", n_rt), asym = fill(NaN, n_rt), tail_fraction = fill(NaN, n_rt),
            tail_scale = fill(NaN * u"keV", n_rt), centroid = fill(NaN * u"keV", n_rt), fct = fill(NaN, n_rt),
            m_cal_simple = fill(NaN * u"keV", n_rt), ctc_converged = fill(false, n_rt), n_events = fill(0, n_rt)),
        Table(merge((scan = fill("ft_scan", n_ft), rt = fill(uconvert(u"µs", rt_enc), n_ft),
            ft = uconvert.(u"µs", report_ft.table.ft), stage = fill("", n_ft), step_rt = fill(NaN * u"µs", n_ft),
            step_ft = fill(uconvert(u"µs", step(e_grid_ft)), n_ft)), metric_columns(report_ft.table))),
        Table(merge((scan = fill("lattice", n_lat), rt = uconvert.(u"µs", report_rtft.table.rt),
            ft = uconvert.(u"µs", report_rtft.table.ft), stage = string.(report_rtft.table.stage),
            step_rt = uconvert.(u"µs", report_rtft.table.step_rt), step_ft = uconvert.(u"µs", report_rtft.table.step_ft)),
            metric_columns(report_rtft.table))))
    crosscheck = Table(vcat(map(((:legacy, rt_enc, legacy_ft, cc_legacy), (:new, rt_new, ft_new, cc_new))) do (optimum, rt, ft, cc)
        [merge((optimum = String(optimum), rt = uconvert(u"µs", rt), ft = uconvert(u"µs", ft), fct = mvalue(cc.fep_row.fct),
                sg_wl = uconvert(u"ns", sg_wl), sg_wl_source = String(sg_wl_source), slow_mean_residual = cc.slow_mean_residual), row)
         for row in cc.rows]
    end...))
    write_fltopt_tables(f_tablepath(flt), (evaluation = evaluation, crosscheck = crosscheck,
        residuals_legacy = Base.structdiff(cc_legacy.residuals, NamedTuple{(:slow_mean,)}),
        residuals_new = Base.structdiff(cc_new.residuals, NamedTuple{(:slow_mean,)})))

    pars = (
        rt = rt_new, ft = ft_new,
        min_enc = result_rt.min_enc, rt_enc = result_rt.rt,
        objective = string(objective), containment = opt_config.containment,
        min_objective = result_rtft.min_objective, fwhm = result_rtft.fwhm, w90 = result_rtft.w90,
        asym = result_rtft.asym, fct = result_rtft.fct,
        legacy = (rt = rt_enc, ft = legacy_ft, fwhm = cc_legacy.fep_row.fwhm),
        n_evals = result_rtft.n_evals, converged = result_rtft.converged
    )
    return (; pars, log = (objective = pars.objective, legacy_rt = rt_enc, legacy_ft, crosscheck_warning = isempty(warning) ? "-" : warning))
end


"""
    run_filter_optimization_channel(f_load::Function, filter_types::AbstractVector, dsp_config::DSPConfig,
                                    opt_config::PropDict, τ::Unitful.Time, f_evaluate_qc, sg_wl::Unitful.Time,
                                    sg_wl_source::AbstractString; f_title::Function, f_save::Function, f_tablepath::Function)

Filter optimization of one detector. Loads the FEP waveforms and, if enabled in
`opt_config.crosscheck`, the DEP and SEP waveforms with `f_load(peakname)` (as returned by
`load_peak_waveforms`), applies the QC, computes qdrift and prepares every set once
(`prepare_peak_set`), computes the FEP pulse shapes (and, for the single-site A/E selection,
the DEP current amplitudes `sets.dep.a`) on the windowed waveforms with the SG window length
`sg_wl`, and runs `optimize_channel_filter` for every filter in `filter_types`, a vector of
filter `Symbol`s (the keys of a `PropDict`, whose eltype is wider than `Symbol`). Throws an
`ArgumentError` if `opt_config.crosscheck.aoe_cut` is enabled without `crosscheck.dep`.

Returns a `Dict` from filter to its `(pars, log)`, or to the exception that stopped that
filter. Errors while loading or preparing a peak set propagate.
"""
function run_filter_optimization_channel(f_load::Function, filter_types::AbstractVector, dsp_config::DSPConfig,
        opt_config::PropDict, τ::Unitful.Time, f_evaluate_qc, sg_wl::Unitful.Time, sg_wl_source::AbstractString;
        f_title::Function, f_save::Function, f_tablepath::Function)
    opt_config.crosscheck.aoe_cut && !opt_config.crosscheck.dep && throw(ArgumentError(
        "The single-site A/E selection (crosscheck.aoe_cut) is fitted on the DEP and needs crosscheck.dep"))
    peaknames = (fep = Symbol(opt_config.peakname),)
    opt_config.crosscheck.dep && (peaknames = merge(peaknames, (dep = DEP_PEAKNAME,)))
    opt_config.crosscheck.sep && (peaknames = merge(peaknames, (sep = SEP_PEAKNAME,)))
    sets = NamedTuple{keys(peaknames)}(map(keys(peaknames)) do key
        set = try
            prepare_peak_set(f_load(peaknames[key]), dsp_config, τ, f_evaluate_qc, opt_config.qc)
        catch e
            e isa InterruptException && rethrow()
            throw(ErrorException("$(peaknames[key]): $(truncate_error(e))"))
        end
        # the raw presummed waveforms serve only the FEP noise scan, the windowed ones only the
        # FEP pulse shapes and the DEP A/E of the single-site selection
        if key == :fep
            set
        elseif key == :dep && opt_config.crosscheck.aoe_cut
            (prep = set.prep, qdrift = set.qdrift, a = dsp_pulse_shape_flt_optimization((wvfs_pz = set.wvfs_wdw_pz,), dsp_config, sg_wl).a)
        else
            (prep = set.prep, qdrift = set.qdrift)
        end
    end)
    pulse = dsp_pulse_shape_flt_optimization((wvfs_pz = sets.fep.wvfs_wdw_pz,), dsp_config, sg_wl)
    sets = merge(sets, (fep = Base.structdiff(sets.fep, NamedTuple{(:wvfs_wdw_pz,)}),))
    GC.gc()

    results = Dict{Symbol, Union{NamedTuple, Exception}}()
    for flt in filter_types
        results[flt] = try
            optimize_channel_filter(sets, pulse, flt, dsp_config, opt_config, τ, sg_wl, sg_wl_source; f_title, f_save, f_tablepath)
        catch e
            e isa InterruptException && rethrow()
            @error "Filter $flt: $(truncate_error(e))"
            e
        end
        GC.gc()
    end
    return results
end
