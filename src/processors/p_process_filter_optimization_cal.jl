"""
    p_process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Optimize the energy filter rise time and flat-top time per detector and `cal` partition for all partitions that contain `period`, using all analysis runs of the partition (HPGe detectors `geds`).

The method is the same as in `process_filter_optimization_cal`: for each filter type listed under `e_filter`, the rise time is chosen from a baseline noise sweep and the flat-top time from a sweep over full-energy-peak events. The waveforms of the peak named by `peakname` are read from the `jlpks` tier of all runs of the partition (`n_evts` events per run, drawn randomly if `select_random` is set) and at most `max_wvfs` of them are used after the quality cuts (`qc` expression).

If `e_filter` lists `dplms`, a DPLMS filter is synthesized on the same waveforms for every flat-top widening `ff` of LegendDSP's `dplms_default_grid`, and the widening with the smallest FEP FWHM is selected with the same fit as the flat-top time of the other filters.

# Inputs
- `jlpks` tier of the `cal` runs of each partition, for each detector.
- `dataprod_config(l200).dsp(filekey)`, in particular `flt_optimization.p_default` and the per-detector entries `flt_optimization.p`, and the DSP config used for the filter grids.
- `l200.par.ppars.pz[det, part]` (decay times).
- Quality-cut evaluator loaded by `load_qc_evaluator(l200, filekey)`.
- `l200.par.ppars.fltopt[det, part]` (existing results, if present).

# Outputs
- `l200.par.ppars.fltopt[det, part]`: per filter type the optimal rise time, flat-top time and minimal FWHM, with validity entries for the partition; the validity of all partitions of the period is written to `l200.par.ppars.fltopt`. For `dplms`: the filter `coefficients`, the read-out time `t_pickoff` after `t50`, `shaping_time`, `flat_top`, `ff`, `n_pre`, `n_post`, the synthesis `weights` and `min_fwhm` of the selected grid point.
- Per detector, partition and filter type, plots `noise_sweep_<filter_type>` and `fwhm_ft_scan_<filter_type>`, for `dplms` `fwhm_ft_scan_dplms` and `dplms_filter`, saved only at the debug plot level.
- Partition report `:filter_optimization` (Main Log, Metadata, Results table with one row per detector, partition and filter type; the DPLMS row shows shaping time and flat top in the rise-time and flat-top columns).

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
    log_nt = NamedTuple{(:Detector, :usability, :psd_usability, :Partition, :Status, Symbol("Filter Type"), Symbol("Rise Time"),
                         Symbol("Flat-Top Time"),
                         Symbol("Min. FWHM"), :Error)}

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

        pars_tau = get_values(l200.par.ppars.pz[det, part])
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
        e_filter = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in e_filter
                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                   process_skipped, filter_type, fill("-", 3)...,
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
                    @debug "Filter $filter_type already processed, skip"
                    pars_flt = pars_db_det[det][filter_type]
                    rt, ft = filter_type == :dplms ? (pars_flt.shaping_time, pars_flt.flat_top) : (pars_flt.rt, pars_flt.ft)
                    log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                       ProcessStatus(1), filter_type, rt, ft, pars_flt.min_fwhm, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict, validity = validity_det)
        end

        # load data
        wvfs_det_pre, wvfs_det_wdw, presum_rate = @process_step "$peakname data loading" begin
            @debug "Loading $peakname data from $(part), select $(ifelse(select_random, "randomly ", ""))$n_evts events from each run"
            # The events of each run are selected by timestamp before reading, so only the
            # selected waveforms are loaded from disk.
            f_timestamp = ljl_propfunc("$peakname.timestamp")
            peak_data = fast_flatten(map(partinfo_det) do r
                                         ts = read_ldata(f_timestamp, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det)
                                         n_sel = n_evts == -1 ? length(ts) : min(n_evts, length(ts))
                                         ts_sel = select_random ? sample(ts, n_sel; replace = false, ordered = true) :
                                                  ts[begin:(begin + n_sel - 1)]
                                         read_ldata(peakname, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det;
                                                    filterby = @pf $timestamp in ts_sel)
                                     end)
            wvfs_det_pre = peak_data.waveform_presummed
            wvfs_det_wdw = peak_data.waveform_windowed
            presum_rate = peak_data.presum_rate
            if length(wvfs_det_pre) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                sel = sample(eachindex(wvfs_det_pre), max_wvfs; replace = false, ordered = true)
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
            blmean_wdw = dsp_qc.blmean ./ presum_rate
            wvfs_det_pre = wvfs_det_pre[findall(qc)]
            wvfs_det_wdw = wvfs_det_wdw[findall(qc)]
            blmean_wdw = blmean_wdw[findall(qc)]
            @debug "Survival Fraction: $(round(count(qc) / length(qc) * 100, digits=2))%"
            wvfs_det_pre, wvfs_det_wdw, blmean_wdw
        end

        # get qdrift; events without a finite qdrift are removed like the QC cuts
        wvfs_det_pre, qdrift = @process_step "QDrift" begin
            @debug "Get QDrift"
            qdrift = dsp_qdrift_flt_optimization(wvfs_det_wdw, blmean_wdw, dsp_config_det, pars_tau[det].τ)
            ok = findall(isfinite, qdrift)
            @debug "Remove $(length(qdrift) - length(ok)) events with non-finite QDrift"
            wvfs_det_pre[ok], qdrift[ok]
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

                # optimize RT
                enc_grid = @process_step "$filter_type RT DSP for FEP" begin
                    @debug "Generate $filter_type ENC filter grid"
                    legend_dsp_function("dsp_$(filter_type)_rt_optimization", "dsp.flt_optimization.e_filter.$filter_type")(wvfs_det_pre,
                                                                                                                            dsp_config_det,
                                                                                                                            pars_tau[det].τ;
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
                                          title = get_plottitle(filekey_det, part, det, "Noise Sweep";
                                                                additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("noise_sweep_$(filter_type)"))
                end

                # optimize FT
                yield()
                e_grid = @process_step "$filter_type FT DSP for FEP" begin
                    @debug "Generate $filter_type FT energy grid"
                    legend_dsp_function("dsp_$(filter_type)_ft_optimization", "dsp.flt_optimization.e_filter.$filter_type")(wvfs_det_pre,
                                                                                                                            dsp_config_det,
                                                                                                                            pars_tau[det].τ,
                                                                                                                            mvalue(result_rt.rt))
                end
                yield()
                result_ft, report_ft = @process_step "$filter_type flat-top time extraction" begin
                    fit_fwhm_ft(e_grid, e_grid_ft, qdrift, result_rt.rt, optimization_config_flt.min_e_fep,
                                optimization_config_flt.max_e_fep, optimization_config_flt.rel_cut_fit_e_fep,
                                optimization_config_det.apply_ctc; n_bins = optimization_config_flt.nbins_e_fep,
                                peak = optimization_config_det.peak,
                                window = (optimization_config_det.left_window_size, optimization_config_det.right_window_size),
                                ft_fwhm_tol = optimization_config_det.ft_fwhm_tol)
                end
                @debug "Found optimal $filter_type FT at $(result_ft.ft) with FWHM $(round(u"keV", result_ft.min_fwhm, digits=2))"
                yield()

                @debug_plot begin
                    p = LegendMakie.lplot(report_ft,
                                          title = get_plottitle(filekey_det, part, det, "FEP FT Scan";
                                                                additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("fwhm_ft_scan_$(filter_type)"))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                   ProcessStatus(1), filter_type, result_rt.rt,
                                   result_ft.ft, result_ft.min_fwhm, "-"))

                # add results to dict
                result_rt_ft_dict[filter_type] = merge(result_rt, result_ft)
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                yield()
            catch e
                e isa ProcessStepError || @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                   ProcessStatus(0), filter_type, "-", "-", "-",
                                   "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        if :dplms in e_filter && !haskey(processed_dict, :dplms)
            try
                @debug "Synthesize DPLMS filter"
                optimization_config_flt = optimization_config_det.e_filter.dplms
                res = @process_step "dplms filter synthesis for FEP" begin
                    dsp_dplms_optimization(wvfs_det_pre, dsp_config_det, pars_tau[det].τ, qdrift)
                end
                yield()
                Δt = step(res.superpulse.time)
                ffs = [w.ff for w in res.grid]
                e_grid_ff = range(first(ffs) * Δt; step = (length(ffs) > 1 ? ffs[2] - ffs[1] : 1) * Δt, length = length(ffs))
                e_grid_ff ≈ ffs .* Δt || throw(ArgumentError("DPLMS flat-top widenings $ffs are not equally spaced"))
                result_ft, report_ft = @process_step "dplms flat-top widening extraction" begin
                    fit_fwhm_ft(res.e_grid, e_grid_ff, qdrift, 0.0u"µs", optimization_config_flt.min_e_fep,
                                optimization_config_flt.max_e_fep, optimization_config_flt.rel_cut_fit_e_fep,
                                optimization_config_det.apply_ctc; n_bins = optimization_config_flt.nbins_e_fep,
                                peak = optimization_config_det.peak,
                                window = (optimization_config_det.left_window_size, optimization_config_det.right_window_size),
                                ft_fwhm_tol = optimization_config_det.ft_fwhm_tol)
                end
                i = only(findall(≈(mvalue(result_ft.ft)), e_grid_ff))
                w = res.grid[i]
                @debug "Selected DPLMS ff = $(w.ff) samples with FWHM $(round(u"keV", result_ft.min_fwhm, digits=2))"
                @debug_plot begin
                    p = LegendMakie.lplot(report_ft,
                                          title = get_plottitle(filekey_det, part, det, "FEP Flat-Top Widening Scan";
                                                                additional_type = "dplms"))
                    save_plot(p, l200, part, filekey_det, det, :fwhm_ft_scan_dplms)
                    p = LegendMakie.lplot((; res.coeffs, res.grid, res.superpulse, res.t_pickoff, res.n_pre, res.n_post); idxs = [i],
                                          title = get_plottitle(filekey_det, part, det, "DPLMS Filter"))
                    save_plot(p, l200, part, filekey_det, det, :dplms_filter)
                end

                result_rt_ft_dict[:dplms] = (coefficients = res.coeffs[i], t_pickoff = uconvert(u"µs", res.t_pickoff),
                                             shaping_time = uconvert(u"µs", res.shaping_time[i]), flat_top = uconvert(u"µs", res.flat_top[i]),
                                             ff = w.ff, n_pre = res.n_pre, n_post = res.n_post,
                                             weights = (nm = w.nm, za = w.za, ft = w.ft, ct = w.ct), min_fwhm = result_ft.min_fwhm)
                log_info_dict[:dplms] = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                                ProcessStatus(1), :dplms, result_rt_ft_dict[:dplms].shaping_time,
                                                result_rt_ft_dict[:dplms].flat_top, result_ft.min_fwhm, "-"))
                processed_dict[:dplms] = true
                yield()
            catch e
                e isa ProcessStepError || @error "Filter: dplms filter optimization: $(truncate_error(e))"
                log_info_dict[:dplms] = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                                ProcessStatus(0), :dplms, "-", "-", "-", "$(truncate_error(e))"))
                processed_dict[:dplms] = false
            end
        end

        # generate detector result
        result_det = (result = result_rt_ft_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_flt_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

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
