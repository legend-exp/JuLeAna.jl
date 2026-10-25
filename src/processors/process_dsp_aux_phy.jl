"""
    process_dsp_aux_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Run the DSP and the calibration for the auxiliary detectors (for example the pulser) of the `phy` data of a run.

The auxiliary detectors are the channels selected by `get_aux_evt_detsel_propfunc`. For each of
them, the raw data of the `phy` filekeys of the run listed in the runinfo are read together and processed with the
function configured for it under `additional_detectors` in the DSP configuration. The result is
then extended by the auxiliary calibration property function. A cross-check histogram of the
energy named in the `cal.aux_trig` condition of the event configuration is saved, with the
trigger threshold marked.

# Inputs
- `raw` tier of the `phy` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `dataprod_config(l200).dsp(filekey)`, section `additional_detectors`
- `dataprod_config(l200).evt(filekey)`, section `aux`
- the auxiliary calibration from `get_aux_cal_propfunc(l200, filekey, det)`

# Outputs
- `jlaux` tier file for each auxiliary detector, with the DSP and calibrated columns
- plot `:dsp_aux_energy` for each auxiliary detector (debug plot level)
- run report `:dsp_aux_phy`, with one row per detector (status, number of events)

# Keywords
- `reprocess`: process detectors again whose `jlaux` file exists; otherwise a detector with a readable `jlaux` file is skipped
- `timeout`: seconds allowed per auxiliary detector in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)

# Returns
Return `nothing`.
"""
function process_dsp_aux_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                             timeout::Real = 0, use_cache::Bool = true)
    @info "Process auxiliary detector DSP for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :phy)).keys))

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey)
    @info "Loaded channel info with $(length(chinfo)) channels"

    chinfo_aux = filterby(get_aux_evt_detsel_propfunc(l200, filekey))(chinfo)
    @info "Loaded auxiliary detectors: $(join(string.(chinfo_aux.detector), ", "))"

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Number Events"), :Error)}

    # get worker pool

    function plot_dsp_aux_crosscheck(dsp_data, det, energy_type, threshold)
        energy = filter(x -> isfinite(x) && x > 0, ustrip.(getproperty(dsp_data, energy_type)))
        log_min = floor(log10(max(minimum(energy), 1.0)))
        log_max = max(log_min + 1, ceil(log10(max(maximum(energy), threshold))))
        bins = 10.0 .^ range(log_min, log_max; length = 101)
        p = LegendMakie.lhist(energy; bins = bins, figsize = (700, 450), title = get_plottitle(filekey, det, "Auxiliary DSP cross-check"),
                              xlabel = "$energy_type (ADC)", ylabel = "Counts / bin", xscale = log10, yscale = log10, xlims = extrema(bins),
                              legend_position = :none)
        ax = Makie.current_axis()
        Makie.vlines!(ax, [threshold]; color = LegendMakie.BEGeOrange, linestyle = :dash, linewidth = 2,
                      label = "$energy_type > $threshold")
        Makie.axislegend(ax; position = :lt)
        return p
    end

    function det_dsp_aux(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing DSP for auxiliary detector $det ($ch)"
        dspfilename = l200.tier[:jlaux, filekey, det]

        if !reprocess && !redo_detector(det) && isfile(dspfilename)
            try
                n_evts = length(read_ldata(:timestamp, l200, DataTier(:jlaux), filekey, det))
                @info "DSP for auxiliary detector $det ($ch) already exists, skip"
                return (result = (n_evts = n_evts,), processed = false,
                        log = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "$n_evts",
                                      "Already processed --> skipped.")))
            catch e
                @warn "Error reading existing DSP file for auxiliary detector $det ($ch): $(truncate_error(e))"
                @info "Reprocess auxiliary detector $det ($ch)"
            end
        end

        try
            raw_data = @process_step "raw data loading" begin
                read_ldata(l200, DataTier(:raw), filekeys, det)
            end

            dsp_config_pd = dataprod_config(l200).dsp(filekey)
            dsp_config_pd_det = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
            dsp_config_det = DSPConfig(dsp_config_pd_det)
            @debug "Loaded DSP config: $(lstring(dsp_config_det))"

            @debug "Generate DSP for $det"
            dsp_data = @process_step "auxiliary DSP" begin
                legend_dsp_function(dsp_config_pd.additional_detectors[det], "dsp.additional_detectors.$det")(raw_data, dsp_config_det)
            end

            @debug "Calibrate DSP data"
            evt_config_pd_det = dataprod_config(l200).evt(filekey).aux[det]
            cal_output = @process_step "auxiliary calibration" begin
                auxcal_pf = get_aux_cal_propfunc(l200, filekey, det)
                auxcal_pf.(dsp_data)
            end

            merged_table = merge(columns(dsp_data), columns(cal_output))

            @debug_plot begin
                @info "Generate auxiliary DSP cross-check plot for $det"
                energy_type, threshold = split(evt_config_pd_det.cal.aux_trig, '>'; limit = 2)
                energy_type, threshold = Symbol(strip(energy_type)), parse(Float64, strip(threshold))
                p = plot_dsp_aux_crosscheck(dsp_data, det, energy_type, threshold)
                save_plot(p, l200, filekey, det, :dsp_aux_energy)
            end

            @info "Write DSP data to disk"
            write_files(dspfilename; use_cache, mode = CreateOrReplace()) do outfilename
                lh5open(outfilename, "w") do outdata
                    return outdata[:jlaux, det] = merged_table
                end
            end

            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "$(length(dsp_data))", ""))
            @info "Finished DSP for auxiliary detector $det ($ch): $(length(dsp_data)) events"

            return (result = (n_evts = length(dsp_data),), processed = true, log = log_det)
        catch e
            e isa ProcessStepError || @error "Error while running DSP for auxiliary detector $det: $(e)"
            return (processed = false, log = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), "0", "$e")))
        end
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_dsp_aux = parallel(det_dsp_aux, chinfo_aux, log_nt; timeout = timeout, retry = false,
                              process_name = "$period-$run-process_dsp_aux_phy")

    @info "Finished auxiliary detector DSP"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_dsp_aux)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_dsp_aux))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :dsp_aux_phy), report)
    @info report

    return flush(stdout)
end

register_processor!(process_dsp_aux_phy; output_tiers = [:jlaux])
