# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Per-detector filter optimization shared by the run and partition processors.

# The Tl-208 SEP and DEP lie one and two electron masses below the FEP.
const ELECTRON_MASS_ENERGY = 510.999u"keV"

# The DEP window excludes the Bi-212 FEP at 1620.7 keV, 28 keV above the DEP.
const DEP_WINDOW = (15.0u"keV", 12.0u"keV")

const DEP_PEAKNAME = :Tl208DEP_Bi212FEP
const SEP_PEAKNAME = :Tl208SEP

"""
    crosscheck_warning(cc::NamedTuple; max_shift_sigma::Real)

Warning text for a `crosscheck_optimum` result `cc`, `""` if nothing is flagged.

Flagged are: a peak whose fit failed, a peak whose shift exceeds `max_shift_sigma * σ`, a
non-finite shift or σ, and a high-qdrift residual whose magnitude exceeds `max_shift_sigma`.
Without a FEP fit the shifts and the residual are not checked.
"""
function crosscheck_warning(cc::NamedTuple; max_shift_sigma::Real)
    warnings = String[]
    failed = [row.peak for row in cc.rows if row.status != "ok"]

    for peak in keys(cc.shifts)
        String(peak) in failed && continue
        shift, σ = cc.shifts[peak].shift, cc.shifts[peak].σ
        if !(isfinite(shift) && isfinite(σ))
            push!(warnings, "$peak shift or σ not finite")
        elseif abs(shift) > max_shift_sigma * σ
            push!(warnings, "$peak shifted by $(round(u"keV", shift, digits = 2))")
        end
    end

    for peak in sort(failed)
        push!(warnings, "$peak fit failed")
    end

    if "FEP" ∉ failed
        r = cc.slow_mean_residual
        if !isfinite(r)
            push!(warnings, "high-qdrift residual not finite")
        elseif abs(r) > max_shift_sigma
            push!(warnings, "high-qdrift residual of $(round(r, digits = 2))σ")
        end
    end
    return join(warnings, "; ")
end


"""
    write_fltopt_tables(path::AbstractString, tables::NamedTuple)

Write every entry of `tables` (anything `TypedTables.Table` accepts) to the LH5 file `path`
under its name, overwriting the file. Symbol and string columns are stored as strings,
`Measurement` values as their central values.
"""
function write_fltopt_tables(path::AbstractString, tables::NamedTuple)
    lh5open(path, "w") do h
        for (name, t) in pairs(tables)
            cols = map(columns(Table(t))) do col
                map(x -> x isa Union{Symbol, AbstractString} ? String(x) : mvalue(x), col)
            end
            h[string(name)] = Table(cols)
        end
    end
    return path
end


"""
    load_peak_waveforms(l200::LegendData, filekey::FileKey, det, peakname::Symbol, max_wvfs::Integer)
    load_peak_waveforms(l200::LegendData, partinfo_det, det, peakname::Symbol, max_wvfs::Integer; n_evts::Integer)

Presummed and windowed waveforms and presum rates of the `peakname` events of detector `det`
from the jlpks tier, for the run of `filekey` or for all runs of the partition `partinfo_det`.
The partition method takes `n_evts` events per run (all for `n_evts == -1`), random ones if
`select_random` is set and the first ones otherwise. Sets above `max_wvfs` events are reduced
with `limit_peak_waveforms`. The RNG is seeded from the detector and the filekey or runs, so
repeated calls select the same events.
"""
function load_peak_waveforms(l200::LegendData, filekey::FileKey, det, peakname::Symbol, max_wvfs::Integer)
    rng = MersenneTwister(hash((string(det), string(filekey))))
    limit_peak_waveforms(read_ldata(peakname, l200, DataTier(:jlpks), filekey, det), peakname, max_wvfs, rng)
end

function load_peak_waveforms(l200::LegendData, partinfo_det, det, peakname::Symbol, max_wvfs::Integer; n_evts::Integer,
                             select_random::Bool = false)
    rng = MersenneTwister(hash((string(det), join(string.(partinfo_det.period, "-", partinfo_det.run), ","))))
    # Select by timestamp before reading so that only the selected waveforms are loaded.
    f_timestamp = ljl_propfunc("$peakname.timestamp")
    peak_data = fast_flatten(map(partinfo_det) do r
                                 ts = read_ldata(f_timestamp, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det)
                                 n_sel = n_evts == -1 ? length(ts) : min(n_evts, length(ts))
                                 ts_sel = select_random ? sample(rng, ts, n_sel; replace = false, ordered = true) :
                                          ts[begin:(begin + n_sel - 1)]
                                 read_ldata(peakname, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det;
                                            filterby = @pf $timestamp in ts_sel)
                             end)
    return limit_peak_waveforms(peak_data, peakname, max_wvfs, rng)
