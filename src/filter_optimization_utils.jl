# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Per-detector filter optimization shared by the run and partition processors.

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
    qc_mad_selection(table, qc_mad)

Boolean vector of the rows of `table` that lie within `k` normalized MADs of the median for every
`column => k` of `qc_mad`: `|x - median(x)| <= k * mad(x)`, with median and normalized MAD of the
finite values of the column. Columns are looked up by name in `table`.
"""
function qc_mad_selection(table, qc_mad)
    mapreduce(.&, collect(qc_mad); init = trues(length(table))) do (column, k)
        x = getproperty(table, Symbol(column))
        x_finite = filter(isfinite, x)
        abs.(x .- median(x_finite)) .<= k * mad(x_finite; normalize = true)
    end
end


"""
    prepare_peak_set(wvfs::NamedTuple, dsp_config::DSPConfig, τ::Unitful.Time, f_evaluate_qc,
                     qc_string::AbstractString, qc_mad)

Apply the QC selection to the waveforms of one peak (see `load_peak_waveforms`) and prepare the
presummed waveforms of the selected events with `dsp_flt_optimization_prepare`.

qdrift is computed from the windowed waveforms of all events and added to the table of
`dsp_qc_flt_optimization_compressed`. An event is selected if it is within the MAD limits `qc_mad`
(see `qc_mad_selection`) and the expression `qc_string` holds on that table.

Returns `(prep, qdrift, wvfs_pre)` of the selected events, where `prep` is a `FltOptPrep` and
`wvfs_pre` are the presummed waveforms.
"""
function prepare_peak_set(wvfs::NamedTuple, dsp_config::DSPConfig, τ::Unitful.Time, f_evaluate_qc, qc_string::AbstractString, qc_mad)
    dsp_qc = dsp_qc_flt_optimization_compressed(wvfs.wvfs_pre, dsp_config, τ, f_evaluate_qc)
    qdrift_all = dsp_qdrift_flt_optimization(wvfs.wvfs_wdw, dsp_qc.blmean ./ wvfs.presum_rate, dsp_config, τ)
    dsp_qc = Table(dsp_qc; qdrift = qdrift_all)
    mad_ok = qc_mad_selection(dsp_qc, qc_mad)
    qc = findall(mad_ok .& ljl_propfunc(qc_string).(dsp_qc))
    isempty(qc) && throw(ErrorException("No event passes the QC selection $qc_string and the qc_mad limits"))
    @debug "QC survival fraction: $(round(count(mad_ok) / length(dsp_qc) * 100, digits = 2))% after the MAD cuts, $(round(length(qc) / length(dsp_qc) * 100, digits = 2))% after all cuts"
    wvfs_pre = wvfs.wvfs_pre[qc]
    return (; prep = dsp_flt_optimization_prepare(wvfs_pre, dsp_config, τ), qdrift = qdrift_all[qc], wvfs_pre)
end


"""
    fit_fep_peak(e_cal::AbstractVector{<:Unitful.Energy}, peak::Unitful.Energy, window::Tuple; containment::Real)

Fit the calibrated energies `e_cal` inside `peak - window[1] .. peak + window[2]` with
`fit_single_peak_th228` and compute `peak_width_metrics` of the fitted signal shape.

