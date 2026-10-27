"""
    process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Optimize the energy filter rise time and flat-top time for all processable HPGe detectors (`geds`) of the `cal` run.

For each filter type listed under `e_filter` in the optimization config, the rise time is chosen first from a sweep over the baseline noise (minimal ENC at a fixed flat-top time). The flat-top time is then chosen from a sweep over the full-energy-peak events as the one with the smallest FWHM. Waveforms of the peak named by `peakname` are taken from the `jlpks` tier. Quality cuts (`qc` expression of the optimization config) are applied to the waveforms before the sweeps, and at most `max_wvfs` waveforms are used. Filter types that already have results are skipped unless `reprocess` is set.

# Inputs
- `jlpks` tier of the start `cal` filekey of the run, for each detector (peak waveforms named by `peakname`).
- `dataprod_config(l200).dsp(filekey)`, in particular the `flt_optimization` section (`default` and per-detector entries) and the DSP config used for the filter grids.
- `l200.par.rpars.pz[period, run]` (decay times).
- Quality-cut evaluator loaded by `load_qc_evaluator(l200, filekey)`.
- `l200.par.rpars.fltopt[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.fltopt[period, run]`: per detector and filter type the optimal rise time, flat-top time and minimal FWHM, together with the validity entry for the run.
- Per detector and filter type, plots `noise_sweep_<filter_type>` and `fwhm_ft_scan_<filter_type>`, saved only at the debug plot level.
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

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    pars_tau = get_values(l200.par.rpars.pz[period, run])
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
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Filter Type"), Symbol("Rise Time"), Symbol("Flat-Top Time"),
                         Symbol("Min. FWHM"), :Error)}

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
        e_filter = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), filter_type,
                                       pars_db[det][filter_type].rt, pars_db[det][filter_type].ft, pars_db[det][filter_type].min_fwhm,
                                       "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
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

        # get qdrift
        qdrift = @process_step "QDrift" begin
            @debug "Get QDrift"
            dsp_qdrift_flt_optimization(wvfs_det_wdw, blmean_wdw, dsp_config_det, pars_tau[det].τ)
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
                                          title = get_plottitle(filekey, det, "Noise Sweep"; additional_type = string(filter_type)))
                    save_plot(p, l200, filekey, det, Symbol("noise_sweep_$(filter_type)"))
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
                                          title = get_plottitle(filekey, det, "FEP FT Scan"; additional_type = string(filter_type)))
                    save_plot(p, l200, filekey, det, Symbol("fwhm_ft_scan_$(filter_type)"))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), filter_type, result_rt.rt, result_ft.ft,
                                   result_ft.min_fwhm, "-"))

                # add results to dict
                result_rt_ft_dict[filter_type] = merge(result_rt, result_ft)
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                yield()
            catch e
                e isa ProcessStepError || @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), filter_type, "-", "-", "-",
                                   "$(truncate_error(e))"))
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

    pars_db = create_pars(pars_db, result_flt)
    write_pars(l200.par.rpars.fltopt[period], run, pars_db)
    write_validity(l200.par.rpars.fltopt, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_flt)]))
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