end


"""
    limit_peak_waveforms(peak_data, peakname::Symbol, max_wvfs::Integer, rng::AbstractRNG)

`(wvfs_pre, wvfs_wdw, presum_rate)` of `peak_data`. A set with more than `max_wvfs` events is
reduced to `max_wvfs` events drawn with `rng` without replacement, in their original order.
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

Apply the QC selection `qc_string` to the waveforms of one peak (see `load_peak_waveforms`),
compute qdrift from the windowed waveforms and prepare the presummed waveforms with
`dsp_flt_optimization_prepare`.

Returns `(prep, qdrift)` of the events passing the QC, where `prep` is a `FltOptPrep`.
"""
function prepare_peak_set(wvfs::NamedTuple, dsp_config::DSPConfig, τ::Unitful.Time, f_evaluate_qc, qc_string::AbstractString)
    dsp_qc = dsp_qc_flt_optimization_compressed(wvfs.wvfs_pre, dsp_config, τ, f_evaluate_qc)
    qc = findall(ljl_propfunc(qc_string).(dsp_qc))
    isempty(qc) && throw(ErrorException("No event passes the QC selection $qc_string"))
    @debug "QC survival fraction: $(round(length(qc) / length(dsp_qc) * 100, digits = 2))%"
    wvfs_pre, wvfs_wdw = wvfs.wvfs_pre[qc], wvfs.wvfs_wdw[qc]
    blmean_wdw = (dsp_qc.blmean ./ wvfs.presum_rate)[qc]
    qdrift = dsp_qdrift_flt_optimization(wvfs_wdw, blmean_wdw, dsp_config, τ)
    return (; prep = dsp_flt_optimization_prepare(wvfs_pre, dsp_config, τ), qdrift)
end


"""
    fit_crosscheck_peak(e_cal::AbstractVector{<:Unitful.Energy}, line::Unitful.Energy, window::Tuple; containment::Real)

Fit the calibrated energies `e_cal` inside `line - window[1] .. line + window[2]` with
`fit_single_peak_th228` and compute `peak_width_metrics` of the fitted signal shape.

Returns `(μ, σ, fwhm, w90, asym, tail_fraction, tail_scale, centroid, n_events, h, f_fit, report)`.
Energies carry keV units; `h` and `f_fit` work on unitless keV. Throws an `ArgumentError` with
fewer than 100 events in the window.
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
            n_events = length(x), h = h, f_fit = report.f_fit, report = report)
end


"""
    try_fit_crosscheck_peak(e_cal, line, window; containment, context = "")

`(fit_crosscheck_peak(e_cal, line, window; containment), "ok")`, or `(nothing, "failed: ...")` if
the fit throws, with a warning that includes `context`. An `InterruptException` propagates.
"""
function try_fit_crosscheck_peak(e_cal, line, window; containment, context::AbstractString = "")
    try
        return fit_crosscheck_peak(e_cal, line, window; containment), "ok"
    catch err
        err isa InterruptException && rethrow()
        @warn "Crosscheck fit of the peak at $line failed$context" exception = (err, catch_backtrace())
        return nothing, "failed: $(truncate_error(err, 200))"
    end
end


"""
    crosscheck_peak_figure(check::NamedTuple, fit, status::AbstractString; title::AbstractString)

Figure of one crosscheck peak fit. `check` is an entry of `crosscheck_optimum(...).checks`;
`fit` and `status` are the results of `try_fit_crosscheck_peak`. A failed fit is shown as the
histogram of the energies in the fit window with the `status` text.
"""
function crosscheck_peak_figure(check::NamedTuple, fit, status::AbstractString; title::AbstractString)
    isnothing(fit) || return LegendMakie.lplot(fit.report; title, figsize = (700, 450), show_residuals = false)
    lo, hi = ustrip.(u"keV", (check.line - first(check.window), check.line + last(check.window)))
    h = StatsBase.fit(StatsBase.Histogram, filter(e -> lo < e < hi, ustrip.(u"keV", check.e_cal)), range(lo, hi, length = 41))
    fig = LegendMakie.lplot(h; title, figsize = (700, 450), xlabel = "Energy (keV)", ylabel = "Counts",
        ylims = (0, max(1, 1.2 * maximum(h.weights))))
    Makie.text!(Makie.current_axis(), 0.03, 0.97; text = join(String.(collect(Iterators.partition(status, 60))), "\n"),
        space = :relative, align = (:left, :top), fontsize = 11, color = :red)
    return fig
end


"""
    crosscheck_optimum(sets::NamedTuple, dsp_config, opt_config::PropDict, flt_config::PropDict,
                       flt::Symbol, rt::Unitful.Time, ft::Unitful.Time)