Returns `(μ, σ, fwhm, w90, asym, tail_fraction, tail_scale, centroid, n_events, h, f_fit, report)`.
Energies carry keV units; `h` and `f_fit` work on unitless keV. Throws an `ArgumentError` with
fewer than 100 events in the window.
"""
function fit_fep_peak(e_cal::AbstractVector{<:Unitful.Energy}, peak::Unitful.Energy, window::Tuple; containment::Real)
    x = ustrip.(u"keV", filter(e -> peak - first(window) < e < peak + last(window), e_cal))
    length(x) >= 100 || throw(ArgumentError("Only $(length(x)) events in the fit window around $peak"))
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
    evaluate_optimum(fep::NamedTuple, dsp_config, opt_config::PropDict, flt_config::PropDict,
                     flt::Symbol, rt::Unitful.Time, ft::Unitful.Time)

Evaluation of the FEP set `fep` (see `prepare_peak_set`) with filter `flt` at `(rt, ft)`.

The energies are evaluated with `evaluate_energy_point` and the calibrated energies are fitted with
`fit_fep_peak`, which throws if the fit fails.

Returns `(fep_row, fit, residuals, ctc_report)`:
- `fep_row`: `evaluate_energy_point` row
- `fit`: `fit_fep_peak` result
- `residuals`: `(residual, qdrift, slow_mean)`, the residuals `(e - μ) / σ` of the events in the
  FEP window with finite qdrift and their mean over the five percent with the highest qdrift
- `ctc_report`: `ctc_energy` report of the energies if `opt_config.apply_ctc`, else `nothing`
"""
function evaluate_optimum(fep::NamedTuple, dsp_config, opt_config::PropDict, flt_config::PropDict,
        flt::Symbol, rt::Unitful.Time, ft::Unitful.Time)
    peak = opt_config.peak
    window = (opt_config.left_window_size, opt_config.right_window_size)

    e = dsp_energy_rtft(fep.prep, dsp_config, rt, ft, flt)
    fep_row = evaluate_energy_point(e, fep.qdrift, peak, window, flt_config.min_e_fep, flt_config.max_e_fep,
        flt_config.rel_cut_fit_e_fep; n_bins = flt_config.nbins_e_fep, apply_ctc = opt_config.apply_ctc,
        containment = opt_config.containment)
    e_cal = (e .+ fep_row.fct .* fep.qdrift) .* fep_row.m_cal_simple
    fit = fit_fep_peak(e_cal, peak, window; containment = opt_config.containment)

    sel = [i for i in eachindex(e_cal, fep.qdrift) if peak - first(window) < e_cal[i] < peak + last(window) && isfinite(fep.qdrift[i])]
    residual = ustrip.(NoUnits, (e_cal[sel] .- fit.μ) ./ fit.σ)
    slow = fep.qdrift[sel] .>= quantile(fep.qdrift[sel], 0.95)
    residuals = (residual = residual, qdrift = fep.qdrift[sel], slow_mean = mean(residual[slow]))

    ctc_report = nothing
    if opt_config.apply_ctc
        valid = [i for i in eachindex(e, fep.qdrift) if isfinite(e[i]) && isfinite(fep.qdrift[i]) && e[i] > 0 && fep.qdrift[i] > 0]
        ctc_report = last(ctc_energy(e[valid] .* fep_row.m_cal_simple, fep.qdrift[valid], peak, window, fep_row.m_cal_simple))
    end

    return (; fep_row, fit, residuals, ctc_report)
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
    optimize_channel_filter(fep::NamedTuple, flt::Symbol, dsp_config::DSPConfig,
                            opt_config::PropDict, τ::Unitful.Time;
                            detector, f_title::Function, f_save::Function, f_tablepath::Function)

Optimize energy filter `flt` of one detector on the prepared FEP set `fep` (see
`run_filter_optimization_channel`):
1. A noise sweep gives the rise time `rt_enc` with minimal ENC.
2. A flat-top scan at `rt_enc` gives `ft0`, the optimum of `opt_config.objective`.
3. With `opt_config.joint_search`, a lattice search with `optimize_rtft` from `(rt_enc, ft0)`
   gives the optimum; otherwise it is `(rt_enc, ft0)`.
4. An evaluation of the FEP at the optimum (`evaluate_optimum`).
5. Figures are saved with `f_save(fig, name)` and titles `f_title(label, flt)`; tables are
   written to `f_tablepath(flt)` with `write_fltopt_tables`.

