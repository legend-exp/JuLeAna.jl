"""
    process_energy_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Calibrate the energy of all processable HPGe detectors (`geds`) of the `cal` run with the Th-228 spectrum.

For each energy type in `energy_types` of the energy config, the uncalibrated energies of single-pulse, non-pulser events passing the quality cuts are calibrated in three steps: a simple calibration locates the Th-228 peaks, the peaks are fitted with the functions in `th228_fit_func`, and a polynomial calibration curve (`cal_pol_order`) and a FWHM curve (`fwhm_pol_order` for energy types ending in `_ctc`, otherwise a quadratic FWHM² model) are fitted to the peaks that pass the fit quality cuts in `qc`. Peaks in `cal_fit_excluded_peaks` and `fwhm_fit_excluded_peaks` are left out of the respective fit. Energy types ending in `_ctc` use the charge-trapping-corrected energy expression from the CT correction results.

# Inputs
- `jlqcs` tier of the start `cal` filekey (event mask `is_single_pulse && !is_pulser`) and `jldsp` tier of the `cal` run, for each detector.
- `dataprod_config(l200).energy(filekey)` (`default` and per-detector entries).
- `l200.par.rpars.ctc[period, run]` (needed for `_ctc` energy types).
- `l200.par.rpars.ecal[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.ecal[period, run]`: per detector and energy type the simple calibration constant (`m_cal_simple`), FWHM curve (`fwhm`), calibration curve (`cal`) and calibrated peak fit results (`fit`), together with the validity entry for the run.
- Per detector and energy type, plots `simple_calibration_<e_type>`, `peak_fits_<e_type>`, `calibration_curve_<e_type>` and `fwhm_<e_type>`. `simple_calibration_<e_type>` and `peak_fits_<e_type>` are saved only at the debug plot level.
- Run report `:energy_calibration` (Main Log, Metadata, Results table with one row per detector and energy type).

# Keywords
- `reprocess`: redo all detectors and energy types, discarding existing results in `l200.par.rpars.ecal[period, run]`. If `false`, only energy types without results are processed.
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_energy_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                        timeout::Real = 0)
    @info "Energy calibration for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded energy config: $(lstring(energy_config))"

    pars_ctc = get_values(l200.par.rpars.ctc[period, run])
    @debug "Loaded CTC parameters"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.ecal), string(period)))
    pars_db = PropDict(l200.par.rpars.ecal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Energy Type"), Symbol("FWHM Qbb"), Symbol("FWHM FEP"),
                         Symbol("Cal. Constant"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_energy_calibration(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        energy_config_det = merge(energy_config.default, get(energy_config, det, PropDict()))

        energy_types = Symbol.(energy_config_det.energy_types)

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), e_type, pars_db[det][e_type].fwhm.qbb,
                                       pars_db[det][e_type].fit.Tl208FEP.fwhm, pars_db[det][e_type].cal.par[2],
                                       "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data; `nothing` if all energy types are already processed
        data_det_after_qc = @process_step "data loader" begin
            @debug "Load DSP data after QC"
            if !all([haskey(processed_dict, e_type) for e_type in energy_types])
                e_names = Symbol.(first.(split.(string.(energy_types), "_ctc")))
                columns_to_read = any(endswith(string(e_type), "_ctc") for e_type in energy_types) ? (unique(e_names)..., :qdrift) :
                                  Tuple(unique(e_names))
                qc_mask = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs, filekey, det)
                read_ldata(columns_to_read, l200, :jldsp, :cal, period, run, det)[qc_mask]
            end
        end

        quantile_perc = if energy_config_det.quantile_perc isa String
            parse(Float64, energy_config_det.quantile_perc)
        else
            energy_config_det.quantile_perc
        end
        th228_names = Symbol.(energy_config_det.th228_names)
        th228_lines_dict = Dict(th228_names .=> energy_config_det.th228_lines)

        @debug_progress "Detector: $det" for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end
            try
                @debug "Calibrate $e_type"

                # get data
                e_uncal, e_uncal_func = @process_step "$e_type data extraction" begin
                    @debug "Get $e_type data"
                    e_type_name = Symbol(split(string(e_type), "_ctc")[1])
                    if endswith(string(e_type), "_ctc")
                        @debug "Apply CT correction for $e_type"
                        ctc_func = pars_ctc[det][e_type_name].func
                        ljl_propfunc(ctc_func).(data_det_after_qc), ctc_func
                    else
                        getproperty(data_det_after_qc, e_type_name), "$e_type_name"
                    end
                end

                # with error plots on, a failed simple calibration saves the uncalibrated spectrum
                plot_uncal_spectrum() = begin
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey, det, "Uncalibrated Spectrum"; additional_type = string(e_type)),
                                    xlabel = "Energy (ADC)", ylabel = "Counts")
                    Makie.stephist!(ax, filter(isfinite, ustrip.(e_uncal)); bins = 1000)
                    save_plot(fig, l200, filekey, det, Symbol("error_simple_calibration_$(e_type)"))
                end
                result_simple, report_simple = @process_step "$e_type simple calibration" on_error = plot_uncal_spectrum begin
                    @debug "Get $e_type simple calibration"
                    simple_calibration(e_uncal, energy_config_det.th228_lines, energy_config_det.left_window_sizes,
                                       energy_config_det.right_window_sizes, ; calib_type = :th228, quantile_perc = quantile_perc,
                                       binning_peak_window = energy_config_det.binning_peak_window)
                end

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                @debug_plot @process_step "$e_type simple calibration plot" begin
                    p = LegendMakie.lplot(report_simple,
                                          title = get_plottitle(filekey, det, "Simple Calibration"; additional_type = string(e_type)),
                                          cal = true)
                    save_plot(p, l200, filekey, det, Symbol("simple_calibration_$(e_type)"))
                end
                yield()

                result_fit, report_fit = @process_step "$e_type peak fitting" begin
                    @debug "Fit all $e_type peaks"
                    fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names; e_unit = result_simple.unit,
                              calib_type = :th228, fit_func = Symbol.(energy_config_det.th228_fit_func), m_cal_simple = m_cal_simple)
                end

                @debug_plot @process_step "$e_type peak fits plot" begin
                    p = LegendMakie.lplot(report_fit, figsize = (600, 400*length(report_fit)),
                                          title = get_plottitle(filekey, det, "Peak Fits"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("peak_fits_$(e_type)"))
                end

                yield()

                # fit QC peaks
                fit_qc = energy_config_det.qc.fit

                # peak fitting QC
                fwhm_cut = [result_fit[th228_names[i]].fwhm .* m_cal_simple > energy_config_det.qc.min_fwhm &&
                                result_fit[th228_names[i]].fwhm .* m_cal_simple .<
                                energy_config_det.qc.max_fwhm_per_window *
                                (energy_config_det.left_window_sizes[i] + energy_config_det.right_window_sizes[i])
                            for i in eachindex(th228_names)]
                qc_cut = ljl_propfunc(fit_qc).([result_fit[k] for k in th228_names]) .&& fwhm_cut

                th228_names_qc = th228_names[qc_cut]
                th228_names_cut = th228_names[.!qc_cut]

                @debug "Get $e_type calibration values"

                th228_names_qc_cal_fit = [p for p in th228_names_qc if !(p in Symbol.(energy_config_det.cal_fit_excluded_peaks))]

                result_calib, report_calib = @process_step "$e_type calibration curve fitting" begin
                    μ_fit = [result_fit[p].centroid for p in th228_names_qc_cal_fit]
                    pp_fit = [th228_lines_dict[p] for p in th228_names_qc_cal_fit]
                    fit_calibration(energy_config_det.cal_pol_order, μ_fit, pp_fit; e_expression = e_uncal_func)
                end
                @debug "Found $e_type calibration curve: $(result_calib.func)"
                # add not-fitted peaks to plot 
                μ_notfit = [result_fit[p].centroid for p in th228_names if !(p in th228_names_qc_cal_fit)]
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_cal_fit)]

                @process_step "$e_type calibration curve plot" begin
                    p = LegendMakie.lplot(report_calib, xerrscaling = 100, additional_pts = (μ = μ_notfit, peaks = pp_notfit),
                                          title = get_plottitle(filekey, det, "Calibration Curve"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("calibration_curve_$(e_type)"))
                end

                yield()

                f_cal_widths(x) = report_calib.f_fit(x) .* report_calib.e_unit .- first(report_calib.par)

                th228_names_qc_fwhm_fit = [p for p in th228_names_qc if !(p in Symbol.(energy_config_det.fwhm_fit_excluded_peaks))]

                # energies without charge trapping correction get a quadratic FWHM² model
                fwhm_order = endswith(string(e_type), "_ctc") ? energy_config_det.fwhm_pol_order : 2
                result_fwhm, report_fwhm = @process_step "$e_type FWHM fitting" begin
                    fwhm_fit = f_cal_widths.([result_fit[p].fwhm for p in th228_names_qc_fwhm_fit])
                    pp_fit = [th228_lines_dict[p] for p in th228_names_qc_fwhm_fit]
                    fit_fwhm(fwhm_order, pp_fit, fwhm_fit; e_type_cal = Symbol("$(e_type)_cal"), e_expression = e_uncal_func,
                             uncertainty = true)
                end
                @debug "Found $e_type FWHM: $(round(u"keV", result_fwhm.qbb, digits=2))"
                fwhm_notfit = f_cal_widths.([result_fit[p].fwhm for p in th228_names if !(p in th228_names_qc_fwhm_fit)])
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_fwhm_fit)]

                @process_step "$e_type FWHM plot" begin
                    p = LegendMakie.lplot(report_fwhm, additional_pts = (peaks = pp_notfit, fwhm = fwhm_notfit),
                                          title = get_plottitle(filekey, det, "FWHM"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("fwhm_$(e_type)"))
                end

                f_cal_pos(x) = report_calib.f_fit(x) .* report_calib.e_unit

                # calibrate best fit values
                width_pars = [:σ, :fwhm]
                position_pars = [:μ, :centroid]
                for (peak, result_peak) in result_fit
                    result_peak = merge(result_peak, NamedTuple{Tuple(width_pars)}([f_cal_widths(result_peak[k]) for k in width_pars]...))
                    result_peak = merge(result_peak,
                                        NamedTuple{Tuple(position_pars)}([f_cal_pos(result_peak[k]) for k in position_pars]...))
                    result_fit[peak] = result_peak
                end

                yield()

                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), e_type, result_fwhm.qbb,
                                   result_fit[:Tl208FEP].fwhm, result_calib.par[2], "-"))

                result_energy = (m_cal_simple = m_cal_simple, fwhm = result_fwhm, cal = result_calib, fit = result_fit)

                # add results to dict
                result_dict[e_type] = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

            catch e
                # a failed `@process_step` has logged its error already
                e isa ProcessStepError || @error "$e_type calibration failed for $det: $(truncate_error(e))"
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

    result_energy = parallel(det_energy_calibration, chinfo, log_nt; timeout = timeout, retry = false,
                             process_name = "$period-$run-process_energy_calibration_cal")

    @info "Finished energy calibration"

    pars_db = create_pars(pars_db, result_energy)
    write_pars(l200.par.rpars.ecal[period], run, pars_db)
    write_validity(l200.par.rpars.ecal, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_energy)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, energy_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_energy))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :energy_calibration), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_energy_calibration_cal)
