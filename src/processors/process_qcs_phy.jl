"""
    process_qcs_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Generate the quality-cut (QC) flags and their survival fractions for the `phy` data of the HPGe detectors (`geds`) of a run.

The QC flags are generated per filekey: for each detector, the QC labels and the `is_single_pulse`
and `is_empty_trace` flags defined in the QC configuration are evaluated on the `jldsp` data.
Pulser events and forced-trigger events (without pulser events) are taken from the `aux_trig` flags
of the pulser channel (`pulser.puls_detector`) and of the forced-trigger channel
(`forced_trigger.detector`) of the filekey. Each filekey also counts its global events (built from
the detectors of the event-tier selection) that pass QC, i.e. in which every germanium row is a
single pulse, an empty trace or crosstalk. Each detector is then summarized over the run without the
removed filekeys: the survival fraction of each flag is computed for the pulser events and for the
forced-trigger events. A detector with single-pulse events that fail the `is_valid_dsp` flag gets the
status warning. The pulser single-pulse and forced-trigger empty-trace survival fractions of each
filekey are compared with those of the other nonremoved filekeys by an exact count test, and
deviations above `filekey_stability.sigma` of the QC config are reported without changing the status.

# Inputs
- `jldsp` tier of the `phy` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `jlaux` tier column `aux_trig` of the pulser and forced-trigger channels
- the filekeys marked removed in `datasets/ignored_daq_cycles`, which are left out of the run summary
- `dataprod_config(l200).qc(filekey)`, and the event-tier detector selection and crosstalk definition
- `l200.par.rpars.qcs[period, Symbol("<run>-phy")]` (existing parameters, unless `reprocess` is `true`)

# Outputs
- `jlqcs` tier file for each filekey, with one table per detector (QC flags, `timestamp`, `is_pulser`, `is_forced`)
- `l200.par.rpars.qcs[period, Symbol("<run>-phy")]` (flag definition, survival fractions, event counts, and per filekey the event counts and stability tests in `filekey_summary`; the global event QC survival in `event_survival`) with its validity (category `phy`)
- plots `:qc_filekey_efficiency`, `:qc_survival_fractions` and `:qc_survival_fractions_forced_trigger` for each detector; `:qc_survival_fractions_forced_trigger` is saved only at the debug plot level
- run report `:qcs_phy`, with the global event QC survival, the stability warnings, one row per detector and one row per filekey

# Keywords
- `reprocess`: remove the existing `jlqcs` files and parameters and process all detectors again; otherwise detectors already present in a `jlqcs` file are skipped there. The run summary of every detector is always recomputed.
- `timeout`: seconds allowed per filekey and per detector summary in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)

# Returns
Return `nothing`.
"""
function process_qcs_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         use_cache::Bool = true)
    @info "Generate physics QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :phy)).keys))
    # Removed filekeys keep their QC flags and filekey diagnostics but do not enter the run summary.
    removed_filekeys = bad_filekeys(l200; load_key = :removed)
    included_filekeys = .!in.(filekeys, Ref(removed_filekeys))
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_qcs_phy)
    @info "Loaded channel info with $(length(chinfo)) detectors"
    event_detectors = filterby(get_ged_evt_detsel_propfunc(l200, filekey))(channelinfo(l200, filekey; system = :geds)).detector
    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"
    stability_sigma = qc_config.filekey_stability.sigma

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.qcs), string(period)))
    pars_file = Symbol("$(run)-phy")
    pars_db = PropDict(l200.par.rpars.qcs[period, pars_file])
    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :psd_usability, :Status, Symbol("Pulser single-pulse SF"),
                         Symbol("Forced-trigger empty-trace SF"),
                         Symbol("Number Pulser Events"), Symbol("Number Forced-trigger Events"), Symbol("Number Physics Events"),
                         Symbol("Single pulses with invalid DSP properties"), :Error)}
    log_fk_nt = NamedTuple{(:Filekey, :Status, Symbol("Processed Detectors"), Symbol("Failed Detectors"), :Error)}

    # flush stdout
    flush(stdout)

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    chinfo_forced = channelinfo(l200, filekey, Symbol(qc_config.forced_trigger.detector))
    det_forced = chinfo_forced.detector

    function filekey_qcs(fk::FileKey)
        n_processed = 0
        failed_detectors = DetectorId[]
        # The auxiliary trigger flags of the filekey are shared by all detectors.
        # jlaux groups are LH5 structs, for which a single-column read returns the bare column.
        is_pulser = read_ldata(:aux_trig, l200, DataTier(:jlaux), fk, det_puls)
        is_forced = read_ldata(:aux_trig, l200, DataTier(:jlaux), fk, det_forced) .&& .!is_pulser
        write_files(l200.tier[:jlqcs, fk]; use_cache, mode = CreateOrModify()) do outfilename
            if reprocess && isfile(outfilename)
                rm(outfilename; force = true)
            end
            lh5open(outfilename, "cw") do outdata
                processed_detectors = stored_detectors(outdata, "jlqcs")
                for chinfo_det in chinfo
                    det = chinfo_det.detector
                    detector_selected(det) || continue
                    if "$det" in processed_detectors && !redo_detector(det)
                        @info "QC flags of detector $det in $fk already exist, skip"
                        continue
                    end
                    try
                        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))
                        timestamps = read_ldata(:timestamp, l200, DataTier(:jldsp), fk, det).timestamp
                        qc_labels = read_ldata(ljl_propfunc(qc_config_det.labels), l200, DataTier(:jldsp), fk, det)
                        is_single_pulse = ljl_propfunc(qc_config_det.is_single_pulse).(qc_labels)
                        is_empty_trace = ljl_propfunc(qc_config_det.is_empty_trace).(qc_labels)
                        "$det" in processed_detectors && delete_entry!(outdata, "jlqcs/$det")
                        outdata[:jlqcs, det] = Table(merge(columns(qc_labels),
                                                           (; timestamp = timestamps, is_single_pulse, is_empty_trace, is_pulser, is_forced)))
                        n_processed += 1
                    catch e
                        @error "QC failed for $det in $fk: $(truncate_error(e))"
                        push!(failed_detectors, det)
                    end
                end
            end
        end
        # Count each global event of the filekey once. Only `run_step` with temporary outputs writes the
        # flags of the selected detectors alone, so only there the events are built from those.
        event_counts = @process_step "event QC survival" begin
            evt_dets = WRITE_PARS[] ? event_detectors : filter(detector_selected, event_detectors)
            event_data = Dict{DetectorId,StructArray}()
            for det in evt_dets
                qc = read_ldata(l200, DataTier(:jlqcs), fk, det)
                is_crosstalk = get_ged_qc_is_crosstalk_propfunc(l200, filekey, det).(qc)
                event_data[det] = StructArray(timestamp = qc.timestamp, is_valid_qc = qc.is_single_pulse .| qc.is_empty_trace .| is_crosstalk,
                                              is_pulser = qc.is_pulser, is_forced = qc.is_forced)
            end
            events = build_global_events(event_data, evt_dets)
            passed = all.(events.is_valid_qc)
            pulser = any.(events.is_pulser)
            forced = any.(events.is_forced) .& .!pulser
            other = .!pulser .& .!forced
            (n_events = length(events), n_pass = count(passed), n_pulser = count(pulser), n_pulser_pass = count(passed .& pulser),
             n_forced = count(forced), n_forced_pass = count(passed .& forced), n_other = count(other), n_other_pass = count(passed .& other))
        end
        return (result = (event_counts = event_counts,), processed = n_processed > 0,
                log = log_fk_nt((fk, ProcessStatus(isempty(failed_detectors) ? 1 : 0), n_processed, string.(failed_detectors), "")))
    end

    function det_qcs_phy(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))

        @debug "Summarize QC for detector $det ($ch)"
        qc_parts, qc = @process_step "data loader" begin
            # Per filekey for the filekey summary, which includes the removed filekeys.
            qc_parts = [read_ldata(l200, DataTier(:jlqcs), fk, det) for fk in filekeys]
            qc_parts, reduce(vcat, qc_parts[included_filekeys]; init = first(qc_parts)[1:0])
        end
        flag_names = [Symbol.(keys(qc_config_det.labels))...; :is_single_pulse; :is_empty_trace]
        qc_propfunc = merge(qc_config_det.labels,
                            PropDict(:is_single_pulse => qc_config_det.is_single_pulse, :is_empty_trace => qc_config_det.is_empty_trace))
        is_pulser = qc.is_pulser
        is_forced = qc.is_forced

        n_single_pulse = count(qc.is_single_pulse)
        n_physics = count(qc.is_single_pulse .&& .!is_pulser)
        n_invalid_dsp_single_pulse = count(qc.is_single_pulse .&& .!qc.is_valid_dsp)
        if n_invalid_dsp_single_pulse > 0
            @warn "Detector $det ($ch): $n_invalid_dsp_single_pulse of $n_single_pulse single-pulse events fail is_valid_dsp; check the QC cuts"
        end

        n_pulser = count(is_pulser)
        n_forced = count(is_forced)
        pulser_sf, forced_trigger_sf = @process_step "survival fractions" begin
            pulser_sf_values = [(n_pulser == 0 ? NaN : count(getproperty(qc, flag_name)[is_pulser]) / n_pulser) * 100u"percent"
                                for flag_name in flag_names]
            forced_trigger_sf_values = [(n_forced == 0 ? NaN : count(getproperty(qc, flag_name)[is_forced]) / n_forced) * 100u"percent"
                                        for flag_name in flag_names]
            NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values)), NamedTuple{Tuple(flag_names)}(Tuple(forced_trigger_sf_values))
        end
        survival_fractions = (pulser = pulser_sf, forced_trigger = forced_trigger_sf)

        # Per-filekey counts, of the removed filekeys too, for the stability test and diagnostics.
        filekey_summary = PropDict()
        for (fk, qc_part) in zip(filekeys, qc_parts)
            pulser = qc_part.is_pulser
            filekey_summary[Symbol(fk)] = PropDict(:is_removed => fk in removed_filekeys, :n_events => length(qc_part),
                                                   :n_pulser => count(pulser), :n_nonpulser => count(.!pulser),
                                                   :n_single_pulse => count(qc_part.is_single_pulse),
                                                   :n_pulser_pass => count(qc_part.is_single_pulse .& pulser),
                                                   :n_nonpulser_pass => count(qc_part.is_single_pulse .& .!pulser),
                                                   :n_forced => count(qc_part.is_forced),
                                                   :n_forced_pass => count(qc_part.is_empty_trace .& qc_part.is_forced))
        end
        stability_warnings = @process_step "filekey stability" begin
            selections = ((name = :pulser, n = :n_pulser, k = :n_pulser_pass, monitor = true, label = "Pulser single pulse",
                           color = LegendMakie.AchatBlue),
                          (name = :forced_trigger, n = :n_forced, k = :n_forced_pass, monitor = true, label = "Forced trigger empty trace",
                           color = LegendMakie.BEGeOrange))
            warnings, fig = qc_filekey_stability!(filekey_summary, det, filekeys, included_filekeys, selections; stability_sigma,
                                                  title = get_plottitle(filekey, det, "QC Survival Fractions per Filekey"))
            save_plot(fig, l200, filekey, det, :qc_filekey_efficiency)
            warnings
        end
        status_messages = String[]
        n_invalid_dsp_single_pulse > 0 && push!(status_messages, "$n_invalid_dsp_single_pulse single-pulse events fail is_valid_dsp.")
        isempty(stability_warnings) ||
            push!(status_messages, "$(length(stability_warnings)) filekey survival fractions deviate by more than $(stability_sigma)σ; see QC stability warnings.")

        # Survival fractions of is_single_pulse and is_empty_trace and of the flags they combine
        @process_step "pulser survival fraction plot" begin
            fig = plot_qc_survival_fractions([_input_columns([ljl_propfunc(qc_config_det.is_single_pulse)]); :is_single_pulse],
                                             (("Pulser", pulser_sf, LegendMakie.AchatBlue),);
                                             title = get_plottitle(filekey, det, "Pulser QC Survival Fractions"))
            save_plot(fig, l200, filekey, det, :qc_survival_fractions)
        end

        @debug_plot @process_step "forced-trigger survival fraction plot" begin
            fig = plot_qc_survival_fractions([_input_columns([ljl_propfunc(qc_config_det.is_empty_trace)]); :is_empty_trace],
                                             (("Forced trigger", forced_trigger_sf, LegendMakie.BEGeOrange),);
                                             title = get_plottitle(filekey, det, "Forced-trigger QC Survival Fractions"))
            save_plot(fig, l200, filekey, det, :qc_survival_fractions_forced_trigger)
        end

        log_det = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability),
                          # Filekey deviations are only reported; they leave the detector and processor status unchanged.
                          ProcessStatus(n_invalid_dsp_single_pulse > 0 ? -1 : 1), pulser_sf.is_single_pulse, forced_trigger_sf.is_empty_trace, n_pulser, n_forced, n_physics,
                          n_invalid_dsp_single_pulse, isempty(status_messages) ? "-" : join(status_messages, " ")))
        return (result = (func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser, n_forced = n_forced,
                          n_single_pulse = n_single_pulse, n_physics = n_physics, n_invalid_dsp_single_pulse = n_invalid_dsp_single_pulse),
                filekey_summary = filekey_summary, warnings = stability_warnings, log = log_det, processed = true)
    end

    # get start time
    start_time = now()

    # Generate the QC flags per filekey before the run summary of each detector.
    result_filekeys = parallel(filekey_qcs, filekeys, log_fk_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_phy")
    result_qc = parallel(det_qcs_phy, chinfo, log_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_phy-summary")

    @info "Finished physics QC detector processing"

    # The run summary replaces the previous results of each detector.
    for (chinfo_det, res) in result_qc
        det = Symbol(chinfo_det.detector)
        haskey(res, :filekey_summary) ? (pars_db[det] = PropDict(:filekey_summary => res.filekey_summary)) : delete!(pars_db, det)
    end
    pars_db = create_pars(pars_db, result_qc)
    # Run totals exclude the removed filekeys, whose counts remain in the filekey summary.
    event_survival = PropDict(:filekey_summary => PropDict(), :survival_fractions => PropDict(), :n_detectors => length(event_detectors),
                              :complete => all(haskey(res, :result) for (_, res) in result_filekeys))
    for (fk, res) in result_filekeys
        haskey(res, :result) &&
            (event_survival.filekey_summary[Symbol(fk)] = PropDict(pairs(merge(res.result.event_counts, (is_removed = fk in removed_filekeys,)))))
    end
    event_row_nt = NamedTuple{(:Selection, :Events, :Accepted, Symbol("Survival (%)")),Tuple{String,Int,Int,Float64}}
    event_rows = event_row_nt[]
    for (selection, n_key, k_key, label) in ((:all, :n_events, :n_pass, "All events"), (:pulser, :n_pulser, :n_pulser_pass, "Pulser"),
                                             (:forced_trigger, :n_forced, :n_forced_pass, "Forced trigger"),
                                             (:other, :n_other, :n_other_pass, "Other triggers"))
        counted = [res.result.event_counts for (fk, res) in result_filekeys if !(fk in removed_filekeys) && haskey(res, :result)]
        n = sum(getproperty.(counted, n_key); init = 0)
        k = sum(getproperty.(counted, k_key); init = 0)
        efficiency = n == 0 ? NaN : 100 * k / n
        event_survival.survival_fractions[selection] = PropDict(:n_events => n, :n_pass => k, :efficiency => efficiency)
        push!(event_rows, event_row_nt((label, n, k, efficiency)))
    end
    pars_db[:event_survival] = event_survival
    write_pars(l200.par.rpars.qcs[period], pars_file, pars_db)
    write_validity(l200.par.rpars.qcs, filekey, "$(period)/$(pars_file).yaml"; category = :phy)
    @info "Saved QC-survival pars to disk"

    warning_rows = reduce(vcat, (res.warnings for (_, res) in result_qc if haskey(res, :warnings)); init = QCStabilityWarning[])

    # Disabled until legend-exp/LegendMakie.jl#76 is fixed: LegendMakie's lplot and
    # parameterplot use Makie's global current axis, which steps running at the same time overwrite.
    # # plot the final survival fractions for all detectors from the parameter database
    # fig = LegendMakie.lplot(
    #     chinfo, pars_db, [:survival_fractions, :pulser, :is_single_pulse];
    #     figsize = (max(1600, 18 * length(chinfo)), 600),
    #     ylabel = "Survival fraction (%)", color = LegendMakie.AchatBlue,
    #     label = "Pulser", detector_status_colors = true, watermark = false)
    # ax = Makie.current_axis()
    # LegendMakie.parameterplot!(
    #     ax, chinfo, pars_db, [:survival_fractions, :forced_trigger, :is_empty_trace];
    #     ylabel = "Survival fraction (%)", color = LegendMakie.BEGeOrange,
    #     label = "Forced trigger empty trace", detector_status_colors = true)
    # ax.title = get_plottitle(filekey, :all, "QC Survival Fractions")
    # Makie.axislegend(ax, position = :lb, orientation = :horizontal,
    #     framevisible = true, framecolor = :lightgray)
    # LegendMakie.add_watermarks!(final = true)
    # @debug_plot save_plot(fig, l200, filekey, :all, :qc_survival_fractions; cleanup = false)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_qcs_phy, result_filekeys, result_qc)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_phy_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Overall event QC survival")
    lreport!(report,
             "An event passes when every participating germanium row passes is_single_pulse, is_empty_trace, or is_crosstalk, using the event-tier detector selection and timestamp grouping. " *
             "Each global event is counted once. Removed filekeys are excluded; no trigger multiplicity, energy, or PSD selection is applied. Other triggers exclude pulser and forced-trigger events.")
    lreport!(report, StructArray(event_rows))
    event_survival.complete ||
        lreport!(report, "Incomplete event summary: one or more filekeys failed. Counts cover only successfully summarized filekeys; see Filekey Results.")
    lreport!(report, "# QC stability warnings")
    lreport!(report,
             "Pulser single-pulse and forced-trigger empty-trace survival fractions of filekeys that deviate from the other nonremoved filekeys by more than $(stability_sigma)σ.")
    lreport!(report, isempty(warning_rows) ? "No unexpected filekey survival fraction deviations." : StructArray(warning_rows))
    # lreport!(report, "# Detector overview")
    # lreport!(report, fig)
    lreport!(report, "\n# Results")
    lreport!(report, create_logtbl(result_qc))
    lreport!(report, "\n# Filekey Results")
    lreport!(report, create_logtbl(result_filekeys))

    report_filename = get_rreportfilename(l200, filekey, :qcs_phy)

    @info "Write log report"
    write_report(report_filename, report)
    @info report
    # Base.empty!(fig)

    # flush stdout
    return flush(stdout)
end

register_processor!(process_qcs_phy; output_tiers = [:jlqcs])
