"""
    p_process_aoe_cut_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Generate the A/E cuts from the combined `cal` data of every detector and partition that contains `period`.

The `cal` data of all runs in a detector's partition are calibrated with the run-level parameters
(`rpars`, category `aoe`) through `calibrate_ged_detector_data`. For each A/E type in `aoe_funcs`, the low A/E cut of
its classifier `<type>_classifier` is searched on the DEP of the combined data, the high cut is set from
`sigma_high_sided`, and survival fractions are computed for the configured peaks and the Qbb window with the low cut
alone and with both cuts (`ds`). Detectors with `low_aoe_status` of `:valid` or `:present` are processed.

# Inputs
- `jlqcs` tier (single pulse, non-pulser events) and `jldsp` tier of all `cal` runs in the partition, calibrated with
  the run-level A/E parameters `l200.par.rpars.aoe` (and the parameters `calibrate_ged_detector_data` reads for the
  energy).
- `dataprod_config(l200).psd(filekey).aoe` of the first run of the partition, `p_default` merged with `p[det]`:
  `e_type`, `aoe_funcs` (only the keys), `sigma_high_sided`, the DEP cut search settings (`dep`, `dep_window`,
  `dep_cut_search_interval`, `dep_bin_width_window`, `dep_cut_search_rtol`, `dep_cut_search_maxiters`,
  `dep_cut_search_target_sf`, `dep_cut_search_fixed_position`, `dep_cut_search_fit_func`) and the survival fraction
  settings (`aoe_peaks`, `aoe_peaks_names`, `aoe_peaks_windows_left`, `aoe_peaks_windows_right`,
  `aoe_peaks_bin_width_window`, `aoe_peaks_fit_funcs`, `qbb`, `qbb_window`).

# Outputs
- `l200.par.ppars.aoecut[det, part]`: per classifier, `lowcut`, `highcut`, and `peaks` and `qbb` survival fractions
  with the `low` cut and with both cuts `ds`, plus the validity of `ppars.aoecut` for `period`.
- Plots per detector and partition: `aoe_normalized_runcal_<classifier>`,
  `aoe_energy_afterAoE_zoom_runcal_<classifier>` and `aoe_peaks_sf_runcal_<classifier>`. Only `aoe_normalized_runcal_<classifier>` is saved below the debug plot level.
- If `error_plots` is on, a failed cut generation saves `error_cut_generation_<classifier>` and a failed survival fraction step `error_survival_fractions_<classifier>`.
- Partition report `aoe_cut` with the processing status, a metadata table and one result row per detector,
  partition and classifier.

# Keywords
- `reprocess`: Discard the existing `ppars.aoecut` parameters of each detector and partition and process all
  classifiers again. Otherwise, classifiers that already have results are kept.
- `timeout`: Seconds allowed per detector and partition in `parallel`; `0` means no limit.
- `only_first_period`: If `true`, a detector whose partition starts in an earlier period is skipped and logged as
  skipped. `run_processing` sets it to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`. `run_processing` uses
this to wait for the same step in the previous period.
"""
function p_process_aoe_cut_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                               only_first_period::Bool = true)
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
    log_nt = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"),
                         Symbol("FEP SF"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_aoe_cut(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        make_par_dir(joinpath(data_path(l200.par.ppars.aoecut), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.aoecut), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.aoecut[det, part])
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

        aoe_classifiers = [Symbol("$(aoe_type)_classifier") for aoe_type in keys(aoe_config_det.aoe_funcs)]
        e_type = Symbol(aoe_config_det.e_type)

        # sigma_high_sided = ifelse(chinfo_det.high_aoe_status == :valid, aoe_config_det.sigma_high_sided, Inf)
        sigma_high_sided = aoe_config_det.sigma_high_sided

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for aoe_classifier in aoe_classifiers
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, aoe_classifier, fill("-", 3)...,
                                   "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db_det[det], aoe_classifier)
                    log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), aoe_classifier,
                                       pars_db_det[det][aoe_classifier].lowcut, pars_db_det[det][aoe_classifier].peaks.ds[:Tl208SEP].sf,
                                       pars_db_det[det][aoe_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        e_cal, hit_cal, e_unit = @process_step "E data loader" begin
            if !all([haskey(processed_dict, aoe_classifier) for aoe_classifier in aoe_classifiers])
                hit_cal = fast_flatten([begin
                                            @debug "Reading from $(pinfo.period)-$(pinfo.run)"
                                            qc_mask = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs, pinfo.cal.startkey,
                                                                 det)
                                            dsp = read_ldata(l200, :jldsp, :cal, pinfo.period, pinfo.run, det)[qc_mask]
                                            calibrate_ged_detector_data(l200, pinfo.cal.startkey, det, dsp; aoe_cal_pars_type = :rpars,
                                                                        aoe_cal_pars_cat = :aoe, aoe_cut_pars_type = :rpars,
                                                                        aoe_cut_pars_cat = :aoe)
                                        end
                                        for pinfo in partinfo_det])
                e_cal = collect(getproperty(hit_cal, e_type))
                e_unit = unit(first(e_cal))
                e_cal, hit_cal, e_unit
            else
                nothing, nothing, nothing
            end
        end

        @debug_progress "Detector: $det" for aoe_classifier in aoe_classifiers
            if haskey(processed_dict, aoe_classifier)
                continue
            end
            try
                @debug "Generate $aoe_classifier cut"

                aoe = @process_step "$aoe_classifier data extraction" begin
                    getproperty(hit_cal, aoe_classifier)
                end

                @process_step "$aoe_classifier normalized A/E plot" begin
                    h_aoe_ctc = fit(Histogram, (ustrip.(e_unit, e_cal), aoe), (0:0.5:3000, -20:0.1:10))
                    p = LegendMakie.lhist(h_aoe_ctc, figsize = (670, 400), rasterize = true,
                                          title = get_plottitle(filekey_det, part, det, ""; additional_type = string(aoe_classifier)),
                                          xlabel = "Energy ($e_unit)", ylabel = "A/E", xticks = 0:500:3000, yticks = -20:10:10)
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_normalized_runcal_$aoe_classifier"))
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

                # plot spectrum before and after cut
                @debug_plot @process_step "$aoe_classifier A/E performance plot" begin
                    p = LegendMakie.lplot(report_cut, figsize = (750, 400),
                                          title = get_plottitle(filekey_det, part, det, "A/E Performance";
                                                                additional_type = string(aoe_classifier)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_energy_afterAoE_zoom_runcal_$aoe_classifier"))
                end

                plot_peak_survival() = begin
                    x = ustrip.(e_unit, e_cal)
                    fig = Makie.Figure(size = (900, 300 * cld(length(aoe_config_det.aoe_peaks), 2)))
                    Makie.Label(fig[0, 1:2],
                                get_plottitle(filekey_det, part, det, "Survival Fractions"; additional_type = string(aoe_classifier)))
                    for (i, peak) in pairs(aoe_config_det.aoe_peaks)
                        lo = ustrip(e_unit, peak - aoe_config_det.aoe_peaks_windows_left[i])
                        hi = ustrip(e_unit, peak + aoe_config_det.aoe_peaks_windows_right[i])
                        in_peak = lo .< x .< hi
                        ax = Makie.Axis(fig[cld(i, 2), mod1(i, 2)]; title = string(aoe_config_det.aoe_peaks_names[i]),
                                        xlabel = "Energy ($e_unit)", ylabel = "Counts")
                        Makie.stephist!(ax, x[in_peak]; bins = range(lo, hi; length = 51), label = "all")
                        Makie.stephist!(ax, x[in_peak .&& (aoe .> mvalue(result_cut.lowcut))]; bins = range(lo, hi; length = 51),
                                        label = "A/E > low cut")
                        Makie.stephist!(ax, x[in_peak .&& (mvalue(result_cut.lowcut) .< aoe .< mvalue(result_cut.highcut))];
                                        bins = range(lo, hi; length = 51), label = "low < A/E < high")
                        i == 1 && Makie.axislegend(ax)
                    end
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_survival_fractions_$aoe_classifier"))
                end
                result_peaks_low, report_peaks_low = @process_step "$aoe_classifier low survival fractions" on_error = plot_peak_survival begin
                    @debug "Generate A/E low Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, aoe_config_det.aoe_peaks, Symbol.(aoe_config_det.aoe_peaks_names),
                                                 aoe_config_det.aoe_peaks_windows_left, aoe_config_det.aoe_peaks_windows_right;
                                                 low_cut = result_cut.lowcut, bin_width_window = aoe_config_det.aoe_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(aoe_config_det.aoe_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low, _ = @process_step "$aoe_classifier Qbb low survival fraction" begin
                    get_continuum_survival_fraction(aoe, e_cal, aoe_config_det.qbb, aoe_config_det.qbb_window; low_cut = result_cut.lowcut)
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"

                result_peaks_ds, report_peaks_ds = @process_step "$aoe_classifier DS survival fractions" on_error = plot_peak_survival begin
                    @debug "Generate A/E DS Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, aoe_config_det.aoe_peaks, Symbol.(aoe_config_det.aoe_peaks_names),
                                                 aoe_config_det.aoe_peaks_windows_left, aoe_config_det.aoe_peaks_windows_right;
                                                 low_cut = result_cut.lowcut, high_cut = result_cut.highcut,
                                                 bin_width_window = aoe_config_det.aoe_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(aoe_config_det.aoe_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds, _ = @process_step "$aoe_classifier Qbb DS survival fraction" begin
                    get_continuum_survival_fraction(aoe, e_cal, aoe_config_det.qbb, aoe_config_det.qbb_window; low_cut = result_cut.lowcut,
                                                    high_cut = result_cut.highcut)
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"

                @debug_plot @process_step "$aoe_classifier DS survival fractions plot" begin
                    p = LegendMakie.lplot(report_peaks_ds, figsize = (600, 400*length(report_peaks_ds)),
                                          title = get_plottitle(filekey_det, part, det, "A/E Performance";
                                                                additional_type = string(aoe_classifier)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_peaks_sf_runcal_$aoe_classifier"))
                end

                # save results
                result = merge(result_cut,
                               (peaks = (low = result_peaks_low, ds = result_peaks_ds), qbb = (low = qbb_result_low, ds = qbb_result_ds)))

                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), aoe_classifier, result_cut.lowcut,
                                   result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier] = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

                GC.gc()
            catch e
                e isa ProcessStepError || @error "Error in $aoe_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), aoe_classifier, "-", "-", "-",
                                   truncate_error(e)))

                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
        end

        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_aoe_cut_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_aoe_cut_det)
        write_pars(l200.par.ppars.aoecut[det], part, pars_db_det)
        write_validity(l200.par.ppars.aoecut[det], filekey_det, part)

        return result_det
    end

    # get start time
    start_time = now()

    result_aoe = parallel(det_aoe_cut, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                          process_name = "$period-p_process_aoe_cut_cal")
    @info "Finished AoE cut generation"

    @info "Write $period validity"
    validity_all = create_validity(result_aoe)
    write_validity(l200.par.ppars.aoecut, validity_all)

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
    write_report(get_preportfilename(l200, filekey, :aoe_cut), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_aoe))
end

register_processor!(p_process_aoe_cut_cal)