Reconstruction crosscheck of filter `flt` at `(rt, ft)`.

The FEP set is evaluated with `evaluate_energy_point`; its qdrift slope `fct` and simple
calibration `m_cal_simple` are applied to the DEP and SEP sets (if present in `sets`). Every peak
is fitted with `try_fit_crosscheck_peak`; a failed fit is recorded in the `status` of its row.
Without a FEP fit `shifts` is empty, `residuals` holds empty vectors and `slow_mean` is `NaN`.

Returns `(fep_row, checks, fits, rows, shifts, slow_mean_residual, residuals, ctc_report)`:
- `fep_row`: `evaluate_energy_point` row of the FEP
- `checks`: `(name, e_cal, line, window)` of every attempted peak
- `fits`: `fit_crosscheck_peak` results by peak (`:FEP`, `:DEP`, `:SEP`)
- `rows`: one crosscheck table row per attempted peak
- `shifts`: `(shift, σ)` of `:DEP` and `:SEP`, scaled so that the FEP sits at its line
- `residuals`: `(residual, qdrift, slow_mean)`, the residuals `(e - μ) / σ` of the FEP events in
  the FEP window with finite qdrift and their mean over the five percent with the highest qdrift
- `ctc_report`: `ctc_energy` report of the FEP energies if `opt_config.apply_ctc`, else `nothing`
"""
function crosscheck_optimum(sets::NamedTuple, dsp_config, opt_config::PropDict, flt_config::PropDict,
        flt::Symbol, rt::Unitful.Time, ft::Unitful.Time)
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
        e_dep = dsp_energy_rtft(sets.dep.prep, dsp_config, rt, ft, flt)
        push!(checks, (name = :DEP, e_cal = calibrate(e_dep, sets.dep.qdrift),
                       line = peak - 2 * ELECTRON_MASS_ENERGY, window = DEP_WINDOW))
    end
    if haskey(sets, :sep)
        e_sep = dsp_energy_rtft(sets.sep.prep, dsp_config, rt, ft, flt)
        push!(checks, (name = :SEP, e_cal = calibrate(e_sep, sets.sep.qdrift),
                       line = peak - ELECTRON_MASS_ENERGY, window = window))
    end

    fit_names, fit_values, statuses = Symbol[], NamedTuple[], String[]
    for c in checks
        context = " ($(c.name) of $flt at rt = $rt, ft = $ft)"
        fit, status = try_fit_crosscheck_peak(c.e_cal, c.line, c.window; containment, context)
        push!(statuses, status)
        if !isnothing(fit)
            push!(fit_names, c.name)
            push!(fit_values, fit)
        end
    end
    fits = NamedTuple{Tuple(fit_names)}(Tuple(fit_values))

    # DEP and SEP positions are scaled with the FEP fit.
    k = haskey(fits, :FEP) ? peak / fits.FEP.μ : NaN

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

    shifts = (;)
    if haskey(fits, :FEP)
        shift_pairs = [c.name => (shift = fits[c.name].μ * k - c.line, σ = fits[c.name].σ * k)
                       for c in checks if c.name != :FEP && haskey(fits, c.name)]
        shifts = (; shift_pairs...)
    end

    if haskey(fits, :FEP)
        sel = [i for i in eachindex(e_cal_fep, sets.fep.qdrift)
               if peak - first(window) < e_cal_fep[i] < peak + last(window) && isfinite(sets.fep.qdrift[i])]
        residual = ustrip.(NoUnits, (e_cal_fep[sel] .- fits.FEP.μ) ./ fits.FEP.σ)
        slow = sets.fep.qdrift[sel] .>= quantile(sets.fep.qdrift[sel], 0.95)
        residuals = (residual = residual, qdrift = sets.fep.qdrift[sel], slow_mean = mean(residual[slow]))
    else
        residuals = (residual = Float64[], qdrift = sets.fep.qdrift[Int[]], slow_mean = NaN)
    end

    ctc_report = nothing
    if opt_config.apply_ctc
        valid = [i for i in eachindex(e_fep, sets.fep.qdrift)
                 if isfinite(e_fep[i]) && isfinite(sets.fep.qdrift[i]) && e_fep[i] > 0 && sets.fep.qdrift[i] > 0]
        ctc_report = last(ctc_energy(e_fep[valid] .* fep_row.m_cal_simple, sets.fep.qdrift[valid], peak, window,
                                     fep_row.m_cal_simple))
    end

    return (; fep_row, checks, fits, rows, shifts, slow_mean_residual = residuals.slow_mean, residuals, ctc_report)
end


"""
    snap_seed(rt0, ft0, rt_bounds, ft_bounds, lattice, feasible, flt)

