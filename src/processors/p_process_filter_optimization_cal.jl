"""
    p_process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Optimize the energy filter rise time and flat-top time per detector and `cal` partition for all partitions that contain `period`, using all analysis runs of the partition (HPGe detectors `geds`).

The method is the same as in `process_filter_optimization_cal`: for each filter type listed under `e_filter`, the rise time is chosen from a baseline noise sweep and the flat-top time from a sweep over full-energy-peak events, or both from a joint search if `joint_search` is enabled. The waveforms of the peak named by `peakname` are read from the `jlpks` tier of all runs of the partition (`n_evts` events per run, drawn randomly with a seeded random number generator if `select_random` is set) and at most `max_wvfs` of them are used. The quality cuts (`qc` expression and optional `qc_mad` section) are those of `process_filter_optimization_cal`. Results lacking `objective`, `w90`, `ct_spread` or `joint_search` are optimized again (`families` instead of `joint_search` for `dplms`).

If `e_filter` lists `dplms`, a DPLMS filter is synthesized and selected after the other filter types as in `process_filter_optimization_cal`, on the same QC-selected waveforms and with the flat-top widenings `ff` of the config range `e_filter.dplms.ff` (start, stop, step; whole multiples of the sample time) if given. The `qc_mad` section is required, and the `qc` expression must remove events with a non-finite `qdrift` and events with a `t50_pre` outside the current window; the DPLMS synthesis throws otherwise.

# Inputs
- `jlpks` tier of the `cal` runs of each partition, for each detector.
- `dataprod_config(l200).dsp(filekey)`, in particular `flt_optimization.p_default` and the per-detector entries `flt_optimization.p`, and the DSP config used for the filter grids.
- `l200.par.ppars.pz[det, part]` (decay times).
- Quality-cut evaluator loaded by `load_qc_evaluator(l200, filekey)`.
- `l200.par.ppars.fltopt[det, part]` (existing results, if present).

# Outputs
- `l200.par.ppars.fltopt[det, part]`: per filter type the optimal rise time `rt` and flat-top time `ft` (the flat-top time the CUSP and ZAC filters apply), the `objective` with its value `min_objective`, the `fwhm`, `w90`, `asym`, `fct` and `ct_spread` at the optimum, `ctc_rel_uncertainty`, `joint_search`, `containment`, the noise sweep results `rt_enc` and `min_enc`, and `n_evals` and `converged` of the joint search if it ran, with validity entries for the partition; the validity of all partitions of the period is written to `l200.par.ppars.fltopt`. The `dplms` entry holds instead the filter `coefficients`, the `reference` pulse over the window (`n_pre` samples before to `n_post` after `t50`, unit plateau), its filter output `response` over the `n_pre + n_post + 1` samples from `t50`, the read-out time `t_pickoff` after `t50`, `shaping_time`, `flat_top`, `ff` (in samples), `n_pre`, `n_post`, the synthesis `weights`, the `output_area` of the filter output, the objective fields of the other filters (`objective`, `ctc_rel_uncertainty`, `containment`, `min_objective`, `min_fwhm`, `w90`, `asym`, `fct`, `ct_spread`) and per family its `weights`, `ff` (in samples), `min_objective`, `min_fwhm` and the scan (`ff` in µs, `fwhm`, `w90`, `status` per grid point) under `families`.
- Per detector, partition and filter type, plots `noise_sweep_<filter_type>`, `fwhm_ft_scan_<filter_type>`, `rtft_landscape_<filter_type>` (joint search only), `ctc_<filter_type>`, `residuals_<filter_type>` and `example_wvfs_<filter_type>`, saved only at the debug plot level. For `dplms`: `fwhm_ft_scan_dplms` (scan over `ff` of the selected family), `dplms_filter`, `dplms_reference`, `dplms_response` and `dplms_matrices`, and no noise sweep, joint search, CTC, residual or example waveform plots.
- Partition report `:filter_optimization` (Main Log, Metadata, Results table with one row per detector, partition and filter type; the `dplms` row shows shaping time and flat top in the rise-time and flat-top columns).

# Keywords
- `reprocess`: redo all filter types, ignoring results in `l200.par.ppars.fltopt[det, part]`. If `false`, only filter types without results are processed.
- `timeout`: seconds allowed per detector and partition in `parallel` (0 = no limit).
- `only_first_period`: if `true`, a detector whose partition starts in an earlier period is skipped (it is processed with that earlier period). `run_processing` sets this to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector and partition was skipped because of `only_first_period`, otherwise `false`. `run_processing` uses this to wait for the same step in the previous period.
"""
function p_process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false,
                                           timeout::Real = 0, only_first_period::Bool = true)
    @info "Optimize filter for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :cal; system = :geds, explode_partitions = true) |>
                      detector_filter(processing_config, :p_process_filter_optimization_cal)
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :psd_usability, :Partition, :Status, Symbol("Filter Type"), :Objective,
                         Symbol("Rise Time"), Symbol("Flat-Top Time"), :FWHM, :W90, :Converged, Symbol("FT Edge"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_filter_optimization(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @debug "Processing detector $det ($ch)"

        make_par_dir(joinpath(data_path(l200.par.ppars.fltopt), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.fltopt[det]), "$part.yaml"))
            PropDict(l200.par.ppars.fltopt[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.fltopt), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        pars_tau = get_values(PropDict(l200.par.ppars.pz[det, part]))
        @debug "Loaded decay times"

        dsp_config_pd = dataprod_config(l200).dsp(filekey_det)
        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        optimization_config = dataprod_config(l200).dsp(filekey_det).flt_optimization
        optimization_config_det = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded optimization config: $(lstring(optimization_config_det))"

        # extract config
        n_evts = optimization_config_det.n_evts
        max_wvfs = optimization_config_det.max_wvfs
        select_random = optimization_config_det.select_random
        qc_string = optimization_config_det.qc
        peakname = Symbol(optimization_config_det.peakname)
        peak = optimization_config_det.peak
        window = (optimization_config_det.left_window_size, optimization_config_det.right_window_size)
        objective = Symbol(optimization_config_det.objective)
        joint_search = optimization_config_det.joint_search
        ctc_rel_uncertainty = optimization_config_det.ctc_rel_uncertainty
        containment = optimization_config_det.containment
        e_filter = collect(keys(optimization_config_det.e_filter))
        qc_mad = get(optimization_config_det, :qc_mad, PropDict())
        qc_mad isa PropDict || throw(ArgumentError("flt_optimization config of $det: qc_mad must be a section of column => limit entries"))
        :dplms in e_filter && !haskey(optimization_config_det, :qc_mad) &&
            throw(ArgumentError("flt_optimization config of $det: the dplms filter requires a qc_mad section"))

        result_rt_ft_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in e_filter
                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                   process_skipped, filter_type, fill("-", 7)...,
                                   "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db_det[det], filter_type)
                    pars_flt = pars_db_det[det][filter_type]
                    if all(k -> haskey(pars_flt, k), (:objective, :w90, :ct_spread, filter_type == :dplms ? :families : :joint_search))
                        @debug "Filter $filter_type already processed, skip"
                        rt, ft, fwhm = filter_type == :dplms ? (pars_flt.shaping_time, pars_flt.flat_top, pars_flt.min_fwhm) :
                                       (pars_flt.rt, pars_flt.ft, pars_flt.fwhm)
                        log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                           ProcessStatus(1), filter_type, pars_flt.objective, rt, ft, fwhm,
                                           pars_flt.w90, get(pars_flt, :converged, "-"), "-", "Already processed --> skipped."))
                        # add results to dict
                        log_info_dict[filter_type] = log_info
                        processed_dict[filter_type] = false
                    else
                        @info "Detector $det, filter $filter_type: pars lack fields of the current method, optimize again"
                    end
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict, validity = validity_det)
        end

        if !haskey(pars_tau, det) || !haskey(pars_tau[det], :τ)
            throw(ErrorException("Detector $det has no decay time τ in the pz pars of partition $part"))
        end

        rng = MersenneTwister(hash((string(det), join(string.(partinfo_det.period, "-", partinfo_det.run), ","))))

        # load data
        wvfs_det_pre, wvfs_det_wdw, presum_rate = @process_step "$peakname data loading" begin
            @debug "Loading $peakname data from $(part), select $(ifelse(select_random, "randomly ", ""))$n_evts events from each run"
            # The events of each run are selected by timestamp before reading, so only the
            # selected waveforms are loaded from disk.
            f_timestamp = ljl_propfunc("$peakname.timestamp")
            peak_data = fast_flatten(map(partinfo_det) do r
                                         ts = read_ldata(f_timestamp, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det)
                                         n_sel = n_evts == -1 ? length(ts) : min(n_evts, length(ts))
                                         ts_sel = select_random ? sample(rng, ts, n_sel; replace = false, ordered = true) :
                                                  ts[begin:(begin + n_sel - 1)]
                                         read_ldata(peakname, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det;
                                                    filterby = @pf $timestamp in ts_sel)
                                     end)
            wvfs_det_pre = peak_data.waveform_presummed
            wvfs_det_wdw = peak_data.waveform_windowed
            presum_rate = peak_data.presum_rate
            if length(wvfs_det_pre) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                sel = sample(rng, eachindex(wvfs_det_pre), max_wvfs; replace = false, ordered = true)
                wvfs_det_pre = wvfs_det_pre[sel]
                wvfs_det_wdw = wvfs_det_wdw[sel]
                presum_rate = presum_rate[sel]
            end
            wvfs_det_pre, wvfs_det_wdw, presum_rate
        end
        yield()

        # get QC cuts: qdrift of all events is part of the QC table; an event is kept if it lies within k normalized MADs of the
        # median of the finite values for every column => k of qc_mad and the qc expression holds
        wvfs_det_pre, qdrift = @process_step "QC cuts" begin
            @debug "Get QC cuts"
            dsp_qc = dsp_qc_flt_optimization_compressed(wvfs_det_pre, dsp_config_det, pars_tau[det].τ, f_evaluate_qc)
            qdrift = dsp_qdrift_flt_optimization(wvfs_det_wdw, dsp_qc.blmean ./ presum_rate, dsp_config_det, pars_tau[det].τ)
            dsp_qc = Table(dsp_qc; qdrift)
            mad_ok = mapreduce(.&, collect(qc_mad); init = trues(length(dsp_qc))) do (col, k)
                x = getproperty(dsp_qc, Symbol(col))
                x_finite = filter(isfinite, x)
                abs.(x .- median(x_finite)) .<= k * mad(x_finite; normalize = true)
            end
            qc = mad_ok .& ljl_propfunc(qc_string).(dsp_qc)
            if count(qc) == 0
                throw(ErrorException("No event passes the QC selection $qc_string" *
                                        (isempty(qc_mad) ? "" : " and the qc_mad limits")))
            end
            @debug "Survival Fraction: $(round(count(mad_ok) / length(qc) * 100, digits=2))% after the MAD cuts, $(round(count(qc) / length(qc) * 100, digits=2))% after all cuts"
            wvfs_det_pre[findall(qc)], qdrift[findall(qc)]
        end

        # prepare the waveforms once for all filter evaluations
        prep = @process_step "FEP preparation" begin
            @debug "Prepare FEP waveforms"
            dsp_flt_optimization_prepare(wvfs_det_pre, dsp_config_det, pars_tau[det].τ)
        end

        @debug_progress "Computing $det ..." for filter_type in e_filter
            if haskey(processed_dict, filter_type) || filter_type == :dplms
                continue
            end

            try
                @debug "Optimize $filter_type filter"

                optimization_config_flt = optimization_config_det.e_filter[filter_type]
                # unpack config
                e_grid_rt = getproperty(dsp_config_det, Symbol("e_grid_rt_$(filter_type)"))
                e_grid_ft = getproperty(dsp_config_det, Symbol("e_grid_ft_$(filter_type)"))

                lattice = prep.sampling_period
                # The filters read every FEP waveform inside its time axis: trapezoidal output exists from
                # t_first + 2rt + ft on and is read at t50 + rt + ft/2; CUSP and ZAC are read at t50 + flt_length/2.
                t_first, t_last = extrema(first(prep.wvfs_pz).time)
                if !all(t -> extrema(t) == (t_first, t_last), prep.wvfs_pz.time)
                    throw(ArgumentError("The FEP waveforms do not share one time axis"))
                end
                t50_min, t50_max = extrema(filter(isfinite, prep.t50))
                max_half_length = min(t50_min - t_first, t_last - t50_max) - dsp_config_det.kwargs_pars.sig_interpolation_length
                flt_length = filter_type == :trap ? zero(lattice) : getproperty(dsp_config_det, Symbol("flt_length_$(filter_type)"))
                if filter_type != :trap && !(flt_length / 2 <= max_half_length)
                    throw(ArgumentError("The $filter_type filter length $flt_length does not fit the FEP waveform window"))
                end

                # CUSP and ZAC lengthen some flat tops by one sample; the trapezoidal flat top is used as requested
                applied_ft(ft) = uconvert(u"µs", filter_type == :trap ? ft : realized_flattop(ft, flt_length, lattice, filter_type))
                # flat tops that CUSP and ZAC do not apply as requested duplicate a longer flat top
                function feasible(rt, ft)
                    if filter_type == :trap
                        return rt + ft / 2 <= max_half_length
                    end
                    return ft < flt_length && applied_ft(ft) == uconvert(u"µs", ft)
                end

                # one dsp_energy_rtft call allocates up to five times the prepared waveforms, limit simultaneous calls
                sem = Base.Semaphore(optimization_config_det.max_concurrent_evals)
                function f_energy(rt, ft)
                    Base.acquire(sem)
                    try
                        return dsp_energy_rtft(prep, dsp_config_det, rt, ft, filter_type)
                    finally
                        Base.release(sem)
                    end
                end

                # optimize RT
                enc_grid = @process_step "$filter_type RT DSP for FEP" begin
                    @debug "Generate $filter_type ENC filter grid"
                    legend_dsp_function("dsp_$(filter_type)_rt_optimization", "dsp.flt_optimization.e_filter.$filter_type")(prep,
                                                                                                                            dsp_config_det;
                                                                                                                            ft = optimization_config_flt.ft_fixed)
                end
                yield()
                result_rt, report_rt = @process_step "$filter_type rise time extraction" begin
                    fit_enc_sigmas(enc_grid, e_grid_rt, optimization_config_flt.min_enc, optimization_config_flt.max_enc,
                                   optimization_config_flt.nbins_enc_sigmas, optimization_config_flt.rel_cut_fit_enc_sigmas)
                end
                @debug format("Found optimal $filter_type RT at $(result_rt.rt) with ENC {:.2f} ADC", result_rt.min_enc)
                yield()

                @debug_plot begin
                    p = LegendMakie.lplot(report_rt,
                                          title = get_plottitle(filekey_det, part, det, "Noise Sweep"; additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("noise_sweep_$(filter_type)"))
                end

                # optimize FT
                yield()
                e_grid = @process_step "$filter_type FT DSP for FEP" begin
                    @debug "Generate $filter_type FT energy grid"
                    permutedims(reduce(hcat, [f_energy(mvalue(result_rt.rt), ft) for ft in e_grid_ft]))
                end
                yield()
                result_ft, report_ft = @process_step "$filter_type flat-top time extraction" begin
                    fit_fwhm_ft(e_grid, e_grid_ft, qdrift, result_rt.rt, optimization_config_flt.min_e_fep,
                                optimization_config_flt.max_e_fep, optimization_config_flt.rel_cut_fit_e_fep,
                                optimization_config_det.apply_ctc; n_bins = optimization_config_flt.nbins_e_fep, peak, window,
                                objective, ctc_rel_uncertainty, containment, rel_tol = optimization_config_det.rel_tol)
                end
                @debug "Found optimal $filter_type FT at $(result_ft.ft) with FWHM $(round(u"keV", result_ft.min_fwhm, digits=2))"
                yield()
                @debug_plot begin
                    p = LegendMakie.lplot(report_ft,
                                          title = get_plottitle(filekey_det, part, det, "FEP FT Scan"; additional_type = string(filter_type)),
                                          figsize = (600, 900))
                    save_plot(p, l200, part, filekey_det, det, Symbol("fwhm_ft_scan_$(filter_type)"))
                end

                # optimize RT and FT jointly
                if joint_search
                    result_rtft, report_rtft = @process_step "$filter_type joint RT and FT search" begin
                        # seed on the lattice inside the bounds, with the flat-top time lowered until it is feasible
                        lattice_range(bounds) = ceil(Int, ustrip(NoUnits, first(bounds) / lattice) - 1e-6):floor(Int, ustrip(NoUnits, last(bounds) / lattice) + 1e-6)
                        rt_range = lattice_range(extrema(e_grid_rt))
                        ft_range = lattice_range(extrema(e_grid_ft))
                        i_seed = clamp(round(Int, ustrip(NoUnits, mvalue(result_rt.rt) / lattice)), first(rt_range), last(rt_range))
                        j_seed = clamp(round(Int, ustrip(NoUnits, applied_ft(mvalue(result_ft.ft)) / lattice)), first(ft_range),
                                       last(ft_range))
                        while j_seed in ft_range && !feasible(i_seed * lattice, j_seed * lattice)
                            j_seed -= 1
                        end
                        if !(j_seed in ft_range)
                            throw(ErrorException("No feasible seed for the joint search inside the $filter_type grids"))
                        end

                        # CUSP and ZAC flat tops lie on every second lattice point: the flat-top step is a power of two
                        # lattice steps, at least two
                        if filter_type == :trap
                            step_ft = step(e_grid_ft)
                        else
                            n_steps = ustrip(NoUnits, max(step(e_grid_rt), step(e_grid_ft)) / lattice)
                            step_ft = 2^max(1, round(Int, log2(n_steps))) * lattice
                        end
                        optimize_rtft(f_energy, qdrift, i_seed * lattice, j_seed * lattice;
                                      rt_bounds = extrema(e_grid_rt), ft_bounds = extrema(e_grid_ft), feasible,
                                      step0 = (step(e_grid_rt), step_ft), lattice = lattice, objective, ctc_rel_uncertainty,
                                      rel_tol = optimization_config_det.rel_tol, max_evals = optimization_config_det.max_evals,
                                      peak, window, min_e = optimization_config_flt.min_e_fep, max_e = optimization_config_flt.max_e_fep,
                                      rel_cut_fit = optimization_config_flt.rel_cut_fit_e_fep, n_bins = optimization_config_flt.nbins_e_fep,
                                      apply_ctc = optimization_config_det.apply_ctc, containment)
                    end
                    @debug "Found optimal $filter_type RT at $(result_rtft.rt) and FT at $(result_rtft.ft) after $(result_rtft.n_evals) evaluations"
                    yield()
                    @debug_plot begin
                        p = LegendMakie.lplot(report_rtft,
                                              title = get_plottitle(filekey_det, part, det, "RT-FT Search"; additional_type = string(filter_type)),
                                              figsize = (700, 550))
                        save_plot(p, l200, part, filekey_det, det, Symbol("rtft_landscape_$(filter_type)"))
                    end
                    optimum = result_rtft
                else
                    i_scan = only(findall(==(mvalue(result_ft.ft)), report_ft.table.ft))
                    optimum = merge(report_ft.table[i_scan],
                                    (rt = mvalue(result_rt.rt), ft = mvalue(result_ft.ft), min_objective = result_ft.min_objective))
                end
                rt_opt = uconvert(u"µs", mvalue(optimum.rt))
                ft_opt = applied_ft(mvalue(optimum.ft))

                # an optimum on the edge of the flat-top grid may lie beyond it
                n_ft = round(Int, ustrip(NoUnits, ft_opt / lattice))
                n_ft_min, n_ft_max = round.(Int, ustrip.(NoUnits, applied_ft.(extrema(e_grid_ft)) ./ lattice))
                ft_edge = n_ft == n_ft_max ? "upper" : n_ft == n_ft_min ? "lower" : "-"
                if ft_edge != "-"
                    @warn "Detector $det, filter $filter_type: optimum flat-top time $ft_opt is on the $ft_edge edge of the flat-top grid $(extrema(e_grid_ft))"
                end

                @debug_plot begin
                    e_opt = dsp_energy_rtft(prep, dsp_config_det, rt_opt, ft_opt, filter_type)
                    point = evaluate_energy_point(e_opt, qdrift, peak, window, optimization_config_flt.min_e_fep,
                                                  optimization_config_flt.max_e_fep, optimization_config_flt.rel_cut_fit_e_fep;
                                                  n_bins = optimization_config_flt.nbins_e_fep,
                                                  apply_ctc = optimization_config_det.apply_ctc, containment)
                    e_cal = (e_opt .+ point.fct .* qdrift) .* point.m_cal_simple

                    # residuals of the events in the FEP window with finite qdrift, relative to the peak fit
                    x = ustrip.(u"keV", filter(en -> peak - first(window) < en < peak + last(window), e_cal))
                    if length(x) < 100
                        throw(ArgumentError("Only $(length(x)) events in the fit window around $peak"))
                    end
                    h = fit(Histogram, x, minimum(x):(2 * StatsBase.iqr(x) / cbrt(length(x))):maximum(x))
                    result_fep, _ = fit_single_peak_th228(h, estimate_single_peak_stats(h); uncertainty = false)
                    in_window = [i for i in eachindex(e_cal, qdrift) if peak - first(window) < e_cal[i] < peak + last(window) && isfinite(qdrift[i])]
                    residual = ustrip.(NoUnits, (e_cal[in_window] .- mvalue(result_fep.μ) * u"keV") ./ (mvalue(result_fep.σ) * u"keV"))
                    qdrift_sel = qdrift[in_window]
                    slow_mean = mean(residual[qdrift_sel .>= quantile(qdrift_sel, 0.95)])

                    if optimization_config_det.apply_ctc
                        valid = [i for i in eachindex(e_opt, qdrift) if isfinite(e_opt[i]) && isfinite(qdrift[i]) && e_opt[i] > 0 && qdrift[i] > 0]
                        ctc_report = last(ctc_energy(e_opt[valid] .* point.m_cal_simple, qdrift[valid], peak, window, point.m_cal_simple))
                        p = LegendMakie.lplot(ctc_report, figsize = (600, 600),
                                              title = get_plottitle(filekey_det, part, det, "CTC Optimum"; additional_type = string(filter_type)))
                        save_plot(p, l200, part, filekey_det, det, Symbol("ctc_$(filter_type)"))
                    end
                    p = LegendMakie.lplot((; residual, qdrift = qdrift_sel, slow_mean); figsize = (900, 450),
                                          title = get_plottitle(filekey_det, part, det, "FEP Residuals"; additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("residuals_$(filter_type)"))

                    # example waveforms: the events with the lowest and the highest qdrift
                    n_class = optimization_config_det.n_example_wvfs
                    valid = [i for i in eachindex(qdrift) if isfinite(qdrift[i])]
                    idx = vcat(valid[partialsortperm(qdrift[valid], 1:n_class)],
                               valid[partialsortperm(qdrift[valid], 1:n_class, rev = true)])
                    if filter_type == :trap
                        T = typeof(float(lattice))
                        flt = TrapezoidalChargeFilter(convert(T, rt_opt), convert(T, ft_opt))
                    else
                        T = typeof(float(flt_length))
                        FilterType = filter_type == :cusp ? CUSPChargeFilter : ZACChargeFilter
                        flt = FilterType(convert(T, rt_opt), convert(T, ft_opt), convert(T, 10000000.0u"µs"), flt_length,
                                         ustrip(NoUnits, flt_length / lattice))
                    end
                    wvfs = prep.wvfs_pz[idx]
                    p = LegendMakie.lplot((; classes = repeat([:fast, :slow], inner = n_class), wvfs, flt = flt.(wvfs));
                                          figsize = (1200, 600),
                                          title = get_plottitle(filekey_det, part, det, "Example Waveforms"; additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("example_wvfs_$(filter_type)"))
                end

                pars = (rt = rt_opt, ft = ft_opt, min_enc = result_rt.min_enc, rt_enc = result_rt.rt, objective = string(objective),
                        ctc_rel_uncertainty, joint_search, containment, min_objective = optimum.min_objective, fwhm = optimum.fwhm,
                        w90 = optimum.w90, asym = optimum.asym, fct = optimum.fct, ct_spread = optimum.ct_spread)
                if joint_search
                    pars = merge(pars, (n_evals = result_rtft.n_evals, converged = result_rtft.converged))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part, ProcessStatus(1),
                                   filter_type, pars.objective, pars.rt, pars.ft, pars.fwhm, pars.w90, get(pars, :converged, "-"),
                                   ft_edge, "-"))

                # add results to dict
                result_rt_ft_dict[filter_type] = pars
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                GC.gc()
            catch e
                e isa ProcessStepError || @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                   ProcessStatus(0), filter_type, fill("-", 7)..., "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        if :dplms in e_filter && !haskey(processed_dict, :dplms)
            try
                @debug "Optimize dplms filter"
                optimization_config_flt = optimization_config_det.e_filter.dplms
                lattice = prep.sampling_period
                # flat-top widenings of the config range `ff` in whole samples, else multiples of the pulse rise time
                dplms_grid = if haskey(optimization_config_flt, :ff)
                    ff_cfg = optimization_config_flt.ff
                    ffs = uconvert.(NoUnits, (ff_cfg.start:ff_cfg.step:ff_cfg.stop) ./ lattice)
                    all(f -> isapprox(f, round(f); atol = 1e-6), ffs) ||
                        throw(ArgumentError("DPLMS flat-top widenings $(ff_cfg.start):$(ff_cfg.step):$(ff_cfg.stop) " *
                                            "are not whole multiples of the sample time"))
                    n -> dplms_default_grid(n; ff = round.(Int, ffs))
                else
                    dplms_default_grid
                end
                res = @process_step "dplms filter synthesis for FEP" begin
                    dsp_dplms_optimization(wvfs_det_pre, dsp_config_det, pars_tau[det].τ, qdrift; grid = dplms_grid)
                end
                yield()

                # one flat-top widening fit per family of grid points with equal weights; the family with the smallest
                # objective is kept. rel_tol = 0 takes the scan minimum: the filter length does not depend on ff.
                grid_weights = [(; w.nm, w.za, w.ft, w.ct, w.zo) for w in res.grid]
                fits = map(unique(grid_weights)) do weights
                    idxs = findall(==(weights), grid_weights)
                    ffs = [res.grid[k].ff for k in idxs]
                    e_grid_ff = range(first(ffs) * lattice; step = (length(ffs) > 1 ? ffs[2] - ffs[1] : 1) * lattice, length = length(ffs))
                    e_grid_ff ≈ ffs .* lattice || throw(ArgumentError("DPLMS flat-top widenings $ffs are not equally spaced"))
                    result_ft, report_ft = @process_step "dplms flat-top widening extraction" begin
                        fit_fwhm_ft(res.e_grid[idxs, :], e_grid_ff, qdrift, 0.0u"µs", optimization_config_flt.min_e_fep,
                                    optimization_config_flt.max_e_fep, optimization_config_flt.rel_cut_fit_e_fep,
                                    optimization_config_det.apply_ctc; n_bins = optimization_config_flt.nbins_e_fep, peak, window,
                                    objective, ctc_rel_uncertainty, containment, rel_tol = 0)
                    end
                    i_scan = only(findall(==(mvalue(result_ft.ft)), report_ft.table.ft))
                    (; weights, i = idxs[i_scan], i_scan, result_ft, report_ft)
                end
                (; weights, i, i_scan, result_ft, report_ft) = argmin(f -> mvalue(f.result_ft.min_objective), fits)
                w = res.grid[i]
                optimum = report_ft.table[i_scan]
                @debug "Found optimal dplms weights $weights and ff = $(w.ff) samples with FWHM $(round(u"keV", result_ft.min_fwhm, digits=2))"

                @debug_plot begin
                    p = LegendMakie.lplot(report_ft; xlabel = "Flat-Top Widening ff", figsize = (600, 900),
                                          title = get_plottitle(filekey_det, part, det, "FEP FT Scan"; additional_type = "dplms"))
                    save_plot(p, l200, part, filekey_det, det, :fwhm_ft_scan_dplms)
                    p = LegendMakie.lplot((; res.coeffs, res.grid, res.superpulse, res.t_pickoff, res.n_pre, res.n_post); idxs = [i],
                                          title = get_plottitle(filekey_det, part, det, "DPLMS Filter"))
                    save_plot(p, l200, part, filekey_det, det, :dplms_filter)
                    p = LegendMakie.lplot((; res.superpulse, res.ref, res.ref_bins, res.t50, res.t_pickoff, res.n_pre, res.n_post);
                                          figsize = (1200, 800), title = get_plottitle(filekey_det, part, det, "DPLMS Reference"))
                    save_plot(p, l200, part, filekey_det, det, :dplms_reference)
                    p = LegendMakie.lplot((; res.superpulse, res.response, res.grid, res.t50, res.t_pickoff, res.n_pre, res.n_post); idxs = [i],
                                          xlims = (-(res.n_pre + 8), res.n_pre + res.n_post + 16) .*
                                                  ustrip(u"µs", lattice),
                                          figsize = (1200, 600), title = get_plottitle(filekey_det, part, det, "DPLMS Response"))
                    save_plot(p, l200, part, filekey_det, det, :dplms_response)
                    p = LegendMakie.lplot((; res.noise, res.flattops, res.ref, res.superpulse, res.n_pre, res.n_post); ff = w.ff,
                                          figsize = (1200, 1000), title = get_plottitle(filekey_det, part, det, "DPLMS Matrices"))
                    save_plot(p, l200, part, filekey_det, det, :dplms_matrices)
                end

                # filter output for the superpulse over the samples from the alignment point; the output has its own time axis
                k0 = argmin(abs.(res.response[i].time .- median(res.t50)))
                response = res.response[i].signal[k0:(k0 + length(res.ref) - 1)]

                pars = (coefficients = res.coeffs[i], reference = res.ref, response, t_pickoff = uconvert(u"µs", res.t_pickoff),
                        shaping_time = uconvert(u"µs", res.shaping_time[i]), flat_top = uconvert(u"µs", res.flat_top[i]), ff = w.ff,
                        n_pre = res.n_pre, n_post = res.n_post, weights, output_area = uconvert(u"µs", res.output_area[i]),
                        objective = string(objective), ctc_rel_uncertainty, containment, min_objective = result_ft.min_objective,
                        min_fwhm = result_ft.min_fwhm, w90 = optimum.w90, asym = optimum.asym, fct = optimum.fct,
                        ct_spread = optimum.ct_spread,
                        families = [(weights = f.weights, ff = res.grid[f.i].ff, min_objective = f.result_ft.min_objective,
                                     min_fwhm = f.result_ft.min_fwhm,
                                     scan = (ff = uconvert.(u"µs", f.report_ft.table.ft),
                                             fwhm = mvalue.(uconvert.(u"keV", f.report_ft.table.fwhm)),
                                             w90 = mvalue.(uconvert.(u"keV", f.report_ft.table.w90)),
                                             status = string.(f.report_ft.table.status))) for f in fits])

                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part, ProcessStatus(1),
                                   :dplms, pars.objective, pars.shaping_time, pars.flat_top, pars.min_fwhm, pars.w90, "-", "-", "-"))

                # add results to dict
                result_rt_ft_dict[:dplms] = pars
                log_info_dict[:dplms] = log_info
                processed_dict[:dplms] = true

                # call garbage collector
                GC.gc()
            catch e
                e isa ProcessStepError || @error "Filter: dplms filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part, ProcessStatus(0),
                                   :dplms, fill("-", 7)..., "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[:dplms] = log_info
                processed_dict[:dplms] = false
            end
        end

        # generate detector result
        result_det = (result = result_rt_ft_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_flt_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        # a re-optimized filter replaces its previous entry so that no fields of an earlier method remain
        for filter_type in keys(result_rt_ft_dict)
            if haskey(pars_db_det, det) && haskey(pars_db_det[det], filter_type)
                @info "Detector $det, filter $filter_type: replacing the previous pars entry"
                delete!(pars_db_det[det], filter_type)
            end
        end
        pars_db_det = create_pars(pars_db_det, result_flt_det)
        write_pars(l200.par.ppars.fltopt[det], part, pars_db_det)
        write_validity(l200.par.ppars.fltopt[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_flt = parallel(det_filter_optimization, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                          process_name = "$period-p_process_filter_optimization_cal")
    @info "Finished filter optimization"

    @info "Write $period validity"
    validity_all = create_validity(result_flt)
    write_validity(l200.par.ppars.fltopt, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :p_process_filter_optimization_cal, result_flt)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, filter_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_flt))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :filter_optimization), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_flt))
end

register_processor!(p_process_filter_optimization_cal)
