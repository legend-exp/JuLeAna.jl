"""
    process_qcs_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Generate the quality-cut (QC) flags and their survival fractions for the `phy` data of the HPGe detectors (`geds`) of a run.

For each detector, the QC labels and the `is_single_pulse` and `is_empty_trace` flags defined
in the QC configuration are evaluated on the `jldsp` data. Pulser events and forced-trigger
events (without pulser events) are taken from the `aux_trig` flags of the pulser channel
(`pulser.puls_detector`) and of the forced-trigger channel (`forced_trigger.detector`). The
survival fraction of each flag is computed for the pulser events and for the forced-trigger
events. A detector with fewer than 5000 events fails. A warning is logged if single-pulse events
fail the `is_valid_dsp` flag.

# Inputs
- `jldsp` tier of the `phy` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `jlaux` tier column `aux_trig` of the pulser and forced-trigger channels
- `dataprod_config(l200).qc(filekey)`
- `l200.par.rpars.qcs[period, Symbol("<run>-phy")]` (existing parameters, unless `reprocess` is `true`)

# Outputs
- `jlqcs` tier file for each detector, with the QC flags and the pulser flag
- `l200.par.rpars.qcs[period, Symbol("<run>-phy")]` (flag definition, survival fractions, event counts) with its validity (category `phy`)
- plots `:qc_survival_fractions` and `:qc_survival_fractions_forced_trigger` for each detector; `:qc_survival_fractions_forced_trigger` is saved only at the debug plot level
- run report `:qcs_phy`, with one row per detector

# Keywords
- `reprocess`: discard the existing parameters and process all detectors; otherwise a detector with complete parameters and an existing `jlqcs` file is skipped
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)

# Returns
Return `nothing`.
"""
function process_qcs_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         use_cache::Bool = true)
    @info "Generate physics QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :phy)).keys))
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_qcs_phy)
    @info "Loaded channel info with $(length(chinfo)) detectors"
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

    # get worker pool

    # flush stdout
    flush(stdout)

    # load pulser flags
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    @info "Load pulser flags for $det_puls"
    is_pulser = @process_step "pulser flag loader" begin
        read_ldata(:aux_trig, l200, DataTier(:jlaux), :phy, period, run, det_puls)
    end
    @info "Loaded $(count(is_pulser)) pulser flags"

    # load forced-trigger flags
    chinfo_forced = channelinfo(l200, filekey, Symbol(qc_config.forced_trigger.detector))
    det_forced = chinfo_forced.detector
    @info "Load forced-trigger flags for $det_forced"
    is_forced = @process_step "forced-trigger flag loader" begin
        read_ldata(:aux_trig, l200, DataTier(:jlaux), :phy, period, run, det_forced) .&& .!is_pulser
    end
    @info "Loaded $(count(is_forced)) forced-trigger events excluding pulsers"

    function det_qcs_phy(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        qcsfilename = l200.tier[:jlqcs, filekey, det]
        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))

        if !reprocess &&
           !redo_detector(det) &&
           haskey(pars_db, det) &&
           haskey(pars_db[det].survival_fractions, :pulser) &&
           haskey(pars_db[det].survival_fractions, :forced_trigger) &&
           haskey(pars_db[det].survival_fractions.pulser, :is_valid_dsp) &&
           haskey(pars_db[det], :n_pulser) &&
           haskey(pars_db[det], :n_forced) &&
           haskey(pars_db[det], :n_physics) &&
           haskey(pars_db[det], :n_invalid_dsp_single_pulse) &&
           isfile(qcsfilename)
            sf = pars_db[det].survival_fractions
            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), sf.pulser.is_single_pulse,
                              sf.forced_trigger.is_empty_trace, pars_db[det].n_pulser, pars_db[det].n_forced, pars_db[det].n_physics,
                              pars_db[det].n_invalid_dsp_single_pulse, "Already processed --> skipped."))
            @debug "Detector $det already processed"
            return (processed = false, log = log_det)
        end

        @debug "Processing detector $det ($ch)"
        qc_labels = @process_step "data loader" begin
            labels = read_ldata(ljl_propfunc(qc_config_det.labels), l200, DataTier(:jldsp), filekeys, det)
            length(labels) < 5000 && throw(ErrorException("Not enough data points for detector $det ($ch): $(length(labels)) < 5000"))
            labels
        end

        qc_flags, qc_propfunc, single_pulse_pf, empty_trace_pf = @process_step "QC flags" begin
            single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
            empty_trace_pf = ljl_propfunc(qc_config_det.is_empty_trace)
            qc_flags = Table(merge(columns(qc_labels),
                                   (is_single_pulse = single_pulse_pf.(qc_labels), is_empty_trace = empty_trace_pf.(qc_labels))))
            qc_propfunc = merge(qc_config_det.labels,
                                PropDict(:is_single_pulse => qc_config_det.is_single_pulse,
                                         :is_empty_trace => qc_config_det.is_empty_trace))
            qc_flags, qc_propfunc, single_pulse_pf, empty_trace_pf
        end

        n_single_pulse = count(qc_flags.is_single_pulse)
        n_physics = count(qc_flags.is_single_pulse .&& .!is_pulser)
        n_invalid_dsp_single_pulse = count(qc_flags.is_single_pulse .&& .!qc_labels.is_valid_dsp)
        if n_invalid_dsp_single_pulse > 0
            @warn "Detector $det ($ch): $n_invalid_dsp_single_pulse of $n_single_pulse single-pulse events fail is_valid_dsp; check the QC cuts"
        end

        qc = Table(merge(columns(qc_flags), (is_pulser = is_pulser,)))
        flag_names = collect(columnnames(qc_flags))
        n_pulser = count(is_pulser)
        n_forced = count(is_forced)
        pulser_sf, forced_trigger_sf = @process_step "survival fractions" begin
            pulser_sf_values = [count(getproperty(qc_flags, flag_name)[is_pulser]) / n_pulser * 100u"percent" for flag_name in flag_names]
            forced_trigger_sf_values = [count(getproperty(qc_flags, flag_name)[is_forced]) / n_forced * 100u"percent"
                                        for flag_name in flag_names]
            NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values)), NamedTuple{Tuple(flag_names)}(Tuple(forced_trigger_sf_values))
        end
        survival_fractions = (pulser = pulser_sf, forced_trigger = forced_trigger_sf)

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

        @process_step "QC flag file writer" begin
            write_files(qcsfilename; use_cache, mode = CreateOrReplace()) do outfilename
                lh5open(outfilename, "w") do outdata
                    return outdata[:jlqcs, det] = qc
                end
            end
        end

        log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), pulser_sf.is_single_pulse,
                          forced_trigger_sf.is_empty_trace, n_pulser, n_forced, n_physics, n_invalid_dsp_single_pulse, "-"))
        return (result = (func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser, n_forced = n_forced,
                          n_single_pulse = n_single_pulse, n_physics = n_physics, n_invalid_dsp_single_pulse = n_invalid_dsp_single_pulse),
                log = log_det, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(det_qcs_phy, chinfo, log_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_phy")

    @info "Finished physics QC detector processing"

    pars_db = create_pars(pars_db, result_qc)
    write_pars(l200.par.rpars.qcs[period], pars_file, pars_db)
    write_validity(l200.par.rpars.qcs, filekey, "$(period)/$(pars_file).yaml"; category = :phy)
    @info "Saved QC-survival pars to disk"

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
             StructArray(var"Processor Status" = [master_status(processing_config, :process_qcs_phy, result_qc)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_phy_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    # lreport!(report, "# Detector overview")
    # lreport!(report, fig)
    lreport!(report, "\n# Results")
    lreport!(report, create_logtbl(result_qc))

    report_filename = get_rreportfilename(l200, filekey, :qcs_phy)

    @info "Write log report"
    write_report(report_filename, report)
    @info report
    # Base.empty!(fig)

    # flush stdout
    return flush(stdout)
end

register_processor!(process_qcs_phy; output_tiers = [:jlqcs])