Move the seed `(rt0, ft0)` onto the lattice `k * lattice` inside the bounds (snapped inward to
lattice points), lowering `ft` in lattice steps until `feasible(rt, ft)` holds. Returns the
seed `(rt, ft)`. Throws an `ErrorException` naming the filter `flt` if no admissible seed exists.
"""
function snap_seed(rt0, ft0, rt_bounds, ft_bounds, lattice, feasible, flt)
    to_lattice(t) = uconvert(NoUnits, t / lattice)
    rt_range = ceil(Int, to_lattice(first(rt_bounds)) - 1e-6):floor(Int, to_lattice(last(rt_bounds)) + 1e-6)
    ft_range = ceil(Int, to_lattice(first(ft_bounds)) - 1e-6):floor(Int, to_lattice(last(ft_bounds)) + 1e-6)
    if isempty(rt_range) || isempty(ft_range)
        throw(ErrorException("Filter $flt: no lattice point inside the bounds $rt_bounds, $ft_bounds"))
    end
    i = clamp(round(Int, to_lattice(rt0)), first(rt_range), last(rt_range))
    j = clamp(round(Int, to_lattice(ft0)), first(ft_range), last(ft_range))
    while j in ft_range && !feasible(i * lattice, j * lattice)
        j -= 1
    end
    j in ft_range ||
        throw(ErrorException("Filter $flt: no feasible seed for (rt, ft) = ($rt0, $ft0) inside the bounds $rt_bounds, $ft_bounds"))
    return i * lattice, j * lattice
end


"""
    flat_top_edge(ft, ft_range, lattice)

`:lower` or `:upper` if `ft` equals the first or last element of `ft_range` (`(lowest, highest)`)
at the precision of `lattice`, otherwise `nothing`. A degenerate range gives `:upper`.
"""
function flat_top_edge(ft, ft_range, lattice)
    n = round(Int, ustrip(NoUnits, ft / lattice))
    lo = round(Int, ustrip(NoUnits, first(ft_range) / lattice))
    hi = round(Int, ustrip(NoUnits, last(ft_range) / lattice))
    return n == hi ? :upper : n == lo ? :lower : nothing
end


"""
    optimize_channel_filter(sets::NamedTuple, flt::Symbol, dsp_config::DSPConfig,
                            opt_config::PropDict, τ::Unitful.Time;
                            detector, f_title::Function, f_save::Function, f_tablepath::Function)

Optimize energy filter `flt` of one detector on the prepared peak sets `sets` (see
`run_filter_optimization_channel`):
1. A noise sweep gives the rise time `rt_enc` with minimal ENC.
2. A flat-top scan at `rt_enc` gives `ft0`, the optimum of `opt_config.objective`.
3. With `opt_config.joint_search`, a lattice search with `optimize_rtft` from `(rt_enc, ft0)`
   gives the optimum; otherwise it is `(rt_enc, ft0)`.
4. A crosscheck at the optimum (`crosscheck_optimum`, `crosscheck_warning`).
5. Figures are saved with `f_save(fig, name)` and titles `f_title(label, flt)`; tables are
   written to `f_tablepath(flt)` with `write_fltopt_tables`.

For CUSP and ZAC the flat-top times in the pars, the crosscheck table and the log are those the
filter applies (`realized_flattop`), and the lattice search visits only flat tops that are applied
as requested. The `ft_applied` column of the evaluation table holds the applied flat-top time;
`ft` is the requested one. The trapezoidal flat-top time is written as requested.

An optimum on the lower or upper end of the flat-top grid (`flat_top_edge`) logs a warning naming
`detector` and `flt` and is added to the crosscheck warning.

