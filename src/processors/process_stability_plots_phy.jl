"""
    process_stability_plots_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Plot the stability of the HPGe detectors (`geds`) over one run from `phy` data.

For each processable detector, the following time-dependent quantities are plotted: baseline,
baseline sigma, the `e_10410` energy estimator, the pulser rate, and the gain stability. The
gain stability compares the relative change of `e_10410` of the pulser channel and of the
detector for pulser-triggered events, scaled to keV at `Qbb`. Each plot is made and logged
separately; a failing plot does not stop the others.

# Inputs
- `dsp` tier (`DataTier(:jldsp)`) of the `phy` data of the run, per detector, fields `timestamp`,
  `blmean`, `blsigma` and `e_10410`; events with non-finite values are dropped.
- `jlaux` tier fields `e_10410` and `aux_trig` of the pulser channel named by
  `dataprod_config(l200).qc(filekey).pulser.puls_detector`.
- `dataprod_config(l200).qc(filekey).stability_plots`: `n_ref` (number of events for the
  reference value), `n_smooth` (smoothing window of `20 * n_smooth` seconds) and `Qbb`.

# Outputs
- Plots per detector: `stability_time_vs_bl`, `stability_time_vs_blsigma`,
  `stability_time_vs_e10410`, `stability_e10410_hist`. If pulser-triggered events exist:
  `stability_time_vs_e10410_trig` and `stability_pulser_rate`. If more than `n_ref` finite
  pulser-triggered events exist: `stability_gain_stability`. Only `stability_gain_stability` is saved
  below the debug plot level.
- Run report `stability_plots_phy`.

No parameters are written.

# Keywords
- `reprocess`: only logged; plots are always remade and overwritten.
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_stability_plots_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                     timeout::Real = 0)
    @info "Process detector stability plots for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    n_ref = qc_config.stability_plots.n_ref
    n_smooth = qc_config.stability_plots.n_smooth
    Qbb = qc_config.stability_plots.Qbb
    smooth_window = 20n_smooth * u"s"

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    @info "Loaded pulser channel info: $chinfo_puls"

    if reprocess
        @info "Reprocess all detectors"
    end

    log_nt = NamedTuple{(:Detector, :usability, :Status, :Plot, :Error)}

    @info "Loading pulser data for period $period and run $run"
    puls = @process_step "pulser data loader" begin
        read_ldata((:e_10410, :aux_trig), l200, DataTier(:jlaux), :phy, period, run, det_puls)
    end

    start_time = now()

    function det_stability_plots(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        data = @process_step "data loader" begin
            read_ldata((:timestamp, :blmean, :blsigma, :e_10410), l200, DataTier(:jldsp), :phy, period, run, det)
        end

        timestamp, time_s, bl_f, σbl, e10410, puls_e10410, aux_trig = @process_step "finite event filter" begin
            length(puls.e_10410) == length(data.timestamp) ||
                throw(DimensionMismatch("pulser data of $det_puls ($(length(puls.e_10410)) events) does not match the data of $det ($(length(data.timestamp)) events)"))
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
                    save_plot(p, l200, filekey, det, plot_name)
                end
                log_info_dict[plot_name] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), plot_name, ""))
                processed_dict[plot_name] = true
            catch e
                e isa ProcessStepError || rethrow()
                log_info_dict[plot_name] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), plot_name,
                                                   "$(truncate_error(e.exception))"))
                processed_dict[plot_name] = false
            end
        end

        heatmap_kwargs = (bins = 600, figsize = (900, 600), xlabel = "Time (s)", colormap = :viridis, colorbarlabel = "Counts")

        @debug_plot begin
            run_plot(:stability_time_vs_bl) do
                LegendMakie.lhist(time_s, bl_f; heatmap_kwargs..., ylabel = "Baseline (ADC)",
                                  title = get_plottitle(filekey, det, "Time vs Baseline"))
            end
        end

        @debug_plot begin
            run_plot(:stability_time_vs_blsigma) do
                LegendMakie.lhist(time_s, σbl; heatmap_kwargs..., ylabel = "Baseline σ (ADC)", ylims = (0.0, 1000.0),
                                  title = get_plottitle(filekey, det, "Time vs Baseline σ"))
            end
        end

        @debug_plot begin
            run_plot(:stability_time_vs_e10410) do
                LegendMakie.lhist(time_s, e10410; heatmap_kwargs..., ylabel = "E_10410 (ADC)", ylims = (0.0, 1e5),
                                  title = get_plottitle(filekey, det, "Time vs E_10410"))
            end
        end

        @debug_plot begin
            run_plot(:stability_e10410_hist) do
                LegendMakie.lhist(e10410; bins = 0:1000:6e5, figsize = (900, 400), xlabel = "E_10410 (ADC)", ylabel = "Counts",
                                  yscale = log10, title = get_plottitle(filekey, det, "E_10410 Distribution"))
            end
        end

        mask_trig = aux_trig .== true
        if any(mask_trig)
            @debug_plot begin
                run_plot(:stability_time_vs_e10410_trig) do
                    LegendMakie.lhist(time_s[mask_trig], e10410[mask_trig]; heatmap_kwargs..., ylabel = "E_10410 (ADC)",
                                      title = get_plottitle(filekey, det, "Time vs E_10410 (Pulser-Triggered)"))
                end
            end
            @debug_plot begin
                run_plot(:stability_pulser_rate) do
                    LegendMakie.lplot(rate(timestamp[mask_trig], smooth_window); figsize = (900, 400), ylabel = "Pulser rate (Hz)",
                                      title = get_plottitle(filekey, det, "Pulser Rate"))
                end
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
                                      ylims = (-8, 8), title = get_plottitle(filekey, det, "Gain Stability"))
                ax = Makie.content(p[1, 1])
                LegendMakie.lplot!(ax, energy_gain; color = :red, label = "E_10410", sigmas = (1,))
                Makie.axislegend(ax; position = :rt)
                return p
            end
        else
            @warn "Not enough pulser statistics for gain plot: $det"
        end

        return (processed = processed_dict, log = log_info_dict)
    end

    result_stability = parallel(det_stability_plots, chinfo, log_nt; timeout = timeout, retry = false,
                                process_name = "$period-$run-process_stability_plots_phy")

    @info "Finished stability plot generation"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_stability)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_stability))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :stability_plots_phy), report)
    @info report

    return flush(stdout)
end

register_processor!(process_stability_plots_phy; detector_selection = false)