For CUSP and ZAC the flat-top times in the pars and the log are those the
filter applies (`realized_flattop`), and the lattice search visits only flat tops that are applied
as requested. The `ft_applied` column of the evaluation table holds the applied flat-top time;
`ft` is the requested one. The trapezoidal flat-top time is written as requested.

An optimum on the lower or upper end of the flat-top grid (`flat_top_edge`) logs a warning naming
`detector` and `flt`; the log field `ft_edge` holds `"lower"`, `"upper"` or `"-"`.

Returns `(pars, log)`: the fltopt pars of the filter and the extra log table fields. `pars` holds
`n_evals` and `converged` only if the joint search ran.
"""
function optimize_channel_filter(fep::NamedTuple, flt::Symbol, dsp_config::DSPConfig, opt_config::PropDict,
        τ::Unitful.Time; detector, f_title::Function, f_save::Function, f_tablepath::Function)
    flt_config = opt_config.e_filter[flt]
    objective = Symbol(opt_config.objective)
    (; joint_search, ctc_rel_uncertainty) = opt_config
    e_grid_rt = getproperty(dsp_config, Symbol("e_grid_rt_$(flt)"))
    e_grid_ft = getproperty(dsp_config, Symbol("e_grid_ft_$(flt)"))
    window = (opt_config.left_window_size, opt_config.right_window_size)
    prep = fep.prep

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
        result_ft, report_ft = fit_fwhm_ft(e_grid, e_grid_ft, fep.qdrift, rt_enc, flt_config.min_e_fep,
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
            result_rtft, report_rtft = optimize_rtft(f_energy, fep.qdrift, rt_seed, ft_seed;
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

    ev = @process_step "$flt evaluation" evaluate_optimum(fep, dsp_config, opt_config, flt_config, flt, rt_opt, ft_opt)

    # An optimum on the edge of the ft grid may lie beyond it.
    ft_edge = flat_top_edge(ft_opt, ft_written.(extrema(e_grid_ft)), prep.sampling_period)
    if !isnothing(ft_edge)
        @warn "Detector $detector, filter $flt: optimum flat-top time $ft_opt is on the $ft_edge edge of the ft grid $(extrema(e_grid_ft))"
    end

    @process_step "$flt evaluation plots" begin
        if opt_config.apply_ctc
            f_save(LegendMakie.lplot(ev.ctc_report, figsize = (600, 600), title = f_title("CTC Optimum", flt)), Symbol("ctc_$(flt)"))
        end
        f_save(LegendMakie.lplot(ev.residuals; figsize = (900, 450), title = f_title("FEP Residuals", flt)), Symbol("residuals_$(flt)"))
    end

    # Example waveforms: the events with the lowest and the highest qdrift.
    @process_step "$flt example waveforms" begin
        n_class = opt_config.n_example_wvfs
        qdrift = fep.qdrift
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

        write_fltopt_tables(f_tablepath(flt), (;
            evaluation,
            residuals = (; ev.residuals.residual, ev.residuals.qdrift),
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
    log = (objective = pars.objective, ft_edge = isnothing(ft_edge) ? "-" : string(ft_edge))
    return (; pars, log)
end


"""
    dplms_grid(flt_config, sampling_period)

Grid for `dsp_dplms_optimization`: LegendDSP's `dplms_default_grid` if `flt_config` has no `ff`
section, otherwise a function of the rise time in samples that returns `dplms_default_grid` with the
flat-top widenings `ff.start:ff.step:ff.stop` of the section, in samples. Throws an `ArgumentError`
if a widening is not a whole multiple of `sampling_period`.
"""
function dplms_grid(flt_config, sampling_period)
    haskey(flt_config, :ff) || return dplms_default_grid
    ff = flt_config.ff
    ffs = uconvert.(NoUnits, (ff.start:ff.step:ff.stop) ./ sampling_period)
    all(f -> isapprox(f, round(f); atol = 1e-6), ffs) ||
        throw(ArgumentError("DPLMS flat-top widenings $(ff.start):$(ff.step):$(ff.stop) are not whole multiples of the sample time $sampling_period"))
    return n -> dplms_default_grid(n; ff = round.(Int, ffs))
end


"""
    dplms_weight_families(grid)

