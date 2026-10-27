"""
    process_aoe_calibration_cut_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Calibrate A/E and generate the A/E cuts for the HPGe detectors (`geds`) of one `cal` run.

For each detector with `usability == :on` and `low_aoe_status` of `:valid` or `:present`, the A/E of every type listed
in `aoe_funcs` is normalized and the Compton bands (`compton_bands`) are fitted. The fitted mean and width are
described with energy-dependent correction functions, optionally refined by a combined fit (`use_combined_fit`).
If `apply_ctc` is set, a charge trapping correction against the effective drift time (`qdrift_expression`) follows.
For each classifier in `aoe_classifiers`, the low A/E cut is searched on the DEP, the high cut is set from
`sigma_high_sided`, and survival fractions are computed for the configured peaks and the Qbb window with the low cut
alone and with both cuts (`ds`).

# Inputs
- First `cal` filekey of the run.
- `l200.par.rpars.ecal[period, run]`: the calibration function of the energy type `e_type`.
- `jlqcs` tier (single pulse, non-pulser events) and `jldsp` tier of the `cal` run.
- `dataprod_config(l200).psd(filekey).aoe`, `default` merged with the detector section: `e_type`, `aoe_funcs`,
  `aoe_classifiers`, `compton_bands`, `compton_window`, `p_value`, `use_combined_fit`, `apply_ctc`,
  `qdrift_expression`, `sigma_high_sided`, the DEP cut search settings (`dep`, `dep_window`,
  `dep_cut_search_interval`, `dep_bin_width_window`, `dep_cut_search_rtol`, `dep_cut_search_maxiters`,
  `dep_cut_search_target_sf`, `dep_cut_search_fixed_position`, `dep_cut_search_fit_func`) and the survival fraction
  settings (`aoe_peaks`, `aoe_peaks_names`, `aoe_peaks_windows_left`, `aoe_peaks_windows_right`,
  `aoe_peaks_bin_width_window`, `aoe_peaks_fit_funcs`, `qbb`, `qbb_window`).

# Outputs
- `l200.par.rpars.aoe[period, run]`: per detector, one entry per A/E type (`func`, `ctc`, `correction`, `apply_ctc`,
  `use_combined_fit`) and one entry per classifier (`lowcut`, `highcut`, and `peaks` and `qbb` survival fractions
  with the `low` cut and with both cuts `ds`), plus the matching validity entry. The classifier name is the A/E type
  name followed by `_classifier`.
- Plots per detector: `aoe_uncalibrated_<type>`, `compton_bands_mu_<type>`, `compton_bands_sigma_<type>`,
  `aoe_ctc_<type>` (if `apply_ctc`), `aoe_normalized_<type>`, `aoe_normalized_<classifier>`,
  `aoe_energy_afterAoE_zoom_<classifier>` and `aoe_peaks_ds_sf_<classifier>`. Only `aoe_normalized_<classifier>` is saved below the debug plot level.
- If `error_plots` is on, a failed Compton band fitting saves `error_compton_band_fitting_<type>` and a failed cut generation `error_cut_generation_<classifier>`.
- Run report `aoe_calibration_cut` with the processing status, a metadata table, and one row per detector and A/E type
  combining the calibration and the cut results.

# Keywords
- `reprocess`: Discard the existing `aoe` parameters of the run and process all detectors, A/E types and classifiers
  again. Otherwise, entries that already exist are kept and only missing ones are computed.
- `timeout`: Seconds allowed per detector in `parallel`; `0` means no limit.

# Returns
The return value is not used by `run_processing`.
"""
function process_aoe_calibration_cut_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                         timeout::Real = 0)
    @info "Calibrate AoE for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_aoe_calibration_cut_cal)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    aoe_config = dataprod_config(l200).psd(filekey).aoe
    @debug "Loaded aoe config: $(lstring(aoe_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.aoe), string(period)))
    pars_db = PropDict(l200.par.rpars.aoe[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Detector, :usability, :Status, Symbol("Filter Type"), Symbol("N Compt. Bands"), Symbol("Median norm. Resid."),
                             Symbol("StD norm. Resid."), Symbol("FCT"), :CalError)}
    log_nt_cut = NamedTuple{(:Detector, :usability, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"),
                             Symbol("FEP SF"), :CutError)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_aoe_cut(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        aoe_config_det = merge(aoe_config.default, get(aoe_config, det, PropDict()))

        compton_bands = aoe_config_det.compton_bands
        compton_window = aoe_config_det.compton_window
        p_value_cut = aoe_config_det.p_value # what is this? p values threshold 
        e_type = Symbol(aoe_config_det.e_type)
        aoe_types = collect(keys(aoe_config_det.aoe_funcs))
        aoe_funcs = aoe_config_det.aoe_funcs
        qdrift_expression = aoe_config_det.qdrift_expression

        aoe_classifiers = Symbol.(aoe_config_det.aoe_classifiers)

        # sigma_high_sided = ifelse(chinfo_det.high_aoe_status == :valid, aoe_config_det.sigma_high_sided, Inf)
        sigma_high_sided = aoe_config_det.sigma_high_sided

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for aoe_type in aoe_types
                if haskey(pars_db[det], aoe_type)
                    pars_db_det_aoe_type = pars_db[det][aoe_type]
                    log_ch = log_nt_cal((det, detector_status(chinfo_det.usability), ProcessStatus(1), aoe_type,
                                         length(pars_db_det_aoe_type.µ_compton.µ), get(pars_db_det_aoe_type.gof, :median_residuals, NaN),
                                         get(pars_db_det_aoe_type.gof, :std_residuals, NaN), get(pars_db_det_aoe_type.ctc, :fct, NaN),
                                         "Already processed --> skipped."))
                    processed_dict[aoe_type] = false
                    log_info_dict[aoe_type] = log_ch
                end
            end
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db[det], aoe_classifier)
                    log_info = log_nt_cut((det, detector_status(chinfo_det.usability), ProcessStatus(1), aoe_classifier,
                                           pars_db[det][aoe_classifier].lowcut, pars_db[det][aoe_classifier].peaks.ds[:Tl208SEP].sf,
                                           pars_db[det][aoe_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        # `nothing` if all A/E types and classifiers are already processed
        e_cal, hit_cal, e_unit = @process_step "hit data loading" begin
            if !all([haskey(processed_dict, aoe_type) for aoe_type in aoe_types]) ||
               !all([haskey(processed_dict, aoe_classifier) for aoe_classifier in aoe_classifiers])
                hit_cal = read_hit_cal(l200, det, [(period, run)], [e_type],
                                       vcat(collect(values(aoe_funcs)), aoe_config_det.apply_ctc ? [qdrift_expression] : []))
                e_cal = collect(getproperty(hit_cal, e_type))
                e_unit = unit(eltype(e_cal))
                e_cal, hit_cal, e_unit
            else
                nothing, nothing, nothing
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
                                          title = get_plottitle(filekey, det, "uncalibrated"; additional_type = string(aoe_type)),
                                          xlabel = "Energy ($e_unit)", titlesize = 14, ylabel = Makie.rich("A/E", Makie.subscript(" norm")),
                                          xticks = 0:500:3000, yticks = 0.25:0.25:1.75)
                    save_plot(p, l200, filekey, det, Symbol("aoe_uncalibrated_$aoe_type"))
                end

                plot_compton_bands() = begin
                    x = ustrip.(e_unit, e_cal)
                    mask = isfinite.(x) .&& isfinite.(aoe)
                    h = fit(Histogram, (x[mask], aoe[mask]),
                            (range(0, 3000; length = 301), range(quantile(aoe[mask], [0.001, 0.999])...; length = 201)))
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey, det, "Compton Bands"; additional_type = string(aoe_type)),
                                    xlabel = "Energy ($e_unit)", ylabel = "A/E")
                    Makie.heatmap!(ax, h.edges[1], h.edges[2], replace(float.(h.weights), 0.0 => NaN); colorscale = log10)
                    for band in compton_bands
                        Makie.vspan!(ax, ustrip(e_unit, band), ustrip(e_unit, band + compton_window); color = (:red, 0.3))
                    end
                    save_plot(fig, l200, filekey, det, Symbol("error_compton_band_fitting_$aoe_type"))
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
                                                title = get_plottitle(filekey, det, "A/E μ"; additional_type = string(aoe_type)))
                        save_plot(p_μ, l200, filekey, det, Symbol("compton_bands_mu_$aoe_type"))
                    end
                    @debug_plot @process_step "$aoe_type compton bands sigma plot" begin
                        p_σ = LegendMakie.lplot(report_fit_single.report_σ, report_fit_combined.report_σ, legend_position = :rt,
                                                figsize = (600, 420),
                                                title = get_plottitle(filekey, det, "A/E σ"; additional_type = string(aoe_type)))
                        save_plot(p_σ, l200, filekey, det, Symbol("compton_bands_sigma_$aoe_type"))
                    end

                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_combined.func).(hit_cal)

                    # create result
                    result_correction = result_fit_combined
                else
                    # create plots
                    @debug_plot @process_step "$aoe_type compton bands mu plot" begin
                        p_μ = LegendMakie.lplot(report_fit_single.report_μ, legend_position = :lb, figsize = (600, 420),
                                                title = get_plottitle(filekey, det, "A/E μ"; additional_type = string(aoe_type)))
                        save_plot(p_μ, l200, filekey, det, Symbol("compton_bands_mu_$aoe_type"))
                    end
                    @debug_plot @process_step "$aoe_type compton bands sigma plot" begin
                        p_σ = LegendMakie.lplot(report_fit_single.report_σ, legend_position = :rt, figsize = (600, 420),
                                                title = get_plottitle(filekey, det, "A/E σ"; additional_type = string(aoe_type)))
                        save_plot(p_σ, l200, filekey, det, Symbol("compton_bands_sigma_$aoe_type"))
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

                    # plot A/E ctc correlation plot
                    @debug_plot @process_step "$aoe_type charge trapping correction plot" begin
                        p = LegendMakie.lplot(report_aoe_ctc, figsize = (600, 600),
                                              title = get_plottitle(filekey, det, "A/E CT Correction"; additional_type = string(aoe_type)))
                        save_plot(p, l200, filekey, det, Symbol("aoe_ctc_$aoe_type"))
                    end

                    aoe_corr = ljl_propfunc(result_aoe_ctc.func).(hit_cal)
                end

                # plot corrected A/E 2D histogram 

                @debug_plot @process_step "$aoe_type normalized A/E plot" begin
                    h_aoe_ec = fit(Histogram, (ustrip.(u"keV", e_cal), aoe_corr), (0:0.5:3000, -30:0.1:10))
                    p = LegendMakie.lhist(h_aoe_ec, figsize = (670, 400), rasterize = true,
                                          title = get_plottitle(filekey, det, "normalized"; additional_type = string(aoe_type)),
                                          xlabel = "Energy ($e_unit)", titlesize = 14, ylabel = Makie.rich("A/E", Makie.subscript(" ec")),
                                          xticks = 0:500:3000, yticks = -30:10:10)
                    save_plot(p, l200, filekey, det, Symbol("aoe_normalized_$aoe_type"))
                end

                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), ProcessStatus(1), aoe_type, length(compton_bands_qc),
                                       get(result_correction.gof, :median_residuals, NaN), get(result_correction.gof, :std_residuals, NaN),
                                       get(result_aoe_ctc, :fct, NaN), "-"))

                # create result
                result = (func = get(result_aoe_ctc, :func, result_correction.func), ctc = result_aoe_ctc, correction = result_correction,
                          apply_ctc = aoe_config_det.apply_ctc, use_combined_fit = aoe_config_det.use_combined_fit)
                # add results to dict
                result_dict[aoe_type] = result
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = true

            catch e
                e isa ProcessStepError || @error "Error in $aoe_type calibration: $(truncate_error(e))"
                log_info = log_nt_cal((det, detector_status(chinfo_det.usability), ProcessStatus(0), aoe_type, fill("-", 4)...,
                                       truncate_error(e)))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
        end
        @info "AoE calibration for detector $det ($ch) finished"

        # add calbiration results to pars_db
        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict)
        result_aoe_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_ch = create_pars(pars_db_ch, result_aoe_det)

        @debug_progress "Detector: $det" for aoe_classifier in aoe_classifiers
            if haskey(processed_dict, aoe_classifier)
                continue
            end
            try
                @debug "Generate $aoe_classifier cut"

                aoe = @process_step "$aoe_classifier A/E loading" begin
                    ljl_propfunc(pars_db_ch[det][Symbol(first(split(string(aoe_classifier), "_classifier")))].func).(hit_cal)
                end

                @process_step "$aoe_classifier normalized A/E plot" begin
                    h_aoe_ctc = fit(Histogram, (ustrip.(e_unit, e_cal), aoe), (0:0.5:3000, -20:0.1:10))
                    p = LegendMakie.lhist(h_aoe_ctc, figsize = (670, 400), rasterize = true,
                                          title = get_plottitle(filekey, det, ""; additional_type = string(aoe_classifier)),
                                          xlabel = "Energy ($e_unit)", ylabel = Makie.rich("A/E", Makie.subscript(" ctc")),
                                          xticks = 0:500:3000,
                                          yticks = -20:10:10)
                    save_plot(p, l200, filekey, det, Symbol("aoe_normalized_$aoe_classifier"))
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
                    ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey, det, "DEP Window"; additional_type = string(aoe_classifier)),
                                    xlabel = "Energy ($e_unit)", ylabel = "A/E")
                    Makie.heatmap!(ax, h.edges[1], h.edges[2], replace(float.(h.weights), 0.0 => NaN); colorscale = log10)
                    Makie.vlines!(ax, ustrip.(e_unit, [dep - first(window), dep + last(window)]); color = :red, linestyle = :dash)
                    save_plot(fig, l200, filekey, det, Symbol("error_cut_generation_$aoe_classifier"))
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

                # plot spectrum before and after cut
                @debug_plot @process_step "$aoe_classifier A/E performance plot" begin
                    p = LegendMakie.lplot(report_cut, figsize = (750, 400),
                                          title = get_plottitle(filekey, det, "A/E Performance"; additional_type = string(aoe_classifier)))
                    save_plot(p, l200, filekey, det, Symbol("aoe_energy_afterAoE_zoom_$aoe_classifier"))
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
                    p = LegendMakie.lplot(report_peaks_ds, figsize = (600, 400*length(report_peaks_ds)), titlesize = 17,
                                          title = get_plottitle(filekey, det, "A/E Performance"; additional_type = string(aoe_classifier)))
                    save_plot(p, l200, filekey, det, Symbol("aoe_peaks_ds_sf_$aoe_classifier"))
                end

                # save results
                result = merge(result_cut,
                               (peaks = (low = result_peaks_low, ds = result_peaks_ds), qbb = (low = qbb_result_low, ds = qbb_result_ds)))

                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), ProcessStatus(1), aoe_classifier, result_cut.lowcut,
                                       result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier] = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

            catch e
                e isa ProcessStepError || @error "Error in $aoe_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), ProcessStatus(0), aoe_classifier, "-", "-", "-",
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

        return (result = result_dict, log = log_info_dict_cleaned, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_aoe = parallel(det_aoe_cut, chinfo, merge(log_nt_cal, log_nt_cut); timeout = timeout, retry = false,
                          process_name = "$period-$run-process_aoe_calibration_cut_cal")

    @info "Finished AoE calibration"

    pars_db = create_pars(pars_db, result_aoe)
    write_pars(l200.par.rpars.aoe[period], run, pars_db)
    write_validity(l200.par.rpars.aoe, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_aoe_calibration_cut_cal, result_aoe)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoe))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :aoe_calibration_cut), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_aoe_calibration_cut_cal)
