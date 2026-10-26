"""
    process_qcs_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0, stability_sigma::Real=5.0)

Generate the quality-cut (QC) flags and their survival fractions for the `cal` data of the HPGe detectors (`geds`) of a run.

The QC flags are generated per filekey: for each detector, the QC labels and the `is_single_pulse`
flag defined in the QC configuration are evaluated on the `jldsp` data, and pulser events are
flagged by coincidence of the event timestamps with the raw timestamps of the pulser channel
(`pulser.puls_detector`) of the filekey. Each detector is then summarized over the run without the
removed filekeys: the survival fraction of each flag is computed for the pulser events and for the
Tl-208 full-energy peak, which is located with a simple Th-228 calibration of the non-pulser events.
A detector with fewer than 5000 events fails. A warning is logged if single-pulse events fail the
`is_valid_e` flag. The single-pulse survival fraction of the pulser events of each filekey is
compared with that of the other nonremoved filekeys by an exact count test, and deviations above
`stability_sigma` are reported; the non-pulser survival fraction is shown for diagnosis only.

# Inputs
- `jldsp` tier of the `cal` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `raw` tier timestamps of the pulser channel
- the filekeys marked removed in `datasets/ignored_daq_cycles`, which are left out of the run summary
- `dataprod_config(l200).qc(filekey)` and `dataprod_config(l200).energy(filekey)`
- `l200.par.rpars.qcs[period, run]` (existing parameters, unless `reprocess` is `true`)

# Outputs
- `jlqcs` tier file for each filekey, with one table per detector (QC flags, `timestamp`, `is_pulser`)
- `l200.par.rpars.qcs[period, run]` (flag definition, survival fractions, event counts, and per filekey the event counts and stability tests in `filekey_summary`) with its validity (category `cal`)
- plots `:raw_energy_e_trap`, `:qc_filekey_efficiency` and `:qc_survival_fractions` for each detector; `:qc_survival_fractions` is saved only at the debug plot level
- run report `:qcs_cal`, with the stability warnings, one row per detector and one row per filekey

# Keywords
- `reprocess`: remove the existing `jlqcs` files and parameters and process all detectors again; otherwise detectors already present in a `jlqcs` file are skipped there. The run summary of every detector is always recomputed.
- `timeout`: seconds allowed per filekey and per detector summary in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)
- `stability_sigma`: deviation, in Gaussian standard deviations, above which a filekey survival fraction is reported (default: `5.0`)

# Returns
Return `nothing`.
"""
function process_qcs_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         use_cache::Bool = true, stability_sigma::Real = 5.0)
    isfinite(stability_sigma) && stability_sigma > 0 || throw(ArgumentError("stability_sigma must be finite and positive"))

    @info "Generate calibration QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :cal)).keys))
    # Removed filekeys keep their QC flags and filekey diagnostics but do not enter the run summary.
    removed_filekeys = bad_filekeys(l200; load_key = :removed)
    included_filekeys = .!in.(filekeys, Ref(removed_filekeys))
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
    log_fk_nt = NamedTuple{(:Filekey, :Status, Symbol("Processed Detectors"), Symbol("Failed Detectors"), :Error)}
    warning_nt = NamedTuple{(:Detector, :Filekey, :Selection, Symbol("Efficiency (%)"), Symbol("Reference (%)"), :Events, Symbol("Reference events"),
                             Symbol("Deviation (σ)")),Tuple{DetectorId,FileKey,Symbol,Float64,Float64,Int,Int,Float64}}

    # flush stdout
    flush(stdout)

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector

    function filekey_qcs(fk::FileKey)
        n_processed = 0
        failed_detectors = DetectorId[]
        # The raw pulser timestamps of the filekey are the coincidence reference for all detectors.
        pulser_timestamps = read_ldata(:timestamp, l200, DataTier(:raw), fk, det_puls).timestamp
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
                        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
                        is_pulser = flag_coincidences(timestamps, pulser_timestamps; ts_window = pulser_config_det.puls_ts_window)
                        "$det" in processed_detectors && delete_entry!(outdata, "jlqcs/$det")
                        outdata[:jlqcs, det] = Table(merge(columns(qc_labels), (; timestamp = timestamps, is_single_pulse, is_pulser)))
                        n_processed += 1
                    catch e
                        @error "QC failed for $det in $fk: $(truncate_error(e))"
                        push!(failed_detectors, det)
                    end
                end
            end
        end
        return (processed = n_processed > 0,
                log = log_fk_nt((fk, ProcessStatus(isempty(failed_detectors) ? 1 : 0), n_processed, string.(failed_detectors), "")))
    end

    function det_qcs_cal(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))
        energy_config_det = merge(energy_config.default, get(energy_config, det, PropDict()))

        @debug "Summarize QC for detector $det ($ch)"
        qc_parts, qc, data_det = @process_step "data loader" begin
            qc_parts = [read_ldata(l200, DataTier(:jlqcs), fk, det) for fk in filekeys]
            data_parts = [read_ldata((:timestamp, :e_trap), l200, DataTier(:jldsp), fk, det) for fk in filekeys]
            qc = reduce(vcat, qc_parts[included_filekeys]; init = first(qc_parts)[1:0])
            data_det = reduce(vcat, data_parts[included_filekeys]; init = first(data_parts)[1:0])
            data_det.timestamp == qc.timestamp || throw(DimensionMismatch("DSP and QC timestamps differ for $det in $period-$run"))
            qc_parts, qc, data_det
        end
        single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
        flag_names = [Symbol.(keys(qc_config_det.labels))...; :is_single_pulse]
        qc_propfunc = merge(qc_config_det.labels, PropDict(:is_single_pulse => qc_config_det.is_single_pulse))
        is_pulser = qc.is_pulser

        # Count accepted events missed by the configured single-pulse cuts.
        n_single_pulse = count(qc.is_single_pulse)
        n_invalid_e_single_pulse = count(qc.is_single_pulse .&& .!qc.is_valid_e)
        if n_invalid_e_single_pulse > 0
            @warn "Detector $det ($ch): $n_invalid_e_single_pulse of $n_single_pulse single-pulse events fail is_valid_e; check the QC cuts"
        end

        n_pulser = count(is_pulser)
        pulser_sf = @process_step "pulser survival fractions" begin
            pulser_sf_values = [(n_pulser == 0 ? NaN : count(getproperty(qc, flag_name)[is_pulser]) / n_pulser) * 100u"percent"
                                for flag_name in flag_names]
            NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values))
        end

        # Per-filekey counts, of the removed filekeys too, for the stability test and diagnostics.
        filekey_summary = PropDict()
        for (fk, qc_part) in zip(filekeys, qc_parts)
            pulser = qc_part.is_pulser
            filekey_summary[Symbol(fk)] = PropDict(:is_removed => fk in removed_filekeys, :n_events => length(qc_part),
                                                   :n_pulser => count(pulser), :n_nonpulser => count(.!pulser),
                                                   :n_single_pulse => count(qc_part.is_single_pulse),
                                                   :n_pulser_pass => count(qc_part.is_single_pulse .& pulser),
                                                   :n_nonpulser_pass => count(qc_part.is_single_pulse .& .!pulser))
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
                                                                     (:nonpulser, :n_nonpulser, :n_nonpulser_pass, LegendMakie.BEGeOrange, "Non-pulser single pulse", false))
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

        # A failed run summary keeps the filekey summary of the detector.
        try
            length(qc) < 5000 && throw(ErrorException("Not enough data points for detector $det ($ch): $(length(qc)) < 5000"))

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
                                                               getproperty(qc, flag_name)[valid_energy];
                                                               fit_func = Symbol(energy_config_det.th228_fit_func[fep_idx]), uncertainty = true)
                    return result_fep.sf
                end
                NamedTuple{Tuple(flag_names)}(Tuple(fep_sf_values))
            end
            survival_fractions = (pulser = pulser_sf, Tl208FEP = fep_sf)

            @process_step "energy spectrum plot" begin
                # plot energy spectra before and after QC
                data_det_for_plot = data_det[qc.is_valid_e]
                data_det_after_qc = data_det[qc.is_single_pulse .&& .!is_pulser .&& qc.is_valid_e]
                data_pulser = data_det[qc.is_single_pulse .&& is_pulser .&& qc.is_valid_e]
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

            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(isempty(stability_warnings) ? 1 : -1),
                              pulser_sf.is_single_pulse, fep_sf.is_single_pulse, n_pulser, n_single_pulse, n_invalid_e_single_pulse,
                              stability_message))
            return (result = (filekey_summary = filekey_summary, func = qc_propfunc, survival_fractions = survival_fractions,
                              n_pulser = n_pulser, n_single_pulse = n_single_pulse, n_invalid_e_single_pulse = n_invalid_e_single_pulse),
                    warnings = stability_warnings, log = log_det, processed = true)
        catch e
            e isa ProcessStepError || @error "QC summary failed for $det: $(truncate_error(e))"
            return (warnings = stability_warnings, filekey_summary = filekey_summary, processed = false,
                    log = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), "-", "-", n_pulser, n_single_pulse,
                                  n_invalid_e_single_pulse, truncate_error(e))))
        end
    end

    # get start time
    start_time = now()

    # Generate the QC flags per filekey before the run summary of each detector.
    result_filekeys = parallel(filekey_qcs, filekeys, log_fk_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_cal")
    result_qc = parallel(det_qcs_cal, chinfo, log_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_qcs_cal-summary")

    @info "Finished QC detector processing"

    # A detector whose run summary failed keeps no previous results, only its new filekey summary.
    for (chinfo_det, result) in result_qc
        haskey(result, :result) || delete!(pars_db, Symbol(chinfo_det.detector))
    end
    pars_db = create_pars(pars_db, result_qc)
    # Replace the filekey summaries, which `create_pars` merges into the obsolete ones.
    for (chinfo_det, result) in result_qc
        if haskey(result, :result)
            pars_db[chinfo_det.detector][:filekey_summary] = result.result.filekey_summary
        elseif haskey(result, :filekey_summary)
            pars_db[chinfo_det.detector] = PropDict(:filekey_summary => result.filekey_summary)
        end
    end
    write_pars(l200.par.rpars.qcs[period], run, pars_db)
    write_validity(l200.par.rpars.qcs, filekey, (period, run); category = :cal)
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
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_filekeys, result_qc)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
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

    report_filename = get_rreportfilename(l200, filekey, :qcs_cal)

    @info "Write log report"
    write_report(report_filename, report)
    @info report
    # Base.empty!(fig)

    # flush stdout
    return flush(stdout)
end

register_processor!(process_qcs_cal; output_tiers = [:jlqcs])
