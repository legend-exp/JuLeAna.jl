"""
    process_dsp_aux_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Run the DSP and the calibration for the auxiliary detectors (for example the pulser) of the `phy` data of a run, per filekey.

The auxiliary detectors are the channels selected by `get_aux_evt_detsel_propfunc`. For each
filekey, the raw fields listed under `raw_fields` for the DSP function of each auxiliary
detector (`additional_detectors` in the DSP configuration) are read and processed with that
function, and the result is extended by the auxiliary calibration property function. After all
filekeys, each detector is summarized over the run without the filekeys in `bad_filekeys`
(also the removed ones): its number of events, a cross-check
histogram of the energy named in the `cal.aux_trig` condition of the event configuration with
the trigger threshold marked, and, for detectors with a `cal.aux_trig_intime` condition, a 2D histogram of that energy
versus the time column of the condition (`t_max`, or `t50` for the pulser) with its time window marked.

# Inputs
- `raw` tier of the `phy` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `dataprod_config(l200).dsp(filekey)`, sections `additional_detectors` and `raw_fields`
- `dataprod_config(l200).evt(filekey)`, section `aux`
- the auxiliary calibration from `get_aux_cal_propfunc(l200, filekey, det)`

# Outputs
- `jlaux` tier file for each filekey, with one table per auxiliary detector (DSP and calibrated columns)
- plots `:dsp_aux_energy` and `:dsp_aux_energy_time` for each auxiliary detector (debug plot level)
- run report `:dsp_aux_phy`, with one row per detector (status, number of events) and one row per filekey

# Keywords
- `reprocess`: remove the existing `jlaux` files and process all detectors again; otherwise detectors already present in a file are skipped
- `timeout`: seconds allowed per filekey and per detector summary in `parallel` (0 = no limit)
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

    chinfo = channelinfo(l200, filekey) |> detector_filter(processing_config, :process_dsp_aux_phy)
    @info "Loaded channel info with $(length(chinfo)) channels"

    chinfo_aux = filterby(get_aux_evt_detsel_propfunc(l200, filekey))(chinfo)
    @info "Loaded auxiliary detectors: $(join(string.(chinfo_aux.detector), ", "))"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    evt_config_pd = dataprod_config(l200).evt(filekey)

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Number Events"), :Error)}
    log_fk_nt = NamedTuple{(:Filekey, :Status, Symbol("Processed Detectors"), Symbol("Failed Detectors"), :Error)}

    function filekey_dsp_aux(fk::FileKey)
        n_processed = 0
        failed_detectors = DetectorId[]
        write_files(l200.tier[:jlaux, fk]; use_cache, mode = CreateOrModify()) do outfilename
            if reprocess && isfile(outfilename)
                rm(outfilename; force = true)
            end
            lh5open(outfilename, "cw") do outdata
                processed_detectors = stored_detectors(outdata, "jlaux")
                for chinfo_det in chinfo_aux
                    ch, det = chinfo_det.channel, chinfo_det.detector
                    detector_selected(det) || continue
                    if "$det" in processed_detectors && !redo_detector(det)
                        @info "DSP for auxiliary detector $det ($ch) in $fk already exists, skip"
                        continue
                    end
                    @info "Processing DSP for auxiliary detector $det ($ch) in $fk"
                    try
                        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
                        dsp_function = dsp_config_pd.additional_detectors[det]
                        # Read only the raw columns the DSP function needs, not the full waveforms of every field.
                        raw_fields = Tuple(Symbol.(dsp_config_pd.raw_fields[Symbol(dsp_function)]))
                        raw_data = read_ldata(raw_fields, l200, DataTier(:raw), fk, det)
                        dsp_data = legend_dsp_function(dsp_function, "dsp.additional_detectors.$det")(raw_data, dsp_config_det)
                        cal_output = get_aux_cal_propfunc(l200, filekey, det).(dsp_data)
                        "$det" in processed_detectors && delete_entry!(outdata, "jlaux/$det")
                        outdata[:jlaux, det] = merge(columns(dsp_data), columns(cal_output))
                        n_processed += 1
                    catch e
                        @error "Error while running DSP for auxiliary detector $det in $fk: $(truncate_error(e))"
                        push!(failed_detectors, det)
                    end
                end
            end
        end
        return (processed = n_processed > 0,
                log = log_fk_nt((fk, ProcessStatus(isempty(failed_detectors) ? 1 : 0), n_processed, string.(failed_detectors), "")))
    end

    # Run-level summaries need all filekeys, so they follow the filekey stage, one detector per worker.
    function det_dsp_aux(chinfo_det::NamedTuple)
        det = chinfo_det.detector
        energy_type, threshold = split(evt_config_pd.aux[det].cal.aux_trig, '>'; limit = 2)
        energy_type, threshold = Symbol(strip(energy_type)), parse(Float64, strip(threshold))
        # jlaux groups are LH5 structs, for which a single-column read returns the bare column.
        energy = @process_step "auxiliary energy loader" begin
            ustrip.(read_ldata(energy_type, l200, DataTier(:jlaux), :phy, period, run, det))
        end
        n_evts = length(energy)
        valid = isfinite.(energy) .& (energy .> 0)

        @debug_plot if any(valid)
            @process_step "auxiliary DSP cross-check plot" begin
                log_min = floor(Int, log10(minimum(energy[valid])))
                log_max = max(log_min + 1, floor(Int, log10(max(maximum(energy[valid]), threshold))) + 1)
                p = LegendMakie.lhist(fit(Histogram, energy[valid], 10.0 .^ (log_min:0.05:log_max)); figsize = (700, 450),
                                      title = get_plottitle(filekey, det, "Auxiliary DSP cross-check"), xlabel = "$energy_type (ADC)",
                                      ylabel = "Counts / bin", yscale = log10, xticks = Makie.LogTicks(Makie.WilkinsonTicks(5; k_min = 3)),
                                      juleana_logo = false)
                ax = Makie.current_axis()
                ax.xscale = log10
                Makie.vlines!(ax, [threshold]; color = LegendMakie.BEGeOrange, linestyle = :dash, linewidth = 2,
                              label = "$energy_type > $threshold")
                Makie.axislegend(ax; position = :rt)
                save_plot(p, l200, filekey, det, :dsp_aux_energy)
            end
        end

        # time bounds of the `cal.aux_trig_intime` condition, e.g. `e_10410 > 1000 && t50 >= 48u"µs" && t50 <= 50u"µs"`
        intime = collect(eachmatch(r"(\w+)\s*[<>]=?\s*([\d.]+)\s*u\"([^\"]+)\"", get(evt_config_pd.aux[det].cal, :aux_trig_intime, "")))
        @debug_plot if !isempty(intime) && any(valid)
            @process_step "auxiliary energy versus time plot" begin
                time_type = Symbol(first(intime)[1])
                window = [ustrip(u"µs", parse(Float64, m[2]) * uparse(m[3])) for m in intime]
                t = ustrip.(u"µs", read_ldata(time_type, l200, DataTier(:jlaux), :phy, period, run, det))
                sel = valid .& isfinite.(t)
                t, e = t[sel], energy[sel]
                log_min = floor(log10(minimum(e)))
                log_max = max(log_min + 1, ceil(log10(maximum(e))))
                energy_bins = 10.0 .^ range(log_min, log_max; length = 201)
                energy_bins[end] = nextfloat(last(energy_bins))
                time_bins = first(fit(Histogram, t; nbins = 200).edges)
                p = LegendMakie.lhist(fit(Histogram, (t, e), (time_bins, energy_bins)); figsize = (800, 500),
                                      title = get_plottitle(filekey, det, "$energy_type vs. $time_type"), xlabel = "$time_type (µs)",
                                      ylabel = "$energy_type (ADC)", yscale = log10, colorbarlabel = "Counts / bin", juleana_logo = false)
                ax = Makie.current_axis()
                Makie.vlines!(ax, window; color = LegendMakie.BEGeOrange, linestyle = :dash, linewidth = 2,
                              label = "aux_trig_intime window")
                Makie.axislegend(ax; position = :rt)
                save_plot(p, l200, filekey, det, :dsp_aux_energy_time)
            end
        end

        return (result = (n_evts = n_evts,), processed = true,
                log = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "$n_evts", "")))
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_filekeys = parallel(filekey_dsp_aux, filekeys, log_fk_nt; timeout = timeout, retry = false,
                               process_name = "$period-$run-process_dsp_aux_phy")
    result_dsp_aux = parallel(det_dsp_aux, chinfo_aux, log_nt; timeout = timeout, retry = false,
                              process_name = "$period-$run-process_dsp_aux_phy-summary")

    @info "Finished auxiliary detector DSP"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_dsp_aux_phy, result_filekeys,
                                                                result_dsp_aux)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_dsp_aux))
    lreport!(report, "# Filekeys")
    lreport!(report, filekey_logtbl(l200, result_filekeys))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :dsp_aux_phy), report)
    @info report

    return flush(stdout)
end

register_processor!(process_dsp_aux_phy; output_tiers = [:jlaux])
