"""
    p_process_lq_calibration_cut_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Calibrate LQ and generate the LQ cut for every detector and `cal` partition that contains `period`.

This is the partition-level counterpart of [`process_lq_calibration_cut_cal`](@ref): the `cal` data of all runs in a
detector's partition are combined, and the drift time correction, normalization, cut and survival fractions are
computed once per detector and partition. Detectors with `lq_status` of `:valid` or `:present` are processed.

# Inputs
- `l200.par.rpars.ecal[period, run]` of every run in the partition: the calibration function of the energy type `e_type`.
- `l200.par.ppars.ecal[det, part]`: the DEP resolution from the `Tl208DEP` peak fit of the same energy type.
- `jlqcs` tier (single pulse, non-pulser events) and `jldsp` tier of all `cal` runs in the partition.
- `dataprod_config(l200).psd(filekey).lq` of the first run of the partition, `p_default` merged with `p[det]`, with
  the same entries as described for `process_lq_calibration_cut_cal`.

# Outputs
- `l200.par.ppars.lq[det, part]`: per LQ type the drift time correction and normalization results, and per classifier
  `highcut`, `peaks` and `qbb`, plus the validity of `ppars.lq` for `period`.
- Plots per detector and partition: `lq_ctc_DEP_<type>`, `lq_ctc_<type>`, `lq_dep_normalization_<type>`,
  `lq_sidebands_<type>`, `lq_sideband_position_<type>`, `lq_classalized_<classifier>` and
  `lq_energy_after_<classifier>`. Only `lq_classalized_<classifier>` is saved below the debug plot level.
- If `error_plots` is on, a failed drift time correction saves `error_drift_time_correction_<type>`, a failed LQ normalization `error_lq_normalization_<type>` and a failed peak survival fraction step `error_peak_survival_fractions_<classifier>`.
- Partition report `lq_calibration_cut` with the processing status, a metadata table, and one row per detector,
  partition and LQ type.

# Keywords
- `reprocess`: Discard the existing `ppars.lq` parameters of each detector and partition and process all LQ types
  and classifiers again.
- `timeout`: Seconds allowed per detector and partition in `parallel`; `0` means no limit.
- `only_first_period`: If `true`, a detector whose partition starts in an earlier period is skipped and logged as
  skipped. `run_processing` sets it to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`. `run_processing` uses
this to wait for the same step in the previous period.
"""
function p_process_lq_calibration_cut_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false,
                                          timeout::Real = 0, only_first_period::Bool = true)
    @info "Generate lq cut for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :cal; system = :geds, only_processable = true, explode_partitions = true) |>
                      filterby(@pf $lq_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Classifier Type"), Symbol("DT Corr. Type"),
                             Symbol("Correction Slope"), :CalError)}
    log_nt_cut = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Classifier Type"), Symbol("High Cut"), Symbol("DEP SF"),
                             Symbol("CC SF"), :CutError)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_lq_cut(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        make_par_dir(joinpath(data_path(l200.par.ppars.lq), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.lq), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.lq[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.lq), "$det"))
            PropDict()
        end

        pars_energy = get_values(l200.par.ppars.ecal[det, part])
        @debug "Loaded energy calibration parameters"

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        # load lq config
        lq_config = dataprod_config(l200).psd(filekey_det).lq
        lq_config_det = merge(lq_config.p_default, get(lq_config.p, det, PropDict()))
        @debug "Loaded lq config: $(lq_config_det)"

        e_type = Symbol(lq_config_det.e_type)
        lq_funcs = lq_config_det.lq_funcs
        lq_types = collect(keys(lq_funcs))
        lq_classifiers = [Symbol("$(lq_type)_classifier") for lq_type in lq_types]
        qdrift_expression = lq_config_det.qdrift_expression

        #for lq_ctc_correction
        dep_µ = lq_config_det.dep_mu
        ctc_dep_edgesigma = lq_config_det.ctc_dep_edgesigma
        ctc_lq_precut_relative_cut = lq_config_det.ctc_lq_precut_relative_cut
        ctc_driftime_cutoff_method = Symbol(lq_config_det.ctc_driftime_cutoff_method)
        lq_outlier_sigma = lq_config_det.lq_outlier_sigma
        dt_eff_outlier_sigma = lq_config_det.dt_eff_outlier_sigma
        ctc_dt_eff_low_quantile = lq_config_det.ctc_dt_eff_low_quantile
        ctc_dt_eff_high_quantile = lq_config_det.ctc_dt_eff_high_quantile
        pol_fit_order = lq_config_det.pol_fit_order
        ctc_uncertainty = lq_config_det.ctc_uncertainty

        #for lq_norm
        dep_sideband_sigma = lq_config_det.dep_sideband_sigma
        cut_truncation_sigma = lq_config_det.cut_truncation_sigma
        cut_uncertainty = lq_config_det.cut_uncertainty

        #for get_peaks_survival_fractions
        high_cut_sigma = lq_config_det.high_cut_sigma
        lq_peaks_names = Symbol.(lq_config_det.lq_peaks_names)
        lq_peaks = lq_config_det.lq_peaks
        lq_peaks_windows_left = lq_config_det.lq_peaks_windows_left
        lq_peaks_windows_right = lq_config_det.lq_peaks_windows_right
        lq_peaks_fit_funcs = Symbol.(lq_config_det.lq_peaks_fit_funcs)
        qbb_pos = lq_config_det.qbb
        qbb_window = lq_config_det.qbb_window

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for lq_type in lq_types
                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), part, process_skipped, lq_type, fill("-", 2)...,
                                       "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[lq_type] = log_info
                processed_dict[lq_type] = false
            end
            for lq_classifier in lq_classifiers
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, process_skipped, lq_classifier, fill("-", 3)...,
                                       "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[lq_classifier] = log_info
                processed_dict[lq_classifier] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing lq_classifiers"
            for lq_type in lq_types
                if haskey(pars_db_det[det], lq_type)
                    log_det = log_nt_cal((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), lq_type,
                                          ctc_driftime_cutoff_method, pars_db_det[det][lq_type].drift_result.fit_result.par[1],
                                          "Already processed --> skipped."))
                    processed_dict[lq_type] = false
                    log_info_dict[lq_type] = log_det
                end
            end
            for lq_classifier in lq_classifiers
                if haskey(pars_db_det[det], lq_classifier)
                    log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), lq_classifier,
                                           pars_db_det[det][lq_classifier].highcut, pars_db_det[det][lq_classifier].peaks[:Tl208DEP].sf,
                                           pars_db_det[det][lq_classifier].qbb.sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[lq_classifier] = log_info
                    processed_dict[lq_classifier] = false
                end
            end
        end

        hit_cal, e_cal, dep_σ = @process_step "data loader" begin
            @debug("Load data")
            if !all([haskey(processed_dict, lq_type) for lq_type in lq_types]) ||
               !all([haskey(processed_dict, lq_classifier) for lq_classifier in lq_classifiers])
                hit_cal = read_hit_cal(l200, det, zip(partinfo_det.period, partinfo_det.run), e_type,
                                       vcat(collect(values(lq_funcs)), [qdrift_expression]))
                e_cal = collect(getproperty(hit_cal, e_type))
                dep_σ = mvalue(pars_energy[det][Symbol(first(split(string(e_type), "_cal")))].fit.Tl208DEP.fwhm / (2 * sqrt(2 * log(2))))
                hit_cal, e_cal, dep_σ
            else
                nothing, nothing, nothing
            end
        end

        @debug_progress "Detector: $det" for lq_type in lq_types
            if haskey(processed_dict, lq_type)
                continue
            end
            try
                @debug "Calculate energy corrected and normalized lq and effective drift time"
                lq_e_corr, dt_eff, mean_lq, std_lq, median_lq, lq_e_corr_expression, dt_eff_expression = @process_step "$lq_type energy correction and normalization" begin
                    lq_e_corr = ljl_propfunc(lq_funcs[lq_type]).(hit_cal)
                    dt_eff = ljl_propfunc(qdrift_expression).(hit_cal)

                    mean_lq = mean(filter(isfinite, lq_e_corr))
                    std_lq = std(filter(isfinite, lq_e_corr))
                    median_lq = median(filter(isfinite, lq_e_corr))

                    # pre normalization
                    cuts_lq = cut_single_peak(lq_e_corr, 0.0, quantile(filter(isfinite, lq_e_corr), 0.99); n_bins = -1)
                    lq_e_corr ./= cuts_lq.max

                    lq_e_corr_expression = "( $(lq_funcs[lq_type]) ) / $(cuts_lq.max)"
                    lq_e_corr, dt_eff, mean_lq, std_lq, median_lq, lq_e_corr_expression, qdrift_expression
                end

                @debug "Drift time correction of $lq_type"
                plot_lq_drift_time() = begin
                    local fig, ax
                    in_dep = dep_µ - ctc_dep_edgesigma * dep_σ .< e_cal .< dep_µ + ctc_dep_edgesigma * dep_σ
                    dt = ustrip.(dt_eff[in_dep])
                    lq = ustrip.(lq_e_corr[in_dep])
                    ok = isfinite.(dt) .&& isfinite.(lq)
                    h = fit(Histogram, (dt[ok], lq[ok]),
                            (range(quantile(dt[ok], [0.001, 0.999])...; length = 101),
                             range(quantile(lq[ok], [0.001, 0.999])...; length = 101)))
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey_det, part, det, "LQ Drift Time"; additional_type = string(lq_type)),
                                    xlabel = "Effective drift time", ylabel = "LQ")
                    Makie.heatmap!(ax, h.edges[1], h.edges[2], replace(float.(h.weights), 0.0 => NaN); colorscale = log10)
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_drift_time_correction_$lq_type"))
                end
                drift_result, drift_report = @process_step "$lq_type drift time correction" on_error = plot_lq_drift_time begin
                    lq_ctc_correction(lq_e_corr, dt_eff, e_cal, dep_µ, dep_σ; ctc_dep_edgesigma, ctc_lq_precut_relative_cut,
                                      lq_outlier_sigma, ctc_driftime_cutoff_method, dt_eff_outlier_sigma, lq_e_corr_expression,
                                      dt_eff_expression, ctc_dt_eff_low_quantile, ctc_dt_eff_high_quantile, pol_fit_order,
                                      uncertainty = ctc_uncertainty)
                end

                # create and save plots
                @debug_plot @process_step "$lq_type DEP drift time correlation plot" begin
                    p = LegendMakie.lplot(drift_report, e_cal, dt_eff, lq_e_corr, :DEP,
                                          title = "Drift Time vs LQ in DEP for Detector: $det", figsize = (620, 400))
                    save_plot(p, l200, part, filekey_det, det, Symbol("lq_ctc_DEP_$lq_type"))
                end

                @debug_plot @process_step "$lq_type drift time correlation plot" begin
                    p = LegendMakie.lplot(drift_report, e_cal, dt_eff, lq_e_corr, :whole, title = "Drift Time vs LQ for Detector: $det",
                                          figsize = (620, 400))
                    save_plot(p, l200, part, filekey_det, det, Symbol("lq_ctc_$lq_type"))
                end

                # create lq normalization
                lq_class_expression = drift_result.func
                plot_lq_sidebands() = begin
                    local fig, ax
                    lq = ljl_propfunc(lq_class_expression).(hit_cal)
                    dep_left = dep_µ - dep_sideband_sigma * dep_σ
                    dep_right = dep_µ + dep_sideband_sigma * dep_σ
                    windows = if dep_σ < 2.0u"keV"
                        ["DEP" => (dep_left, dep_right), "lower sideband" => (dep_µ - 2 * dep_sideband_sigma * dep_σ, dep_left),
                         "upper sideband" => (dep_right, dep_µ + 2 * dep_sideband_sigma * dep_σ)]
                    else
                        ["DEP" => (dep_left, dep_right), "sideband 1" => (dep_µ - 2 * dep_sideband_sigma * dep_σ, dep_left),
                         "sideband 2" => (dep_µ - 3 * dep_sideband_sigma * dep_σ, dep_µ - 2 * dep_sideband_sigma * dep_σ)]
                    end
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey_det, part, det, "LQ DEP and Sidebands";
                                                          additional_type = string(lq_type)), xlabel = "LQ", ylabel = "Counts")
                    for (name, (lo, hi)) in windows
                        Makie.stephist!(ax, filter(isfinite, ustrip.(lq[lo .< e_cal .< hi])); bins = 100, label = name)
                    end
                    Makie.axislegend(ax)
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_lq_normalization_$lq_type"))
                end
                lq_ctc, result, report = @process_step "$lq_type LQ normalization" on_error = plot_lq_sidebands begin
                    lq_ctc = ljl_propfunc(lq_class_expression).(hit_cal)

                    result, report = lq_norm(dep_µ, dep_σ, e_cal, lq_ctc; dep_sideband_sigma, cut_truncation_sigma,
                                             uncertainty = cut_uncertainty, lq_class_expression)
                    lq_ctc, result, report
                end

                # create and save plots
                @debug_plot @process_step "$lq_type DEP normalization plot" begin
                    p = LegendMakie.lplot(report.fit_report, xlabel = Makie.rich("LQ", Makie.subscript(" ctc")), digits = 3,
                                          figsize = (600, 450), legend_position = :none,
                                          title = get_plottitle(filekey_det, part, det, "LQ DEP fit", additional_type = string(lq_type)))
                    Makie.axislegend(position = :lt)
                    save_plot(p, l200, part, filekey_det, det, Symbol("lq_dep_normalization_$lq_type"))
                end

                @debug_plot @process_step "$lq_type sidebands plot" begin
                    p = LegendMakie.lplot(report.temp_hists,
                                          title = get_plottitle(filekey_det, part, det, "LQ sidebands", additional_type = string(lq_type)),
                                          xlims = (StatsBase.quantile.(Ref(filter(isfinite, lq_ctc)), (0.05, 0.95))))
                    save_plot(p, l200, part, filekey_det, det, Symbol("lq_sidebands_$lq_type"))
                end

                @debug_plot @process_step "$lq_type sideband position plot" begin
                    p = LegendMakie.lplot((; e_cal, edges = report.edges, dep_σ = report.dep_σ),
                                          title = get_plottitle(filekey_det, part, det, "LQ side bands", additional_type = string(lq_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("lq_sideband_position_$lq_type"))
                end

                # create log entry
                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), lq_type,
                                       ctc_driftime_cutoff_method, drift_result.fit_result.par[1], "-"))

                # add results to dict
                result_dict[lq_type] = merge(result,
                                             (drift_result = drift_result, mean_lq = mean_lq, std_lq = std_lq, median_lq = median_lq))
                log_info_dict[lq_type] = log_info
                processed_dict[lq_type] = true

                # free memory
                GC.gc()
            catch e
                # a failed `@process_step` has logged its error already
                e isa ProcessStepError || @error "$lq_type calibration failed for $det: $(truncate_error(e))"
                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), lq_type, "-", "-",
                                       truncate_error(e)))

                # add results to dict
                log_info_dict[lq_type] = log_info
                processed_dict[lq_type] = false
            end
        end

        @debug "LQ calibration for detector $det ($ch) finished"

        # add lq constructor results to pars_db
        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_lq_cons = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)
        pars_db_det = create_pars(pars_db_det, result_lq_cons)

        # continue with lq cut
        @debug_progress "Detector: $det" for lq_classifier in lq_classifiers
            if haskey(processed_dict, lq_classifier)
                continue
            end
            try
                @debug "Generate lq cut"

                # get lq classifier and lq classifier expression
                lq_class = @process_step "$lq_classifier classifier loading" begin
                    norm_func = pars_db_det[det][Symbol(first(split(string(lq_classifier), "_classifier")))].func
                    ljl_propfunc(norm_func).(hit_cal)
                end

                # create and save plots
                @process_step "$lq_classifier classified LQ plot" begin
                    sel = isfinite.(e_cal)
                    p = LegendMakie.lhist(StatsBase.fit(StatsBase.Histogram, (Unitful.ustrip.(e_cal)[sel], lq_class[sel]),
                                                        (0:1:3000, range(-5.5, 9.5, length = 200))),
                                          title = get_plottitle(filekey_det, part, det, "LQ"), figsize = (620, 400), watermark = false,
                                          xlabel = "Energy (keV)", ylabel = Makie.rich("LQ", Makie.subscript(" norm")),
                                          limits = (0, 3000, -5.5, 9.5))
                    Makie.hlines!([high_cut_sigma], color = LegendMakie.CoaxGreen, label = "LQ cut", linewidth = 4)
                    Makie.axislegend(position = :rb)
                    LegendMakie.add_watermarks!(position = "outer top", final = true)
                    save_plot(p, l200, part, filekey_det, det, Symbol("lq_classalized_$lq_classifier"))
                end

                @debug_plot @process_step "$lq_classifier performance plot" begin
                    p = LegendMakie.lplot((; e_cal, lq_class, cut_value = high_cut_sigma), figsize = (750, 400),
                                          title = get_plottitle(filekey_det, part, det, "LQ Performance",
                                                                additional_type = string(lq_classifier)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("lq_energy_after_$lq_classifier"))
                end

                @debug("Generate Survival Fractions for LQ")

                plot_lq_peak_survival() = begin
                    local fig, ax
                    x = ustrip.(e_cal)
                    fig = Makie.Figure(size = (900, 300 * cld(length(lq_peaks), 2)))
                    Makie.Label(fig[0, 1:2],
                                get_plottitle(filekey_det, part, det, "LQ Survival Fractions"; additional_type = string(lq_classifier)))
                    for (i, peak) in pairs(lq_peaks)
                        lo = ustrip(unit(first(e_cal)), peak - lq_peaks_windows_left[i])
                        hi = ustrip(unit(first(e_cal)), peak + lq_peaks_windows_right[i])
                        in_peak = lo .< x .< hi
                        ax = Makie.Axis(fig[cld(i, 2), mod1(i, 2)]; title = string(lq_peaks_names[i]),
                                        xlabel = "Energy ($(unit(first(e_cal))))", ylabel = "Counts")
                        Makie.stephist!(ax, x[in_peak]; bins = range(lo, hi; length = 51), label = "all")
                        Makie.stephist!(ax, x[in_peak .&& (lq_class .< high_cut_sigma)]; bins = range(lo, hi; length = 51),
                                        label = "LQ < cut")
                        i == 1 && Makie.axislegend(ax)
                    end
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_peak_survival_fractions_$lq_classifier"))
                end
                result_peaks, report_peaks = @process_step "$lq_classifier peak survival fraction calculation" on_error = plot_lq_peak_survival begin
                    get_peaks_survival_fractions(lq_class, e_cal, lq_peaks, lq_peaks_names, lq_peaks_windows_left, lq_peaks_windows_right;
                                                 high_cut = high_cut_sigma, fit_funcs = lq_peaks_fit_funcs)
                end

                result_qbb, report_qbb = @process_step "$lq_classifier qbb survival fraction calculation" begin
                    get_continuum_survival_fraction(lq_class, e_cal, qbb_pos, qbb_window; high_cut = high_cut_sigma)
                end

                # save results
                final_result = (highcut = high_cut_sigma, peaks = result_peaks, qbb = result_qbb)

                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), lq_classifier,
                                       final_result.highcut, final_result.peaks[:Tl208DEP].sf, final_result.qbb.sf, "-"))

                # add results to dict
                result_dict[lq_classifier] = final_result
                log_info_dict[lq_classifier] = log_info
                processed_dict[lq_classifier] = true

                GC.gc()
            catch e
                # a failed `@process_step` has logged its error already
                e isa ProcessStepError || @error "lq cut generation of $lq_classifier failed for $det: $(truncate_error(e))"
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), lq_classifier, "-", "-", "-",
                                       truncate_error(e)))

                # add results to dict
                log_info_dict[lq_classifier] = log_info
                processed_dict[lq_classifier] = false
            end
        end
        # cleanup log and combine
        log_info_dict_cleaned = Dict{Symbol,NamedTuple}()
        for lq_type in lq_types
            log_info_dict_cleaned[lq_type] = merge(log_info_dict[lq_type], log_info_dict[Symbol("$(string(lq_type))_classifier")])
        end
        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict_cleaned, validity = validity_det)
        result_lq_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_lq_det)
        write_pars(l200.par.ppars.lq[det], part, pars_db_det)
        write_validity(l200.par.ppars.lq[det], filekey_det, part)

        return result_det
    end

    # get start time
    start_time = now()

    result_lq = parallel(det_lq_cut, chinfo_unfolded, merge(log_nt_cal, log_nt_cut); timeout = timeout, retry = false,
                         process_name = "$period-p_process_lq_calibration_cut_cal")
    @info "Finished lq cut generation"

    @info "Write $period validity"
    validity_all = create_validity(result_lq)
    write_validity(l200.par.ppars.lq, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_lq)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, lq_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_lq))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :lq_calibration_cut), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_lq))
end

register_processor!(p_process_lq_calibration_cut_cal)
