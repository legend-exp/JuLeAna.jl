"""
    process_daq_energy_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Calibrate the DAQ online energy (`daqenergy`) of the HPGe detectors (`geds`) of a `cal` run.

For each detector, the `daqenergy` of the raw `cal` files of the run listed in the runinfo, except the filekeys
marked unprocessable, is calibrated automatically with the Th-228 lines (`th228_cal_lines`)
by `autocal_energy`. The result is a linear calibration `c * daqenergy` in keV, which
[`process_peak_split_cal`](@ref) and [`process_peak_split_phy`](@ref) use to select the
events of their peaks. When the calibration fails, the uncalibrated spectrum is plotted
instead.

# Inputs
- `raw` tier of the `cal` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `dataprod_config(l200).raw(filekey)`, sections `default` and per detector

# Outputs
- `l200.par.rpars.daqecal[period, run]`: per detector the calibration constant `c` and the calibration function `func`, with a validity entry of category `all` for the run
- plot `:daq_energy` for each calibrated detector, `:daq_energy_failed` for each detector whose calibration failed
- run report `:daq_energy_calibration_cal` with one row per detector

# Keywords
- `reprocess`: discard the existing parameters and calibrate all detectors; otherwise a detector with parameters is skipped
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit)

# Returns
Return `nothing`.
"""
function process_daq_energy_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                            timeout::Real = 0)
    @info "Process DAQ energy calibration for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_daq_energy_calibration_cal)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)
    @debug "Loaded raw config: $(lstring(raw_config))"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :cal)).keys))
    isempty(filekeys) && error("No cal filekeys of period $period run $run in the runinfo")
    @info "Found $(length(filekeys)) cal filekeys"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.daqecal), string(period)))
    pars_db = PropDict(l200.par.rpars.daqecal[period, run])
    pars_db = ifelse(reprocess, PropDict(), pars_db)

    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :psd_usability, :Status, Symbol("Cal. Constant"), Symbol("Total Time"),
                         Symbol("Total Allocated"), :Error)}

    # flush stdout
    flush(stdout)

    function calibrate_det(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $det already processed, skip"
            log_det = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), ProcessStatus(1),
                              pars_db[det].c, "0", "0",
                              "Already processed --> skipped."))
            return (processed = false, log = log_det)
        end

        raw_config_det = merge(raw_config.default, get(raw_config, det, PropDict()))

        calibration_timer = TimerOutput()
        result_autocal = nothing
        @timeit calibration_timer "$det" begin
            @timeit calibration_timer "Get DAQ Energy" begin
                @debug "Reading DAQ energy for detector $det from $(length(filekeys)) files"
                e_daq = @process_step "data loader" begin
                    read_ldata(:daqenergy, l200, DataTier(:raw), filekeys, det).daqenergy
                end
            end
            try
                @info "Auto calibrating $det ($ch)"
                result_autocal, report_autocal = @process_step "automatic calibration" begin
                    autocal_energy(e_daq, raw_config_det.th228_cal_lines; mode = :ratio, min_e = raw_config_det.min_e,
                                   max_e = raw_config_det.max_e, max_e_binning_quantile = raw_config_det.max_e_binning_quantile,
                                   σ = raw_config_det.σ, threshold = raw_config_det.threshold, min_n_peaks = raw_config_det.min_n_peaks,
                                   max_n_peaks = raw_config_det.max_n_peaks, α = raw_config_det.α, rtol = raw_config_det.rtol)
                end
                @process_step "calibrated energy plot" begin
                    p = LegendMakie.lplot(report_autocal, raw_config_det.th228_cal_lines, figsize = (650, 400),
                                          title = get_plottitle(filekey, det, "Calibrated DAQ Online Energy"))
                    save_plot(p, l200, filekey, det, :daq_energy)
                end
            catch e
                e isa ProcessStepError || rethrow()
                @process_step "uncalibrated energy plot" begin
                    binwidth = 8 * 15
                    edges = range(0; step = binwidth, length = max(2, floor(Int, maximum(e_daq) / binwidth) + 2))
                    hist = StatsBase.fit(StatsBase.Histogram, e_daq, edges)
                    fig = Makie.Figure(size = (650, 400))
                    ax = Makie.Axis(fig[1, 1], xlabel = "Energy (ADC)", ylabel = "Counts / $binwidth ADC", yscale = log10,
                                    limits = (extrema(edges), (0.9, max(1, maximum(hist.weights)) * 1.2)),
                                    title = get_plottitle(filekey, det, "Failed DAQ Calibration: Uncalibrated Spectrum"))
                    Makie.stephist!(ax, StatsBase.midpoints(edges), weights = replace(hist.weights, 0 => 1e-10), bins = edges,
                                    color = LegendMakie.BEGeOrange)
                    LegendMakie.add_watermarks!(final = true)
                    save_plot(fig, l200, filekey, det, :daq_energy_failed)
                end
                log_det = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), ProcessStatus(0),
                                  "-", "-", "-", truncate_error(e.exception)))
                return (processed = false, log = log_det)
            end
        end

        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(calibration_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(calibration_timer))
        calibration = (c = result_autocal.c * u"keV", func = "$(repr(result_autocal.c)) * daqenergy * keV")
        log_det = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), ProcessStatus(1),
                          calibration.c, "$total_time", total_allocated, ""))
        @info "Finished processing detector $det ($ch) in $total_time"

        return (result = calibration, processed = true, log = log_det)
    end

    # get start time
    start_time = now()

    result_calib = parallel(calibrate_det, chinfo, log_nt; timeout = timeout, retry = false,
                            process_name = "$period-$run-process_daq_energy_calibration_cal")

    @info "Finished DAQ energy calibration"

    pars_db = create_pars(pars_db, result_calib)
    write_pars(l200.par.rpars.daqecal[period], run, pars_db)
    # category `all`: the phy peak splitting of the run uses the calibration as well
    write_validity(l200.par.rpars.daqecal, filekey, (period, run); category = :all)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_daq_energy_calibration_cal, result_calib)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, daq_energy_calibration_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_calib))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :daq_energy_calibration_cal), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_daq_energy_calibration_cal)
