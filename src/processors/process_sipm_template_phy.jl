"""
    process_sipm_template_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Extract the single-photon pulse template and the noise spectrum of the SiPM channels (`spms`) of one run from `phy`
data and design their inverse kernel.

For each processable SiPM, a derivative plus moving-window trigger with a MAD threshold per waveform
counts the pulses of every waveform without pole-zero correction and without pars
(`dsp_sipm_template_compressed`). Waveforms with exactly one trigger and a complete template window
are aligned at the threshold crossing of the shaped trace and baseline subtracted; waveforms without any trigger and without any
sample beyond `n_σ_noise` MAD-σ of their baseline are the noise traces. Every pulse is normalised to its own maximum and the median per sample is the pulse shape of
the channel with peak 1, continued beyond the window with an exponential tail fit;
the noise spectrum is the median periodogram of the noise traces (`fit_sipm_template`). From template and
noise spectrum the inverse kernel is designed: the largest Wiener brake `λ` for which the template, sent through
the kernel, stays within `tail_max` of the target stick in the tail window, as largest deviation and as running integral (`fit_sipm_kernel`). Nothing is
calibrated, all values are in ADC.

# Inputs
- `raw` tier of the `phy` filekeys of the run listed in the runinfo (excluding filekeys marked `unprocessable`),
  fields `waveform_bit_drop` and `timestamp`; `max_wvfs` of them drawn at random and selected by timestamp before reading.
- `jlaux` tier fields `timestamp` and `aux_trig` of the pulser channel named by
  `dataprod_config(l200).qc(filekey).pulser.puls_detector`; waveforms within `puls_ts_window`
  of a pulser trigger are excluded.
- `dataprod_config(l200).sipm(filekey).template`: the `default` section merged with the per-detector
  section (`max_wvfs`, `trigger`, `window`, `n_σ_baseline`, `n_σ_noise`, `max_noise_wvfs`, `target_fwhm`,
  `tail_fit_window`, `min_pulses`, `min_noise_traces`).
- `dataprod_config(l200).sipm(filekey).kernel`: the `default` section merged with the per-detector section
  (`target_fwhm`, `tail_start_n_sigma`, `tail_end`, `tail_max`, `lambda_range`, `n_lambda`, `kernel_half_length`).
- `l200.par.rpars.sipmtmpl[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.sipmtmpl[period, run]`: per detector the `template` (`t0`, `dt`, `pulse` with peak 1, `n_pulses`,
  `tail_level`, `tail_tau`, `baseline_σ` in ADC), the `noise` spectrum (`df`, `psd` in ADC²/Hz, `n_noise`, Gaussian `μ`, `σ` in ADC) and the
  `kernel` (`lambda`, `half_length`, `dt`, `taps`, `target_fwhm`, `tail_local`, `tail_integral`, `fwhm`, `noise_per_sample`, `noise_shaped`, `trigger_shaping`,
  `response_sum`, `truncation_ok`); the validity entry is written for `(period, run)`.
- Plots per detector: `template_pulse` (template and target stick), `template_tail` (template on a log scale with
  the tail fit window and the continuation), `template_noise` (noise spectrum), `template_noise_samples` (noise samples against a Gaussian) and `template_amplitude` (pulse
  maxima), `kernel_lambda` (the λ scan), `kernel_response` (template through the kernel against the target),
  `kernel_spectrum` and `kernel_filtered` (spectra before and after the kernel), `kernel_pulses` (the single pulses
  through the kernel); at the debug plot level also `template_heatmap`, `template_heatmap_norm`, `template_residual`
  and `kernel_taps`.
- Run report `sipm_template_phy`.

# Keywords
- `reprocess`: discard the existing results of the run and extract the templates of all detectors
  again. Otherwise, detectors that already have results are skipped.
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_sipm_template_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                   timeout::Real = 0)
    @info "Process SiPM template for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :phy)).keys))

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :spms) |> detector_filter(processing_config, :process_sipm_template_phy)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    template_config = dataprod_config(l200).sipm(filekey).template
    @debug "Loaded template config: $(lstring(template_config))"

    kernel_config = dataprod_config(l200).sipm(filekey).kernel
    @debug "Loaded kernel config: $(lstring(kernel_config))"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.sipmtmpl), string(period)))
    pars_db = PropDict(l200.par.rpars.sipmtmpl[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("N wvfs"), Symbol("N single"), Symbol("N noise"), Symbol("Noise μ"), Symbol("Noise σ"), Symbol("Tail τ"), :λ,
                         Symbol("Kernel tail"), :Error)}

    # flush stdout
    flush(stdout)

    # get pulser detector information
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    @info "Loaded pulser channel info: $(chinfo_puls)"

    # function to process the template of one detector
    function det_sipm_template(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        det_puls = chinfo_puls.detector

        @debug "Processing detector $det ($ch)"

        template_config_det = merge(template_config.default, get(template_config, det, PropDict()))
        kernel_config_det = merge(kernel_config.default, get(kernel_config, det, PropDict()))
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))

        max_wvfs = template_config_det.max_wvfs

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, skip"
            log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "-", pars_db[det].template.n_pulses,
                               pars_db[det].noise.n_noise, pars_db[det].noise.μ, pars_db[det].noise.σ, pars_db[det].template.tail_tau,
                               pars_db[det].kernel.lambda, max(pars_db[det].kernel.tail_local, pars_db[det].kernel.tail_integral),
                               "Already processed --> skipped."))
            return (processed = false, log = log_info)
        end

        # load data
        data_det = @process_step "data loader" begin
            @debug "Loading SiPM data from $(period)-$(run), $max_wvfs random events"
            # The events are selected by timestamp before reading, so only the selected waveforms are loaded from disk.
            ts = read_ldata(ljl_propfunc("timestamp"), l200, DataTier(:raw), filekeys, det)
            ts_sel = Set(sample(ts, min(max_wvfs, length(ts)); replace = false))
            read_ldata((:waveform_bit_drop, :timestamp), l200, DataTier(:raw), filekeys, det; filterby = @pf $timestamp in ts_sel)
        end

        wvfs_det = @process_step "pulser tag" begin
            @debug "Get Pulser tags"
            data_pulser = read_ldata((:timestamp, :aux_trig), l200, DataTier(:jlaux), :phy, period, run, det_puls)
            is_pulser = flag_coincidences(data_det.timestamp, data_pulser.timestamp[data_pulser.aux_trig],
                                          ts_window = pulser_config_det.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
            data_det[findall(.!is_pulser)].waveform_bit_drop[:]
        end

        dsp_tmpl = @process_step "single pulse selection" begin
            @debug "Trigger and single-pulse selection"
            dsp_sipm_template_compressed(10000, wvfs_det, template_config_det)
        end
        n_single = count(dsp_tmpl.is_single)
        @debug "Found $n_single single-trigger waveforms of $(length(wvfs_det)) for detector $det ($ch)"

        result_tmpl, report_tmpl = @process_step "template" begin
            @debug "Build median template"
            fit_sipm_template(dsp_tmpl.pulse[dsp_tmpl.is_single], [v for v in dsp_tmpl.noise if !isempty(v)], step(first(wvfs_det).time),
                              first(template_config_det.window); target_fwhm = template_config_det.target_fwhm,
                              tail_fit_window = Tuple(template_config_det.tail_fit_window),
                              min_pulses = template_config_det.min_pulses, min_noise_traces = template_config_det.min_noise_traces)
        end

        @debug "Template tail level $(round(result_tmpl.template.tail_level, digits = 4)), τ $(result_tmpl.template.tail_tau), $(result_tmpl.noise.n_noise) noise traces for detector $det ($ch)"

        @process_step "template plots" begin
            for plot_type in (:pulse, :tail, :noise, :noise_samples, :amplitude)
                p = LegendMakie.lplot(report_tmpl, plot_type = plot_type,
                                      title = get_plottitle(filekey, det, "Template"; additional_type = string(plot_type)))
                save_plot(p, l200, filekey, det, Symbol("template_$(plot_type)"))
            end
        end

        @debug_plot @process_step "template debug plots" begin
            for plot_type in (:heatmap, :heatmap_norm, :residual)
                p = LegendMakie.lplot(report_tmpl, plot_type = plot_type,
                                      title = get_plottitle(filekey, det, "Template"; additional_type = string(plot_type)))
                save_plot(p, l200, filekey, det, Symbol("template_$(plot_type)"))
            end
        end

        result_kern, report_kern = @process_step "kernel" begin
            @debug "Design the inverse kernel"
            fit_sipm_kernel(result_tmpl.template, result_tmpl.noise; target_fwhm = kernel_config_det.target_fwhm,
                            tail_start_n_sigma = kernel_config_det.tail_start_n_sigma, tail_end = kernel_config_det.tail_end,
                            tail_max = kernel_config_det.tail_max, lambda_range = Tuple(kernel_config_det.lambda_range),
                            n_lambda = kernel_config_det.n_lambda, kernel_half_length = kernel_config_det.kernel_half_length,
                            trigger_shaping = template_config_det.trigger.mwa_window, pulses = dsp_tmpl.pulse[dsp_tmpl.is_single])
        end
        result_kern.truncation_ok ||
            @warn "Kernel of $det ($ch) cut to ±$(result_kern.half_length) exceeds the tail limit: $(round(result_kern.tail_local, sigdigits = 2)) local, $(round(result_kern.tail_integral, sigdigits = 2)) integral"
        @debug "Kernel λ $(round(result_kern.lambda, sigdigits = 3)), noise $(round(result_kern.noise_per_sample, sigdigits = 3)) of the target peak per sample for detector $det ($ch)"

        @process_step "kernel plots" begin
            for plot_type in (:lambda, :response, :spectrum, :filtered, :pulses)
                p = LegendMakie.lplot(report_kern, plot_type = plot_type,
                                      title = get_plottitle(filekey, det, "Kernel"; additional_type = string(plot_type)))
                save_plot(p, l200, filekey, det, Symbol("kernel_$(plot_type)"))
            end
        end

        @debug_plot @process_step "kernel debug plots" begin
            p = LegendMakie.lplot(report_kern, plot_type = :taps, title = get_plottitle(filekey, det, "Kernel"; additional_type = "taps"))
            save_plot(p, l200, filekey, det, :kernel_taps)
        end

        log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), length(wvfs_det), n_single, result_tmpl.noise.n_noise,
                           result_tmpl.noise.μ, result_tmpl.noise.σ, result_tmpl.template.tail_tau,
                           result_kern.lambda, max(result_kern.tail_local, result_kern.tail_integral), "-"))

        # call garbage collector
        GC.gc()
        yield()

        return (result = merge(result_tmpl, (kernel = result_kern,)), log = log_info, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_template = parallel(det_sipm_template, chinfo, log_nt; timeout = timeout, retry = false,
                                    process_name = "$period-$run-process_sipm_template_phy")
    @info "Finished SiPM template extraction"

    pars_db = create_pars(pars_db, result_sipm_template)
    write_pars(l200.par.rpars.sipmtmpl[period], run, pars_db)
    write_validity(l200.par.rpars.sipmtmpl, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_sipm_template)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_template_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_template))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :sipm_template_phy), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_sipm_template_phy)
