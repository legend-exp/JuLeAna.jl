"""
    process_sipm_optimization_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Optimize the energy filters of the SiPM channels (`spms`) of one run from `phy` data and
extract the trigger thresholds.

For each processable SiPM and each filter listed under `e_filter` in the optimization
configuration, the DSP is run on a grid of filter window lengths. The window length with the
best one photoelectron peak is selected (`fit_sipm_wl`), and the gain and the one photoelectron
resolution are determined there. At the selected window length, the baseline distributions of
the threshold waveforms are fitted (`fit_sipm_threshold`) and their sigma is taken as the
trigger threshold.

# Inputs
- `raw` tier of the `phy` filekeys of the run listed in the runinfo (excluding filekeys marked `unprocessable`),
  fields `waveform_bit_drop` and `timestamp`.
- `jlaux` tier fields `timestamp` and `aux_trig` of the pulser channel named by
  `dataprod_config(l200).qc(filekey).pulser.puls_detector`; waveforms within `puls_ts_window`
  of a pulser trigger are excluded.
- `dataprod_config(l200).sipm(filekey)`: the `default` section (DSP settings) merged with the
  per-detector section, and its `optimization` subsection (`max_wvfs`, `e_filter` with
  `e_grid_wl`, `kwargs` and `threshold`).
- `l200.par.rpars.sipmopt[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.sipmopt[period, run]`: per detector and filter, the window length `wl`, `gain`,
  `res_1pe` and the trigger thresholds `trig_threshold`; the validity entry is written for
  `(period, run)`.
- Plots per detector and filter: `wl_sweep_<filter>`, `wl_sweep_calibration_<filter>`, and per
  threshold type `trigger_threshold_<threshold type>`, all saved only at the debug plot level.
- If `error_plots` is on, a failed trigger threshold extraction saves `error_trigger_threshold_extraction_<filter>_<threshold type>`.
- Run report `sipm_optimization_phy`.

# Keywords
- `reprocess`: discard the existing results of the run and optimize all filters of all
  detectors again. Otherwise, filters that already have results are skipped and only missing
  ones are optimized.
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_sipm_optimization_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                       timeout::Real = 0)
    @info "Process SiPM optimization for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :phy)).keys))

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :spms) |> detector_filter(processing_config, :process_sipm_optimization_phy)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config = dataprod_config(l200).sipm(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config))"

    optimization_config = dataprod_config(l200).sipm(filekey).optimization
    @debug "Loaded Optimization config: $(lstring(optimization_config))"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.sipmopt), string(period)))
    pars_db = PropDict(l200.par.rpars.sipmopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Filter Type"), Symbol("Window length"), :Gain, Symbol("Res. 1PE"),
                         Symbol("Trig. Thres."), :Error)}
    # get worker pool

    # flush stdout
    flush(stdout)

    # get pulser detector information
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    @info "Loaded pulser channel info: $(chinfo_puls)"

    # function to process filter optimization
    function det_sipm_optimization(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        det_puls = chinfo_puls.detector

        @debug "Processing detector $det ($ch)"

        dsp_config_det = merge(dsp_config.default, get(dsp_config, det, PropDict()))

        optimization_config_det = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        e_filter = collect(keys(optimization_config_det.e_filter))

        max_wvfs = optimization_config_det.max_wvfs

        result_wl_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), filter_type,
                                       pars_db[det][filter_type].wl, pars_db[det][filter_type].gain, pars_db[det][filter_type].res_1pe,
                                       pars_db[det][filter_type].trig_threshold.bsl_deriv.σ, "Already processed --> skipped."))
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

        # load data
        data_det = @process_step "data loader" begin
            data_det = read_ldata((:waveform_bit_drop, :timestamp), l200, DataTier(:raw), filekeys, det)
            @debug "Loading SiPM data from $(period)-$(run)"
            if length(data_det) > max_wvfs
                @warn "SiPM events exceed $max_wvfs, keep only $max_wvfs events"
                sel = sort!(sample(eachindex(data_det), max_wvfs; replace = false))
                data_det = data_det[sel]
            end
            data_det
        end

        wvfs_det = @process_step "pulser tag" begin
            @debug "Get Pulser tags"
            data_pulser = read_ldata((:timestamp, :aux_trig), l200, DataTier(:jlaux), :phy, period, run, det_puls)
            is_pulser = flag_coincidences(data_det.timestamp, data_pulser.timestamp[data_pulser.aux_trig],
                                          ts_window = pulser_config_det.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
            data_det[findall(.!is_pulser)].waveform_bit_drop[:]
        end

        @debug_progress "Computing $det ..." for filter_type in e_filter
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
                                                   "sipm.optimization.e_filter.$filter_type")(10000, decode_data(wvfs_det), dsp_config_det,
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
                                          title = get_plottitle(filekey, det, "Filter Optimization"; additional_type = string(filter_type)))
                    save_plot(p, l200, filekey, det, Symbol("wl_sweep_$(filter_type)"))
                end

                @debug_plot @process_step "$filter_type window length sweep calibration plot" begin
                    p = LegendMakie.lplot(report_wl.report_simple, cal = true,
                                          title = get_plottitle(filekey, det, "Opt. Calibration"; additional_type = string(filter_type)))
                    save_plot(p, l200, filekey, det, Symbol("wl_sweep_calibration_$(filter_type)"))
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
                                        title = get_plottitle(filekey, det, "Baseline distribution"; additional_type = string(thres)),
                                        xlabel = "Threshold", ylabel = "Counts")
                        Makie.stephist!(ax, filter(isfinite, ustrip.(getproperty(dsp_thresholds, thres))); bins = 100)
                        Makie.vlines!(ax,
                                      [ustrip(optimization_config_flt.threshold.min_cut),
                                       ustrip(optimization_config_flt.threshold.max_cut)]; color = :red, linestyle = :dash)
                        save_plot(fig, l200, filekey, det, Symbol("error_trigger_threshold_extraction_$(filter_type)_$(thres)"))
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
                                              title = get_plottitle(filekey, det, "Baseline distribution"; additional_type = string(thres)))
                        save_plot(p, l200, filekey, det, Symbol("trigger_threshold_$(thres)"))
                    end

                    result_trig = merge(result_trig, NamedTuple{(thres,)}([result_thres]))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), filter_type, result_wl.wl, result_wl.gain,
                                   result_wl.res_1pe, result_trig.bsl_deriv.σ, "-"))

                # add results to dict
                result_wl_dict[filter_type] = merge(result_wl, (trig_threshold = result_trig,))
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                yield()
            catch e
                e isa ProcessStepError || @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), filter_type, "-", "-", "-", "-",
                                   "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        return (result = result_wl_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_optimization = parallel(det_sipm_optimization, chinfo, log_nt; timeout = timeout, retry = false,
                                        process_name = "$period-$run-process_sipm_optimization_phy")
    @info "Finished SiPM optimization extraction"

    pars_db = create_pars(pars_db, result_sipm_optimization)
    write_pars(l200.par.rpars.sipmopt[period], run, pars_db)
    write_validity(l200.par.rpars.sipmopt, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_sipm_optimization_phy,
                                                                result_sipm_optimization)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_optimization))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :sipm_optimization_phy), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_sipm_optimization_phy)
