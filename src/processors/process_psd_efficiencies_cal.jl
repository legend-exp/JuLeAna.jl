"""
    process_psd_efficiencies_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0, use_partition_pars::Bool=true)

Compute the survival fractions of the combined A/E and LQ cuts for the HPGe detectors (`geds`) of one `cal` run.

For each detector with `usability == :on` and `low_aoe_status` of `:valid` or `:present`, and for each classifier in
the `psd_classifiers` table, the processor applies the A/E and LQ cuts to the `cal` data of the run and fits the
configured peaks and the Qbb window. Survival fractions are evaluated for four selections: the low A/E cut (`low`),
the low and high A/E cuts (`ds`), the low A/E cut and the LQ cut (`low_lq`), and all three cuts (`lq_ds`).

# Inputs
- First `cal` filekey of the run.
- `l200.par.rpars.ecal[period, run]`: the calibration function of the energy type `e_type`.
- A/E and LQ parameters of the run: the `aoe` and `lq` parameters from `ppars` if `use_partition_pars` is `true`,
  otherwise from `rpars`. The low A/E cut is `lowcut` of the A/E classifier and the LQ cut is `highcut` of the LQ
  classifier.
- `jlqcs` tier (single pulse, non-pulser events) and `jldsp` tier of the `cal` run.
- `dataprod_config(l200).psd(filekey).psd`, `default` merged with the detector section: `e_type`, `psd_classifiers`
  (per classifier name, a list of the A/E classifier, the high A/E cut and the LQ classifier), `psd_peaks`,
  `psd_peaks_names`, `psd_peaks_windows_left`, `psd_peaks_windows_right`, `psd_peaks_bin_width_window`,
  `psd_peaks_fit_funcs`, `qbb` and `qbb_window`.

# Outputs
- `l200.par.rpars.psd[period, run]`: per detector and classifier, `cuts` (`lowcut`, `highcut`, `lq`) and the `peaks`
  and `qbb` survival fractions for the four selections, plus the matching validity entry.
- Run report `psd_efficiencies` with the processing status, a metadata table and one result row per detector and
  classifier.
- At the debug plot level, per detector and classifier, the survival fractions of the A/E peaks,
  `aoe_peaks_ds_sf_<classifier>`.
- If `error_plots` is on, a failed A/E data loading saves `error_aoe_data_loading_<classifier>` and a failed survival fraction step `error_survival_fraction_<classifier>`.

# Keywords
- `reprocess`: Discard the existing `psd` parameters of the run and process all detectors and classifiers again.
  Otherwise, classifiers that already have results are kept.
- `timeout`: Seconds allowed per detector in `parallel`; `0` means no limit.
- `use_partition_pars`: If `true` (default), read the A/E and LQ cuts from the partition parameters (`ppars`);
  if `false`, from the run parameters (`rpars`).

# Returns
The return value is not used by `run_processing`.
"""
function process_psd_efficiencies_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                      timeout::Real = 0, use_partition_pars::Bool = true)
    @info "Generate PSD efficiencies for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true) |>
             filterby(@pf $usability == :on && $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) detectors"

    psd_config = dataprod_config(l200).psd(filekey).psd
    @debug "Loaded psd config: $(lstring(psd_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.psd), string(period)))
    pars_db = PropDict(l200.par.rpars.psd[period, run])

    pars_type = ifelse(use_partition_pars, :ppars, :rpars)
    @info "Use $(ifelse(use_partition_pars, "partition", "run"))-based pars from $pars_type for PSD parameters"

    pars_aoe = get_values(l200.par[pars_type, :aoe](filekey))
    @debug "Loaded aoe pars"

    pars_lq = get_values(l200.par[pars_type, :lq](filekey))
    @debug "Loaded lq pars"

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt_cut = NamedTuple{(:Detector, :usability, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"),
                             Symbol("FEP SF"), :CutError)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_psd_sf(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        psd_config_det = merge(psd_config.default, get(psd_config, det, PropDict()))

        e_type = Symbol(psd_config_det.e_type)
        psd_classifiers = collect(keys(psd_config_det.psd_classifiers))
        psd_classifiers_dict = psd_config_det.psd_classifiers

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for psd_classifier in psd_classifiers
                if haskey(pars_db[det], psd_classifier)
                    log_info = log_nt_cut((det, detector_status(chinfo_det.usability), ProcessStatus(1), psd_classifier,
                                           pars_db[det][psd_classifier].cuts.lowcut, pars_db[det][psd_classifier].peaks.ds[:Tl208SEP].sf,
                                           pars_db[det][psd_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[psd_classifier] = log_info
                    processed_dict[psd_classifier] = false
                end
            end
        end

        e_cal, hit_cal = @process_step "hit data loader" begin
            hit_cal = let e_type_cal=e_type, e_type=Symbol(first(split(string(e_type), "_cal")))

                @debug "Reading from $(period)-$(run)"
                cal_func = ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type].cal.func)
                qc_mask = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs, filekey, det)
                read_ldata(row -> merge(NamedTuple{(e_type_cal,)}((cal_func(row),)), row), l200, :jldsp, :cal, period, run, det)[qc_mask]
            end
            getproperty(hit_cal, e_type), hit_cal
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

                plot_aoe_cuts() = begin
                    aoe_name = Symbol(first(split(string(aoe_classifier), "_classifier")))
                    aoe_values = ljl_propfunc(pars_aoe[det][aoe_name].func).(hit_cal)
                    fig = Makie.Figure()
                    ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey, det, "A/E Cuts"; additional_type = string(psd_classifier)),
                                    xlabel = "A/E", ylabel = "Counts")
                    Makie.stephist!(ax, filter(isfinite, aoe_values);
                                    bins = range(quantile(filter(isfinite, aoe_values), [0.001, 0.999])...; length = 201))
                    Makie.vlines!(ax, [mvalue(get(pars_aoe[det][aoe_classifier], :lowcut, NaN))]; color = :red, linestyle = :dash)
                    Makie.vlines!(ax, [aoe_high_cut]; color = :red, linestyle = :dash)
                    save_plot(fig, l200, filekey, det, Symbol("error_aoe_data_loading_$psd_classifier"))
                end
                aoe, aoe_low_cut = @process_step "AoE data loading" on_error = plot_aoe_cuts begin
                    ljl_propfunc(pars_aoe[det][Symbol(first(split(string(aoe_classifier), "_classifier")))].func).(hit_cal),
                    pars_aoe[det][aoe_classifier].lowcut
                end

                lq, lq_cut = @process_step "LQ data loading" begin
                    ljl_propfunc(pars_lq[det][Symbol(first(split(string(lq_classifier), "_classifier")))].func).(hit_cal),
                    pars_lq[det][lq_classifier].highcut
                end

                @debug "Use low A/E cut at $(round(aoe_low_cut, digits=2)) and high A/E cut at $(round(aoe_high_cut, digits=2))"

                plot_cut_spectra() = begin
                    x = ustrip.(e_cal)
                    selections = ["A/E low cut" => (aoe .> mvalue(aoe_low_cut)),
                                  "A/E low and high cut" => (mvalue(aoe_low_cut) .< aoe .< aoe_high_cut),
                                  "A/E and LQ cut" => (mvalue(aoe_low_cut) .< aoe .< aoe_high_cut .&& lq .< lq_cut)]
                    fig = Makie.Figure(size = (900, 300 * cld(length(psd_config_det.psd_peaks), 2)))
                    Makie.Label(fig[0, 1:2],
                                get_plottitle(filekey, det, "PSD Survival Fractions"; additional_type = string(psd_classifier)))
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
                    save_plot(fig, l200, filekey, det, Symbol("error_survival_fraction_$psd_classifier"))
                end
                ### low A/E cut
                result_peaks_low, report_peaks_low = @process_step "AoE peaks low SF" on_error = plot_cut_spectra begin
                    @debug "Generate A/E low Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right;
                                                 low_cut = aoe_low_cut, bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low, _ = @process_step "Qbb low SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(aoe, e_cal, psd_config_det.qbb, psd_config_det.qbb_window; low_cut = aoe_low_cut)
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"

                ### low A/E cut & high A/E cut
                result_peaks_ds, report_peaks_ds = @process_step "AoE peaks DS SF" on_error = plot_cut_spectra begin
                    @debug "Generate A/E DS Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right;
                                                 low_cut = aoe_low_cut, high_cut = aoe_high_cut,
                                                 bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds, _ = @process_step "Qbb DS SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(aoe, e_cal, psd_config_det.qbb, psd_config_det.qbb_window; low_cut = aoe_low_cut,
                                                    high_cut = aoe_high_cut)
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"

                ### low A/E cut & LQ cut
                result_peaks_low_lq, report_peaks_low_lq = @process_step "AoE+LQ peaks low SF" on_error = plot_cut_spectra begin
                    @debug "Generate low A/E + LQ Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right;
                                                 low_cut = aoe_low_cut, selection = lq .< lq_cut,
                                                 bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found low A/E + LQ SEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208SEP].sf, digits=2))"
                @debug "Found low A/E + LQ FEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208FEP].sf, digits=2))"

                qbb_result_low_lq, _ = @process_step "Qbb+LQ low SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(aoe, e_cal, psd_config_det.qbb, psd_config_det.qbb_window; low_cut = aoe_low_cut,
                                                    selection = lq .< lq_cut)
                end

                @debug "Found low A/E + LQ Qbb Survival Fraction at $(round(u"percent", qbb_result_low_lq.sf, digits=2))"

                ### low A/E cut & high A/E cut & LQ cut
                result_peaks_lq_ds, report_peaks_lq_ds = @process_step "AoE+LQ peaks DS SF" on_error = plot_cut_spectra begin
                    @debug "Generate DS A/E + LQ Survival Fractions"
                    get_peaks_survival_fractions(aoe, e_cal, psd_config_det.psd_peaks, Symbol.(psd_config_det.psd_peaks_names),
                                                 psd_config_det.psd_peaks_windows_left, psd_config_det.psd_peaks_windows_right;
                                                 low_cut = aoe_low_cut, high_cut = aoe_high_cut, selection = lq .< lq_cut,
                                                 bin_width_window = psd_config_det.psd_peaks_bin_width_window,
                                                 fit_funcs = Symbol.(psd_config_det.psd_peaks_fit_funcs), uncertainty = true)
                end

                @debug "Found DS A/E + LQ SEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS A/E + LQ FEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_lq_ds, _ = @process_step "Qbb+LQ DS SF" on_error = plot_cut_spectra begin
                    get_continuum_survival_fraction(aoe, e_cal, psd_config_det.qbb, psd_config_det.qbb_window; low_cut = aoe_low_cut,
                                                    high_cut = aoe_high_cut, selection = lq .< lq_cut)
                end

                @debug "Found DS A/E + LQ Qbb Survival Fraction at $(round(u"percent", qbb_result_lq_ds.sf, digits=2))"

                @debug_plot begin
                    p = LegendMakie.lplot(report_peaks_ds, titlesize = 17, figsize = (600, 400*length(report_peaks_ds)),
                                          title = get_plottitle(filekey, det, "A/E DS Performance";
                                                                additional_type = string(psd_classifier)))
                    save_plot(p, l200, filekey, det, Symbol("aoe_peaks_ds_sf_$psd_classifier"))
                end

                # save results
                result = merge((cuts = (lowcut = aoe_low_cut, highcut = aoe_high_cut, lq = lq_cut),),
                               (peaks = (low = result_peaks_low, ds = result_peaks_ds, low_lq = result_peaks_low_lq,
                                         lq_ds = result_peaks_lq_ds),
                                qbb = (low = qbb_result_low, ds = qbb_result_ds, low_lq = qbb_result_low_lq, lq_ds = qbb_result_lq_ds)))

                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), ProcessStatus(1), psd_classifier, aoe_low_cut,
                                       result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[psd_classifier] = result
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = true

                GC.gc()
            catch e
                # a failed `@process_step` has logged its error already
                e isa ProcessStepError || @error "Error in $psd_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((det, detector_status(chinfo_det.usability), ProcessStatus(0), psd_classifier, "-", "-", "-",
                                       truncate_error(e)))

                # add results to dict
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_psd = parallel(det_psd_sf, chinfo, log_nt_cut; timeout = timeout, retry = false,
                          process_name = "$period-$run-process_psd_efficiencies_cal")

    @info "Finished PSD efficiencies"

    pars_db = create_pars(pars_db, result_psd)
    write_pars(l200.par.rpars.psd[period], run, pars_db)
    write_validity(l200.par.rpars.psd, filekey, (period, run))
    @info "Saved pars to disk"

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
    write_report(get_rreportfilename(l200, filekey, :psd_efficiencies), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_psd_efficiencies_cal)