Groups of the points of a DPLMS `grid` that share all synthesis weights `nm`, `za`, `ft`, `ct`, `zo`,
in order of first occurrence, as a vector of `(weights, idxs)` with the `NamedTuple` of the weights
and the indices of the grid points.
"""
function dplms_weight_families(grid)
    weights = map(w -> (; w.nm, w.za, w.ft, w.ct, w.zo), grid)
    return [(weights = u, idxs = findall(==(u), weights)) for u in unique(weights)]
end


"""
    optimize_dplms_filter(fep::NamedTuple, dsp_config, opt_config::PropDict, τ::Unitful.Time;
                          detector, f_title::Function, f_save::Function)

Synthesize DPLMS energy filters on the prepared FEP set `fep` (see `prepare_peak_set`) and select one.

`dsp_dplms_optimization` synthesizes a filter for every point of the grid of `dplms_grid`, with the
flat-top widenings `ff` of `opt_config.e_filter.dplms.ff` if given. Grid points that share all weights
form a family (`dplms_weight_families`). For each family `fit_fwhm_ft` fits the FEP over `ff` with
the objective, `ctc_rel_uncertainty` and `containment` of `opt_config` and `rel_tol = 0`: the DPLMS
filter length does not depend on `ff`, so the scan minimum is taken without a preference for long
flat tops, and equal objective values select the largest `ff`. The family with the smallest objective
is kept. An `ff` on the edge of the scan range of the selected family (`flat_top_edge`) logs a warning
naming `detector`; the log field `ft_edge` holds `"lower"`, `"upper"` or `"-"`.

The QC expression has to remove events with a non-finite qdrift and events whose `t50_pre` lies outside
the current window of `dsp_config`: the synthesis throws otherwise.

Figures are saved with `f_save(fig, name)` and titles `f_title(label, :dplms)`.