Returns `(pars, log)`: the fltopt pars of the filter and the extra log table fields. `pars` holds
`n_evals` and `converged` only if the joint search ran.
"""
function optimize_channel_filter(sets::NamedTuple, flt::Symbol, dsp_config::DSPConfig, opt_config::PropDict,
        τ::Unitful.Time; detector, f_title::Function, f_save::Function, f_tablepath::Function)
    flt_config = opt_config.e_filter[flt]
    objective = Symbol(opt_config.objective)
    (; joint_search, ctc_rel_uncertainty) = opt_config
    e_grid_rt = getproperty(dsp_config, Symbol("e_grid_rt_$(flt)"))
    e_grid_ft = getproperty(dsp_config, Symbol("e_grid_ft_$(flt)"))
    window = (opt_config.left_window_size, opt_config.right_window_size)
    prep = sets.fep.prep

    # Every candidate filter must be readable in every FEP waveform. Trapezoidal output exists
    # from t_first + 2rt + ft on and is read at t50 + rt + ft/2. CUSP and ZAC are read at
    # t50 + flt_length/2 and hold the flat top inside flt_length. Events without a finite t50
    # have no energy and do not constrain the window.
    t_first, t_last = extrema(first(prep.wvfs_pz).time)
    all(t -> extrema(t) == (t_first, t_last), prep.wvfs_pz.time) ||
        throw(ArgumentError("The FEP waveforms do not share one time axis"))
    t50_min, t50_max = extrema(filter(isfinite, prep.t50))
    max_half_length = min(t50_min - t_first, t_last - t50_max) - dsp_config.kwargs_pars.sig_interpolation_length
    flt_length = flt == :trap ? zero(prep.sampling_period) : getproperty(dsp_config, Symbol("flt_length_$(flt)"))
    if flt != :trap && !(flt_length / 2 <= max_half_length)
        throw(ArgumentError("The $flt filter length $flt_length does not fit the FEP waveform window"))
    end

    # CUSP and ZAC lengthen some flat tops by one sample.
    ft_applied(ft) = uconvert(u"µs", realized_flattop(ft, flt_length, prep.sampling_period, flt))
    ft_written(ft) = flt == :trap ? uconvert(u"µs", ft) : ft_applied(ft)

    # Flat tops that CUSP and ZAC do not apply as requested duplicate a longer flat top.
    function feasible(rt, ft)
        flt == :trap && return rt + ft / 2 <= max_half_length
        return ft < flt_length && ft_applied(ft) == uconvert(u"µs", ft)
    end

    result_rt, report_rt = @process_step "$flt noise sweep" begin
        enc_grid = getfield(LegendDSP, Symbol("dsp_$(flt)_rt_optimization"))(prep, dsp_config; ft = flt_config.ft_fixed)
        result_rt, report_rt = fit_enc_sigmas(enc_grid, e_grid_rt, flt_config.min_enc, flt_config.max_enc,
            flt_config.nbins_enc_sigmas, flt_config.rel_cut_fit_enc_sigmas)
        f_save(LegendMakie.lplot(report_rt, title = f_title("Noise Sweep", flt)), Symbol("noise_sweep_$(flt)"))
        (result_rt, report_rt)
    end
    rt_enc = mvalue(result_rt.rt)
    @debug "Filter $flt: ENC rise time $rt_enc"

    # One dsp_energy_rtft call allocates about five (CUSP, ZAC) or two (trap) times the prepared
    # waveform set, so the number of simultaneous calls is bounded (relevant for the threaded
    # optimize_rtft batches).
    sem = Base.Semaphore(opt_config.max_concurrent_evals)
    function f_energy(rt, ft)
        Base.acquire(sem)
        try
            return dsp_energy_rtft(prep, dsp_config, rt, ft, flt)
        finally
            Base.release(sem)
        end
    end

    result_ft, report_ft = @process_step "$flt flat-top scan" begin
        e_grid = permutedims(reduce(hcat, [f_energy(rt_enc, ft) for ft in e_grid_ft]))
        result_ft, report_ft = fit_fwhm_ft(e_grid, e_grid_ft, sets.fep.qdrift, rt_enc, flt_config.min_e_fep,
            flt_config.max_e_fep, flt_config.rel_cut_fit_e_fep, opt_config.apply_ctc;
            n_bins = flt_config.nbins_e_fep, peak = opt_config.peak, window, objective, ctc_rel_uncertainty,
            containment = opt_config.containment, rel_tol = opt_config.rel_tol)
        f_save(LegendMakie.lplot(report_ft, title = f_title("FEP FT Scan", flt), figsize = (600, 900)), Symbol("ft_scan_$(flt)"))
        (result_ft, report_ft)
    end
    ft0 = mvalue(result_ft.ft)
    @debug "Filter $flt: seed flat-top time $ft0"

    if joint_search
        result_rtft, report_rtft = @process_step "$flt joint search" begin
            # CUSP and ZAC flat tops lie on every second lattice point: the flat-top step is a power
            # of two lattice steps, at least two, so that halving keeps it feasible down to two.
            if flt == :trap
                step_ft = step(e_grid_ft)
            else
                n_steps = ustrip(NoUnits, max(step(e_grid_rt), step(e_grid_ft)) / prep.sampling_period)
                step_ft = 2^max(1, round(Int, log2(n_steps))) * prep.sampling_period
            end
            rt_seed, ft_seed = snap_seed(rt_enc, ft_written(ft0), extrema(e_grid_rt), extrema(e_grid_ft),
                                         prep.sampling_period, feasible, flt)
            result_rtft, report_rtft = optimize_rtft(f_energy, sets.fep.qdrift, rt_seed, ft_seed;
                rt_bounds = extrema(e_grid_rt), ft_bounds = extrema(e_grid_ft), feasible,
                step0 = (step(e_grid_rt), step_ft), lattice = prep.sampling_period,
                objective, ctc_rel_uncertainty, rel_tol = opt_config.rel_tol, max_evals = opt_config.max_evals,
                peak = opt_config.peak, window, min_e = flt_config.min_e_fep, max_e = flt_config.max_e_fep,
                rel_cut_fit = flt_config.rel_cut_fit_e_fep, n_bins = flt_config.nbins_e_fep,
                apply_ctc = opt_config.apply_ctc, containment = opt_config.containment)
            @debug "Filter $flt: optimum rt = $(result_rtft.rt), ft = $(result_rtft.ft) after $(result_rtft.n_evals) evaluations"
            f_save(LegendMakie.lplot(report_rtft, title = f_title("RT-FT Search", flt),
                                     figsize = (700, 550)), Symbol("rtft_landscape_$(flt)"))
            (result_rtft, report_rtft)
        end
        optimum = result_rtft
    else
        result_rtft, report_rtft = nothing, nothing
        i_scan = only(findall(==(ft0), report_ft.table.ft))
        @debug "Filter $flt: optimum rt = $rt_enc, ft = $ft0 from the flat-top scan"
        optimum = merge(report_ft.table[i_scan], (rt = rt_enc, ft = ft0, min_objective = result_ft.min_objective))
    end
    rt_opt = uconvert(u"µs", mvalue(optimum.rt))
    ft_opt = ft_written(mvalue(optimum.ft))

    cc, warning = @process_step "$flt crosscheck" begin
        cc = crosscheck_optimum(sets, dsp_config, opt_config, flt_config, flt, rt_opt, ft_opt)
        warning = crosscheck_warning(cc; max_shift_sigma = opt_config.crosscheck.max_shift_sigma)
        isempty(warning) || @warn "Detector $detector, filter $flt crosscheck: $warning"
        (cc, warning)
    end

    # An optimum on the edge of the ft grid may lie beyond it.
    ft_edge = flat_top_edge(ft_opt, ft_written.(extrema(e_grid_ft)), prep.sampling_period)
    if !isnothing(ft_edge)
        @warn "Detector $detector, filter $flt: optimum flat-top time $ft_opt is on the $ft_edge edge of the ft grid $(extrema(e_grid_ft))"
        warning = isempty(warning) ? "" : warning * "; "
        warning *= "flat-top time on the $ft_edge edge of the ft grid"
    end

    @process_step "$flt crosscheck plots" begin
        if opt_config.apply_ctc
            f_save(LegendMakie.lplot(cc.ctc_report, figsize = (600, 600), title = f_title("CTC Optimum", flt)),
                   Symbol("ctc_$(flt)"))
        end

        peaks = collect(keys(cc.fits))
        if !isempty(peaks)
            fits = (; peaks, fits = [cc.fits[p] for p in peaks])
            f_save(LegendMakie.lplot(fits; figsize = (700, 300 * length(peaks)), title = f_title("Crosscheck Peaks", flt)),
                   Symbol("peaks_$(flt)"))
        end
        for (c, row) in zip(cc.checks, cc.rows)
            c.name in peaks && continue
            f_save(crosscheck_peak_figure(c, nothing, row.status; title = f_title("Crosscheck $(c.name)", flt)),
                   Symbol("crosscheck_$(lowercase(String(c.name)))_$(flt)"))
        end
        if !isempty(cc.residuals.residual)
            f_save(LegendMakie.lplot(cc.residuals; figsize = (900, 450), title = f_title("FEP Residuals", flt)),
                   Symbol("residuals_$(flt)"))
        end
    end

    # Example waveforms: the events with the lowest and the highest qdrift.
    @process_step "$flt example waveforms" begin
        n_class = opt_config.n_example_wvfs
        qdrift = sets.fep.qdrift
        valid = [i for i in eachindex(qdrift) if isfinite(qdrift[i])]
        idx = vcat(valid[partialsortperm(qdrift[valid], 1:n_class)],
                   valid[partialsortperm(qdrift[valid], 1:n_class, rev = true)])
        wvfs = prep.wvfs_pz[idx]

        # The filters take all times in one floating-point type.
        function make_filter(rt, ft)
            if flt == :trap
                T = typeof(float(prep.sampling_period))
                return TrapezoidalChargeFilter(convert(T, rt), convert(T, ft))
            end
            # Constants as in dsp_energy_rtft.
            flt_length = getproperty(dsp_config, Symbol("flt_length_$(flt)"))
            T = typeof(float(flt_length))
            FilterType = flt == :cusp ? CUSPChargeFilter : ZACChargeFilter
            return FilterType(convert(T, rt), convert(T, ft), convert(T, 10000000.0u"µs"),
                              flt_length, ustrip(NoUnits, flt_length / prep.sampling_period))
        end
        flt = make_filter(rt_opt, ft_opt).(wvfs)

        classes = repeat([:fast, :slow], inner = n_class)
        f_save(LegendMakie.lplot((; classes, wvfs, flt); figsize = (1200, 600),
                                 title = f_title("Example Waveforms", flt)), Symbol("example_wvfs_$(flt)"))
    end

    # The noise scan, ft scan and lattice rows share the columns of `evaluation`.
    @process_step "$flt tables" begin
        metric_columns(t) = (
            status = string.(t.status), enc = fill(NaN, length(t)),
            fwhm_before = uconvert.(u"keV", mvalue.(t.fwhm_before)), fwhm = uconvert.(u"keV", mvalue.(t.fwhm)),
            w90 = uconvert.(u"keV", mvalue.(t.w90)), asym = mvalue.(t.asym),
            tail_fraction = mvalue.(t.tail_fraction), tail_scale = uconvert.(u"keV", mvalue.(t.tail_scale)),
            centroid = uconvert.(u"keV", mvalue.(t.centroid)), fct = mvalue.(t.fct),
            ct_spread = uconvert.(u"keV", mvalue.(t.ct_spread)), m_cal_simple = uconvert.(u"keV", mvalue.(t.m_cal_simple)),
            ctc_converged = t.ctc_converged, n_events = t.n_events,
        )

        n_rt = length(report_rt.enc)
        noise_table = Table(
            scan = fill("noise", n_rt), rt = uconvert.(u"µs", collect(report_rt.enc_grid_rt)),
            ft = fill(uconvert(u"µs", flt_config.ft_fixed), n_rt), ft_applied = fill(ft_applied(flt_config.ft_fixed), n_rt),
            stage = fill("", n_rt), step_rt = fill(NaN * u"µs", n_rt), step_ft = fill(NaN * u"µs", n_rt),
            status = fill("ok", n_rt), enc = mvalue.(report_rt.enc), fwhm_before = fill(NaN * u"keV", n_rt),
            fwhm = fill(NaN * u"keV", n_rt), w90 = fill(NaN * u"keV", n_rt), asym = fill(NaN, n_rt),
            tail_fraction = fill(NaN, n_rt), tail_scale = fill(NaN * u"keV", n_rt), centroid = fill(NaN * u"keV", n_rt),
            fct = fill(NaN, n_rt), ct_spread = fill(NaN * u"keV", n_rt), m_cal_simple = fill(NaN * u"keV", n_rt),
            ctc_converged = fill(false, n_rt), n_events = fill(0, n_rt),
        )

        n_ft = length(report_ft.table)
        ft_scan_table = Table(merge((
            scan = fill("ft_scan", n_ft), rt = fill(uconvert(u"µs", rt_enc), n_ft),
            ft = uconvert.(u"µs", report_ft.table.ft), ft_applied = ft_applied.(report_ft.table.ft),
            stage = fill("", n_ft), step_rt = fill(NaN * u"µs", n_ft),
            step_ft = fill(uconvert(u"µs", step(e_grid_ft)), n_ft),
        ), metric_columns(report_ft.table)))

        evaluation_tables = [noise_table, ft_scan_table]
        if joint_search
            lattice = report_rtft.table
            push!(evaluation_tables, Table(merge((
                scan = fill("lattice", length(lattice)), rt = uconvert.(u"µs", lattice.rt),
                ft = uconvert.(u"µs", lattice.ft), ft_applied = ft_applied.(lattice.ft), stage = string.(lattice.stage),
                step_rt = uconvert.(u"µs", lattice.step_rt), step_ft = uconvert.(u"µs", lattice.step_ft),
            ), metric_columns(lattice))))
        end
        evaluation = vcat(evaluation_tables...)

        crosscheck = Table([
            merge((; rt = uconvert(u"µs", rt_opt), ft = uconvert(u"µs", ft_opt), fct = mvalue(cc.fep_row.fct),
                   ct_spread = uconvert(u"keV", mvalue(cc.fep_row.ct_spread)), slow_mean_residual = cc.slow_mean_residual), row)
            for row in cc.rows
        ])

        write_fltopt_tables(f_tablepath(flt), (;
            evaluation, crosscheck,
            residuals = (; cc.residuals.residual, cc.residuals.qdrift),
        ))
    end

    pars = (
        rt = rt_opt, ft = ft_opt,
        min_enc = result_rt.min_enc, rt_enc = result_rt.rt,
        objective = string(objective), ctc_rel_uncertainty, joint_search, containment = opt_config.containment,
        min_objective = optimum.min_objective, fwhm = optimum.fwhm, w90 = optimum.w90,
        asym = optimum.asym, fct = optimum.fct, ct_spread = optimum.ct_spread,
    )
    joint_search && (pars = merge(pars, (n_evals = result_rtft.n_evals, converged = result_rtft.converged)))
    log = (objective = pars.objective, crosscheck_warning = isempty(warning) ? "-" : warning, ft_edge)
    return (; pars, log)
end


"""
    run_filter_optimization_channel(f_load::Function, filter_types::AbstractVector, dsp_config,
                                    opt_config::PropDict, τ::Unitful.Time, f_evaluate_qc;
                                    detector, f_title::Function, f_save::Function, f_tablepath::Function)

