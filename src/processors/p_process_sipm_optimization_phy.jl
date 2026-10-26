"""
    p_process_sipm_optimization_phy(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Optimize the energy filters of the SiPM channels (`spms`) per partition from `phy` data and
extract the trigger thresholds, for all partitions that contain `period`.

The method is the same as in `process_sipm_optimization_phy`, but the waveforms of all runs of
a detector's partition are used and the results are valid for the whole partition.

# Inputs
- `raw` tier of the `phy` filekeys listed in the runinfo for all runs of each detector's partition (excluding filekeys
  marked `unprocessable`), fields `waveform_bit_drop` and `timestamp`, limited to `n_evts`
  events per detector.
- `jlaux` tier fields `timestamp` and `aux_trig` of the pulser channel named by `dataprod_config(l200).qc(filekey).pulser.puls_detector`;
  waveforms within `puls_ts_window` of a pulser trigger are excluded.
- `dataprod_config(l200).sipm(filekey)`: the `default` section (DSP settings) merged with the
  per-detector section, and its `optimization` subsection using `p_default` merged with `p`
  (`n_evts`, `max_wvfs`, `e_filter` with `e_grid_wl`, `kwargs` and `threshold`).
- `l200.par.ppars.sipmopt[det, part]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.ppars.sipmopt[det, part]`: per filter, the window length `wl`, `gain`, `res_1pe` and
  the trigger thresholds `trig_threshold`, written for each detector as soon as it is finished;
  the validity of all partitions is written once at the end.
- Plots per detector and partition: per filter `wl_sweep_<filter>` and
  `wl_sweep_calibration_<filter>`, per threshold type `trigger_threshold_<threshold type>`. All of
  these plots are saved only at the debug plot level.
- If `error_plots` is on, a failed trigger threshold extraction saves `error_trigger_threshold_extraction_<filter>_<threshold type>`.
- Partition report `sipm_optimization_phy`.

# Keywords
- `reprocess`: discard the existing results and optimize all filters of all detectors again.
  Otherwise, filters that already have results are skipped and only missing ones are optimized.
- `timeout`: seconds allowed per detector and partition in `parallel` (0 = no limit).
- `only_first_period`: if `true`, skip a detector whose partition starts in an earlier period
  than `period`; it is processed together with that earlier period. `run_processing` sets this
  to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`.
"""
function p_process_sipm_optimization_phy(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false,
                                         timeout::Real = 0, only_first_period::Bool = true)
    @info "Process SiPM optimization for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :phy; system = :spms, only_processable = true, explode_partitions = true)
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Filter Type"), Symbol("Window length"), :Gain,
                         Symbol("Res. 1PE"), Symbol("Trig. Thres."), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    # function to process decay time
    function det_sipm_optimization(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.sipmopt), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.sipmopt[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.sipmopt), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekeys = reduce(vcat,
                          [filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (r.period, r.run, :phy)).keys))
                           for r in partinfo_det])

        filekey_det = first(getproperty(partinfo_det, :phy)).startkey
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        dsp_config = dataprod_config(l200).sipm(filekey_det)
        dsp_config_det = merge(dsp_config.default, get(dsp_config, det, PropDict()))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        optimization_config = dataprod_config(l200).sipm(filekey_det).optimization
        optimization_config_det = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded Optimization config: $(lstring(optimization_config_det))"

        qc_config = dataprod_config(l200).qc(filekey_det)
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        @debug "Loaded pulser config: $(lstring(pulser_config_det))"

        #  write out pulser events
        chinfo_puls = channelinfo(l200, filekey_det, Symbol(qc_config.pulser.puls_detector))
        @info "Loaded pulser channel info: $(chinfo_puls)"

        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector

        max_wvfs = optimization_config_det.max_wvfs

        e_filter = collect(keys(optimization_config_det.e_filter))

        result_wl_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in e_filter
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, filter_type, fill("-", 4)...,
                                   "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for filter_type in e_filter
                if haskey(pars_db_det[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), filter_type,
                                       pars_db_det[det][filter_type].wl, pars_db_det[det][filter_type].gain,
                                       pars_db_det[det][filter_type].res_1pe, pars_db_det[det][filter_type].trig_threshold.bsl_deriv.σ,
                                       "Already processed --> skipped."))
                    processed_dict[filter_type] = false
                    log_info_dict[filter_type] = log_info
                end
            end
        end

        # load data
        data_det = @process_step "data loader" begin
            data_det = read_ldata((:waveform_bit_drop, :timestamp), l200, DataTier(:raw), filekeys, det;
                                  n_evts = optimization_config_det.n_evts)
            @debug "Loading SiPM data from $(part)"
            if length(data_det) > max_wvfs
                @warn "SiPM events exceed $max_wvfs, keep only $max_wvfs events"
                sel = sort!(sample(eachindex(data_det), max_wvfs; replace = false))
                data_det = data_det[sel]
            end
            data_det
        end

        wvfs_det = @process_step "pulser tag" begin
            @debug "Get Pulser tags"
            data_pulser = read_ldata((:timestamp, :aux_trig), l200, DataTier(:jlaux), :phy, partinfo_det, det_puls)
            is_pulser = flag_coincidences(data_det.timestamp, data_pulser.timestamp[data_pulser.aux_trig],
                                          ts_window = pulser_config_det.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
            data_det[findall(.!is_pulser)].waveform_bit_drop[:]
        end

        @debug_progress "Detector: $det" for filter_type in e_filter
            if haskey(processed_dict, filter_type)
                continue
            end
            try
                @debug "Optimize $filter_type filter"

                optimization_config_flt = optimization_config_det.e_filter[filter_type]
                # unpack config
                optimization_config_flt.e_grid_wl = optimization_config_flt.e_grid_wl.start:optimization_config_flt.e_grid_wl.step:optimization_config_flt.e_grid_wl.stop

                # optimize WL
                trig_max_grid, thresholds_grid = @process_step "$filter_type DSP filter grid" begin
                    @debug "Generate $filter_type DSP filter grid"
                    dsp_grid = legend_dsp_function("dsp_$(filter_type)_sipm_optimization_compressed",
                                                   "sipm.optimization.e_filter.$filter_type")(1000, decode_data(wvfs_det), dsp_config_det,
                                                                                              optimization_config_flt)
                    dsp_grid.trig_max_grid, dsp_grid.thresholds_grid
                end

                result_wl, report_wl = @process_step "$filter_type window length optimization" begin
                    # fit SG window length
                    @debug "Sweep through window lengths to get optimal gain, resolution and position of 1pe peak"
                    fit_sipm_wl(trig_max_grid, optimization_config_flt.e_grid_wl, thresholds_grid;
                                NamedTuple(optimization_config_flt.kwargs)...)
                end

                @debug "Found optimal window length at $(result_wl.wl) for detector $det ($ch)"

                @debug_plot @process_step "$filter_type window length sweep plot" begin
                    p = LegendMakie.lplot(report_wl,
                                          title = get_plottitle(filekey_det, part, det, "Filter Optimization";
                                                                additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("wl_sweep_$(filter_type)"))
                end

                @debug_plot @process_step "$filter_type window length sweep calibration plot" begin
                    p = LegendMakie.lplot(report_wl.report_simple, cal = true,
                                          title = get_plottitle(filekey_det, part, det, "Opt. Calibration";
                                                                additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("wl_sweep_calibration_$(filter_type)"))
                end

                # thresholds for optimized window lengths
                dsp_thresholds = @process_step "$filter_type DSP thresholds" begin
                    @debug "DSP $filter_type thresholds"
                    legend_dsp_function("dsp_$(filter_type)_sipm_thresholds_compressed", "sipm.optimization.e_filter.$filter_type")(decode_data(wvfs_det[1:optimization_config_flt.threshold.n_wvfs]),
                                                                                                                                    mvalue(result_wl.wl),
                                                                                                                                    dsp_config_det)
                end

                # get trigger threshold
                result_trig = NamedTuple()
                for thres in collect(columnnames(dsp_thresholds))
                    plot_threshold_distribution() = begin
                        fig = Makie.Figure()
                        ax = Makie.Axis(fig[1, 1];
                                        title = get_plottitle(filekey_det, part, det, "Baseline distribution";
                                                              additional_type = string(thres)), xlabel = "Threshold", ylabel = "Counts")
                        Makie.stephist!(ax, filter(isfinite, ustrip.(getproperty(dsp_thresholds, thres))); bins = 100)
                        Makie.vlines!(ax,
                                      [ustrip(optimization_config_flt.threshold.min_cut),
                                       ustrip(optimization_config_flt.threshold.max_cut)]; color = :red, linestyle = :dash)
                        save_plot(fig, l200, part, filekey_det, det, Symbol("error_trigger_threshold_extraction_$(filter_type)_$(thres)"))
                    end
                    result_thres, report_thres = @process_step "$filter_type trigger threshold extraction for $thres" on_error = plot_threshold_distribution begin
                        @debug "Extract trigger threshold for $thres"
                        fit_sipm_threshold(getproperty(dsp_thresholds, thres), optimization_config_flt.threshold.min_cut,
                                           optimization_config_flt.threshold.max_cut; n_bins = optimization_config_flt.threshold.nbins,
                                           relative_cut = optimization_config_flt.threshold.rel_cut,
                                           fit_thresholds = optimization_config_flt.threshold.fit_thresholds, uncertainty = true)
                    end

                    @debug "Found 1-σ $thres trigger threshold at $(round(result_thres.σ, digits=2)) for detector $det ($ch)"

                    @debug_plot @process_step "$filter_type trigger threshold plot for $thres" begin
                        p = LegendMakie.lplot(report_thres,
                                              title = get_plottitle(filekey_det, part, det, "Baseline distribution";
                                                                    additional_type = string(thres)))
                        save_plot(p, l200, part, filekey_det, det, Symbol("trigger_threshold_$(thres)"))
                    end

                    result_trig = merge(result_trig, NamedTuple{(thres,)}([result_thres]))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), filter_type, result_wl.wl,
                                   result_wl.gain, result_wl.res_1pe, result_trig.bsl_deriv.σ, "-"))

                # add results to dict
                result_wl_dict[filter_type] = merge(result_wl, (trig_threshold = result_trig,))
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
            catch e
                e isa ProcessStepError || @error "Error in processing detector $det: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), filter_type, "-", "-", "-", "-",
                                   truncate_error(e)))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        result_det = (result = result_wl_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_sipm_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_sipm_det)
        write_pars(l200.par.ppars.sipmopt[det], part, pars_db_det)
        write_validity(l200.par.ppars.sipmopt[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_optimization = parallel(det_sipm_optimization, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                                        process_name = "$period-p_process_sipm_optimization_phy")

    @info "Finished SiPM partition optimization"

    @info "Write $period validity"
    validity_all = create_validity(result_sipm_optimization)
    write_validity(l200.par.ppars.sipmopt, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_sipm_optimization)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_optimization))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :sipm_optimization_phy), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_sipm_optimization))
end

register_processor!(p_process_sipm_optimization_phy)
