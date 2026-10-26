"""
    process_qcs_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0, stability_sigma::Real=5.0)

Generate the quality-cut (QC) flags and their survival fractions for the `phy` data of the HPGe detectors (`geds`) of a run.

The QC flags are generated per filekey: for each detector, the QC labels and the `is_single_pulse`
and `is_empty_trace` flags defined in the QC configuration are evaluated on the `jldsp` data.
Pulser events and forced-trigger events (without pulser events) are taken from the `aux_trig` flags
of the pulser channel (`pulser.puls_detector`) and of the forced-trigger channel
(`forced_trigger.detector`) of the filekey. Each filekey also counts its global events (built from
the detectors of the event-tier selection) that pass QC, i.e. in which every germanium row is a
single pulse, an empty trace or crosstalk. Each detector is then summarized over the run without the
removed filekeys: the survival fraction of each flag is computed for the pulser events and for the
forced-trigger events. A warning is logged if single-pulse events fail the `is_valid_dsp` flag. The
pulser single-pulse and forced-trigger empty-trace survival fractions of each filekey are compared
with those of the other nonremoved filekeys by an exact count test, and deviations above
`stability_sigma` are reported; the non-pulser survival fraction is shown for diagnosis only.

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
- `stability_sigma`: deviation, in Gaussian standard deviations, above which a filekey survival fraction is reported (default: `5.0`)

# Returns
Return `nothing`.
"""
function process_qcs_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         use_cache::Bool = true, stability_sigma::Real = 5.0)
    isfinite(stability_sigma) && stability_sigma > 0 || throw(ArgumentError("stability_sigma must be finite and positive"))

    @info "Generate physics QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :phy)).keys))
    # Removed filekeys keep their QC flags and filekey diagnostics but do not enter the run summary.
    removed_filekeys = bad_filekeys(l200; load_key = :removed)
    included_filekeys = .!in.(filekeys, Ref(removed_filekeys))
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"
    event_detectors = filterby(get_ged_evt_detsel_propfunc(l200, filekey))(channelinfo(l200, filekey; system = :geds)).detector
    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.qcs), string(period)))
    pars_file = Symbol("$(run)-phy")
    pars_db = PropDict(l200.par.rpars.qcs[period, pars_file])
    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Pulser single-pulse SF"), Symbol("Forced-trigger empty-trace SF"),
                         Symbol("Number Pulser Events"), Symbol("Number Forced-trigger Events"), Symbol("Number Physics Events"),
                         Symbol("Single pulses with invalid DSP properties"), :Error)}
    log_fk_nt = NamedTuple{(:Filekey, :Status, Symbol("Processed Detectors"), Symbol("Failed Detectors"), :Error)}
    warning_nt = NamedTuple{(:Detector, :Filekey, :Selection, Symbol("Efficiency (%)"), Symbol("Reference (%)"), :Events, Symbol("Reference events"),
                             Symbol("Deviation (σ)")),Tuple{DetectorId,FileKey,Symbol,Float64,Float64,Int,Int,Float64}}

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
            qc_parts = [read_ldata(l200, DataTier(:jlqcs), fk, det) for fk in filekeys]
            qc_parts, reduce(vcat, qc_parts[included_filekeys]; init = first(qc_parts)[1:0])
        end
        single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
        empty_trace_pf = ljl_propfunc(qc_config_det.is_empty_trace)
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
            # Compare each filekey with the pooled other nonremoved filekeys, using an exact two-sample count test.
            summaries = [filekey_summary[Symbol(fk)] for fk in filekeys]
            foreach(summary -> summary[:stability] = PropDict(), summaries)
            warnings = warning_nt[]
            x_fk = collect(eachindex(filekeys))
            tick_indices = unique(round.(Int, range(1, length(filekeys); length = min(12, length(filekeys)))))
            fig = Makie.Figure(size = (1100, 500))
            ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey, det, "QC Efficiency per Filekey"), xlabel = "Filekey start (UTC)", ylabel = "Survival fraction (%)",
                            xticks = (tick_indices, [string(filekeys[i].time) for i in tick_indices]), xticklabelrotation = pi / 3,
                            limits = (nothing, (-2, 102)))
            for (selection, n_key, k_key, color, label, monitor) in ((:pulser, :n_pulser, :n_pulser_pass, LegendMakie.AchatBlue, "Pulser single pulse", true),
                                                                     (:nonpulser, :n_nonpulser, :n_nonpulser_pass, LegendMakie.BEGeOrange, "Non-pulser single pulse", false),
                                                                     (:forced_trigger, :n_forced, :n_forced_pass, :purple, "Forced trigger empty trace", true))
                n = [getproperty(summary, n_key) for summary in summaries]
                k = [getproperty(summary, k_key) for summary in summaries]
                efficiency = [n[i] == 0 ? NaN : k[i] / n[i] for i in eachindex(n)]
                total_n, total_k = sum(n[included_filekeys]), sum(k[included_filekeys])
                outliers = Int[]
                for i in eachindex(filekeys)
                    ref_n = total_n - (included_filekeys[i] ? n[i] : 0)
                    ref_k = total_k - (included_filekeys[i] ? k[i] : 0)
                    reference = ref_n == 0 ? NaN : ref_k / ref_n
                    sigma = NaN
                    if n[i] > 0 && ref_n > 0
                        # Exact two-sample count test: conditioning on the total accepted and rejected counts
                        # includes the reference uncertainty and handles survival fractions of 0 and 100 %.
                        null = Hypergeometric(k[i] + ref_k, n[i] + ref_n - k[i] - ref_k, n[i])
                        tail = min(cdf(null, k[i]), ccdf(null, k[i] - 1), 0.5)
                        sigma = sign(efficiency[i] - reference) * -quantile(Normal(), max(tail, floatmin(Float64)))
                    end
                    flagged = monitor && included_filekeys[i] && abs(sigma) > stability_sigma
                    summaries[i].stability[selection] = PropDict(:reference => 100 * reference, :reference_events => ref_n, :sigma => sigma,
                                                                 :flagged => flagged, :available => isfinite(sigma))
                    if flagged
                        push!(outliers, i)
                        push!(warnings, warning_nt((det, filekeys[i], selection, 100 * efficiency[i], 100 * reference, n[i], ref_n, sigma)))
                    end
                end
                # Wilson one-sigma intervals remain meaningful for small samples and survival fractions of 0 and 100 %.
                center = [(k[i] + 0.5) / (n[i] + 1) for i in eachindex(n)]
                halfwidth = [n[i] == 0 ? NaN : sqrt(n[i] * efficiency[i] * (1 - efficiency[i]) + 0.25) / (n[i] + 1) for i in eachindex(n)]
                Makie.errorbars!(ax, x_fk, 100 .* efficiency, 100 .* (efficiency .- center .+ halfwidth), 100 .* (center .+ halfwidth .- efficiency);
                                 color)
                Makie.scatterlines!(ax, x_fk, 100 .* efficiency; label, color)
                total_n > 0 && Makie.hlines!(ax, [100 * total_k / total_n]; color, linestyle = :dash, linewidth = 1)
                isempty(outliers) ||
                    Makie.scatter!(ax, x_fk[outliers], 100 .* efficiency[outliers]; color = :red, marker = :xcross, markersize = 16,
                                   label = "$selection outlier")
            end
            removed_indices = findall(!, included_filekeys)
            isempty(removed_indices) || Makie.vlines!(ax, removed_indices; color = (:red, 0.3), linestyle = :dash, label = "Removed cycle")
            Makie.axislegend(ax; position = :lb)
            LegendMakie.add_watermarks!(final = true)
            save_plot(fig, l200, filekey, det, :qc_filekey_efficiency)
            warnings
        end
        stability_message = isempty(stability_warnings) ? "-" :
                            "$(length(stability_warnings)) filekey survival fractions deviate by more than $(stability_sigma)σ; see QC stability warnings."

        @process_step "pulser survival fraction plot" begin
            # plot pulser survival fractions for the flags used by is_single_pulse
            plot_flag_names = Symbol[first(typeof(path).parameters[1])
                                     for path in PropertyFunctions.input_property_paths(single_pulse_pf)]
            x = collect(eachindex(plot_flag_names))
            pulser_sf_plot = mvalue.(ustrip.(u"percent", [getproperty(pulser_sf, flag_name) for flag_name in plot_flag_names]))
            fig = Makie.Figure(size = (max(800, 55 * length(plot_flag_names)), 500))
            ax = Makie.Axis(fig[1, 1], title = get_plottitle(filekey, det, "Pulser QC Survival Fractions"), xlabel = "QC flag",
                            ylabel = "Survival fraction (%)", xticks = (x, string.(plot_flag_names)), xticklabelrotation = pi / 3,
                            limits = ((0.3, length(plot_flag_names) + 0.7), nothing))
            Makie.scatter!(ax, x, pulser_sf_plot, markersize = 12, color = LegendMakie.AchatBlue, label = "Pulser")
            LegendMakie.add_watermarks!(final = true)
            save_plot(fig, l200, filekey, det, :qc_survival_fractions)
        end

        @debug_plot @process_step "forced-trigger survival fraction plot" begin
            # plot forced-trigger survival fractions for is_empty_trace and its component flags
            forced_plot_flag_names = [Symbol[first(typeof(path).parameters[1])
                                             for path in PropertyFunctions.input_property_paths(empty_trace_pf)];
                                      :is_empty_trace]
            x_forced = collect(eachindex(forced_plot_flag_names))
            forced_trigger_sf_plot = mvalue.(ustrip.(u"percent",
                                                     [getproperty(forced_trigger_sf, flag_name) for flag_name in forced_plot_flag_names]))
            fig = Makie.Figure(size = (max(800, 55 * length(forced_plot_flag_names)), 500))
            ax = Makie.Axis(fig[1, 1], title = get_plottitle(filekey, det, "Forced-trigger QC Survival Fractions"), xlabel = "QC flag",
                            ylabel = "Survival fraction (%)", xticks = (x_forced, string.(forced_plot_flag_names)),
                            xticklabelrotation = pi / 3, limits = ((0.3, length(forced_plot_flag_names) + 0.7), nothing))
            Makie.scatter!(ax, x_forced, forced_trigger_sf_plot, markersize = 12, color = LegendMakie.BEGeOrange, label = "Forced trigger")
            LegendMakie.add_watermarks!(final = true)
            save_plot(fig, l200, filekey, det, :qc_survival_fractions_forced_trigger)
        end

        log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(isempty(stability_warnings) ? 1 : -1),
                          pulser_sf.is_single_pulse, forced_trigger_sf.is_empty_trace, n_pulser, n_forced, n_physics,
                          n_invalid_dsp_single_pulse, stability_message))
        return (result = (filekey_summary = filekey_summary, func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser,
                          n_forced = n_forced, n_single_pulse = n_single_pulse, n_physics = n_physics,
                          n_invalid_dsp_single_pulse = n_invalid_dsp_single_pulse),
                warnings = stability_warnings, log = log_det, processed = true)
    end

    # get start time
    start_time = now()

    # Generate the QC flags per filekey before the run summary of each detector.
    result_filekeys = parallel(filekey_qcs, filekeys, log_fk_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_phy")
    result_qc = parallel(det_qcs_phy, chinfo, log_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_phy-summary")

    @info "Finished physics QC detector processing"

    # A detector whose run summary failed keeps no previous results.
    for (chinfo_det, result) in result_qc
        haskey(result, :result) || delete!(pars_db, Symbol(chinfo_det.detector))
    end
    pars_db = create_pars(pars_db, result_qc)
    # Replace the filekey summaries, which `create_pars` merges into the obsolete ones.
    for (chinfo_det, result) in result_qc
        haskey(result, :result) && (pars_db[chinfo_det.detector][:filekey_summary] = result.result.filekey_summary)
    end
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

    warning_rows = reduce(vcat, (res.warnings for (_, res) in result_qc if haskey(res, :warnings)); init = warning_nt[])

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
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_filekeys, result_qc)]))
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
             "Threshold: $(stability_sigma)σ, two-sided exact count comparison against the other nonremoved filekeys. Red crosses mark unexpected deviations; " *
             "dashed reference lines pool nonremoved filekeys. Error bars are one-sigma Wilson intervals. Non-pulser survival is diagnostic only.")
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
