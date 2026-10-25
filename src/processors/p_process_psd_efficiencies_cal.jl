"""
    p_process_psd_efficiencies_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Compute the survival fractions of the combined A/E and LQ cuts for every detector and `cal` partition that contains `period`.

The `cal` data of all runs in a detector's partition are calibrated with `calibrate_ged_detector_data`, which applies
the A/E and LQ cut flags (`<A/E classifier>_low_cut` and `<LQ classifier>_high_cut`) from the parameters selected by
`get_ged_evt_kwargs`. The high A/E cut is taken from the `psd_classifiers` table of the configuration. Peaks and the
Qbb window are fitted for five selections: the low A/E cut (`low`), the high A/E cut (`high`), the low and high A/E
cuts (`ds`), the low A/E cut and the LQ cut (`low_lq`), and all three cuts (`lq_ds`). Detectors with `low_aoe_status`
of `:valid` or `:present` are processed.

# Inputs
- `jlqcs` tier (single pulse, non-pulser events) and `jldsp` tier of all `cal` runs in the partition.
- Calibration and cut parameters as read by `calibrate_ged_detector_data` with the keyword arguments of
  `get_ged_evt_kwargs(l200, filekey)`.
- `dataprod_config(l200).psd(filekey).psd` of the first run of the partition, `default` merged with the detector
  section: `e_type`, `psd_classifiers` (per classifier name, a list of the A/E classifier, the high A/E cut and the LQ
  classifier), `psd_peaks`, `psd_peaks_names`, `psd_peaks_windows_left`, `psd_peaks_windows_right`,
  `psd_peaks_bin_width_window`, `psd_peaks_fit_funcs`, `qbb` and `qbb_window`.

# Outputs
- `l200.par.ppars.psd[det, part]`: per classifier, `cuts` (`highcut` is the configured high A/E cut; `lowcut` and `lq`
  are stored as `NaN`) and the `peaks` and `qbb` survival fractions for the five selections, plus the validity of
  `ppars.psd` for `period`. The file is written only if the detector has results.
- Partition report `psd_efficiencies` with the processing status, a metadata table and one result row per detector,
  partition and classifier.
- At the debug plot level, per detector and classifier, the survival fractions of the A/E peaks,
  `aoe_peaks_sf_<classifier>`.
- If `error_plots` is on, a failed survival fraction step saves `error_survival_fraction_<classifier>`.

# Keywords
- `reprocess`: Discard the existing `ppars.psd` parameters of each detector and partition and process all
  classifiers again. Otherwise, classifiers that already have results are kept.
- `timeout`: Seconds allowed per detector and partition in `parallel`; `0` means no limit.
- `only_first_period`: If `true`, a detector whose partition starts in an earlier period is skipped and logged as
  skipped. `run_processing` sets it to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`. `run_processing` uses
this to wait for the same step in the previous period.
"""
function p_process_psd_efficiencies_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                                        only_first_period::Bool = true)
    @info "Generate PSD efficiencies for all partitions containing period $period"

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
    log_nt_cut = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"),
                             Symbol("FEP SF"), :CutError)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_psd_sf(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        make_par_dir(joinpath(data_path(l200.par.ppars.psd), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.psd), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.psd[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.psd), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        # load config
        psd_config = dataprod_config(l200).psd(filekey_det).psd
        psd_config_det = merge(psd_config.default, get(psd_config, det, PropDict()))
        @debug "Loaded psd config: $(lstring(psd_config_det))"

        e_type = Symbol(psd_config_det.e_type)
        psd_classifiers = collect(keys(psd_config_det.psd_classifiers))
        psd_classifiers_dict = psd_config_det.psd_classifiers

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for psd_classifier in psd_classifiers
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, process_skipped, psd_classifier, fill("-", 3)...,
                                       "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for psd_classifier in psd_classifiers
                if haskey(pars_db_det[det], psd_classifier)
                    log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), psd_classifier,
                                           pars_db_det[det][psd_classifier].cuts.lowcut,
                                           pars_db_det[det][psd_classifier].peaks.ds[:Tl208SEP].sf,
                                           pars_db_det[det][psd_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[psd_classifier] = log_info
                    processed_dict[psd_classifier] = false
                end
            end
        end

        e_cal, hit_cal = @process_step "E data loading" begin
            hpge_kwargs = get_ged_evt_kwargs(l200, filekey_det)
            if !all([haskey(processed_dict, psd_classifier) for psd_classifier in psd_classifiers])
                hit_cal = fast_flatten([let
                                            qc_mask = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs, pinfo.cal.startkey,
                                                                 det)
                                            dsp = read_ldata(l200, :jldsp, :cal, pinfo.period, pinfo.run, det)[qc_mask]
                                            @debug "Calibrating $(pinfo.period)-$(pinfo.run)"
                                            calibrate_ged_detector_data(l200, pinfo.cal.startkey, det, dsp; keep_detdata = true,
                                                                        hpge_kwargs...)
                                        end
                                        for pinfo in partinfo_det])
                collect(getproperty(hit_cal, e_type)), hit_cal
            else
                nothing, nothing
            end
        end

        @debug_progress "Detector: $det" for psd_classifier in psd_classifiers
            if haskey(processed_dict, psd_classifier)
                continue
            end
            try
                @debug "Generate $psd_classifier cut"

                aoe_classifier = Symbol(psd_classifiers_dict[psd_classifier][1])
                aoe_high_cut = psd_classifiers_dict[psd_classifier][2]
                lq_classifier = Symbol(psd_classifiers_dict[psd_classifier][3])

                aoe_low_cut_vec, aoe_high_cut_vec, aoe_ds_cut_vec = @process_step "AoE data loading" begin
                    .!getproperty(hit_cal, Symbol("$(aoe_classifier)_low_cut")), .!(getproperty(hit_cal, Symbol("$(aoe_classifier)")) .> aoe_high_cut),
                    .!(getproperty(hit_cal, Symbol("$(aoe_classifier)_low_cut")) .|| getproperty(hit_cal, Symbol("$(aoe_classifier)")) .> aoe_high_cut)
                end

                lq_high_cut_vec = @process_step "LQ data loading" begin
                    .!getproperty(hit_cal, Symbol("$(lq_classifier)_high_cut"))
                end

                plot_cut_spectra() = begin
                    x = ustrip.(e_cal)
                    selections = ["A/E low cut" => aoe_low_cut_vec, "A/E high cut" => aoe_high_cut_vec,
                                  "A/E low and high cut" => aoe_ds_cut_vec, "A/E and LQ cut" => (aoe_ds_cut_vec .&& lq_high_cut_vec)]
                    fig = Makie.Figure(size = (900, 300 * cld(length(psd_config_det.psd_peaks), 2)))
                    Makie.Label(fig[0, 1:2],
                                get_plottitle(filekey_det, part, det, "PSD Survival Fractions"; additional_type = string(psd_classifier)))
                    for (i, peak) in pairs(psd_config_det.psd_peaks)
                        lo = ustrip(unit(first(e_cal)), peak - psd_config_det.psd_peaks_windows_left[i])
                        hi = ustrip(unit(first(e_cal)), peak + psd_config_det.psd_peaks_windows_right[i])
                        in_peak = lo .< x .< hi
                        ax = Makie.Axis(fig[cld(i, 2), mod1(i, 2)]; title = string(psd_config_det.psd_peaks_names[i]),
                                        xlabel = "Energy ($(unit(first(e_cal))))", ylabel = "Counts")
                        Makie.stephist!(ax, x[in_peak]; bins = range(lo, hi; length = 51), label = "all")
                        for (name, sel) in selections
                            Makie.stephist!(ax, x[in_peak .&& sel]; bins = range(lo, hi; length = 51), label = name)
                        end
                        i == 1 && Makie.axislegend(ax)
                    end
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_survival_fraction_$psd_classifier"))
                end
                ## low A/E cut
                result_peaks_low, report_peaks_low = @process_step "AoE peaks low SF" on_error = plot_cut_spectra begin
                    @debug "Generate A/E low Survival Fractions"
                    get_peaks_survival_fractions(e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right,
                                                 aoe_low_cut_vec; bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low, _ = @process_step "Qbb low SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(e_cal, psd_config_det.qbb, psd_config_det.qbb_window, aoe_low_cut_vec)
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"

                ## high A/E cut
                result_peaks_high, report_peaks_high = @process_step "AoE peaks high SF" on_error = plot_cut_spectra begin
                    @debug "Generate A/E high Survival Fractions"
                    get_peaks_survival_fractions(e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right,
                                                 aoe_high_cut_vec; bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found high SEP Survival Fraction at $(round(u"percent", result_peaks_high[:Tl208SEP].sf, digits=2))"
                @debug "Found high FEP Survival Fraction at $(round(u"percent", result_peaks_high[:Tl208FEP].sf, digits=2))"

                qbb_result_high, _ = @process_step "Qbb high SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(e_cal, psd_config_det.qbb, psd_config_det.qbb_window, aoe_high_cut_vec)
                end

                @debug "Found high Qbb Survival Fraction at $(round(u"percent", qbb_result_high.sf, digits=2))"

                ### low A/E cut & high A/E cut
                result_peaks_ds, report_peaks_ds = @process_step "AoE peaks DS SF" on_error = plot_cut_spectra begin
                    @debug "Generate A/E DS Survival Fractions"
                    get_peaks_survival_fractions(e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right,
                                                 aoe_ds_cut_vec; bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds, _ = @process_step "Qbb DS SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(e_cal, psd_config_det.qbb, psd_config_det.qbb_window, aoe_ds_cut_vec)
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"

                ### low A/E cut & LQ cut
                result_peaks_low_lq, report_peaks_low_lq = @process_step "AoE+LQ peaks low SF" on_error = plot_cut_spectra begin
                    @debug "Generate low A/E + LQ Survival Fractions"
                    get_peaks_survival_fractions(e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right,
                                                 aoe_low_cut_vec .&& lq_high_cut_vec;
                                                 bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found low A/E + LQ SEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208SEP].sf, digits=2))"
                @debug "Found low A/E + LQ FEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208FEP].sf, digits=2))"

                qbb_result_low_lq, _ = @process_step "Qbb+LQ low SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(e_cal, psd_config_det.qbb, psd_config_det.qbb_window,
                                                    aoe_low_cut_vec .&& lq_high_cut_vec)
                end

                @debug "Found low A/E + LQ Qbb Survival Fraction at $(round(u"percent", qbb_result_low_lq.sf, digits=2))"

                ### low A/E cut & high A/E cut & LQ cut
                result_peaks_lq_ds, report_peaks_lq_ds = @process_step "AoE+LQ peaks DS SF" on_error = plot_cut_spectra begin
                    @debug "Generate DS A/E + LQ Survival Fractions"
                    get_peaks_survival_fractions(e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right,
                                                 aoe_ds_cut_vec .&& lq_high_cut_vec;
                                                 bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found DS A/E + LQ SEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS A/E + LQ FEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_lq_ds, _ = @process_step "Qbb+LQ DS SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(e_cal, psd_config_det.qbb, psd_config_det.qbb_window,
                                                    aoe_ds_cut_vec .&& lq_high_cut_vec)
                end

                @debug "Found DS A/E + LQ Qbb Survival Fraction at $(round(u"percent", qbb_result_lq_ds.sf, digits=2))"

                @debug_plot begin
                    p = LegendMakie.lplot(report_peaks_ds, titlesize = 17, figsize = (600, 400*length(report_peaks_ds)),
                                          title = get_plottitle(filekey_det, part, det, "A/E Performance";
                                                                additional_type = string(psd_classifier)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_peaks_sf_$psd_classifier"))
                end

                # save results
                result = merge((cuts = (lowcut = NaN, highcut = aoe_high_cut, lq = NaN),),
                               (peaks = (low = result_peaks_low, high = result_peaks_high, ds = result_peaks_ds,
                                         low_lq = result_peaks_low_lq, lq_ds = result_peaks_lq_ds),
                                qbb = (low = qbb_result_low, high = qbb_result_high, ds = qbb_result_ds, low_lq = qbb_result_low_lq,
                                       lq_ds = qbb_result_lq_ds)))

                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), psd_classifier, NaN,
                                       result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[psd_classifier] = result
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = true

                GC.gc()
            catch e
                # a failed `@process_step` has logged its error already
                e isa ProcessStepError || @error "Error in $psd_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), psd_classifier, "-", "-", "-",
                                       truncate_error(e)))

                # add results to dict
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = false
            end
        end
        # cleanup log and combine
        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_psd_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_psd_det)
        if !isempty(pars_db_det)
            write_pars(l200.par.ppars.psd[det], part, pars_db_det)
            write_validity(l200.par.ppars.psd[det], filekey_det, part)
        end

        return result_det
    end

    # get start time
    start_time = now()

    result_psd = parallel(det_psd_sf, chinfo_unfolded, log_nt_cut; timeout = timeout, retry = false,
                          process_name = "$period-p_process_psd_efficiencies_cal")
    @info "Finished AoE cut generation"

    @info "Write $period validity"
    validity_all = create_validity(result_psd)
    write_validity(l200.par.ppars.psd, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_psd)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, psd_efficiencies_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_psd))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :psd_efficiencies), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_psd))
end

register_processor!(p_process_psd_efficiencies_cal)
