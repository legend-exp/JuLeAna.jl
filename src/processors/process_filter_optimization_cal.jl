"""
    process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Optimize the energy filter rise time and flat-top time for all processable HPGe detectors (`geds`) of the `cal` run.

For each filter type listed under `e_filter` in the optimization config, the rise time is chosen first from a sweep over the baseline noise (minimal ENC at a fixed flat-top time). The flat-top time is then chosen from a sweep over the full-energy-peak events as the one with the smallest `objective` (see `fit_fwhm_ft`). If `joint_search` is enabled, a search over rise time and flat-top time on the sampling lattice, starting from these two values, gives the optimum instead. Waveforms of the peak named by `peakname` are taken from the `jlpks` tier. Quality cuts (`qc` expression of the optimization config) are applied to the waveforms before the sweeps, and at most `max_wvfs` waveforms, selected with a seeded random number generator, are used. Filter types that already have results from this method are skipped unless `reprocess` is set; results lacking `objective`, `w90`, `ct_spread` or `joint_search` are optimized again.

# Inputs
- `jlpks` tier of the start `cal` filekey of the run, for each detector (peak waveforms named by `peakname`).
- `dataprod_config(l200).dsp(filekey)`, in particular the `flt_optimization` section (`default` and per-detector entries) and the DSP config used for the filter grids.
- `l200.par.rpars.pz[period, run]` (decay times).
- Quality-cut evaluator loaded by `load_qc_evaluator(l200, filekey)`.
- `l200.par.rpars.fltopt[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.fltopt[period, run]`: per detector and filter type the optimal rise time `rt` and flat-top time `ft` (the flat-top time the CUSP and ZAC filters apply), the `objective` with its value `min_objective`, the `fwhm`, `w90`, `asym`, `fct` and `ct_spread` at the optimum, `ctc_rel_uncertainty`, `joint_search`, `containment`, the noise sweep results `rt_enc` and `min_enc`, and `n_evals` and `converged` of the joint search if it ran, together with the validity entry for the run.
- Per detector and filter type, plots `noise_sweep_<filter_type>`, `fwhm_ft_scan_<filter_type>`, `rtft_landscape_<filter_type>` (joint search only), `ctc_<filter_type>`, `residuals_<filter_type>` and `example_wvfs_<filter_type>`, saved only at the debug plot level.
- Run report `:filter_optimization` (Main Log, Metadata, Results table with one row per detector and filter type).

# Keywords
- `reprocess`: redo all detectors and filter types, discarding existing results in `l200.par.rpars.fltopt[period, run]`. If `false`, only filter types without results are processed.
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                         timeout::Real = 0)
    @info "Optimize filter for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_filter_optimization_cal)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    pars_tau = get_values(PropDict(l200.par.rpars.pz[period, run]))
    @debug "Loaded decay times"

    optimization_config = dataprod_config(l200).dsp(filekey).flt_optimization
    @debug "Loaded optimization config: $(lstring(optimization_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.fltopt), string(period)))
    pars_db = PropDict(l200.par.rpars.fltopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :psd_usability, :Status, Symbol("Filter Type"), :Objective, Symbol("Rise Time"),
                         Symbol("Flat-Top Time"), :FWHM, :W90, :Converged, Symbol("FT Edge"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_filter_optimization(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        optimization_config_det = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        qc_string = optimization_config_det.qc
        peakname = Symbol(optimization_config_det.peakname)
        peak = optimization_config_det.peak
        window = (optimization_config_det.left_window_size, optimization_config_det.right_window_size)
        objective = Symbol(optimization_config_det.objective)
        joint_search = optimization_config_det.joint_search
        ctc_rel_uncertainty = optimization_config_det.ctc_rel_uncertainty
        containment = optimization_config_det.containment
        e_filter = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db[det], filter_type)
                    pars_flt = pars_db[det][filter_type]
                    if all(k -> haskey(pars_flt, k), (:objective, :w90, :ct_spread, :joint_search))
                        @debug "Filter $filter_type already processed, skip"
                        log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability),
                                           ProcessStatus(1), filter_type, pars_flt.objective, pars_flt.rt, pars_flt.ft, pars_flt.fwhm,
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
            return (processed = processed_dict, log = log_info_dict)
        end

        filename = l200.tier[:jlpks, filekey, det]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip detector $det"
            throw(ErrorException("File $(basename(filename)) does not exist"))
        end
        yield()

        if !haskey(pars_tau, det) || !haskey(pars_tau[det], :τ)
            throw(ErrorException("Detector $det has no decay time τ in the pz pars of $period-$run"))
        end

        max_wvfs = optimization_config_det.max_wvfs

        # load data
        wvfs_det_pre, wvfs_det_wdw, presum_rate = @process_step "$peakname data loading" begin
            @debug "Loading Tl208 FEP data from $(filename)"
            peak_data = read_ldata(peakname, l200, DataTier(:jlpks), filekey, det)
            wvfs_det_pre = peak_data.waveform_presummed
            wvfs_det_wdw = peak_data.waveform_windowed
            presum_rate = peak_data.presum_rate
            if length(wvfs_det_pre) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                rng = MersenneTwister(hash((string(det), string(filekey))))
                sel = sample(rng, eachindex(wvfs_det_pre), max_wvfs; replace = false, ordered = true)
                wvfs_det_pre = wvfs_det_pre[sel]
                wvfs_det_wdw = wvfs_det_wdw[sel]
                presum_rate = presum_rate[sel]
            end
            wvfs_det_pre, wvfs_det_wdw, presum_rate
        end
        yield()

        # get QC cuts
        wvfs_det_pre, wvfs_det_wdw, blmean_wdw = @process_step "QC cuts" begin
            @debug "Get QC cuts"
            dsp_qc = dsp_qc_flt_optimization_compressed(wvfs_det_pre, dsp_config_det, pars_tau[det].τ, f_evaluate_qc)
            qc = ljl_propfunc(qc_string).(dsp_qc)
            if count(qc) == 0
                throw(ErrorException("No event passes the QC selection $qc_string"))
            end
            blmean_wdw = dsp_qc.blmean ./ presum_rate
            wvfs_det_pre = wvfs_det_pre[findall(qc)]
            wvfs_det_wdw = wvfs_det_wdw[findall(qc)]
            blmean_wdw = blmean_wdw[findall(qc)]
            @debug "Survival Fraction: $(round(count(qc) / length(qc) * 100, digits=2))%"
            wvfs_det_pre, wvfs_det_wdw, blmean_wdw
        end

        # get qdrift
        qdrift = @process_step "QDrift" begin
            @debug "Get QDrift"
            dsp_qdrift_flt_optimization(wvfs_det_wdw, blmean_wdw, dsp_config_det, pars_tau[det].τ)
        end

        # prepare the waveforms once for all filter evaluations
        prep = @process_step "FEP preparation" begin
            @debug "Prepare FEP waveforms"
            dsp_flt_optimization_prepare(wvfs_det_pre, dsp_config_det, pars_tau[det].τ)
        end

        @debug_progress "Computing $det ..." for filter_type in e_filter
            if haskey(processed_dict, filter_type)
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
                                          title = get_plottitle(filekey, det, "Noise Sweep"; additional_type = string(filter_type)))
                    save_plot(p, l200, filekey, det, Symbol("noise_sweep_$(filter_type)"))
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
                                          title = get_plottitle(filekey, det, "FEP FT Scan"; additional_type = string(filter_type)),
                                          figsize = (600, 900))
                    save_plot(p, l200, filekey, det, Symbol("fwhm_ft_scan_$(filter_type)"))
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
                                              title = get_plottitle(filekey, det, "RT-FT Search"; additional_type = string(filter_type)),
                                              figsize = (700, 550))
                        save_plot(p, l200, filekey, det, Symbol("rtft_landscape_$(filter_type)"))
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
                                              title = get_plottitle(filekey, det, "CTC Optimum"; additional_type = string(filter_type)))
                        save_plot(p, l200, filekey, det, Symbol("ctc_$(filter_type)"))
                    end
                    p = LegendMakie.lplot((; residual, qdrift = qdrift_sel, slow_mean); figsize = (900, 450),
                                          title = get_plottitle(filekey, det, "FEP Residuals"; additional_type = string(filter_type)))
                    save_plot(p, l200, filekey, det, Symbol("residuals_$(filter_type)"))

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
                                          title = get_plottitle(filekey, det, "Example Waveforms"; additional_type = string(filter_type)))
                    save_plot(p, l200, filekey, det, Symbol("example_wvfs_$(filter_type)"))
                end

                pars = (rt = rt_opt, ft = ft_opt, min_enc = result_rt.min_enc, rt_enc = result_rt.rt, objective = string(objective),
                        ctc_rel_uncertainty, joint_search, containment, min_objective = optimum.min_objective, fwhm = optimum.fwhm,
                        w90 = optimum.w90, asym = optimum.asym, fct = optimum.fct, ct_spread = optimum.ct_spread)
                if joint_search
                    pars = merge(pars, (n_evals = result_rtft.n_evals, converged = result_rtft.converged))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), ProcessStatus(1),
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
                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), ProcessStatus(0),
                                   filter_type, fill("-", 7)..., "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end
        # return results
        return (result = result_rt_ft_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_flt = parallel(det_filter_optimization, chinfo, log_nt; timeout = timeout, retry = false,
                          process_name = "$period-$run-process_filter_optimization_cal")

    @info "Finished filter optimization"

    # a re-optimized filter replaces its previous entry so that no fields of an earlier method remain
    for (chinfo_det, res_det) in result_flt
        if haskey(res_det, :result)
            for filter_type in keys(res_det.result)
                if haskey(pars_db, chinfo_det.detector) && haskey(pars_db[chinfo_det.detector], filter_type)
                    @info "Detector $(chinfo_det.detector), filter $filter_type: replacing the previous pars entry"
                    delete!(pars_db[chinfo_det.detector], filter_type)
                end
            end
        end
    end
    pars_db = create_pars(pars_db, result_flt)
    write_pars(l200.par.rpars.fltopt[period], run, pars_db)
    write_validity(l200.par.rpars.fltopt, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_filter_optimization_cal, result_flt)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, filter_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_flt))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :filter_optimization), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_filter_optimization_cal)
