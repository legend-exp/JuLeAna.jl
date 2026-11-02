"""
    p_process_sipm_template_phy(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Extract the single-photon pulse template and the noise spectrum of the SiPM channels (`spms`) per partition
from `phy` data and design their inverse kernel, for all partitions that contain `period`.

The method is the same as in `process_sipm_template_phy`, but the waveforms of all runs of a
detector's partition are used and the results are valid for the whole partition.

# Inputs
- `raw` tier of the `phy` filekeys listed in the runinfo for all runs of each detector's partition (excluding filekeys
  marked `unprocessable`), fields `waveform_bit_drop` and `timestamp`; `max_wvfs` of them drawn at random and selected by timestamp before reading.
- `jlaux` tier fields `timestamp` and `aux_trig` of the pulser channel named by `dataprod_config(l200).qc(filekey).pulser.puls_detector`;
  waveforms within `puls_ts_window` of a pulser trigger are excluded.
- `dataprod_config(l200).sipm(filekey).template`: `p_default` merged with `p[det]` (`max_wvfs`,
  `trigger`, `window`, `n_σ_baseline`, `n_σ_noise`, `max_noise_wvfs`, `target_fwhm`, `tail_fit_window`, `min_pulses`,
  `min_noise_traces`).
- `dataprod_config(l200).sipm(filekey).kernel`: `p_default` merged with `p[det]` (`target_fwhm`, `tail_start_n_sigma`,
  `tail_end`, `tail_max`, `lambda_range`, `n_lambda`, `kernel_half_length`).
- `l200.par.ppars.sipmtmpl[det, part]` (existing results, unless `reprocess` is set).

# Outputs
- `l200.par.ppars.sipmtmpl[det, part]`: the `template` (`t0`, `dt`, `pulse`, `amplitude` in ADC, `n_pulses`, `tail_level`,
  `tail_tau`, `baseline_σ` in ADC), the `noise` spectrum (`df`, `psd` in ADC²/Hz, `n_noise`, Gaussian `μ`, `σ` in ADC) and the `kernel`
  (`lambda`, `half_length`, `dt`, `taps`, `target_fwhm`, `tail_local`, `tail_integral`, `fwhm`, `noise_per_sample`, `noise_shaped`, `trigger_shaping`,
  `response_sum`, `truncation_ok`), written for each detector as soon as it is finished; the validity of all
  partitions is written once at the end.
- Plots per detector and partition: `template_pulse` (template and target stick), `template_tail` (template on a
  log scale with the tail fit window and the continuation), `template_noise` (noise spectrum), `template_noise_samples` (noise samples against a Gaussian) and
  `template_amplitude` (pulse maxima), `kernel_lambda`, `kernel_response`, `kernel_spectrum`, `kernel_filtered` and
  `kernel_pulses`; at the debug plot level also `template_heatmap`, `template_heatmap_norm`, `template_residual` and `kernel_taps`.
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
                         Symbol("Noise μ"), Symbol("Noise σ"), Symbol("Tail τ"), :λ, Symbol("Kernel tail"), :Error)}

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
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        @debug "Loaded pulser config: $(lstring(pulser_config_det))"

        # get pulser detector information
        chinfo_puls = channelinfo(l200, filekey_det, Symbol(qc_config.pulser.puls_detector))
        @info "Loaded pulser channel info: $(chinfo_puls)"

        det_puls = chinfo_puls.detector

        max_wvfs = template_config_det.max_wvfs

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            log_info = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, fill("-", 8)...,
                               "Only first periods --> skipped."))
            return (processed = false, log = log_info, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, skip"
            log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), "-", pars_db_det[det].template.n_pulses,
                               pars_db_det[det].noise.n_noise, pars_db_det[det].noise.μ, pars_db_det[det].noise.σ, pars_db_det[det].template.tail_tau,
                               pars_db_det[det].kernel.lambda, max(pars_db_det[det].kernel.tail_local, pars_db_det[det].kernel.tail_integral),
                               "Already processed --> skipped."))
            return (processed = false, log = log_info, validity = validity_det)
        end

        # load data
        data_det = @process_step "data loader" begin
            @debug "Loading SiPM data from $(part), $max_wvfs random events"
            # The events are selected by timestamp before reading, so only the selected waveforms are loaded from disk.
            ts = read_ldata(ljl_propfunc("timestamp"), l200, DataTier(:raw), filekeys, det)
            ts_sel = Set(sample(ts, min(max_wvfs, length(ts)); replace = false))
            read_ldata((:waveform_bit_drop, :timestamp), l200, DataTier(:raw), filekeys, det; filterby = @pf $timestamp in ts_sel)
        end

        wvfs_det = @process_step "pulser tag" begin
            @debug "Get Pulser tags"
            data_pulser = read_ldata((:timestamp, :aux_trig), l200, DataTier(:jlaux), :phy, partinfo_det, det_puls)
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
                                      title = get_plottitle(filekey_det, part, det, "Template"; additional_type = string(plot_type)))
                save_plot(p, l200, part, filekey_det, det, Symbol("template_$(plot_type)"))
            end
        end

        @debug_plot @process_step "template debug plots" begin
            for plot_type in (:heatmap, :heatmap_norm, :residual)
                p = LegendMakie.lplot(report_tmpl, plot_type = plot_type,
                                      title = get_plottitle(filekey_det, part, det, "Template"; additional_type = string(plot_type)))
                save_plot(p, l200, part, filekey_det, det, Symbol("template_$(plot_type)"))
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
                                      title = get_plottitle(filekey_det, part, det, "Kernel"; additional_type = string(plot_type)))
                save_plot(p, l200, part, filekey_det, det, Symbol("kernel_$(plot_type)"))
            end
        end

        @debug_plot @process_step "kernel debug plots" begin
            p = LegendMakie.lplot(report_kern, plot_type = :taps, title = get_plottitle(filekey_det, part, det, "Kernel"; additional_type = "taps"))
            save_plot(p, l200, part, filekey_det, det, :kernel_taps)
        end

        log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), length(wvfs_det), n_single,
                           result_tmpl.noise.n_noise, result_tmpl.noise.μ, result_tmpl.noise.σ, result_tmpl.template.tail_tau,
                           result_kern.lambda, max(result_kern.tail_local, result_kern.tail_integral), "-"))

        # call garbage collector
        GC.gc()

        result_det = (result = merge(result_tmpl, (kernel = result_kern,)), processed = true, log = log_info, validity = validity_det)
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
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_sipm_template)]))
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
