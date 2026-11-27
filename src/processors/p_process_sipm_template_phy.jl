"""
    p_process_sipm_template_phy(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Build the pulse template and the deconvolution kernel of the SiPM channels (`spms`) per partition from `phy` data,
for all partitions that contain `period`.

The method is the same as in `process_sipm_template_phy`, but the waveforms of all runs of a
detector's partition are used and the results are valid for the whole partition.

# Inputs
- `raw` tier of the `phy` filekeys listed in the runinfo for all runs of each detector's partition (excluding filekeys
  marked `unprocessable`), fields `waveform_bit_drop` and `timestamp`; `max_wvfs` of them drawn at random and selected by timestamp before reading.
- `jlaux` tier field `aux_trig_intime` of the pulser channel named by `dataprod_config(l200).qc(filekey).pulser.puls_detector`;
  the in-time pulser events are excluded row by row (the `phy` tiers are event aligned).
- `dataprod_config(l200).sipm(filekey).template`: `p_default` merged with `p[det]` (`max_wvfs` and the settings of
  `dsp_sipm_pulse_selection_compressed`, `dsp_sipm_template` and `dsp_sipm_noise_spectrum`).
- `dataprod_config(l200).sipm(filekey).kernel`: `p_default` merged with `p[det]` (the settings of `dsp_sipm_kernel`).
- `l200.par.ppars.sipmtmpl[det, part]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.ppars.sipmtmpl[det, part]`: the `template` (`pulse` with height 1, `n_samples`, `n_pretrigger`, `dt`, `peak`,
  `n_pulses`, `tail_tau`, `tail_level`) and the `kernel` (`coeffs`, `n_samples`, `dt`, `lambda`, `tail_deviation`,
  `tail_sum`, `noise_out`, `target_fwhm`), written for each detector as soon as it is finished; the validity of all
  partitions is written once at the end.
- Plots per detector and partition: `isolated_pulses`, `template`, `kernel_response` and `kernel_spectrum`; at the debug plot
  level also `noise_traces`, `template_tail` and `kernel_coeffs`.
- Partition report `sipm_template_phy`.

# Keywords
- `reprocess`: discard the existing results and extract the templates of all detectors again.
  Otherwise, detectors that already have results are skipped.
- `timeout`: seconds allowed per detector and partition in `parallel` (0 = no limit).
- `only_first_period`: if `true`, skip a detector whose partition starts in an earlier period
  than `period`; it is processed together with that earlier period. `run_processing` sets this
  to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`.
"""
function p_process_sipm_template_phy(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                                     only_first_period::Bool = true)
    @info "Process SiPM template for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :phy; system = :spms, explode_partitions = true) |>
                      detector_filter(processing_config, :p_process_sipm_template_phy)
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("N wvfs"), Symbol("N single"), Symbol("N noise"),
                         Symbol("Tail τ"), :λ, Symbol("Kernel tail"), Symbol("Kernel noise"), :Error)}

    # flush stdout
    flush(stdout)

    # function to process the template of one detector and partition
    function det_sipm_template(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.sipmtmpl), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.sipmtmpl[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.sipmtmpl), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekeys = reduce(vcat,
                          [filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (r.period, r.run, :phy)).keys))
                           for r in partinfo_det])

        filekey_det = first(getproperty(partinfo_det, :phy)).startkey
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        template_config = dataprod_config(l200).sipm(filekey_det).template
        template_config_det = merge(template_config.p_default, get(template_config.p, det, PropDict()))
        @debug "Loaded template config: $(lstring(template_config_det))"

        kernel_config = dataprod_config(l200).sipm(filekey_det).kernel
        kernel_config_det = merge(kernel_config.p_default, get(kernel_config.p, det, PropDict()))
        @debug "Loaded kernel config: $(lstring(kernel_config_det))"

        qc_config = dataprod_config(l200).qc(filekey_det)

        # get pulser detector information
        chinfo_puls = channelinfo(l200, filekey_det, Symbol(qc_config.pulser.puls_detector))
        @info "Loaded pulser channel info: $(chinfo_puls)"

        det_puls = chinfo_puls.detector

        max_wvfs = template_config_det.max_wvfs

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            log_info = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, fill("-", 7)...,
                               "Only first periods --> skipped."))
            return (processed = false, log = log_info, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, skip"
            log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), "-", pars_db_det[det].template.n_pulses,
                               "-", pars_db_det[det].template.tail_tau, pars_db_det[det].kernel.lambda,
                               max(pars_db_det[det].kernel.tail_deviation, pars_db_det[det].kernel.tail_sum),
                               pars_db_det[det].kernel.noise_out, "Already processed --> skipped."))
            return (processed = false, log = log_info, validity = validity_det)
        end

        # load data
        wvfs_det = @process_step "data loader" begin
            @debug "Loading SiPM data from $(part), $max_wvfs random events"
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
                                  title = get_plottitle(filekey_det, part, det, "Isolated Pulses"))
            save_plot(p, l200, part, filekey_det, det, :isolated_pulses)
        end

        @process_step "template plot" begin
            p = LegendMakie.lplot((pulses = stack(dsp_sel.pulse[template.is_pulse]), trig_amp = dsp_sel.trig_amp[template.is_pulse],
                                   peak = template.peak, pulse = template.pulse, n_pretrigger = template.n_pretrigger, dt = dt),
                                  title = get_plottitle(filekey_det, part, det, "Template"))
            save_plot(p, l200, part, filekey_det, det, :template)
        end

        @debug_plot @process_step "template tail plot" begin
            p = LegendMakie.lplot((; template.pulse, template.tail_tau, template.tail_level,
                                   tail_fit_window = template_config_det.tail_fit_window, template.n_pretrigger, template.dt),
                                  title = get_plottitle(filekey_det, part, det, "Template Tail"))
            save_plot(p, l200, part, filekey_det, det, :template_tail)
        end

        noise = @process_step "noise spectrum" begin
            @debug "Build the noise spectrum"
            dsp_sipm_noise_spectrum(dsp_sel, dt, template_config_det)
        end

        @debug_plot @process_step "noise traces plot" begin
            p = LegendMakie.lplot((traces = stack(dsp_sel.noise[noise.is_trace]), dt = dt),
                                  title = get_plottitle(filekey_det, part, det, "Noise Traces"))
            save_plot(p, l200, part, filekey_det, det, :noise_traces)
        end

        kernel = @process_step "kernel" begin
            @debug "Build the kernel"
            dsp_sipm_kernel(template, noise, kernel_config_det)
        end
        @debug "Kernel λ $(round(kernel.lambda, sigdigits = 3)), tail deviation $(round(kernel.tail_deviation, sigdigits = 2)), noise $(round(kernel.noise_out, sigdigits = 3)) ADC for detector $det ($ch)"

        @process_step "kernel response plot" begin
            p = LegendMakie.lplot((; kernel.template, kernel.target, kernel.response, kernel.tail, kernel.scan, kernel.lambda,
                                   tail_max = kernel_config_det.tail_max, template.n_pretrigger, kernel.dt),
                                  figsize = (600, 800), title = get_plottitle(filekey_det, part, det, "Kernel Response"))
            save_plot(p, l200, part, filekey_det, det, :kernel_response)
        end

        @process_step "kernel spectrum plot" begin
            p = LegendMakie.lplot(merge(kernel.spectrum, (; kernel.lambda)),
                                  figsize = (600, 600), title = get_plottitle(filekey_det, part, det, "Kernel Spectrum"))
            save_plot(p, l200, part, filekey_det, det, :kernel_spectrum)
        end

        @debug_plot @process_step "kernel coefficients plot" begin
            p = LegendMakie.lplot((; kernel.coeffs, kernel.n_samples, kernel.dt),
                                  figsize = (600, 600), title = get_plottitle(filekey_det, part, det, "Kernel Coefficients"))
            save_plot(p, l200, part, filekey_det, det, :kernel_coeffs)
        end

        result = (template = (; template.pulse, template.n_samples, template.n_pretrigger, template.dt, template.peak, template.n_pulses,
                              template.tail_tau, template.tail_level),
                  kernel = (; kernel.coeffs, kernel.n_samples, kernel.dt, kernel.lambda, kernel.tail_deviation, kernel.tail_sum,
                            kernel.noise_out, kernel.target_fwhm))

        log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), length(wvfs_det), template.n_pulses,
                           noise.n_traces, template.tail_tau, kernel.lambda, max(kernel.tail_deviation, kernel.tail_sum),
                           kernel.noise_out, "-"))

        # call garbage collector
        GC.gc()

        result_det = (result = result, processed = true, log = log_info, validity = validity_det)
        result_sipm_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_sipm_det)
        write_pars(l200.par.ppars.sipmtmpl[det], part, pars_db_det)
        write_validity(l200.par.ppars.sipmtmpl[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_template = parallel(det_sipm_template, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                                    process_name = "$period-p_process_sipm_template_phy")

    @info "Finished SiPM partition template extraction"

    @info "Write $period validity"
    validity_all = create_validity(result_sipm_template)
    write_validity(l200.par.ppars.sipmtmpl, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :p_process_sipm_template_phy, result_sipm_template)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_template_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_template))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :sipm_template_phy), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_sipm_template))
end

register_processor!(p_process_sipm_template_phy)
