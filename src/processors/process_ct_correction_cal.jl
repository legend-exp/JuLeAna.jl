"""
    process_ct_correction_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Determine the charge-trapping correction for all processable HPGe detectors (`geds`) of the `cal` run.

For each energy type in `energy_types` of the `ctc` section of the energy config, the energy is calibrated with a simple Th-228 calibration, and the correction parameters (polynomial in `qdrift` of order `ctc_order`) are optimized on the peak `peak` within the window (`left_window_size`, `right_window_size`). The FWHM of the peak before and after the correction is reported. Only single-pulse, non-pulser events passing the quality cuts are used.

# Inputs
- `jlqcs` tier of the start `cal` filekey (event mask `is_single_pulse && !is_pulser`) and `jldsp` tier of the `cal` run (energy types and `qdrift`), for each detector. A missing `jlqcs` file counts as a failure of that detector.
- `dataprod_config(l200).energy(filekey)` (`default`, `ctc.default` and per-detector entries).
- `l200.par.rpars.ctc[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.ctc[period, run]`: per detector and energy type the correction result (including `fct`, `fwhm_before`, `fwhm_after`), together with the validity entry for the run.
- Per detector and energy type, plots `simple_calibration_<e_type>` and `ctc_<e_type>`, saved only at the debug plot level.
- If `error_plots` is on, a failed simple calibration saves `error_simple_calibration_<e_type>` and a failed alpha generation `error_alpha_generation_<e_type>`.
- Run report `:ct_correction` (Main Log, Metadata, Results table with one row per detector and energy type).

# Keywords
- `reprocess`: redo all detectors and energy types, discarding existing results in `l200.par.rpars.ctc[period, run]`. If `false`, only energy types without results are processed.
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_ct_correction_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                   timeout::Real = 0)
    @info "CT correction for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system = :geds, only_processable = true))
    @info "Loaded channel info with $(length(chinfo)) detectors"

    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded energy config: $(lstring(energy_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.ctc), string(period)))
    pars_db = PropDict(l200.par.rpars.ctc[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Energy Type"), Symbol("FCT/1E6"), Symbol("FWHM Before"),
                         Symbol("FWHM After"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_ct_correction(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        qcsfilename = l200.tier[:jlqcs, filekey, det]
        # load data file
        if !isfile(qcsfilename)
            @error "QC file $qcsfilename not found"
            throw(ErrorException("QC file not found"))
        end

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        energy_config_det = merge(energy_config.default, get(energy_config, det, PropDict()))
        ctc_config_det = merge(energy_config.ctc.default, get(energy_config.ctc, det, PropDict()))

        energy_types = Symbol.(ctc_config_det.energy_types)

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), e_type, pars_db[det][e_type].fct*1e6,
                                       pars_db[det][e_type].fwhm_before, pars_db[det][e_type].fwhm_after, "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        # `nothing` if all energy types are already processed
        data_det_after_qc = @process_step "data loader" begin
            @debug "Load DSP data after QC"
            if !all([haskey(processed_dict, e_type) for e_type in energy_types])
                qc_mask = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs, filekey, det)
                read_ldata((energy_types..., :qdrift), l200, :jldsp, :cal, period, run, det)[qc_mask]
            end
        end

        quantile_perc = if energy_config_det.quantile_perc isa String
            parse(Float64, energy_config_det.quantile_perc)
        else
            energy_config_det.quantile_perc
        end

        # get special config for CTC
        ctc_cal_peak = ctc_config_det.peak

        @debug_progress "Detector: $det" for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end

            try
                @debug "Correct $e_type"

                plot_uncal_spectrum() = begin
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey, det, "Uncalibrated Spectrum"; additional_type = string(e_type)),
                                    xlabel = "Energy (ADC)", ylabel = "Counts")
                    Makie.stephist!(ax, filter(isfinite, ustrip.(getproperty(data_det_after_qc, e_type))); bins = 1000)
                    save_plot(fig, l200, filekey, det, Symbol("error_simple_calibration_$(e_type)"))
                end
                result_simple, report_simple = @process_step "$e_type simple calibration" on_error = plot_uncal_spectrum begin
                    @debug "Get $e_type simple calibration"
                    simple_calibration(getproperty(data_det_after_qc, e_type), energy_config_det.th228_lines,
                                       energy_config_det.left_window_sizes, energy_config_det.right_window_sizes, ; calib_type = :th228,
                                       quantile_perc = quantile_perc, binning_peak_window = energy_config_det.binning_peak_window)
                end

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                @debug_plot begin
                    p = LegendMakie.lplot(report_simple, cal = true,
                                          title = get_plottitle(filekey, det, "Simple Calibration"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("simple_calibration_$(e_type)"))
                end

                yield()

                plot_ctc_peak_drift() = begin
                    e_cal_ctc = getproperty(data_det_after_qc, e_type) .* m_cal_simple
                    in_window = ctc_config_det.peak - ctc_config_det.left_window_size .<
                                e_cal_ctc .<
                                ctc_config_det.peak + ctc_config_det.right_window_size
                    x = ustrip.(e_cal_ctc[in_window])
                    y = ustrip.(data_det_after_qc.qdrift[in_window])
                    mask = isfinite.(x) .&& isfinite.(y)
                    h = fit(Histogram, (x[mask], y[mask]),
                            (range(extrema(x[mask])...; length = 101), range(extrema(y[mask])...; length = 101)))
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey, det, "Drift Time vs Energy"; additional_type = "$e_type $ctc_cal_peak"),
                                    xlabel = "Energy", ylabel = "qdrift")
                    Makie.heatmap!(ax, h.edges[1], h.edges[2], h.weights)
                    save_plot(fig, l200, filekey, det, Symbol("error_alpha_generation_$(e_type)"))
                end
                result_ctc, report_ctc = @process_step "$e_type alpha generation" on_error = plot_ctc_peak_drift begin
                    @debug "Get $e_type Charge Trapping Alpha"
                    ctc_energy(getproperty(data_det_after_qc, e_type) .* m_cal_simple, data_det_after_qc.qdrift, ctc_config_det.peak,
                               (ctc_config_det.left_window_size, ctc_config_det.right_window_size), m_cal_simple; e_expression = "$e_type",
                               pol_order = ctc_config_det.ctc_order)
                end

                @debug "Found Best $e_type FWHM: $(round(u"keV", result_ctc.fwhm_after, digits=2))"
                @debug "Found $e_type FCTs: $(round.(result_ctc.fct .* 1e6, digits=2))E-6"

                @debug_plot begin
                    p = LegendMakie.lplot(report_ctc, figsize = (600, 600),
                                          title = get_plottitle(filekey, det, "CTC"; additional_type = "$e_type $ctc_cal_peak"))
                    save_plot(p, l200, filekey, det, Symbol("ctc_$(e_type)"))
                end

                yield()
                log_ch = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "$e_type", result_ctc.fct*1e6,
                                 result_ctc.fwhm_before, result_ctc.fwhm_after, "-"))

                # add results to dict
                result_dict[e_type] = result_ctc
                log_info_dict[e_type] = log_ch
                processed_dict[e_type] = true
            catch e
                e isa ProcessStepError || @error "Error in $e_type CT correction: $(truncate_error(e))"
                log_ch = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), "$e_type", "-", "-", "-",
                                 "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[e_type] = log_ch
                processed_dict[e_type] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    result_ctc = parallel(det_ct_correction, chinfo, log_nt; timeout = timeout, retry = false,
                          process_name = "$period-$run-process_ct_correction_cal")

    @info "Finished CT correction"

    pars_db = create_pars(pars_db, result_ctc)
    write_pars(l200.par.rpars.ctc[period], run, pars_db)
    write_validity(l200.par.rpars.ctc, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_ctc)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, energy_ctc_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_ctc))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :ct_correction), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_ct_correction_cal)
