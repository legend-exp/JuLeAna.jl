"""
    p_process_decay_time_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true) -> Bool

Determine the preamplifier decay time of the HPGe detectors (`geds`) for every `cal` partition that contains `period`.

For each detector and partition, the presummed waveforms of the peak named by `peakname` in the
`pz` section of the DSP configuration are read from the `jlpks` tier of the runs of the
partition, `n_evts` events per run. If there are more than `max_wvfs` waveforms in total,
`max_wvfs` of them are selected at random, without repetition and in their original order.
Waveforms that fail the QC condition `qc` are removed. The decay time of each remaining
waveform is computed, and a truncated Gaussian is fitted to the values between `min_tau` and
`max_tau`; its mean is the decay time. An entry gets warning status if the decay time is
outside 350 to 700 µs. An entry fails if loading, QC, DSP or the fit throws an error.

# Inputs
- `jlpks` tier of all runs of each partition, entry `peakname`
- `dataprod_config(l200).dsp(filekey)`, sections `default`, per detector, and `pz` (`p_default`, `p`)
- the QC evaluator from `load_qc_evaluator(l200, filekey)`
- `l200.par.ppars.pz[det, part]` (existing parameters, unless `reprocess` is `true`)

# Outputs
- `l200.par.ppars.pz[det, part]` with the decay time `τ` and the fit result, for each detector and partition, and the validity of all partitions
- plot `:decay_time` for each detector and partition (debug plot level)
- If `error_plots` is on, a failed decay time extraction saves `error_decay_time_extraction`.
- partition report `:decay_time`, with one row per detector and partition

# Keywords
- `reprocess`: discard the existing parameters and process all entries again; otherwise entries that already have parameters are skipped
- `timeout`: seconds allowed per detector and partition in `parallel` (0 = no limit)
- `only_first_period`: skip a detector whose partition starts in an earlier period than `period`; it is then processed with that period. `run_processing` sets this to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, `false` otherwise. `run_processing` then waits for this step in the previous period.
"""
function p_process_decay_time_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                                  only_first_period::Bool = true)
    @info "Process decay time for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :cal; system = :geds, explode_partitions = true) |>
                      detector_filter(processing_config, :p_process_decay_time_cal)
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Decay Time"), Symbol("σ"), :Error)}

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # get worker pool

    # flush stdout
    flush(stdout)

    # function to process decay time
    function det_decay_time(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        make_par_dir(joinpath(data_path(l200.par.ppars.pz), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.pz), "$det", "$part.yaml"))
            PropDict(l200.par.ppars.pz[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.pz), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        if only_first_period && period != first(partinfo_det.period)
            @info "Only first period in partition $part for $period in $det ($ch)"
            log_det = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, fill("-", 2)...,
                              "Only first periods --> skipped."))
            return (processed = false, log = log_det, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $det already processed, skip"
            log_det = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), pars_db_det[det].τ,
                              pars_db_det[det].fit.σ, "Already processed --> skipped."))
            return (processed = false, log = log_det, validity = validity_det)
        end

        @debug "Processing detector $det ($ch)"

        dsp_config_pd = dataprod_config(l200).dsp(filekey_det)
        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        pz_config = dataprod_config(l200).dsp(filekey_det).pz
        pz_config_det = merge(pz_config.p_default, get(pz_config.p, det, PropDict()))
        @debug "Loaded PZ config: $(lstring(pz_config_det))"

        # unpack config
        min_τ, max_τ = pz_config_det.min_tau, pz_config_det.max_tau
        nbins = pz_config_det.nbins
        rel_cut_fit = pz_config_det.rel_cut_fit
        n_evts = pz_config_det.n_evts
        max_wvfs = pz_config_det.max_wvfs
        select_random = pz_config_det.select_random
        peakname = Symbol(pz_config_det.peakname)
        qc_string = pz_config_det.qc

        # load data
        wvfs_det = @process_step "$peakname data loading" begin
            @debug "Loading $peakname data from $(part), select $(ifelse(select_random, "randomly ", ""))$n_evts events from each run"
            # The events of each run are selected by timestamp before reading, so only the
            # selected waveforms are loaded from disk.
            f_timestamp = ljl_propfunc("$peakname.timestamp")
            wvfs_det = fast_flatten(map(partinfo_det) do r
                                        ts = read_ldata(f_timestamp, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det)
                                        n_sel = n_evts == -1 ? length(ts) : min(n_evts, length(ts))
                                        ts_sel = select_random ? sample(ts, n_sel; replace = false, ordered = true) :
                                                 ts[begin:(begin + n_sel - 1)]
                                        read_ldata(peakname, l200, DataTier(:jlpks), DataCategory(:cal), r.period, r.run, det;
                                                   filterby = @pf $timestamp in ts_sel)
                                    end).waveform_presummed
            if length(wvfs_det) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                wvfs_det = wvfs_det[sample(eachindex(wvfs_det), max_wvfs; replace = false, ordered = true)]
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

        # DSP
        decay_times = @process_step "FEP DSP" begin
            @debug "Generating DSP for FEP decay times"
            dsp_decay_times(wvfs_det, dsp_config_det)
        end
        yield()

        # get decay time
        plot_decay_times() = begin
            fig = Makie.Figure()
            ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey_det, part, det, "Decay Times"), xlabel = "Decay time",
                            ylabel = "Counts")
            Makie.stephist!(ax, filter(isfinite, ustrip.(decay_times)); bins = 100)
            save_plot(fig, l200, part, filekey_det, det, :error_decay_time_extraction)
        end
        result, report = @process_step "decay time extraction" on_error = plot_decay_times begin
            filter!(x -> min_τ < x < max_τ, decay_times)
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ, ; n_bins = nbins, relative_cut = rel_cut_fit)
            fit_single_trunc_gauss(decay_times, cuts_τ; uncertainty = true)
        end
        yield()

        @debug_plot begin
            p = LegendMakie.lplot(report, xlabel = "Decay time ($(unit(result.μ)))",
                                  title = get_plottitle(filekey_det, part, det, "Decay Time Distribution"))
            save_plot(p, l200, part, filekey_det, det, :decay_time)
        end

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for detector $det ($ch)"

        status, message = if 350u"µs" <= mvalue(result.μ) <= 700u"µs"
            (process_succeeded, "-")
        else
            (process_warning, "Decay time $(result.μ) is outside the expected 350–700 µs window.")
        end
        status == process_warning && @warn "$det ($ch) in partition $part: $message"
        log_det = log_nt((det, detector_status(chinfo_det.usability), part, status, result.μ, result.σ, message))

        # generate detector result
        result_det = (result = (τ = result.μ, fit = result), processed = true, log = log_det, validity = validity_det)
        result_pz_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_pz_det)
        write_pars(l200.par.ppars.pz[det], part, pars_db_det)
        write_validity(l200.par.ppars.pz[det], filekey_det, part)
        @info "Saved pars to disk for detector $det ($ch)"

        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pz = parallel(det_decay_time, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                         process_name = "$period-p_process_decay_time_cal")

    @info "Finished decay time extraction"

    @info "Write $period validity"
    validity_all = create_validity(result_pz)
    write_validity(l200.par.ppars.pz, validity_all)

    # create log report
    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :p_process_decay_time_cal, result_pz)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, decay_time_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_pz))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :decay_time), report)
    @info report

    # flush stdout
    flush(stdout)

    # return if any channel was skipped so that the partition is not valid until the lower period is finished
    return any(x -> get(last(x), :skipped, false), values(result_pz))
end

register_processor!(p_process_decay_time_cal)
