"""
    process_sipm_calibration_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Calibrate the SiPM channels (`spms`) of one run from `phy` data.

For each processable SiPM and each energy type listed in the calibration configuration, the
pulser-tagged events and the events failing the energy-type `qc` cut are removed, a simple
calibration of the amplitude spectrum is made, the photoelectron peaks are fitted, and a
polynomial calibration curve is fitted to the peak positions. Control plots are saved for each
step.

# Inputs
- `dsp` tier (`DataTier(:jldsp)`) of the `phy` data of the run, per SiPM.
- `jlaux` tier fields `timestamp` and `aux_trig` of the pulser channel named by `dataprod_config(l200).qc(filekey).pulser.puls_detector`;
  events within `puls_ts_window` of a pulser trigger are excluded.
- `dataprod_config(l200).sipm(filekey).calibration`: the `default` section merged with the
  per-detector section. It sets `energy_types` (each with `qc`, `simple.kwargs`, `fit.min_pe`,
  `fit.max_pe`, `fit.kwargs`) and `pol_order`.
- `l200.par.rpars.sipmcal[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.sipmcal[period, run]`: per detector and energy type, the simple calibration
  constants, the noise thresholds, the peak fit result (`fit`) and the calibration curve (`cal`);
  the validity entry is written for `(period, run)`.
- Plots per detector and energy type: `pe_uncalibrated_<energy type>`,
  `sipm_simple_calibration_<energy type>`, `sipm_peak_fits_<energy type>`,
  `sipm_calibration_curve_<energy type>`. `pe_uncalibrated_<energy type>` and `sipm_simple_calibration_<energy type>` are saved only at the debug plot level.
- If `error_plots` is on, a failed simple calibration saves `error_simple_calibration_<energy type>`.
- Run report `sipm_calibration_phy`.

# Keywords
- `reprocess`: discard the existing results of the run and calibrate all energy types of all
  detectors again. Otherwise, energy types that already have results are skipped and only
  missing ones are calibrated.
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_sipm_calibration_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                      timeout::Real = 0)
    @info "Process SiPM calibration for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :spms, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    calibration_config = dataprod_config(l200).sipm(filekey).calibration
    @debug "Loaded calibration config: $(lstring(calibration_config))"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    @info "Loaded pulser channel info: $(chinfo_puls)"

    ch_puls = chinfo_puls.channel
    det_puls = chinfo_puls.detector

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.sipmcal), string(period)))
    pars_db = PropDict(l200.par.rpars.sipmcal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Filter Type"), Symbol("1PE Pos."), Symbol("1PE Res."),
                         Symbol("Cal. Constant"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    # function to process decay time
    function det_sipm_calibration(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        calibration_config_det = merge(calibration_config.default, get(calibration_config, det, PropDict()))

        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))

        energy_types = Symbol.(collect(keys(calibration_config_det.energy_types)))

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), e_type,
                                       pars_db[det][e_type].fit.positions[1], pars_db[det][e_type].fit.resolutions_cal[1],
                                       pars_db[det][e_type].cal.par[2], "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        data_dsp = @process_step "data loader" begin
            @debug "Load DSP data"
            # load DSP data and apply QC cut
            read_ldata(l200, DataTier(:jldsp), :phy, period, run, det)
        end

        is_pulser = @process_step "pulser tag" begin
            @debug "Get Pulser tags"
            data_pulser = read_ldata((:timestamp, :aux_trig), l200, DataTier(:jlaux), :phy, period, run, det_puls)
            is_pulser = flag_coincidences(data_dsp.timestamp, data_pulser.timestamp[data_pulser.aux_trig],
                                          ts_window = pulser_config_det.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
            is_pulser
        end

        @debug_progress "Detector: $det" for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end

            e_type_config = calibration_config_det.energy_types[e_type]

            # get data after per-energy-type QC
            data_det_after_qc = @process_step "$e_type data loader" begin
                @debug "Load DSP data for $e_type"
                data_dsp[findall(ljl_propfunc(e_type_config.qc).(data_dsp) .&& .!is_pulser)]
            end

            try
                @debug "Calibrate $e_type"

                # get data
                e_uncal = @process_step "$e_type data extraction" begin
                    @debug "Get $e_type data"
                    # open hit data file
                    filter(isfinite, reduce(vcat, getproperty(data_det_after_qc, e_type)))
                end

                @debug_plot @process_step "$e_type PE uncalibrated plot" begin
                    p = LegendMakie.lplot(fit(Histogram, e_uncal,
                                              e_type_config.simple.kwargs.initial_min_amp:0.1:e_type_config.simple.kwargs.initial_max_amp),
                                          xlabel = "Peak Amplitudes (ADC)", ylabel = "Counts / 0.1", label = "Uncalibrated PE",
                                          yscale = log10,
                                          title = get_plottitle(filekey, det, "PE Uncalibrated"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("pe_uncalibrated_$(e_type)"))
                end

                # get uncalibrated energy function
                plot_one_pe_search_range() = begin
                    lo = e_type_config.simple.kwargs.initial_min_amp
                    hi = e_type_config.simple.kwargs.initial_max_amp
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey, det, "Uncalibrated PE"; additional_type = string(e_type)),
                                    xlabel = "Peak Amplitudes (ADC)", ylabel = "Counts")
                    Makie.stephist!(ax, filter(x -> lo <= x <= hi, e_uncal); bins = range(lo, hi; length = 201))
                    save_plot(fig, l200, filekey, det, Symbol("error_simple_calibration_$(e_type)"))
                end
                result_simple, report_simple = @process_step "$e_type simple calibration" on_error = plot_one_pe_search_range begin
                    @debug "Get $e_type simple calibration"
                    sipm_simple_calibration(getproperty(data_det_after_qc, e_type); NamedTuple(e_type_config.simple.kwargs)...)
                end
                GC.gc()

                # save plots for simple calibration for control
                @debug_plot @process_step "$e_type simple calibration plot" begin
                    p = LegendMakie.lplot(report_simple, cal = true,
                                          title = get_plottitle(filekey, det, "Simple Calibration"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("sipm_simple_calibration_$(e_type)"))
                end
                yield()

                result_fit, report_fit = @process_step "$e_type peak fitting" begin
                    @debug "Fit all $e_type peaks"
                    fit_sipm_spectrum(result_simple.pe_simple_cal, e_type_config.fit.min_pe, e_type_config.fit.max_pe;
                                      NamedTuple(e_type_config.fit.kwargs)..., f_uncal = result_simple.f_simple_uncal, uncertainty = true)
                end
                GC.gc()

                @process_step "$e_type peak fits plot" begin
                    p = LegendMakie.lplot(report_fit, figsize = (700, 500), xerrscaling = 5,
                                          title = get_plottitle(filekey, det, "Peak Fits"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("sipm_peak_fits_$(e_type)"))
                end

                yield()

                @debug "Get $e_type calibration values"
                peak_fit_cut = findall(isfinite.(result_fit.positions))

                result_calib, report_calib = @process_step "$e_type calibration curve fitting" begin
                    result_calib, report_calib = fit_calibration(e_type_config.pol_order, result_fit.positions[peak_fit_cut],
                                                                 collect(result_fit.peaks)[peak_fit_cut] .* u"e_au"; e_expression = e_type)
                    @debug "Found $e_type calibration curve: $(result_calib.func)"
                    result_calib, report_calib
                end

                @process_step "$e_type calibration curve plot" begin
                    p = LegendMakie.lplot(report_calib, xerrscaling = 5,
                                          title = get_plottitle(filekey, det, "Calibration Curve"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("sipm_calibration_curve_$(e_type)"))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), e_type, result_fit.positions[1],
                                   result_fit.resolutions_cal[1], result_calib.par[2], "-"))

                result_energy = (m_cal_simple = result_simple.c, n_cal_simple = result_simple.offset,
                                 noise_threshold = result_simple.noise_threshold, noise_threshold_cal = result_simple.noise_threshold_cal,
                                 cal = result_calib, fit = result_fit)

                # add results to dict
                result_dict[e_type] = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

                GC.gc()
            catch e
                e isa ProcessStepError || @error "Error in processing detector $det ($ch): $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), e_type, "-", "-", "-", truncate_error(e)))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_calibration = parallel(det_sipm_calibration, chinfo, log_nt; timeout = timeout, retry = false,
                                       process_name = "$period-$run-process_sipm_calibration_phy")
    @info "Finished SiPM calibration"

    pars_db = create_pars(pars_db, result_sipm_calibration)
    write_pars(l200.par.rpars.sipmcal[period], run, pars_db)
    write_validity(l200.par.rpars.sipmcal, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_sipm_calibration)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_calibration_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_calibration))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :sipm_calibration_phy), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_sipm_calibration_phy)
