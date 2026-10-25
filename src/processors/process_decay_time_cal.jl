"""
    process_decay_time_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Determine the preamplifier decay time of the HPGe detectors (`geds`) from the `cal` data of a run.

For each detector, the presummed waveforms of the peak named by `peakname` in the `pz`
section of the DSP configuration are read from the `jlpks` tier. If there are more than
`max_wvfs` waveforms, `max_wvfs` of them are selected at random, without repetition and in their original order.
Waveforms that fail the QC condition `qc` are removed. The decay time of each
remaining waveform is computed, and a truncated Gaussian is fitted to the values between
`min_tau` and `max_tau`; its mean is the decay time. A detector gets warning status if the
decay time is outside 350 to 700 µs. A detector fails if its `jlpks` file is missing or if
loading, QC, DSP or the fit throws an error.

# Inputs
- `jlpks` tier of the start filekey of the run, entry `peakname`
- `dataprod_config(l200).dsp(filekey)`, sections `default`, per detector, and `pz` (`min_tau`, `max_tau`, `nbins`, `rel_cut_fit`, `peakname`, `qc`, `max_wvfs`)
- the QC evaluator from `load_qc_evaluator(l200, filekey)`
- `l200.par.rpars.pz[period, run]` (existing parameters, unless `reprocess` is `true`)

# Outputs
- `l200.par.rpars.pz[period, run]` with the decay time `τ` and the fit result of each detector, with its validity
- plot `:decay_time` for each detector (debug plot level)
- If `error_plots` is on, a failed decay time extraction saves `error_decay_time_extraction`.
- run report `:decay_time`, with one row per detector (decay time, width)

# Keywords
- `reprocess`: discard the existing parameters and process all detectors; otherwise detectors that already have parameters are skipped
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit)

# Returns
Return `nothing`.
"""
function process_decay_time_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                timeout::Real = 0)
    @info "Process decay time for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    pz_config = dataprod_config(l200).dsp(filekey).pz
    @debug "Loaded PZ config: $(lstring(pz_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.pz), string(period)))
    pars_db = PropDict(l200.par.rpars.pz[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Decay Time"), Symbol("σ"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    # function to process decay time
    function det_decay_time(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $det already processed, skip"
            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), pars_db[det].τ, pars_db[det].fit.σ,
                              "Already processed --> skipped."))
            return (processed = false, log = log_det)
        end

        @debug "Processing detector $det ($ch)"

        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        pz_config_det = merge(pz_config.default, get(pz_config, det, PropDict()))

        # unpack config
        min_τ, max_τ = pz_config_det.min_tau, pz_config_det.max_tau
        nbins = pz_config_det.nbins
        rel_cut_fit = pz_config_det.rel_cut_fit
        peakname = Symbol(pz_config_det.peakname)
        qc_string = pz_config_det.qc
        max_wvfs = pz_config_det.max_wvfs

        filename = l200.tier[:jlpks, filekey, det]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip detector $det"
            throw(ErrorException("File $(basename(filename)) does not exist"))
        end

        # load data
        wvfs_det = @process_step "$peakname data loading" begin
            @debug "Loading $peakname data from $(filename)"
            wvfs_det = read_ldata(peakname, l200, DataTier(:jlpks), filekey, det).waveform_presummed
            if length(wvfs_det) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                sel = sample(eachindex(wvfs_det), max_wvfs; replace = false, ordered = true)
                wvfs_det = wvfs_det[sel]
            end
            wvfs_det
        end
        yield()

        # get QC cuts
        wvfs_det = @process_step "QC cuts" begin
            @debug "Get QC cuts"
            dsp_qc = dsp_qc_flt_optimization_compressed(wvfs_det, dsp_config_det, 400.0u"µs", f_evaluate_qc)
            qc = ljl_propfunc(qc_string).(dsp_qc)
            wvfs_det = wvfs_det[findall(qc)]
            @debug "Survival Fraction: $(round(count(qc) / length(qc) * 100, digits=2))%"
            wvfs_det
        end
        GC.gc()

        # DSP
        decay_times = @process_step "$peakname DSP" begin
            @debug "Generating DSP for $peakname decay times"
            dsp_decay_times(wvfs_det, dsp_config_det)
        end
        yield()

        # get decay time
        plot_decay_times() = begin
            fig = Makie.Figure()
            ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey, det, "Decay Times"), xlabel = "Decay time", ylabel = "Counts")
            Makie.stephist!(ax, filter(isfinite, ustrip.(decay_times)); bins = 100)
            save_plot(fig, l200, filekey, det, :error_decay_time_extraction)
        end
        result, report = @process_step "decay time extraction" on_error = plot_decay_times begin
            filter!(x -> min_τ < x < max_τ, decay_times)
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ, ; n_bins = nbins, relative_cut = rel_cut_fit)
            fit_single_trunc_gauss(decay_times, cuts_τ)
        end
        yield()

        @debug_plot begin
            p = LegendMakie.lplot(report, xlabel = "Decay time ($(unit(result.μ)))",
                                  title = get_plottitle(filekey, det, "Decay Time Distribution"))
            save_plot(p, l200, filekey, det, :decay_time)
        end

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for detector $det ($ch)"

        status, message = if 350u"µs" <= mvalue(result.μ) <= 700u"µs"
            (process_succeeded, "-")
        else
            (process_warning, "Decay time $(result.μ) is outside the expected 350–700 µs window.")
        end
        status == process_warning && @warn "$det ($ch): $message"
        log_det = log_nt((det, detector_status(chinfo_det.usability), status, result.μ, result.σ, message))
        return (result = (τ = result.μ, fit = result), processed = true, log = log_det)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pz = parallel(det_decay_time, chinfo, log_nt; timeout = timeout, retry = false,
                         process_name = "$period-$run-process_decay_time_cal")
    @info "Finished decay time extraction"

    pars_db = create_pars(pars_db, result_pz)
    write_pars(l200.par.rpars.pz[period], run, pars_db)
    write_validity(l200.par.rpars.pz, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_pz)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, decay_time_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_pz))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :decay_time), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_decay_time_cal)
