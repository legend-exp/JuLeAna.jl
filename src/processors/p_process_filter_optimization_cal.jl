"""
    p_process_filter_optimization_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Optimize the energy filter rise time and flat-top time per detector and `cal` partition for all partitions that contain `period`, using all analysis runs of the partition (HPGe detectors `geds`).

The method is the same as in `process_filter_optimization_cal`. The waveforms of the peaks are read from the `jlpks` tier of all runs of the partition (`n_evts` events per run, drawn randomly if `select_random` is set) and at most `max_wvfs` of them are used, drawn with an RNG seeded from the detector and the runs of the partition.

# Inputs
- `jlpks` tier of the `cal` runs of each partition, for each detector.
- `dataprod_config(l200).dsp(filekey)`, in particular `flt_optimization.p_default` and the per-detector entries `flt_optimization.p`, and the DSP config used for the filter grids.
- `l200.par.ppars.pz[det, part]` (decay times).
- Quality-cut evaluator loaded by `load_qc_evaluator(l200, filekey)`.
- `l200.par.ppars.fltopt[det, part]` (existing results, if present).

# Outputs
- `l200.par.ppars.fltopt[det, part]`: per filter type the objective, the optimal rise time and flat-top time, FWHM and W90 at the optimum and the legacy optimum, with validity entries for the partition; the validity of all partitions of the period is written to `l200.par.ppars.fltopt`.
- Per detector and filter type, the tables `fltopt_tables_<filter_type>.lh5` next to the plots, always written.
- Per detector and filter type, the plots `noise_sweep_<filter_type>`, `ft_scan_<filter_type>`, `rtft_landscape_<filter_type>`, the crosscheck figures (`ctc_*`, `peaks_*`, `crosscheck_*`, `residuals_*`) and `example_wvfs_<filter_type>`, saved only at the debug plot level.
- Partition report `:filter_optimization` (Main Log, Metadata, Results table with one row per detector, partition and filter type).

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
                         Symbol("Rise Time"), Symbol("Flat-Top Time"), :FWHM, :W90, Symbol("Legacy RT"), Symbol("Legacy FT"),
                         :Converged, Symbol("Crosscheck Warning"), :Error)}

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
        e_filter = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in e_filter
                log_info = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part,
                                   process_skipped, filter_type, fill("-", 9)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db_det[det], filter_type) && !(all(k -> haskey(pars_db_det[det][filter_type], k), (:objective, :w90, :ct_spread, :joint_search, :legacy)) && haskey(pars_db_det[det][filter_type].legacy, :rt) && haskey(pars_db_det[det][filter_type].legacy, :ft))
                    @info "Detector $det, filter $filter_type: pars from the previous method, re-optimizing"
                elseif haskey(pars_db_det[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    pars_flt = pars_db_det[det][filter_type]
                    log_info_dict[filter_type] = log_nt((det, detector_status(chinfo_det.usability),
                                                         detector_status(chinfo_det.psd_usability), part, ProcessStatus(1), filter_type,
                                                         pars_flt.objective, pars_flt.rt, pars_flt.ft, pars_flt.fwhm, pars_flt.w90,
                                                         pars_flt.legacy.rt, pars_flt.legacy.ft, get(pars_flt, :converged, "-"), "-",
                                                         "Already processed --> skipped."))
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict, validity = validity_det)
        end

        haskey(pars_tau, det) && haskey(pars_tau[det], :τ) || throw(ErrorException("Detector $det has no decay time τ in the pz pars of partition $part"))

        @debug "Loading peak data from $(part), select $(ifelse(select_random, "randomly ", ""))$n_evts events from each run"
        # the steps of loading, preparation and each filter are named in run_filter_optimization_channel
        results = run_filter_optimization_channel(peakname -> load_peak_waveforms(l200, partinfo_det, det, peakname, max_wvfs; n_evts,
                                                                                         select_random),
                                                  filter(!in(keys(processed_dict)), e_filter), dsp_config_det, optimization_config_det,
                                                  pars_tau[det].τ, f_evaluate_qc;
                                                  detector = det, f_title = (label, flt) -> get_plottitle(filekey_det, part, det, label;
                                                                                          additional_type = string(flt)),
                                                  f_save = (fig, name) -> @debug_plot(save_plot(fig, l200, part, filekey_det, det,
                                                                                                name)),
                                                  f_tablepath = flt -> replace(get_pltfilename(l200, part, filekey_det.setup,
                                                                                               filekey_det.category, det,
                                                                                               Symbol("fltopt_tables_$(flt)")),
                                                                               r"\.png$" => ".lh5"))

        for (filter_type, res) in results
            if res isa Exception
                log_info_dict[filter_type] = log_nt((det, detector_status(chinfo_det.usability),
                                                     detector_status(chinfo_det.psd_usability), part, ProcessStatus(0), filter_type,
                                                     fill("-", 9)..., truncate_error(res)))
                processed_dict[filter_type] = false
            else
                log_info_dict[filter_type] = log_nt((det, detector_status(chinfo_det.usability),
                                                     detector_status(chinfo_det.psd_usability), part, ProcessStatus(1), filter_type,
                                                     res.log.objective, res.pars.rt, res.pars.ft, res.pars.fwhm, res.pars.w90,
                                                     res.log.legacy_rt, res.log.legacy_ft, get(res.pars, :converged, "-"),
                                                     res.log.crosscheck_warning, "-"))
                result_rt_ft_dict[filter_type] = res.pars
                processed_dict[filter_type] = true
            end
        end

        # generate detector result
        result_det = (result = result_rt_ft_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_flt_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        # a re-optimized filter replaces its previous entry, so fields of an earlier method do not survive the merge
        for filter_type in keys(result_rt_ft_dict)
            if haskey(pars_db_det, det) && haskey(pars_db_det[det], filter_type)
                @info "Detector $det, filter $filter_type: replacing the previous pars entry"
                delete!(pars_db_det[det], filter_type)
            end
        end
        @process_step "fltopt pars writing" begin
            pars_db_det = create_pars(pars_db_det, result_flt_det)
            write_pars(l200.par.ppars.fltopt[det], part, pars_db_det)
            write_validity(l200.par.ppars.fltopt[det], filekey_det, part)
        end

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
