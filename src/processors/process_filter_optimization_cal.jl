"""
    process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Optimize the energy filter rise time and flat-top time for all processable HPGe detectors (`geds`) of the `cal` run.

For each filter type listed under `e_filter` in the optimization config, `optimize_channel_filter` chooses the rise time from a baseline noise sweep and the flat-top time from a sweep over full-energy-peak events. With `joint_search` enabled, a lattice search over both times gives the optimum of the configured `objective`. The FEP is evaluated at the optimum with a peak fit and the residuals against qdrift. Waveforms come from the `jlpks` tier and are limited to `max_wvfs` events per peak. An event is kept if, for every `column => k` of `qc_mad` (e.g. `blsigma`, `blslope`), its value lies within `k` normalized MADs of the median of the finite values, and the `qc` expression holds on the QC table of `dsp_qc_flt_optimization_compressed` extended by `qdrift`. Filter types that already have results from this method are skipped unless `reprocess` is set; results of an older method are optimized again.

# Inputs
- `jlpks` tier of the start `cal` filekey of the run, for each detector (peak waveforms named by `peakname`).
- `dataprod_config(l200).dsp(filekey)`, in particular the `flt_optimization` section (`default` and per-detector entries) and the DSP config used for the filter grids.
- `l200.par.rpars.pz[period, run]` (decay times).
- Quality-cut evaluator loaded by `load_qc_evaluator(l200, filekey)`.
- `l200.par.rpars.fltopt[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.fltopt[period, run]`: per detector and filter type the objective, the optimal rise time and flat-top time, FWHM and W90 at the optimum, and the validity entry for the run.
- Per detector and filter type, the tables `fltopt_tables_<filter_type>.lh5` next to the plots.
- Per detector and filter type, the plots `noise_sweep_*`, `ft_scan_*`, `rtft_landscape_*`, `ctc_*`, `residuals_*` and `example_wvfs_*`, saved at the debug plot level.
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

    log_nt = NamedTuple{(:Detector, :usability, :psd_usability, :Status, Symbol("Filter Type"), :Objective, Symbol("Rise Time"),
                         Symbol("Flat-Top Time"), :FWHM, :W90, :Converged,
                         Symbol("FT Edge"), :Error)}

    flush(stdout)

    function det_filter_optimization(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        optimization_config_det = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        e_filter = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                haskey(pars_db[det], filter_type) || continue
                pars_flt = pars_db[det][filter_type]
                is_current = all(k -> haskey(pars_flt, k), (:objective, :w90, :ct_spread, :joint_search))
                if !is_current
                    @info "Detector $det, filter $filter_type: pars from the previous method, re-optimizing"
                else
                    @debug "Filter $filter_type already processed, skip"
                    log_info_dict[filter_type] = log_nt((det, detector_status(chinfo_det.usability),
                                                         detector_status(chinfo_det.psd_usability), ProcessStatus(1), filter_type,
                                                         pars_flt.objective, pars_flt.rt, pars_flt.ft, pars_flt.fwhm, pars_flt.w90,
                                                         get(pars_flt, :converged, "-"), "-",
                                                         "Already processed --> skipped."))
                    processed_dict[filter_type] = false
                end
            end
        end

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

        haskey(pars_tau, det) && haskey(pars_tau[det], :τ) || throw(ErrorException("Detector $det has no decay time τ in the pz pars of $period-$run"))

        results = run_filter_optimization_channel(peakname -> load_peak_waveforms(l200, filekey, det, peakname,
                                                                                  optimization_config_det.max_wvfs),
                                                  filter(!in(keys(processed_dict)), e_filter), dsp_config_det, optimization_config_det,
                                                  pars_tau[det].τ, f_evaluate_qc;
                                                  detector = det, f_title = (label, flt) -> get_plottitle(filekey, det, label;
                                                                                          additional_type = string(flt)),
                                                  f_save = (fig, name) -> @debug_plot(save_plot(fig, l200, filekey, det, name)),
                                                  f_tablepath = flt -> replace(get_pltfilename(l200, filekey, det,
                                                                                               Symbol("fltopt_tables_$(flt)")),
                                                                               r"\.png$" => ".lh5"))

        for (filter_type, res) in results
            if res isa Exception
                log_info_dict[filter_type] = log_nt((det, detector_status(chinfo_det.usability),
                                                     detector_status(chinfo_det.psd_usability), ProcessStatus(0), filter_type,
                                                     fill("-", 7)..., truncate_error(res)))
                processed_dict[filter_type] = false
            else
                log_info_dict[filter_type] = log_nt((det, detector_status(chinfo_det.usability),
                                                     detector_status(chinfo_det.psd_usability), ProcessStatus(1), filter_type,
                                                     res.log.objective, res.pars.rt, res.pars.ft, res.pars.fwhm, res.pars.w90,
                                                     get(res.pars, :converged, "-"),
                                                     res.log.ft_edge, "-"))
                result_rt_ft_dict[filter_type] = res.pars
                processed_dict[filter_type] = true
            end
        end

        return (result = result_rt_ft_dict, log = log_info_dict, processed = processed_dict)
    end

    start_time = now()

    result_flt = parallel(det_filter_optimization, chinfo, log_nt; timeout = timeout, retry = false,
                          process_name = "$period-$run-process_filter_optimization_cal")

    @info "Finished filter optimization"

    # A re-optimized filter replaces its previous entry so that no fields of an earlier method survive the merge.
    for (chinfo_det, res_det) in result_flt
        haskey(res_det, :result) || continue
        for filter_type in keys(res_det.result)
            if haskey(pars_db, chinfo_det.detector) && haskey(pars_db[chinfo_det.detector], filter_type)
                @info "Detector $(chinfo_det.detector), filter $filter_type: replacing the previous pars entry"
                delete!(pars_db[chinfo_det.detector], filter_type)
            end
        end
    end
    @process_step "fltopt pars writing" begin
        pars_db = create_pars(pars_db, result_flt)
        write_pars(l200.par.rpars.fltopt[period], run, pars_db)
        write_validity(l200.par.rpars.fltopt, filekey, (period, run))
    end
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

    return flush(stdout)
end

register_processor!(process_filter_optimization_cal)
