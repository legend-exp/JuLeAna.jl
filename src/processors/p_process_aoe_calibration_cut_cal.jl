"""
    p_process_aoe_calibration_cut_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Calibrate A/E and generate the A/E cuts for every detector and `cal` partition that contains `period`.

This is the partition-level counterpart of [`process_aoe_calibration_cut_cal`](@ref): the `cal` data of all runs in a
detector's partition are combined and the A/E normalization, Compton band fits, optional charge trapping correction
and cut search run once per detector and partition. Detectors with `low_aoe_status` of `:valid` or `:present` are
processed. In addition, the Compton-band A/E is plotted against time over the partition.

# Inputs
- `l200.par.rpars.ecal[period, run]` of every run in the partition: the calibration function of the energy type `e_type`.
- `jlqcs` tier (single pulse, non-pulser events) and `jldsp` tier of all `cal` runs in the partition.
- `dataprod_config(l200).psd(filekey).aoe` of the first run of the partition, `p_default` merged with `p[det]`, with
  the same entries as described for `process_aoe_calibration_cut_cal`.

# Outputs
- `l200.par.ppars.aoe[det, part]`: per A/E type (`func`, `ctc`, `correction`, `apply_ctc`, `use_combined_fit`) and per
  classifier (`lowcut`, `highcut`, `peaks` and `qbb` survival fractions), plus the validity of `ppars.aoe` for
  `period`. The file is written only if the detector has results.
- Plots per detector and partition: `aoe_uncalibrated_<type>`, `aoe_stability_<type>`, `compton_bands_mu_<type>`,
  `compton_bands_sigma_<type>`, `aoe_ctc_<type>` and `aoe_compton_after_ctc_<type>` (if `apply_ctc`),
  `aoe_normalized_<type>`, `aoe_normalized_<classifier>`, `aoe_energy_afterAoE_zoom_<classifier>` and
  `aoe_peaks_sf_<classifier>`. Only `aoe_normalized_<classifier>` is saved below the debug plot level.
- If `error_plots` is on, a failed Compton band fitting saves `error_compton_band_fitting_<type>` and a failed cut generation `error_cut_generation_<classifier>`.
- Partition report `aoe_calibration_cut` with the processing status, a metadata table, and one row per detector,
  partition and A/E type.

# Keywords
- `reprocess`: Discard the existing `ppars.aoe` parameters of each detector and partition and process all A/E types
  and classifiers again. Otherwise, entries that already exist are kept.
- `timeout`: Seconds allowed per detector and partition in `parallel`; `0` means no limit.
- `only_first_period`: If `true`, a detector whose partition starts in an earlier period is skipped and logged as
  skipped. `run_processing` sets it to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`. `run_processing` uses
this to wait for the same step in the previous period.
"""
function p_process_aoe_calibration_cut_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false,
                                           timeout::Real = 0, only_first_period::Bool = true)
    @info "Generate AoE cut for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :cal; system = :geds, only_processable = true, explode_partitions = true) |>
                      filterby(@pf $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Filter Type"), Symbol("N Compt. Bands"),
                             Symbol("Median norm. Resid."), Symbol("StD norm. Resid."), Symbol("FCT"), :CalError)}
    log_nt_cut = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"),
                             Symbol("FEP SF"), :CutError)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_aoe_cut(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        make_par_dir(joinpath(data_path(l200.par.ppars.aoe), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.aoe), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.aoe[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.aoecut), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        # load config
        aoe_config = dataprod_config(l200).psd(filekey_det).aoe
        aoe_config_det = merge(aoe_config.p_default, get(aoe_config.p, det, PropDict()))
        @debug "Loaded aoe config: $(lstring(aoe_config_det))"

        compton_bands = aoe_config_det.compton_bands
        compton_window = aoe_config_det.compton_window
        p_value_cut = aoe_config_det.p_value # what is this? p values threshold 
        e_type = Symbol(aoe_config_det.e_type)
        aoe_funcs = aoe_config_det.aoe_funcs
        aoe_types = collect(keys(aoe_funcs))
        aoe_classifiers = [Symbol("$(aoe_type)_classifier") for aoe_type in aoe_types]
        qdrift_expression = aoe_config_det.qdrift_expression

        # sigma_high_sided = ifelse(chinfo_det.high_aoe_status == :valid, aoe_config_det.sigma_high_sided, Inf)
        sigma_high_sided = aoe_config_det.sigma_high_sided

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for aoe_type in aoe_types
                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), part, process_skipped, aoe_type, fill("-", 4)...,
                                       "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
            for aoe_classifier in aoe_classifiers
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, process_skipped, aoe_classifier, fill("-", 3)...,
                                       "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for aoe_type in aoe_types
                if haskey(pars_db_det[det], aoe_type)
                    pars_db_det_aoe_type = pars_db_det[det][aoe_type]
                    log_info = log_nt_cal((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), aoe_type,
                                           length(pars_db_det_aoe_type.µ_compton.µ),
                                           mean(pars_db_det_aoe_type.µ_compton.gof.residuals_norm),
                                           mean(pars_db_det_aoe_type.σ_compton.gof.residuals_norm),
                                           get(pars_db_det_aoe_type.ctc, :fct, NaN), "Already processed --> skipped."))
                    processed_dict[aoe_type] = false
                    log_info_dict[aoe_type] = log_info
                end
            end
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db_det[det], aoe_classifier)
                    log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), aoe_classifier,
                                           pars_db_det[det][aoe_classifier].lowcut, pars_db_det[det][aoe_classifier].peaks.ds[:Tl208SEP].sf,
                                           pars_db_det[det][aoe_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        # `nothing` if all A/E types and classifiers are already processed
        e_cal, hit_cal, e_unit, ts = @process_step "hit data loading" begin
            if !all([haskey(processed_dict, aoe_type) for aoe_type in aoe_types]) ||
               !all([haskey(processed_dict, aoe_classifier) for aoe_classifier in aoe_classifiers])
                hit_cal = read_hit_cal(l200, det, zip(partinfo_det.period, partinfo_det.run), [e_type],
                                       vcat(collect(values(aoe_funcs)), aoe_config_det.apply_ctc ? [qdrift_expression] : []))
                e_cal = collect(getproperty(hit_cal, e_type))
                e_unit = unit(eltype(e_cal))

                # get timestamps for stability plots
                ts = uconvert.(u"hr", hit_cal.timestamp)
                # correct for gaps in timestamps which correspond to phy runs
                run_idx = findall(diff(ts) .> 6u"hr") .+ 1
                for idx in run_idx
                    ts[idx:end] .-= (ts[idx] - ts[idx - 1])
                end
                # normalize to first timestamp
                ts .-= first(ts)
                e_cal, hit_cal, e_unit, ts
            else
                nothing, nothing, nothing, nothing
            end
        end

        @debug_progress "Detector: $det" for aoe_type in aoe_types
            if haskey(processed_dict, aoe_type)
                continue
            end
            try
                @debug "Calibrate $aoe_type"

                # get data
                aoe, aoe_expression = @process_step "$aoe_type simple normalization" begin
                    aoe = ljl_propfunc(aoe_funcs[aoe_type]).(hit_cal)
                    cuts_aoe = cut_single_peak(aoe, 0.0, quantile(filter(isfinite, aoe), 0.99); n_bins = -1)
                    aoe ./= cuts_aoe.max
                    aoe, "$(aoe_funcs[aoe_type]) / $(cuts_aoe.max)"
                end

                @debug_plot @process_step "$aoe_type uncalibrated A/E plot" begin
                    h_aoe_uncal = fit(Histogram, (ustrip.(e_unit, e_cal[isfinite.(aoe)]), aoe[isfinite.(aoe)]), (0:0.5:3000, 0.1:5e-3:1.8))
                    p = LegendMakie.lhist(h_aoe_uncal, figsize = (670, 400), rasterize = true,
                                          title = get_plottitle(filekey_det, part, det, "uncalibrated A/E";
                                                                additional_type = string(aoe_type)), xlabel = "Energy ($e_unit)",
                                          titlesize = 14, ylabel = Makie.rich("A/E", Makie.subscript(" norm")), xticks = 0:500:3000,
                                          yticks = 0.25:0.25:1.75)
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_uncalibrated_$aoe_type"))
                end

                # cut around CC to get only compton band for stability plotting
                cc_min, cc_max = 0.9, 1.1
                aoe_cut = findall(cc_min .< aoe .< cc_max)
                @debug_plot @process_step "$aoe_type A/E stability plot" begin
                    # plot CC A/E over time
                    h_aoe_stability = StatsBase.fit(StatsBase.Histogram, (Unitful.ustrip.(u"hr", ts[aoe_cut]), aoe[aoe_cut]),
                                                    (0:0.01:ustrip(maximum(ts)), cc_min:5e-3:cc_max))
                    p = LegendMakie.lhist(h_aoe_stability, xlabel = "Time (hr)", ylabel = "CC A/E (a.u.)", titlealign = :center,
                                          watermark = false,
                                          title = get_plottitle(filekey_det, part, det, "A/E stability";
                                                                additional_type = string(aoe_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_stability_$aoe_type"))
                end

                plot_compton_bands() = begin
                    x = ustrip.(e_unit, e_cal)
                    mask = isfinite.(x) .&& isfinite.(aoe)
                    h = fit(Histogram, (x[mask], aoe[mask]),
                            (range(0, 3000; length = 301), range(quantile(aoe[mask], [0.001, 0.999])...; length = 201)))
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey_det, part, det, "Compton Bands"; additional_type = string(aoe_type)),
                                    xlabel = "Energy ($e_unit)", ylabel = "A/E")
                    Makie.heatmap!(ax, h.edges[1], h.edges[2], replace(float.(h.weights), 0.0 => NaN); colorscale = log10)
                    for band in compton_bands
                        Makie.vspan!(ax, ustrip(e_unit, band), ustrip(e_unit, band + compton_window); color = (:red, 0.3))
                    end
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_compton_band_fitting_$aoe_type"))
                end
                result_fit, report_fit, compton_band_peakhists = @process_step "$aoe_type compton band fitting" on_error = plot_compton_bands begin
                    # get compton band peak histograms with generated peakstats
                    peakhists_bands = generate_aoe_compton_bands(aoe, e_cal, compton_bands, compton_window)

                    result_bands, report_bands = fit_aoe_compton(peakhists_bands.peakhists, peakhists_bands.peakstats, compton_bands, ;
                                                                 uncertainty = true)
                    result_bands, report_bands, peakhists_bands
                end

                qc_compton_bands = findall(band -> band in keys(result_fit) &&
                                                   result_fit[band].gof.converged &&
                                                   result_fit[band].gof.pvalue >= p_value_cut, compton_bands)
                compton_bands_qc = compton_bands[qc_compton_bands]
                peakhists = compton_band_peakhists.peakhists[qc_compton_bands]
                peakstats = compton_band_peakhists.peakstats[qc_compton_bands]
                μ = [result_fit[band].μ for band in compton_bands_qc]
                σ = [result_fit[band].σ for band in compton_bands_qc]

                # fit μ and σ with correction functions
                result_fit_single, report_fit_single = @process_step "$aoe_type correction fitting" begin
                    fit_aoe_corrections(compton_bands_qc, μ, σ, ; aoe_expression = aoe_expression, e_expression = e_type)
                end

                # perform A/E combined fit
                if aoe_config_det.use_combined_fit
                    result_fit_combined, report_fit_combined = @process_step "$aoe_type combined compton band fitting" begin
                        fit_aoe_compton_combined(peakhists, peakstats, compton_bands_qc, result_fit_single; e_expression = e_type,
                                                 aoe_expression = aoe_expression, uncertainty = true)
                    end

                    # create plots
                    @debug_plot @process_step "$aoe_type compton bands mu plot" begin
                        p_μ = LegendMakie.lplot(report_fit_single.report_μ, report_fit_combined.report_µ, legend_position = :lb,
                                                figsize = (600, 420),
                                                title = get_plottitle(filekey_det, part, det, "A/E μ"; additional_type = string(aoe_type)))
                        save_plot(p_μ, l200, part, filekey_det, det, Symbol("compton_bands_mu_$aoe_type"))
                    end
                    @debug_plot @process_step "$aoe_type compton bands sigma plot" begin
                        p_σ = LegendMakie.lplot(report_fit_single.report_σ, report_fit_combined.report_σ, legend_position = :rt,
                                                figsize = (600, 420),
                                                title = get_plottitle(filekey_det, part, det, "A/E σ"; additional_type = string(aoe_type)))
                        save_plot(p_σ, l200, part, filekey_det, det, Symbol("compton_bands_sigma_$aoe_type"))
                    end

                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_combined.func).(hit_cal)

                    # create result
                    result_correction = result_fit_combined
                else
                    # create plots
                    @debug_plot @process_step "$aoe_type compton bands mu plot" begin
                        p_μ = LegendMakie.lplot(report_fit_single.report_μ, legend_position = :lb, figsize = (600, 420),
                                                title = get_plottitle(filekey_det, part, det, "A/E µ"; additional_type = string(aoe_type)))
                        save_plot(p_μ, l200, part, filekey_det, det, Symbol("compton_bands_mu_$aoe_type"))
                    end
                    @debug_plot @process_step "$aoe_type compton bands sigma plot" begin
                        p_σ = LegendMakie.lplot(report_fit_single.report_σ, legend_position = :rt, figsize = (600, 420),
                                                title = get_plottitle(filekey_det, part, det, "A/E σ"; additional_type = string(aoe_type)))
                        save_plot(p_σ, l200, part, filekey_det, det, Symbol("compton_bands_sigma_$aoe_type"))
                    end

                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_single.func).(hit_cal)

                    # add GoF to result
                    single_fit_residuals = vcat([result_fit[band].gof.residuals_norm for band in compton_bands_qc]...)
                    result_correction = merge(result_fit_single,
                                              (gof = (mean_residuals = mean(single_fit_residuals),
                                                      median_residuals = median(single_fit_residuals),
                                                      std_residuals = std(single_fit_residuals)),))
                end

                # charge trapping correction
                result_aoe_ctc, report_aoe_ctc = NamedTuple(), NamedTuple()
                if aoe_config_det.apply_ctc
                    result_aoe_ctc, report_aoe_ctc = @process_step "$aoe_type charge trapping correction" begin
                        qdrift_e = ljl_propfunc(qdrift_expression).(hit_cal)
                        LegendSpecFits.ctc_aoe(aoe_corr, e_cal, qdrift_e, compton_bands_qc, aoe_expression = result_correction.func,
                                               qdrift_expression = qdrift_expression)
                    end

                    @debug_plot @process_step "$aoe_type charge trapping correction plot" begin
                        # plot A/E ctc correlation plot
                        p = LegendMakie.lplot(report_aoe_ctc, figsize = (600, 600),
                                              title = get_plottitle(filekey_det, part, det, "A/E CT Correction";
                                                                    additional_type = string(aoe_type)))
                        save_plot(p, l200, part, filekey_det, det, Symbol("aoe_ctc_$aoe_type"))
                    end

                    @debug_plot @process_step "$aoe_type compton band after CTC plot" begin
                        # plot A/E normalization after CTC
                        p = LegendMakie.lplot(report_aoe_ctc.report_after, xlims = (-20, 12),
                                              title = get_plottitle(filekey_det, part, det,
                                                                    "$(first(compton_bands_qc)) - $(last(compton_bands_qc)) CTC";
                                                                    additional_type = string(aoe_type)),
                                              xlabel = LaTeXStrings.latexstring("\\fontfamily{Roboto}" * "A/E_{CTC}"),
                                              ylabel = "Counts / $(round(step(report_aoe_ctc.report_after.h.edges[1]), digits=2))")
                        save_plot(p, l200, part, filekey_det, det, Symbol("aoe_compton_after_ctc_$aoe_type"))
                    end

                    aoe_corr = ljl_propfunc(result_aoe_ctc.func).(hit_cal)
                end

                @debug_plot @process_step "$aoe_type normalized A/E plot" begin
                    # plot corrected A/E 2D histogram
                    h_aoe_ec = fit(Histogram, (ustrip.(u"keV", e_cal), aoe_corr), (0:0.5:3000, -30:0.1:10))
                    p = LegendMakie.lhist(h_aoe_ec, figsize = (670, 400), rasterize = true,
                                          title = get_plottitle(filekey_det, part, det, "normalized A/E";
                                                                additional_type = string(aoe_type)), titlesize = 14,
                                          xlabel = "Energy ($e_unit)", ylabel = Makie.rich("A/E", Makie.subscript(" ec")),
                                          xticks = 0:500:3000, yticks = -30:10:10)
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_normalized_$aoe_type"))
                end

                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), aoe_type,
                                       length(compton_bands_qc), get(result_correction.gof, :median_residuals, NaN),
                                       get(result_correction.gof, :std_residuals, NaN), get(result_aoe_ctc, :fct, NaN), "-"))

                # create result
                result = (func = get(result_aoe_ctc, :func, result_correction.func), ctc = result_aoe_ctc, correction = result_correction,
                          apply_ctc = aoe_config_det.apply_ctc, use_combined_fit = aoe_config_det.use_combined_fit)
                # add results to dict
                result_dict[aoe_type] = result
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = true

            catch e
                e isa ProcessStepError || @error "Error in $aoe_type calibration: $(truncate_error(e))"
                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), aoe_type, fill("-", 4)...,
                                       truncate_error(e)))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
        end

        # add calbiration results to pars_db
        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_aoe_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_aoe_det)

        @debug_progress "Detector: $det" for aoe_classifier in aoe_classifiers
            if haskey(processed_dict, aoe_classifier)
                continue
            end
            try
                @debug "Generate $aoe_classifier cut"

                aoe = @process_step "$aoe_classifier A/E loading" begin
                    ljl_propfunc(pars_db_det[det][Symbol(first(split(string(aoe_classifier), "_classifier")))].func).(hit_cal)
                end

                @process_step "$aoe_classifier normalized A/E plot" begin
                    h_aoe_ctc = fit(Histogram, (ustrip.(e_unit, e_cal), aoe), (0:0.5:3000, -20:0.1:10))
                    p = LegendMakie.lhist(h_aoe_ctc, figsize = (670, 400), rasterize = true,
                                          title = get_plottitle(filekey_det, part, det, ""; additional_type = string(aoe_classifier)),
                                          xlabel = "Energy ($e_unit)", ylabel = Makie.rich("A/E", Makie.subscript(" ctc")),
                                          xticks = 0:500:3000,
                                          yticks = -20:10:10)
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_normalized_$aoe_classifier"))
                end

                plot_dep_window() = begin
                    dep = aoe_config_det.dep
                    window = aoe_config_det.dep_window
                    x = ustrip.(e_unit, e_cal)
                    in_range = ustrip(e_unit, dep - 5 * first(window)) .< x .< ustrip(e_unit, dep + 5 * last(window))
                    mask = in_range .&& isfinite.(aoe)
                    h = fit(Histogram, (x[mask], aoe[mask]),
                            (range(ustrip(e_unit, dep - 5 * first(window)), ustrip(e_unit, dep + 5 * last(window)); length = 101),
                             range(quantile(aoe[mask], [0.001, 0.999])...; length = 201)))
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1];
                                    title = get_plottitle(filekey_det, part, det, "DEP Window"; additional_type = string(aoe_classifier)),
                                    xlabel = "Energy ($e_unit)", ylabel = "A/E")
                    Makie.heatmap!(ax, h.edges[1], h.edges[2], replace(float.(h.weights), 0.0 => NaN); colorscale = log10)
                    Makie.vlines!(ax, ustrip.(e_unit, [dep - first(window), dep + last(window)]); color = :red, linestyle = :dash)
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_cut_generation_$aoe_classifier"))
                end
                result_cut, report_cut = @process_step "$aoe_classifier cut generation" on_error = plot_dep_window begin
                    @debug "Generate AoE cut"
                    get_low_aoe_cut(aoe, e_cal, ; dep = aoe_config_det.dep, window = aoe_config_det.dep_window,
                                    cut_search_interval = Tuple(aoe_config_det.dep_cut_search_interval),
                                    bin_width_window = aoe_config_det.dep_bin_width_window, rtol = aoe_config_det.dep_cut_search_rtol,
                                    maxiters = aoe_config_det.dep_cut_search_maxiters, dep_sf = aoe_config_det.dep_cut_search_target_sf,
                                    fixed_position = aoe_config_det.dep_cut_search_fixed_position, sigma_high_sided = sigma_high_sided,
                                    fit_func = Symbol(aoe_config_det.dep_cut_search_fit_func), uncertainty = true)
                end

                @debug "Found low A/E cut at $(round(result_cut.lowcut, digits=2)) and high A/E cut at $(round(result_cut.highcut, digits=2))"

                @debug_plot @process_step "$aoe_classifier A/E performance plot" begin
                    # plot spectrum before and after cut
                    p = LegendMakie.lplot(report_cut, figsize = (750, 400),
                                          title = get_plottitle(filekey_det, part, det, "A/E Performance";
                                                                additional_type = string(aoe_classifier)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_energy_afterAoE_zoom_$aoe_classifier"))
                end

                result_peaks_low, report_peaks_low = @process_step "$aoe_classifier low survival fractions" begin
                    @debug "Generate A/E low Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, aoe_config_det.aoe_peaks, Symbol.(aoe_config_det.aoe_peaks_names),
                                                 aoe_config_det.aoe_peaks_windows_left, aoe_config_det.aoe_peaks_windows_right;
                                                 low_cut = result_cut.lowcut, bin_width_window = aoe_config_det.aoe_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(aoe_config_det.aoe_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low, _ = @process_step "$aoe_classifier low Qbb survival fraction" begin
                    get_continuum_survival_fraction(aoe, e_cal, aoe_config_det.qbb, aoe_config_det.qbb_window; low_cut = result_cut.lowcut)
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"

                result_peaks_ds, report_peaks_ds = @process_step "$aoe_classifier DS survival fractions" begin
                    @debug "Generate A/E DS Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, aoe_config_det.aoe_peaks, Symbol.(aoe_config_det.aoe_peaks_names),
                                                 aoe_config_det.aoe_peaks_windows_left, aoe_config_det.aoe_peaks_windows_right;
                                                 low_cut = result_cut.lowcut, high_cut = result_cut.highcut,
                                                 bin_width_window = aoe_config_det.aoe_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(aoe_config_det.aoe_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds, _ = @process_step "$aoe_classifier DS Qbb survival fraction" begin
                    get_continuum_survival_fraction(aoe, e_cal, aoe_config_det.qbb, aoe_config_det.qbb_window; low_cut = result_cut.lowcut,
                                                    high_cut = result_cut.highcut)
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"

                @debug_plot @process_step "$aoe_classifier DS survival fractions plot" begin
                    p = LegendMakie.lplot(report_peaks_ds, titlesize = 17, figsize = (600, 400*length(report_peaks_ds)),
                                          title = get_plottitle(filekey_det, part, det, "A/E Performance";
                                                                additional_type = string(aoe_classifier)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_peaks_sf_$aoe_classifier"))
                end

                # save results
                result = merge(result_cut,
                               (peaks = (low = result_peaks_low, ds = result_peaks_ds), qbb = (low = qbb_result_low, ds = qbb_result_ds)))

                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), aoe_classifier,
                                       result_cut.lowcut, result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier] = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

            catch e
                e isa ProcessStepError || @error "Error in $aoe_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), aoe_classifier, "-", "-", "-",
                                       truncate_error(e)))

                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
        end
        # cleanup log and combine
        log_info_dict_cleaned = Dict{Symbol,NamedTuple}()
        for aoe_type in aoe_types
            log_info_dict_cleaned[aoe_type] = merge(log_info_dict[aoe_type], log_info_dict[Symbol("$(string(aoe_type))_classifier")])
        end
        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict_cleaned, validity = validity_det)
        result_aoe_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_aoe_det)
        if !isempty(pars_db_det)
            write_pars(l200.par.ppars.aoe[det], part, pars_db_det)
            write_validity(l200.par.ppars.aoe[det], filekey_det, part)
        end

        return result_det
    end

    # get start time
    start_time = now()

    result_aoe = parallel(det_aoe_cut, chinfo_unfolded, merge(log_nt_cal, log_nt_cut); timeout = timeout, retry = false,
                          process_name = "$period-p_process_aoe_calibration_cut_cal")
    @info "Finished AoE cut generation"

    @info "Write $period validity"
    validity_all = create_validity(result_aoe)
    write_validity(l200.par.ppars.aoe, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_aoe)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_partition_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoe))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :aoe_calibration_cut), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_aoe))
end

register_processor!(p_process_aoe_calibration_cut_cal)
