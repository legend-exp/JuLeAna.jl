"""
    p_process_sipm_calibration_phy(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Calibrate the SiPM channels (`spms`) per partition from `phy` data, for all partitions that
contain `period`.

The method is the same as in `process_sipm_calibration_phy`, but the data of all runs of a
detector's partition are combined and the results are valid for the whole partition.

# Inputs
- `dsp` tier (`DataTier(:jldsp)`) of the `phy` data of all runs of each detector's partition.
- `jlaux` tier fields `timestamp` and `aux_trig` of the pulser channel named by `dataprod_config(l200).qc(filekey).pulser.puls_detector`
  over the same runs; events within `puls_ts_window` of a pulser trigger are excluded.
- `dataprod_config(l200).sipm(filekey).calibration`, using the `p_default` section merged with the
  per-detector section `p`. It sets `energy_types` (each with `qc`, `simple.kwargs`, `fit.min_pe`,
  `fit.max_pe`, `fit.kwargs`) and `pol_order`.
- `l200.par.ppars.sipmcal[det, part]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.ppars.sipmcal[det, part]`: per energy type, the simple calibration constants, the
  noise thresholds, the peak fit result (`fit`) and the calibration curve (`cal`), written for
  each detector as soon as it is finished; the validity of all partitions is written once at
  the end.
- Plots per detector, partition and energy type: `pe_uncalibrated_<energy type>`,
  `sipm_simple_calibration_<energy type>`, `sipm_peak_fits_<energy type>`,
  `sipm_calibration_curve_<energy type>`. `pe_uncalibrated_<energy type>` and `sipm_simple_calibration_<energy type>` are saved only at the debug plot level.
- If `error_plots` is on, a failed simple calibration saves `error_simple_calibration_<energy type>`.
- Partition report `sipm_calibration_phy`.

# Keywords
- `reprocess`: discard the existing results and calibrate all energy types of all detectors
  again. Otherwise, energy types that already have results are skipped and only missing ones
  are calibrated.
- `timeout`: seconds allowed per detector and partition in `parallel` (0 = no limit).
- `only_first_period`: if `true`, skip a detector whose partition starts in an earlier period
  than `period`; it is processed together with that earlier period. `run_processing` sets this
  to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`.
"""
function p_process_sipm_calibration_phy(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                                        only_first_period::Bool = true)
    @info "Process SiPM calibration for all partitions containing period $period"

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
    log_nt = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Filter Type"), Symbol("1PE Pos."), Symbol("1PE Res."),
                         Symbol("Cal. Constant"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    # function to process decay time
    function det_sipm_calibration(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.sipmcal), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.sipmcal[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.sipmcal), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = first(getproperty(partinfo_det, :phy)).startkey
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        calibration_config = dataprod_config(l200).sipm(filekey_det).calibration
        calibration_config_det = merge(calibration_config.p_default, get(calibration_config.p, det, PropDict()))
        @debug "Loaded calibration config: $(lstring(calibration_config_det))"

        qc_config = dataprod_config(l200).qc(filekey_det)
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        @debug "Loaded pulser config: $(lstring(pulser_config_det))"

        #  write out pulser events
        chinfo_puls = channelinfo(l200, filekey_det, Symbol(qc_config.pulser.puls_detector))
        @info "Loaded pulser channel info: $(chinfo_puls)"

        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector

        energy_types = Symbol.(collect(keys(calibration_config_det.energy_types)))

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for e_type in energy_types
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, e_type, fill("-", 3)...,
                                   "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db_det[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), e_type,
                                       pars_db_det[det][e_type].fit.positions[1], pars_db_det[det][e_type].fit.resolutions_cal[1],
                                       pars_db_det[det][e_type].cal.par[2], "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        data_dsp = @process_step "data loader" begin
            @debug "Load DSP data"
            # load DSP data and apply QC cut
            if !all([haskey(processed_dict, e_type) for e_type in energy_types])
                @debug "Load DSP data for detector $det"
                read_ldata(l200, DataTier(:jldsp), :phy, partinfo_det, det)
            end
        end

        is_pulser = @process_step "pulser tag" begin
            @debug "Get Pulser tags"
            if !all([haskey(processed_dict, e_type) for e_type in energy_types])
                data_pulser = read_ldata((:timestamp, :aux_trig), l200, DataTier(:jlaux), :phy, partinfo_det, det_puls)
                is_pulser = flag_coincidences(data_dsp.timestamp, data_pulser.timestamp[data_pulser.aux_trig],
                                              ts_window = pulser_config_det.puls_ts_window)
                @debug "Found $(count(is_pulser)) pulser events"
                is_pulser
            end
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
                                          title = get_plottitle(filekey_det, part, det, "PE Uncalibrated";
                                                                additional_type = string(e_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("pe_uncalibrated_$(e_type)"))
                end

                # get uncalibrated energy function
                plot_one_pe_search_range() = begin
                    lo = e_type_config.simple.kwargs.initial_min_amp
                    hi = e_type_config.simple.kwargs.initial_max_amp
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey_det, part, det, "Uncalibrated PE"; additional_type = string(e_type)),
                                    xlabel = "Peak Amplitudes (ADC)", ylabel = "Counts")
                    Makie.stephist!(ax, filter(x -> lo <= x <= hi, e_uncal); bins = range(lo, hi; length = 201))
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_simple_calibration_$(e_type)"))
                end
                result_simple, report_simple = @process_step "$e_type simple calibration" on_error = plot_one_pe_search_range begin
                    @debug "Get $e_type simple calibration"
                    sipm_simple_calibration(getproperty(data_det_after_qc, e_type); NamedTuple(e_type_config.simple.kwargs)...)
                end

                # save plots for simple calibration for control
                @debug_plot @process_step "$e_type simple calibration plot" begin
                    p = LegendMakie.lplot(report_simple, cal = true,
                                          title = get_plottitle(filekey_det, part, det, "Simple Calibration";
                                                                additional_type = string(e_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("sipm_simple_calibration_$(e_type)"))
                end
                yield()

                result_fit, report_fit = @process_step "$e_type peak fitting" begin
                    @debug "Fit all $e_type peaks"
                    fit_sipm_spectrum(result_simple.pe_simple_cal, e_type_config.fit.min_pe, e_type_config.fit.max_pe;
                                      NamedTuple(e_type_config.fit.kwargs)..., f_uncal = result_simple.f_simple_uncal, uncertainty = true)
                end

                @process_step "$e_type peak fits plot" begin
                    p = LegendMakie.lplot(report_fit, figsize = (700, 500), xerrscaling = 5,
                                          title = get_plottitle(filekey_det, part, det, "Peak Fits"; additional_type = string(e_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("sipm_peak_fits_$(e_type)"))
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
                                          title = get_plottitle(filekey_det, part, det, "Calibration Curve";
                                                                additional_type = string(e_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("sipm_calibration_curve_$(e_type)"))
                end

                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), e_type, result_fit.positions[1],
                                   result_fit.resolutions_cal[1], result_calib.par[2], "-"))

                result_energy = (m_cal_simple = result_simple.c, n_cal_simple = result_simple.offset,
                                 noise_threshold = result_simple.noise_threshold, noise_threshold_cal = result_simple.noise_threshold_cal,
                                 cal = result_calib, fit = result_fit)

                # add results to dict
                result_dict[e_type] = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

            catch e
                e isa ProcessStepError || @error "Error in processing detector $det: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), e_type, "-", "-", "-",
                                   truncate_error(e)))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end

        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_sipm_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_sipm_det)
        write_pars(l200.par.ppars.sipmcal[det], part, pars_db_det)
        write_validity(l200.par.ppars.sipmcal[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_calibration = parallel(det_sipm_calibration, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                                       process_name = "$period-p_process_sipm_calibration_phy")

    @info "Finished SiPM partition calibration"

    @info "Write $period validity"
    validity_all = create_validity(result_sipm_calibration)
    write_validity(l200.par.ppars.sipmcal, validity_all)

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
    write_report(get_preportfilename(l200, filekey, :sipm_calibration_phy), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_sipm_calibration))
end

register_processor!(p_process_sipm_calibration_phy)
