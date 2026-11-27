"""
    process_sipm_template_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Build the pulse template and the deconvolution kernel of the SiPM channels (`spms`) of one run from `phy` data.

For each processable SiPM, four steps of LegendDSP run in turn on `max_wvfs` random waveforms of the run:
`dsp_sipm_pulse_selection_compressed` selects the isolated pulses and the noise traces, `dsp_sipm_template` builds
the template from the isolated pulses, `dsp_sipm_noise_spectrum` the noise spectrum from the noise traces, and
`dsp_sipm_kernel` the kernel that turns a pulse of the shape of the template into a narrow Gaussian whose area is
the pulse height. Nothing is calibrated, all values are in ADC.

# Inputs
- `raw` tier of the `phy` filekeys of the run listed in the runinfo (excluding filekeys marked `unprocessable`),
  fields `waveform_bit_drop` and `timestamp`; `max_wvfs` of them drawn at random and selected by timestamp before reading.
- `jlaux` tier field `aux_trig_intime` of the pulser channel named by `dataprod_config(l200).qc(filekey).pulser.puls_detector`;
  the in-time pulser events are excluded row by row (the `phy` tiers are event aligned).
- `dataprod_config(l200).sipm(filekey).template`: the `default` section merged with the per-detector
  section (`max_wvfs` and the settings of `dsp_sipm_pulse_selection_compressed`, `dsp_sipm_template` and
  `dsp_sipm_noise_spectrum`).
- `dataprod_config(l200).sipm(filekey).kernel`: the `default` section merged with the per-detector section
  (the settings of `dsp_sipm_kernel`).
- `l200.par.rpars.sipmtmpl[period, run]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.rpars.sipmtmpl[period, run]`: per detector the `template` (`pulse` with height 1, `n_samples`, `n_pretrigger`,
  `dt`, `peak`, `n_pulses`, `tail_tau`, `tail_level`) and the `kernel` (`coeffs`, `n_samples`, `dt`, `lambda`,
  `tail_deviation`, `tail_sum`, `noise_out`, `target_fwhm`); the validity entry is written for `(period, run)`.
- Plots per detector: `isolated_pulses`, `template`, `kernel_response` and `kernel_spectrum`; at the debug plot level also
  `noise_traces`, `template_tail` and `kernel_coeffs`.
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
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("N wvfs"), Symbol("N single"), Symbol("N noise"), Symbol("Tail τ"), :λ,
                         Symbol("Kernel tail"), Symbol("Kernel noise"), :Error)}

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

        max_wvfs = template_config_det.max_wvfs

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, skip"
            log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "-", pars_db[det].template.n_pulses, "-",
                               pars_db[det].template.tail_tau, pars_db[det].kernel.lambda,
                               max(pars_db[det].kernel.tail_deviation, pars_db[det].kernel.tail_sum), pars_db[det].kernel.noise_out,
                               "Already processed --> skipped."))
            return (processed = false, log = log_info)
        end

        # load data
        wvfs_det = @process_step "data loader" begin
            @debug "Loading SiPM data from $(period)-$(run), $max_wvfs random events"
            # The events are selected by timestamp before reading, so only the selected waveforms are loaded from disk.
            ts = read_ldata(ljl_propfunc("timestamp"), l200, DataTier(:raw), filekeys, det;
                            filterby = :jlaux => ljl_propfunc("!$det_puls.aux_trig_intime"))
            ts_sel = Set(sample(ts, min(max_wvfs, length(ts)); replace = false))
            read_ldata(:waveform_bit_drop, l200, DataTier(:raw), filekeys, det; filterby = @pf $timestamp in ts_sel).waveform_bit_drop[:]
        end

        dsp_sel = @process_step "pulse selection" begin
            @debug "Trigger, isolated pulses and noise traces"
            dsp_sipm_pulse_selection_compressed(10000, wvfs_det, template_config_det)
        end
        dt = step(first(wvfs_det).time)

        template = @process_step "template" begin
            @debug "Build the template"
            dsp_sipm_template(dsp_sel, dt, template_config_det)
        end
        @debug "Template from $(template.n_pulses) isolated pulses of $(length(wvfs_det)) waveforms, tail τ $(template.tail_tau) for detector $det ($ch)"

        @process_step "isolated pulses plot" begin
            p = LegendMakie.lplot((pulses = stack(dsp_sel.pulse[dsp_sel.is_single]), n_pretrigger = template.n_pretrigger, dt = dt),
                                  title = get_plottitle(filekey, det, "Isolated Pulses"))
            save_plot(p, l200, filekey, det, :isolated_pulses)
        end

        @process_step "template plot" begin
            p = LegendMakie.lplot((pulses = stack(dsp_sel.pulse[template.is_pulse]), trig_amp = dsp_sel.trig_amp[template.is_pulse],
                                   peak = template.peak, pulse = template.pulse, n_pretrigger = template.n_pretrigger, dt = dt),
                                  title = get_plottitle(filekey, det, "Template"))
            save_plot(p, l200, filekey, det, :template)
        end

        @debug_plot @process_step "template tail plot" begin
            p = LegendMakie.lplot((; template.pulse, template.tail_tau, template.tail_level,
                                   tail_fit_window = template_config_det.tail_fit_window, template.n_pretrigger, template.dt),
                                  title = get_plottitle(filekey, det, "Template Tail"))
            save_plot(p, l200, filekey, det, :template_tail)
        end

        noise = @process_step "noise spectrum" begin
            @debug "Build the noise spectrum"
            dsp_sipm_noise_spectrum(dsp_sel, dt, template_config_det)
        end

        @debug_plot @process_step "noise traces plot" begin
            p = LegendMakie.lplot((traces = stack(dsp_sel.noise[noise.is_trace]), dt = dt),
                                  title = get_plottitle(filekey, det, "Noise Traces"))
            save_plot(p, l200, filekey, det, :noise_traces)
        end

        kernel = @process_step "kernel" begin
            @debug "Build the kernel"
            dsp_sipm_kernel(template, noise, kernel_config_det)
        end
        @debug "Kernel λ $(round(kernel.lambda, sigdigits = 3)), tail deviation $(round(kernel.tail_deviation, sigdigits = 2)), noise $(round(kernel.noise_out, sigdigits = 3)) ADC for detector $det ($ch)"

        @process_step "kernel response plot" begin
            p = LegendMakie.lplot((; kernel.template, kernel.target, kernel.response, kernel.tail, kernel.scan, kernel.lambda,
                                   tail_max = kernel_config_det.tail_max, template.n_pretrigger, kernel.dt),
                                  figsize = (600, 800), title = get_plottitle(filekey, det, "Kernel Response"))
            save_plot(p, l200, filekey, det, :kernel_response)
        end

        @process_step "kernel spectrum plot" begin
            p = LegendMakie.lplot(merge(kernel.spectrum, (; kernel.lambda)),
                                  figsize = (600, 600), title = get_plottitle(filekey, det, "Kernel Spectrum"))
            save_plot(p, l200, filekey, det, :kernel_spectrum)
        end

        @debug_plot @process_step "kernel coefficients plot" begin
            p = LegendMakie.lplot((; kernel.coeffs, kernel.n_samples, kernel.dt),
                                  figsize = (600, 600), title = get_plottitle(filekey, det, "Kernel Coefficients"))
            save_plot(p, l200, filekey, det, :kernel_coeffs)
        end

        result = (template = (; template.pulse, template.n_samples, template.n_pretrigger, template.dt, template.peak, template.n_pulses,
                              template.tail_tau, template.tail_level),
                  kernel = (; kernel.coeffs, kernel.n_samples, kernel.dt, kernel.lambda, kernel.tail_deviation, kernel.tail_sum,
                            kernel.noise_out, kernel.target_fwhm))

        log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), length(wvfs_det), template.n_pulses,
                           noise.n_traces, template.tail_tau, kernel.lambda, max(kernel.tail_deviation, kernel.tail_sum),
                           kernel.noise_out, "-"))

        # call garbage collector
        GC.gc()
        yield()

        return (result = result, log = log_info, processed = true)
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
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_sipm_template_phy, result_sipm_template)]))
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