Filter optimization of one detector. Loads the FEP waveforms and, if enabled in
`opt_config.crosscheck`, the DEP and SEP waveforms with `f_load(peakname)` (see
`load_peak_waveforms`), applies the QC, prepares every set once (`prepare_peak_set`) and runs
`optimize_channel_filter` for every filter in `filter_types`. Throws an `ArgumentError` if
`opt_config.joint_search` is not a `Bool` or `opt_config.ctc_rel_uncertainty` is not a `Real`.

Returns a `Dict` from filter to its `(pars, log)`, or to the exception that stopped that
filter. Errors while loading or preparing a peak set propagate.
"""
function run_filter_optimization_channel(f_load::Function, filter_types::AbstractVector, dsp_config,
        opt_config::PropDict, τ::Unitful.Time, f_evaluate_qc;
        detector, f_title::Function, f_save::Function, f_tablepath::Function)
    if !(opt_config.joint_search isa Bool)
        throw(ArgumentError("flt_optimization.joint_search must be a Bool, got $(typeof(opt_config.joint_search))"))
    end
    if !(opt_config.ctc_rel_uncertainty isa Real)
        throw(ArgumentError("flt_optimization.ctc_rel_uncertainty must be a Real, got $(typeof(opt_config.ctc_rel_uncertainty))"))
    end

    peaknames = (fep = Symbol(opt_config.peakname),)
    opt_config.crosscheck.dep && (peaknames = merge(peaknames, (dep = DEP_PEAKNAME,)))
    opt_config.crosscheck.sep && (peaknames = merge(peaknames, (sep = SEP_PEAKNAME,)))
    sets = map(peaknames) do peakname
        wvfs = @process_step "$peakname data loader" f_load(peakname)
        @process_step "$peakname QC and preparation" prepare_peak_set(wvfs, dsp_config, τ, f_evaluate_qc, opt_config.qc)
    end
    GC.gc()

    results = Dict{Symbol, Union{NamedTuple, Exception}}()
    for flt in filter_types
        results[flt] = try
            optimize_channel_filter(sets, flt, dsp_config, opt_config, τ; detector, f_title, f_save, f_tablepath)
        catch e
            e isa InterruptException && rethrow()
            e isa ProcessStepError || @error "Filter $flt: $(truncate_error(e))"
            e
        end
        GC.gc()
    end
    return results
end
