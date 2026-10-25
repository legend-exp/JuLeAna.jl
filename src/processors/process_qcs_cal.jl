"""
    process_qcs_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Generate the quality-cut (QC) flags and their survival fractions for the `cal` data of the HPGe detectors (`geds`) of a run.

For each detector, the QC labels and the `is_single_pulse` flag defined in the QC configuration
are evaluated on the `jldsp` data. Pulser events are flagged by coincidence of the event
timestamps with the timestamps of the pulser channel (`pulser.puls_detector`) in the raw data.
The survival fraction of each flag is computed for the pulser events and for the Tl-208
full-energy peak, which is located with a simple Th-228 calibration of the non-pulser events.
A detector with fewer than 5000 events fails. A warning is logged if single-pulse events fail
the `is_valid_e` flag.

# Inputs
- `jldsp` tier of the `cal` filekeys of the run listed in the runinfo, except the filekeys marked bad
- `raw` tier timestamps of the pulser channel
- `dataprod_config(l200).qc(filekey)` and `dataprod_config(l200).energy(filekey)`
- `l200.par.rpars.qcs[period, run]` (existing parameters, unless `reprocess` is `true`)

# Outputs
- `jlqcs` tier file for each detector, with the QC flags and the pulser flag
- `l200.par.rpars.qcs[period, run]` (flag definition, survival fractions, event counts) with its validity (category `cal`)
- plots `:raw_energy_e_trap` and `:qc_survival_fractions` for each detector; `:qc_survival_fractions` is saved only at the debug plot level
- run report `:qcs_cal`, with one row per detector

# Keywords
- `reprocess`: discard the existing parameters and process all detectors; otherwise a detector with complete parameters and an existing `jlqcs` file is skipped
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)

# Returns
Return `nothing`.
"""
function process_qcs_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         use_cache::Bool = true)
    @info "Generate calibration QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :all)), only(runinfo(l200, (period, run, :cal)).keys))
    raw_filekeys = filter(!in(bad_filekeys(l200; load_key = :all)), only(runinfo(l200, (period, run, :cal)).keys))
    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"
    qc_config = dataprod_config(l200).qc(filekey)
    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.qcs), string(period)))
    pars_db = PropDict(l200.par.rpars.qcs[period, run])
    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Pulser SF"), Symbol("Tl-208 FEP SF"), Symbol("Number Pulser Events"),
                         Symbol("Number Single-pulse Events"), Symbol("Single pulses with invalid energy"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    # load pulser timestamps
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    @info "Load pulser timestamps for $det_puls"
    pulser_timestamps = @process_step "pulser timestamp loader" begin
        read_ldata(:timestamp, l200, DataTier(:raw), raw_filekeys, det_puls).timestamp
    end
    @info "Loaded $(length(pulser_timestamps)) pulser timestamps"

    function det_qcs_cal(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        qcsfilename = l200.tier[:jlqcs, filekey, det]
        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))
        energy_config_det = merge(energy_config.default, get(energy_config, det, PropDict()))

        if !reprocess &&
           !redo_detector(det) &&
           haskey(pars_db, det) &&
           haskey(pars_db[det], :n_single_pulse) &&
           haskey(pars_db[det], :n_invalid_e_single_pulse) &&
           isfile(qcsfilename)
            sf = pars_db[det].survival_fractions
            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), sf.pulser.is_single_pulse,
                              sf.Tl208FEP.is_single_pulse, pars_db[det].n_pulser, pars_db[det].n_single_pulse,
                              pars_db[det].n_invalid_e_single_pulse, "Already processed --> skipped."))
            @debug "Detector $det already processed"
            return (processed = false, log = log_det)
        end

        @debug "Processing detector $det ($ch)"
        data_det = @process_step "data loader" begin
            data = read_ldata((:timestamp, :e_trap), l200, DataTier(:jldsp), filekeys, det)
            length(data) < 5000 && throw(ErrorException("Not enough data points for detector $det ($ch): $(length(data)) < 5000"))
            data
        end

        qc_flags, qc_propfunc, single_pulse_pf = @process_step "QC flags" begin
            qc_labels = read_ldata(ljl_propfunc(qc_config_det.labels), l200, DataTier(:jldsp), filekeys, det)
            single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
            qc_flags = Table(merge(columns(qc_labels), (is_single_pulse = single_pulse_pf.(qc_labels),)))
            qc_flags, merge(qc_config_det.labels, PropDict(:is_single_pulse => qc_config_det.is_single_pulse)), single_pulse_pf
        end

        is_pulser = @process_step "pulser flags" begin
            pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
            flag_coincidences(data_det.timestamp, pulser_timestamps; ts_window = pulser_config_det.puls_ts_window)
        end
        @debug "Found $(count(is_pulser)) pulser events"

        # Count accepted events missed by the configured single-pulse cuts.
        n_single_pulse = count(qc_flags.is_single_pulse)
        n_invalid_e_single_pulse = count(qc_flags.is_single_pulse .&& .!qc_flags.is_valid_e)
        if n_invalid_e_single_pulse > 0
            @warn "Detector $det ($ch): $n_invalid_e_single_pulse of $n_single_pulse single-pulse events fail is_valid_e; check the QC cuts"
        end

        qc = Table(merge(columns(qc_flags), (is_pulser = is_pulser,)))
        flag_names = collect(columnnames(qc_flags))
        n_pulser = count(is_pulser)
        pulser_sf = @process_step "pulser survival fractions" begin
            pulser_sf_values = [count(getproperty(qc_flags, flag_name)[is_pulser]) / n_pulser * 100u"percent" for flag_name in flag_names]
            NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values))
        end

        valid_energy = isfinite.(data_det.e_trap) .&& (data_det.e_trap .> 0) .&& .!is_pulser
        e_uncal = collect(data_det.e_trap[valid_energy])
        plot_uncal_spectrum() = begin
            fig = Makie.Figure()
            ax = Makie.Axis(fig[1, 1]; title = get_plottitle(filekey, det, "Uncalibrated Spectrum"), xlabel = "Energy (ADC)",
                            ylabel = "Counts")
            Makie.stephist!(ax, e_uncal; bins = 1000)
            save_plot(fig, l200, filekey, det, :error_simple_calibration)
        end
        result_simple = @process_step "simple calibration" on_error = plot_uncal_spectrum begin
            quantile_perc = if energy_config_det.quantile_perc isa String
                parse(Float64, energy_config_det.quantile_perc)
            else
                energy_config_det.quantile_perc
            end
            first(simple_calibration(e_uncal, energy_config_det.th228_lines, energy_config_det.left_window_sizes,
                                     energy_config_det.right_window_sizes, ; calib_type = :th228, quantile_perc = quantile_perc,
                                     binning_peak_window = energy_config_det.binning_peak_window))
        end

        fep_sf = @process_step "Tl-208 FEP survival fractions" begin
            fep_idx = findfirst(==(:Tl208FEP), Symbol.(energy_config_det.th228_names))
            e_cal = e_uncal .* result_simple.c
            fep_sf_values = map(flag_names) do flag_name
                result_fep, _ = get_peak_survival_fraction(e_cal, mvalue(energy_config_det.th228_lines[fep_idx]),
                                                           (energy_config_det.left_window_sizes[fep_idx],
                                                            energy_config_det.right_window_sizes[fep_idx]),
                                                           getproperty(qc_flags, flag_name)[valid_energy];
                                                           fit_func = Symbol(energy_config_det.th228_fit_func[fep_idx]), uncertainty = true)
                return result_fep.sf
            end
            NamedTuple{Tuple(flag_names)}(Tuple(fep_sf_values))
        end
        survival_fractions = (pulser = pulser_sf, Tl208FEP = fep_sf)

        @process_step "energy spectrum plot" begin
            # plot energy spectra before and after QC
            data_det_for_plot = data_det[qc_flags.is_valid_e]
            data_det_after_qc = data_det[qc_flags.is_single_pulse .&& .!is_pulser .&& qc_flags.is_valid_e]
            data_pulser = data_det[qc_flags.is_single_pulse .&& is_pulser .&& qc_flags.is_valid_e]
            fig = Makie.Figure(size = (620, 400))
            binwidth = 8 * 15
            spectrum_range = range(0, maximum(data_det_after_qc.e_trap), step = binwidth)
            hall = StatsBase.fit(StatsBase.Histogram, data_det_for_plot.e_trap, spectrum_range)
            hqc = StatsBase.fit(StatsBase.Histogram, data_det_after_qc.e_trap, spectrum_range)
            hp = StatsBase.fit(StatsBase.Histogram, data_pulser.e_trap, spectrum_range)
            ax = Makie.Axis(fig[1, 1], xlabel = "Energy (ADC)", ylabel = "Counts / $(binwidth) ADC",
                            xtickformat = x -> string.(round.(Int, x)), yscale = log10,
                            limits = (extrema(first(hall.edges)), (0.9, maximum(hall.weights) * 1.2)),
                            title = get_plottitle(filekey, det, "Trap Raw Energy Spectrum"))
            Makie.stephist!(ax, StatsBase.midpoints(first(hall.edges)), weights = replace(hall.weights, 0 => 1e-10),
                            bins = first(hall.edges), color = LegendMakie.BEGeOrange, label = "Trap - before QC")
            Makie.stephist!(ax, StatsBase.midpoints(first(hqc.edges)), weights = replace(hqc.weights, 0 => 1e-10),
                            bins = first(hqc.edges), color = LegendMakie.AchatBlue, label = "Trap - after QC")
            Makie.stephist!(ax, StatsBase.midpoints(first(hp.edges)), weights = replace(hp.weights, 0 => 1e-10), bins = first(hp.edges),
                            color = :red, label = "Pulser")
            Makie.axislegend(ax, position = :rt, framevisible = true, framecolor = :lightgray)
            LegendMakie.add_watermarks!(final = true)
            save_plot(fig, l200, filekey, det, :raw_energy_e_trap)
        end

        @debug_plot @process_step "survival fraction plot" begin
            # plot survival fractions for the flags used by is_single_pulse
            plot_flag_names = Symbol[first(typeof(path).parameters[1])
                                     for path in PropertyFunctions.input_property_paths(single_pulse_pf)]
            x = collect(eachindex(plot_flag_names))
            pulser_sf_plot = mvalue.(ustrip.(u"percent", [getproperty(pulser_sf, flag_name) for flag_name in plot_flag_names]))
            fep_sf_plot = mvalue.(ustrip.(u"percent", [getproperty(fep_sf, flag_name) for flag_name in plot_flag_names]))
            fig = Makie.Figure(size = (max(800, 55 * length(plot_flag_names)), 500))
            ax = Makie.Axis(fig[1, 1], title = get_plottitle(filekey, det, "QC Survival Fractions"), xlabel = "QC flag",
                            ylabel = "Survival fraction (%)", xticks = (x, string.(plot_flag_names)), xticklabelrotation = pi / 3,
                            limits = ((0.3, length(plot_flag_names) + 0.7), nothing))
            Makie.scatter!(ax, x .- 0.2, pulser_sf_plot, markersize = 12, color = LegendMakie.AchatBlue, label = "Pulser")
            Makie.scatter!(ax, x .+ 0.2, fep_sf_plot, markersize = 12, color = LegendMakie.BEGeOrange, label = "Tl-208 FEP")
            Makie.axislegend(ax, position = :lb, orientation = :horizontal, framevisible = true, framecolor = :lightgray)
            LegendMakie.add_watermarks!(final = true)
            save_plot(fig, l200, filekey, det, :qc_survival_fractions)
        end

        @process_step "QC flag file writer" begin
            write_files(qcsfilename; use_cache, mode = CreateOrReplace()) do outfilename
                lh5open(outfilename, "w") do outdata
                    return outdata[:jlqcs, det] = qc
                end
            end
        end

        log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), pulser_sf.is_single_pulse, fep_sf.is_single_pulse,
                          n_pulser, n_single_pulse, n_invalid_e_single_pulse, "-"))
        return (result = (func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser, n_single_pulse = n_single_pulse,
                          n_invalid_e_single_pulse = n_invalid_e_single_pulse), log = log_det, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(det_qcs_cal, chinfo, log_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_cal")

    @info "Finished QC detector processing"

    pars_db = create_pars(pars_db, result_qc)
    write_pars(l200.par.rpars.qcs[period], run, pars_db)
    write_validity(l200.par.rpars.qcs, filekey, (period, run); category = :cal)
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
    #     ax, chinfo, pars_db, [:survival_fractions, :Tl208FEP, :is_single_pulse];
    #     ylabel = "Survival fraction (%)", color = LegendMakie.BEGeOrange,
    #     label = "Tl-208 FEP", detector_status_colors = true)
    # ax.title = get_plottitle(filekey, :all, "QC Survival Fractions")
    # Makie.axislegend(ax, position = :lb, orientation = :horizontal,
    #     framevisible = true, framecolor = :lightgray)
    # LegendMakie.add_watermarks!(final = true)
    # @debug_plot save_plot(fig, l200, filekey, :all, :qc_survival_fractions; cleanup = false)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_qc)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    # lreport!(report, "# Detector overview")
    # lreport!(report, fig)
    lreport!(report, "\n# Results")
    lreport!(report, create_logtbl(result_qc))

    report_filename = get_rreportfilename(l200, filekey, :qcs_cal)

    @info "Write log report"
    write_report(report_filename, report)
    @info report
    # Base.empty!(fig)

    # flush stdout
    return flush(stdout)
end

register_processor!(process_qcs_cal; output_tiers = [:jlqcs])