Returns `(pars, log)`. `pars` holds the filter `coefficients`, the `reference` pulse over the window
(`n_pre` samples before to `n_post` after `t50`, unit plateau), its filter output `response` over the
`n_pre + n_post + 1` samples from `t50`, the read-out time `t_pickoff` after `t50`, `shaping_time`,
`flat_top`, `ff`, `n_pre`, `n_post`, the synthesis `weights`, the `output_area` of the filter output,
the objective fields of the other filters (`objective`, `ctc_rel_uncertainty`, `containment`,
`min_objective`, `w90`, `asym`, `fct`, `ct_spread`), `min_fwhm`, and per family its `weights`, `ff`,
`min_objective`, `min_fwhm` and the scan (`ff`, `fwhm`, `w90`, `status` per grid point) under `families`.
"""
function optimize_dplms_filter(fep::NamedTuple, dsp_config, opt_config::PropDict, τ::Unitful.Time;
        detector, f_title::Function, f_save::Function)
    flt_config = opt_config.e_filter.dplms
    objective = Symbol(opt_config.objective)
    (; ctc_rel_uncertainty, containment) = opt_config
    window = (opt_config.left_window_size, opt_config.right_window_size)

    res = @process_step "dplms filter synthesis for FEP" dsp_dplms_optimization(fep.wvfs_pre, dsp_config, τ, fep.qdrift;
        grid = dplms_grid(flt_config, fep.prep.sampling_period))
    Δt = step(res.superpulse.time)

    fits = map(dplms_weight_families(res.grid)) do (; weights, idxs)
        ffs = [res.grid[k].ff for k in idxs]
        e_grid_ff = range(first(ffs) * Δt; step = (length(ffs) > 1 ? ffs[2] - ffs[1] : 1) * Δt, length = length(ffs))
        e_grid_ff ≈ ffs .* Δt || throw(ArgumentError("DPLMS flat-top widenings $ffs are not equally spaced"))
        result, report = @process_step "dplms flat-top widening extraction" begin
            fit_fwhm_ft(res.e_grid[idxs, :], e_grid_ff, fep.qdrift, 0.0u"µs", flt_config.min_e_fep, flt_config.max_e_fep,
                flt_config.rel_cut_fit_e_fep, opt_config.apply_ctc; n_bins = flt_config.nbins_e_fep, peak = opt_config.peak,
                window, objective, ctc_rel_uncertainty, containment, rel_tol = 0)
        end
        i_scan = only(findall(==(mvalue(result.ft)), report.table.ft))
        (; weights, e_grid_ff, i = idxs[i_scan], i_scan, result, report)
    end
    (; weights, e_grid_ff, i, i_scan, result, report) = argmin(f -> mvalue(f.result.min_objective), fits)
    w = res.grid[i]
    optimum = report.table[i_scan]
    @debug "Filter dplms: selected weights $weights, ff = $(w.ff) samples with FWHM $(round(u"keV", result.min_fwhm, digits = 2))"

    ft_edge = length(e_grid_ff) > 1 ? flat_top_edge(w.ff * Δt, extrema(e_grid_ff), Δt) : nothing
    if !isnothing(ft_edge)
        @warn "Detector $detector, filter dplms: optimum flat-top widening $(w.ff * Δt) is on the $ft_edge edge of the scan range $(extrema(e_grid_ff))"
    end

    @process_step "dplms plots" begin
        f_save(LegendMakie.lplot(report, title = f_title("FEP Flat-Top Widening Scan", :dplms), xlabel = "Flat-Top Widening ff",
                                 figsize = (600, 900)), :ft_scan_dplms)
        f_save(LegendMakie.lplot((; res.coeffs, res.grid, res.superpulse, res.t_pickoff, res.n_pre, res.n_post); idxs = [i],
                                 title = f_title("DPLMS Filter", :dplms)), :dplms_filter)
        f_save(LegendMakie.lplot((; res.superpulse, res.ref, res.ref_bins, res.t50, res.t_pickoff, res.n_pre, res.n_post);
                                 figsize = (1200, 800), title = f_title("DPLMS Reference", :dplms)), :dplms_reference)
        f_save(LegendMakie.lplot((; res.superpulse, res.response, res.grid, res.t50, res.t_pickoff, res.n_pre, res.n_post); idxs = [i],
                                 xlims = (-(res.n_pre + 8), res.n_pre + res.n_post + 16) .* ustrip(u"µs", Δt),
                                 figsize = (1200, 600), title = f_title("DPLMS Response", :dplms)), :dplms_response)
        f_save(LegendMakie.lplot((; res.noise, res.flattops, res.ref, res.superpulse, res.n_pre, res.n_post); ff = w.ff,
                                 figsize = (1200, 1000), title = f_title("DPLMS Matrices", :dplms)), :dplms_matrices)
    end

    # The filter output of the superpulse has its own time axis: take the samples from the alignment point on.
    k0 = argmin(abs.(res.response[i].time .- median(res.t50)))
    response = res.response[i].signal[k0:(k0 + length(res.ref) - 1)]

    pars = (
        coefficients = res.coeffs[i], reference = res.ref, response, t_pickoff = uconvert(u"µs", res.t_pickoff),
        shaping_time = uconvert(u"µs", res.shaping_time[i]), flat_top = uconvert(u"µs", res.flat_top[i]),
        ff = w.ff, n_pre = res.n_pre, n_post = res.n_post, weights, output_area = uconvert(u"µs", res.output_area[i]),
        objective = string(objective), ctc_rel_uncertainty, containment,
        min_objective = result.min_objective, min_fwhm = result.min_fwhm, w90 = optimum.w90, asym = optimum.asym,
        fct = optimum.fct, ct_spread = optimum.ct_spread,
        families = [(weights = f.weights, ff = res.grid[f.i].ff, min_objective = f.result.min_objective, min_fwhm = f.result.min_fwhm,
                     scan = (ff = uconvert.(u"µs", f.report.table.ft), fwhm = mvalue.(uconvert.(u"keV", f.report.table.fwhm)),
                             w90 = mvalue.(uconvert.(u"keV", f.report.table.w90)), status = string.(f.report.table.status)))
                    for f in fits],
    )
    log = (objective = pars.objective, ft_edge = isnothing(ft_edge) ? "-" : string(ft_edge))
    return (; pars, log)
end


"""
    fltopt_pars_summary(filter_type::Symbol, pars)

