"""
    p_process_energy_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Calibrate the energy per detector and `cal` partition for all partitions that contain `period` (HPGe detectors `geds`).

For each energy type in `energy_types` of the partition energy config, the energies of all runs of the partition are calibrated with the run-level calibration function (`cal.func` from `l200.par.rpars.ecal`) and concatenated, after selecting single-pulse, non-pulser events that pass the quality cuts. The Th-228 peaks in the resulting spectrum are fitted with the functions in `th228_fit_func`, then a polynomial calibration curve (`cal_pol_order`) and a FWHM curve (`fwhm_pol_order` for energy types ending in `_ctc`, otherwise a quadratic FWHM² model) are fitted to the peaks that pass the fit quality cuts in `qc`. Peaks in `cal_fit_excluded_peaks` and `fwhm_fit_excluded_peaks` are left out of the respective fit.

# Inputs
- `jlqcs` and `jldsp` tiers of all `cal` runs of each partition, for each detector.
- `l200.par.rpars.ecal[period, run]` (run-level calibration function) for each run of the partition.
- `dataprod_config(l200).energy(filekey)`, sections `p_default` and per-detector entries `p`.
- `l200.par.ppars.ecal[det, part]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.ppars.ecal[det, part]`: per energy type the FWHM curve (`fwhm`), calibration curve (`cal`) and peak fit results (`fit`), with validity entries for the partition; the validity of all partitions of the period is written to `l200.par.ppars.ecal`.
- Per detector, partition and energy type, plots `partition_spectrum_<e_type>`, `peak_fits_<e_type>`, `calibration_curve_<e_type>` and `fwhm_<e_type>`. `peak_fits_<e_type>` is saved only at the debug plot level.
- If `error_plots` is on, a failed peak fitting saves `error_peak_fitting_<e_type>`.
- Partition report `:energy` (Main Log, Metadata, Results table with one row per detector, partition and energy type).

# Keywords
- `reprocess`: redo all energy types, ignoring results in `l200.par.ppars.ecal[det, part]`. If `false`, only energy types without results are processed.
- `timeout`: seconds allowed per detector and partition in `parallel` (0 = no limit).
- `only_first_period`: if `true`, a detector whose partition starts in an earlier period is skipped (it is processed with that earlier period). `run_processing` sets this to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector and partition was skipped because of `only_first_period`, otherwise `false`. `run_processing` uses this to wait for the same step in the previous period.
"""
function p_process_energy_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                              only_first_period::Bool = true)
    @info "Energy calibration for for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :cal; system = :geds, only_processable = true, explode_partitions = true)
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Energy Type"), Symbol("FWHM Qbb"), Symbol("FWHM FEP"),
                         Symbol("Cal. Constant"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_energy_calibration(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @debug "Processing detector $det ($ch)"

        make_par_dir(joinpath(data_path(l200.par.ppars.ecal), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.ecal), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.ecal[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.ecal), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        energy_config = dataprod_config(l200).energy(filekey_det)
        energy_config_det = merge(energy_config.p_default, get(energy_config.p, det, PropDict()))
        @debug "Loaded energy config: $(lstring(energy_config_det))"

        energy_types = Symbol.(energy_config_det.energy_types)

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for e_type in energy_types
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, e_type, fill("-", 3)...,
                                   "Only first periods --> skipped."))
                # add results to dict
                processed_dict[e_type] = false
                log_info_dict[e_type] = log_info
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db_det[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), e_type,
                                       pars_db_det[det][e_type].fwhm.qbb, pars_db_det[det][e_type].fit.Tl208FEP.fwhm,
                                       pars_db_det[det][e_type].cal.par[2], "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        th228_names = Symbol.(energy_config_det.th228_names)
        th228_lines_dict = Dict(th228_names .=> energy_config_det.th228_lines)

        for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end
            try
                @debug "Calibrate $e_type"

                energy = @process_step "$e_type data loader" begin
                    fast_flatten([begin
                                      @debug "Reading from $(pinfo.period)-$(pinfo.run)"
                                      read_ldata(ljl_propfunc(l200.par.rpars.ecal[pinfo.period, pinfo.run][det][e_type].cal.func), l200,
                                                 :jldsp, :cal, pinfo.period, pinfo.run, det; filterby = :jlqcs => @pf($is_single_pulse && !$is_pulser))
                                  end
                                  for pinfo in partinfo_det])
                end
                GC.gc()

                e_unit = u"keV"
                peakhists, peakstats, _, _ = @process_step "$e_type simple calibration" begin
                    @debug "Get $e_type peakhists and peakstats"
                    peakhists_gamma(collect(energy), energy_config_det.th228_lines, energy_config_det.left_window_sizes,
                                    energy_config_det.right_window_sizes)
                end
                GC.gc()

                @process_step "$e_type energy spectrum plot" begin
                    p = LegendMakie.lplot(fit(Histogram, ustrip.(e_unit, energy), 0:0.5:3000), xlabel = "Energy ($e_unit)",
                                          ylabel = "Counts / 0.5 keV", yscale = log10, label = string(e_type),
                                          title = get_plottitle(filekey_det, part, det, "Energy Spectrum"; additional_type = "$e_type"),
                                          legend_position = :lb, xticks = 0:500:3000)
                    save_plot(p, l200, part, filekey_det, det, Symbol("partition_spectrum_$e_type"))
                end

                yield()

                plot_peak_windows() = begin
                    fig = Makie.Figure(size = (900, 300 * cld(length(peakhists), 2)))
                    Makie.Label(fig[0, 1:2], get_plottitle(filekey_det, part, det, "Peak Windows"; additional_type = string(e_type)))
                    for (i, name) in pairs(th228_names)
                        edges = collect(first(peakhists[i].edges))
                        ax = Makie.Axis(fig[cld(i, 2), mod1(i, 2)]; title = string(name), xlabel = "Energy ($e_unit)", ylabel = "Counts")
                        Makie.stairs!(ax, (edges[1:(end - 1)] .+ edges[2:end]) ./ 2, peakhists[i].weights; step = :center)
                        Makie.vlines!(ax, [first(edges), last(edges)]; color = :red, linestyle = :dash)
                        Makie.vlines!(ax, [peakstats.peak_pos[i]]; color = :green)
                    end
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_peak_fitting_$e_type"))
                end
                result_fit, report_fit = @process_step "$e_type peak fitting" on_error = plot_peak_windows begin
                    @debug "Fit all $e_type peaks"
                    fit_peaks(peakhists, peakstats, th228_names; e_unit = e_unit, fit_func = Symbol.(energy_config_det.th228_fit_func),
                              calib_type = :th228)
                end
                GC.gc()

                @debug_plot @process_step "$e_type peak fits plot" begin
                    p = LegendMakie.lplot(report_fit, figsize = (600, 400 * length(report_fit)),
                                          title = get_plottitle(filekey_det, part, det, "Peak Fits"; additional_type = string(e_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("peak_fits_$e_type"))
                end

                yield()

                # fit QC peaks
                fit_qc = energy_config_det.qc.fit

                # peak fitting QC
                fwhm_cut = [result_fit[th228_names[i]].fwhm > energy_config_det.qc.min_fwhm &&
                                result_fit[th228_names[i]].fwhm .<
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
                    fit_calibration(energy_config_det.cal_pol_order, μ_fit, pp_fit; uncertainty = true)
                end
                @debug "Found $e_type calibration curve: $(result_calib.func)"
                # add not-fitted peaks to plot 
                μ_notfit = [result_fit[p].centroid for p in th228_names if !(p in th228_names_qc_cal_fit)]
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_cal_fit)]

                @process_step "$e_type calibration curve plot" begin
                    p = LegendMakie.lplot(report_calib, xerrscaling = 1, additional_pts = (μ = μ_notfit, peaks = pp_notfit),
                                          title = get_plottitle(filekey_det, part, det, "Calibration Curve";
                                                                additional_type = string(e_type)),
                                          xlims = (0, 3000), ylims = (0, 3000), figsize = (600, 420),
                                          xlabel = L"\fontfamily{Roboto}\mathrm{Energy_{fit} (keV)}",
                                          ylabel = L"\fontfamily{Roboto}\mathrm{Energy_{true} (keV)}")
                    save_plot(p, l200, part, filekey_det, det, Symbol("calibration_curve_$e_type"))
                end

                yield()

                th228_names_qc_fwhm_fit = [p for p in th228_names_qc if !(p in Symbol.(energy_config_det.fwhm_fit_excluded_peaks))]

                # energies without charge trapping correction get a quadratic FWHM² model
                fwhm_order = endswith(string(e_type), "_ctc") ? energy_config_det.fwhm_pol_order : 2
                result_fwhm, report_fwhm = @process_step "$e_type FWHM fitting" begin
                    fwhm_fit = [result_fit[p].fwhm for p in th228_names_qc_fwhm_fit]
                    pp_fit = [th228_lines_dict[p] for p in th228_names_qc_fwhm_fit]
                    fit_fwhm(fwhm_order, pp_fit, fwhm_fit; e_type_cal = Symbol("$(e_type)_cal"), uncertainty = true)
                end
                @debug "Found $e_type FWHM: $(round(u"keV", result_fwhm.qbb, digits=2))"
                fwhm_notfit = [result_fit[p].fwhm for p in th228_names if !(p in th228_names_qc_fwhm_fit)]
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_fwhm_fit)]

                @process_step "$e_type FWHM plot" begin
                    p = LegendMakie.lplot(report_fwhm, additional_pts = (peaks = pp_notfit, fwhm = fwhm_notfit), figsize = (600, 420),
                                          title = get_plottitle(filekey_det, part, det, "FWHM"; additional_type = string(e_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("fwhm_$e_type"))
                end

                yield()

                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), e_type, result_fwhm.qbb,
                                   result_fit[:Tl208FEP].fwhm, result_calib.par[2], "-"))

                result_energy = (fwhm = result_fwhm, cal = result_calib, fit = result_fit)

                # add results to dict
                result_dict[e_type] = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

                GC.gc()
            catch e
                e isa ProcessStepError || @error "Error in $e_type: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), e_type, "-", "-", "-",
                                   truncate_error(e)))

                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end

        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_energy_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_energy_det)
        write_pars(l200.par.ppars.ecal[det], part, pars_db_det)
        write_validity(l200.par.ppars.ecal[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    result_energy = parallel(det_energy_calibration, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                             process_name = "$period-p_process_energy_cal")

    @info "Finished partition calibration"

    @info "Write $period validity"
    validity_all = create_validity(result_energy)
    write_validity(l200.par.ppars.ecal, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_energy)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, energy_partition_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_energy))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :energy), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_energy))
end

register_processor!(p_process_energy_cal)
