"""
    p_process_stability_plots_phy(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Plot the stability of the HPGe detectors (`geds`) per partition from `phy` data, for all
partitions that contain `period`.

The plots are the same as in `process_stability_plots_phy`, but the data of all runs of a
detector's partition are shown together. Each plot is made and logged separately; a failing
plot does not stop the others.

# Inputs
- `dsp` tier (`DataTier(:jldsp)`) of the `phy` data of all runs of each detector's partition,
  fields `timestamp`, `blmean`, `blsigma` and `e_10410`; events with non-finite values are
  dropped.
- `jlaux` tier fields `e_10410` and `aux_trig` of the pulser channel named by
  `dataprod_config(l200).qc(filekey).pulser.puls_detector`, over the same runs.
- `dataprod_config(l200).qc(filekey).stability_plots`: `n_ref` (number of events for the
  reference value), `n_smooth` (smoothing window of `20 * n_smooth` seconds) and `Qbb`.

# Outputs
- Plots per detector and partition: `stability_time_vs_bl`, `stability_time_vs_blsigma`,
  `stability_time_vs_e10410`, `stability_e10410_hist`. If pulser-triggered events exist:
  `stability_time_vs_e10410_trig` and `stability_pulser_rate`. If more than `n_ref` finite
  pulser-triggered events exist: `stability_gain_stability`. Only `stability_pulser_rate` and
  `stability_gain_stability` are saved below the debug plot level.
- Partition report `stability_plots_phy`.

No parameters are written.

# Keywords
- `reprocess`: only logged; plots are always remade and overwritten.
- `timeout`: seconds allowed per detector and partition in `parallel` (0 = no limit).
- `only_first_period`: if `true`, skip a detector whose partition starts in an earlier period
  than `period`; it is processed together with that earlier period. `run_processing` sets this
  to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`.
"""
function p_process_stability_plots_phy(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                                       only_first_period::Bool = true)
    @info "Process detector stability plots for partitions conatining period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :phy; system = :geds, explode_partitions = true) |>
                      detector_filter(processing_config, :p_process_stability_plots_phy)
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :psd_usability, :Partition, :Status, :Plot, :Error)}

    # get worker pool

    # get start time
    start_time = now()

    function det_stability_plots(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch) in partition $part"

        partinfo_det = partitioninfo(l200, det, part)
        filekey_det = first(getproperty(partinfo_det, :phy)).startkey

        if only_first_period && period != first(partinfo_det.period)
            @info "Skip $det in partition $part for period $period, as it starts in period $(first(partinfo_det.period))"
            log_det = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability), part, process_skipped,
                              :all,
                              "Skipped, starts in period $(first(partinfo_det.period))"))
            return (processed = Dict(:all => false), log = Dict(:all => log_det), skipped = true)
        end

        qc_config = dataprod_config(l200).qc(filekey_det)
        @debug "Loaded QC config for $filekey_det: $(lstring(qc_config))"

        n_ref = qc_config.stability_plots.n_ref
        n_smooth = qc_config.stability_plots.n_smooth
        Qbb = qc_config.stability_plots.Qbb
        smooth_window = 20n_smooth * u"s"

        chinfo_puls = channelinfo(l200, filekey_det, Symbol(qc_config.pulser.puls_detector))
        det_puls = chinfo_puls.detector
        @debug "Loaded pulser channel info for partition $part: $chinfo_puls"

        data = @process_step "data loader" begin
            read_ldata((:timestamp, :blmean, :blsigma, :e_10410), l200, DataTier(:jldsp), :phy, partinfo_det, det)
        end

        puls = @process_step "pulser data loader" begin
            read_ldata((:e_10410, :aux_trig), l200, DataTier(:jlaux), :phy, partinfo_det, det_puls)
        end

        timestamp, time_s, bl_f, σbl, e10410, puls_e10410, aux_trig = @process_step "finite event filter" begin
            length(puls.e_10410) == length(data.timestamp) ||
                throw(DimensionMismatch("pulser data of $det_puls ($(length(puls.e_10410)) events) does not match the data of $det ($(length(data.timestamp)) events) in partition $part"))
            finite_data = isfinite.(data.timestamp) .&& isfinite.(data.blmean) .&& isfinite.(data.blsigma) .&& isfinite.(data.e_10410)
            timestamp = data.timestamp[finite_data]
            (timestamp, ustrip.(timestamp), float.(data.blmean[finite_data]), float.(data.blsigma[finite_data]),
             float.(data.e_10410[finite_data]), puls.e_10410[finite_data], puls.aux_trig[finite_data])
        end

        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        # Run, save, and log a plot without aborting the processor on failure.
        function run_plot(make_plot::Function, plot_name::Symbol)
            try
                @process_step "$plot_name plot" begin
                    p = make_plot()
                    save_plot(p, l200, part, filekey_det, det, plot_name)
                end
                log_info_dict[plot_name] = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability),
                                                   part, ProcessStatus(1), plot_name, ""))
                processed_dict[plot_name] = true
            catch e
                e isa ProcessStepError || rethrow()
                log_info_dict[plot_name] = log_nt((det, detector_status(chinfo_det.usability), detector_status(chinfo_det.psd_usability),
                                                   part, ProcessStatus(0), plot_name,
                                                   "$(truncate_error(e.exception))"))
                processed_dict[plot_name] = false
            end
        end

        heatmap_kwargs = (bins = 600, figsize = (900, 600), xlabel = "Time (s)", colormap = :viridis, colorbarlabel = "Counts")

        @debug_plot begin
            run_plot(:stability_time_vs_bl) do
                LegendMakie.lhist(time_s, bl_f; heatmap_kwargs..., ylabel = "Baseline (ADC)",
                                  title = get_plottitle(filekey_det, part, det, "Time vs Baseline"))
            end
        end

        @debug_plot begin
            run_plot(:stability_time_vs_blsigma) do
                LegendMakie.lhist(time_s, σbl; heatmap_kwargs..., ylabel = "Baseline σ (ADC)", ylims = (0.0, 1000.0),
                                  title = get_plottitle(filekey_det, part, det, "Time vs Baseline σ"))
            end
        end

        @debug_plot begin
            run_plot(:stability_time_vs_e10410) do
                LegendMakie.lhist(time_s, e10410; heatmap_kwargs..., ylabel = "E_10410 (ADC)", ylims = (0.0, 1e5),
                                  title = get_plottitle(filekey_det, part, det, "Time vs E_10410"))
            end
        end

        @debug_plot begin
            run_plot(:stability_e10410_hist) do
                LegendMakie.lhist(e10410; bins = 0:1000:6e5, figsize = (900, 400), xlabel = "E_10410 (ADC)", ylabel = "Counts",
                                  yscale = log10, title = get_plottitle(filekey_det, part, det, "E_10410 Distribution"))
            end
        end

        mask_trig = aux_trig .== true
        if any(mask_trig)
            @debug_plot begin
                run_plot(:stability_time_vs_e10410_trig) do
                    LegendMakie.lhist(time_s[mask_trig], e10410[mask_trig]; heatmap_kwargs..., ylabel = "E_10410 (ADC)",
                                      title = get_plottitle(filekey_det, part, det, "Time vs E_10410 (Pulser-Triggered)"))
                end
            end
            run_plot(:stability_pulser_rate) do
                return LegendMakie.lplot(rate(timestamp[mask_trig], smooth_window); figsize = (900, 400), ylabel = "Pulser rate (Hz)",
                                         title = get_plottitle(filekey_det, part, det, "Pulser Rate"))
            end
        end

        mask_gain = isfinite.(puls_e10410) .&& mask_trig
        if count(mask_gain) > n_ref
            run_plot(:stability_gain_stability) do
                pulser_gain = smooth(relative(TimeEvolution(timestamp[mask_gain], puls_e10410[mask_gain]), n_ref), smooth_window)
                energy_gain = smooth(relative(TimeEvolution(timestamp[mask_gain], e10410[mask_gain]), n_ref), smooth_window)
                pulser_gain = TimeEvolution(pulser_gain.time, pulser_gain.values .* (Qbb / 100))
                energy_gain = TimeEvolution(energy_gain.time, energy_gain.values .* (Qbb / 100))

                p = LegendMakie.lplot(pulser_gain; figsize = (1000, 450), label = "Pulser", sigmas = (1,), ylabel = "ΔE (keV)",
                                      ylims = (-8, 8), title = get_plottitle(filekey_det, part, det, "Gain Stability"))
                ax = Makie.content(p[1, 1])
                LegendMakie.lplot!(ax, energy_gain; color = :red, label = "E_10410", sigmas = (1,))
                Makie.axislegend(ax; position = :rt)
                return p
            end
        else
            @warn "Not enough pulser statistics for gain plot: $det in partition $part"
        end

        return (processed = processed_dict, log = log_info_dict)
    end

    # execute in parallel
    result_stability = parallel(det_stability_plots, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                                process_name = "$period-p_process_stability_plots_phy")

    @info "Finished stability plot generation"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :p_process_stability_plots_phy, result_stability)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_stability))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :stability_plots_phy), report)
    @info report

    flush(stdout)
    return any(x -> get(last(x), :skipped, false), values(result_stability))
end

register_processor!(p_process_stability_plots_phy; detector_selection = false)