`(rt, ft, fwhm, w90)` of the fltopt pars `pars` of one filter, as shown in the report tables. For `:dplms`
the rise time and flat-top time are its `shaping_time` and `flat_top` and the FWHM is `min_fwhm`.
"""
function fltopt_pars_summary(filter_type::Symbol, pars)
    filter_type == :dplms && return (rt = pars.shaping_time, ft = pars.flat_top, fwhm = pars.min_fwhm, w90 = pars.w90)
    return (rt = pars.rt, ft = pars.ft, fwhm = pars.fwhm, w90 = pars.w90)
end


"""
    is_current_fltopt_pars(filter_type::Symbol, pars)

`true` if `pars` holds all fields that the current method stores for `filter_type`. Pars of an
earlier method lack some of them and are optimized again.
"""
function is_current_fltopt_pars(filter_type::Symbol, pars)
    required = filter_type == :dplms ? (:objective, :w90, :ct_spread, :families) : (:objective, :w90, :ct_spread, :joint_search)
    return all(k -> haskey(pars, k), required)
end


"""
    run_filter_optimization_channel(f_load::Function, filter_types::AbstractVector, dsp_config,
                                    opt_config::PropDict, τ::Unitful.Time, f_evaluate_qc;
                                    detector, f_title::Function, f_save::Function, f_tablepath::Function)

Filter optimization of one detector. Loads the FEP waveforms with `f_load(peakname)` (see
`load_peak_waveforms`), applies the QC, prepares the set once (`prepare_peak_set`) and runs
`optimize_channel_filter` for every filter in `filter_types` except `:dplms`, which is handled
last by `optimize_dplms_filter`. Throws an `ArgumentError` if
`opt_config.joint_search` is not a `Bool`, `opt_config.ctc_rel_uncertainty` is not a `Real` or
`opt_config.qc_mad` is not a section.

Returns a `Dict` from filter to its `(pars, log)`, or to the exception that stopped that
filter. Errors while loading or preparing the FEP set propagate.
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
    if !(opt_config.qc_mad isa PropDict)
        throw(ArgumentError("flt_optimization.qc_mad must be a section of column => limit entries, got $(typeof(opt_config.qc_mad))"))
    end

    peakname = Symbol(opt_config.peakname)
    wvfs = @process_step "$peakname data loader" f_load(peakname)
    fep = @process_step "$peakname QC and preparation" prepare_peak_set(wvfs, dsp_config, τ, f_evaluate_qc, opt_config.qc,
                                                                        opt_config.qc_mad)
    GC.gc()

    # DPLMS is synthesized after the filters of fixed shape.
    results = Dict{Symbol, Union{NamedTuple, Exception}}()
    for flt in vcat(filter(!=(:dplms), filter_types), filter(==(:dplms), filter_types))
        results[flt] = try
            if flt == :dplms
                optimize_dplms_filter(fep, dsp_config, opt_config, τ; detector, f_title, f_save)
            else
                optimize_channel_filter(fep, flt, dsp_config, opt_config, τ; detector, f_title, f_save, f_tablepath)
            end
        catch e
            e isa InterruptException && rethrow()
            e isa ProcessStepError || @error "Filter $flt: $(truncate_error(e))"
            e
        end
        GC.gc()
    end
    return results
end
