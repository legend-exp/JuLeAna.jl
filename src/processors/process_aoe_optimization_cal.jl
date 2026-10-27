"""
    process_aoe_optimization_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Optimize the window length of the A/E filters for the HPGe detectors (`geds`) of one `cal` run.

For each detector with `usability == :on` and `low_aoe_status` of `:valid` or `:present`, and for each filter type
listed in the `aoe_filter` table of the configuration, the processor runs a short DSP routine on the Tl208 DEP and SEP
waveforms for a grid of window lengths, applies the configured QC expression, and evaluates the SEP survival fraction
after a simple A/E cut set on the DEP. It stores the selected window length together with its survival fraction.

# Inputs
- First `cal` filekey of the run (`start_filekey(l200, (period, run, :cal))`).
- Windowed and presummed waveforms of the `Tl208DEP_Bi212FEP` and `Tl208SEP` selections from the `jlpks` tier.
- `l200.par.rpars.pz[period, run]` (decay times) and `l200.par.rpars.fltopt[period, run]` (energy filter parameters).
- `dataprod_config(l200).dsp(filekey)`: the `default` section merged with the detector section for the DSP settings,
  including the window length grids `a_grid_wl_<filter type>`; and `aoe_optimization` (`default` merged with the
  detector section) with `qc` and the `aoe_filter` table. Each filter entry sets `dep`, `dep_window`, `sep`,
  `sep_window`, `sep_rel_cut`, `min_aoe_quantile`, `max_aoe_quantile`, `min_aoe_offset`, `max_aoe_offset`,
  `dep_cut_search_fit_func` and `sep_cut_search_fit_func`.
- The QC evaluator of the filekey (`load_qc_evaluator`).

# Outputs
- `l200.par.rpars.aoeopt[period, run]`: per detector and filter type, the selected window length (`wl`), SEP survival
  fraction (`sf`) and the number of DEP and SEP events used (`n_dep`, `n_sep`), plus the matching validity entry.
- One plot per detector and filter type of the window length sweep, named `<filter type>_sweep`.
- If `error_plots` is on, a failed DSP of DEP and SEP saves `error_dsp_dep_sep_<filter type>` and a failed window length optimization `error_window_length_optimization_<filter type>`.
- Run report `aoe_optimization` with the processing status, a metadata table and one result row per detector and
  filter type.

# Keywords
- `reprocess`: Discard the existing `aoeopt` parameters of the run and optimize all detectors and filter types again.
  Otherwise, filter types that already have results are kept and only missing ones are computed.
- `timeout`: Seconds allowed per detector in `parallel`; `0` means no limit.

# Returns
The return value is not used by `run_processing`.
"""
function process_aoe_optimization_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                      timeout::Real = 0)
    @info "Optimize PSD filter for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_aoe_optimization_cal)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    pars_tau = get_values(l200.par.rpars.pz[period, run])
    @debug "Loaded decay times"

    pars_fltoptimization = get_values(l200.par.rpars.fltopt[period, run])
    @debug "Loaded energy optimization parameters"

    optimization_config = dataprod_config(l200).dsp(filekey).aoe_optimization
    @debug "Loaded optimization config: $(lstring(optimization_config))"

    @debug "Create pars db"
    make_par_dir(joinpath(data_path(l200.par.rpars.aoeopt), string(period)))
    pars_db = PropDict(l200.par.rpars.aoeopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Filter Type"), Symbol("Window length"), Symbol("Survival Fraction"),
                         Symbol("Number of DEP"), Symbol("Number of SEP"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_sg_optimization(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        aoe_config_det = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        qc_string = aoe_config_det.qc
        aoe_filter = collect(keys(aoe_config_det.aoe_filter))

        result_wl_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in aoe_filter
                if haskey(pars_db[det], filter_type)
                    log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), filter_type,
                                       pars_db[det][filter_type].wl, pars_db[det][filter_type].sf, pars_db[det][filter_type].n_dep,
                                       pars_db[det][filter_type].n_sep, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(aoe_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict)
        end

        filename = l200.tier[:jlpks, filekey, det]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip detector $det"
            throw(ErrorException("File $(filename) does not exist"))
        end

        wvfs_det_sep_wdw, wvfs_det_sep_pre, wvfs_det_dep_wdw, wvfs_det_dep_pre, presum_rate = @process_step "DEP and SEP data loader" begin
            @debug "Loading Tl208 SEP and DEP data from $(filename)"
            dep_data = read_ldata((@pf (; waveform_windowed = $Tl208DEP_Bi212FEP.waveform_windowed,
                                        waveform_presummed = $Tl208DEP_Bi212FEP.waveform_presummed,
                                        daqenergy = $Tl208DEP_Bi212FEP.daqenergy)), l200, DataTier(:jlpks), filekey, det)
            sep_data = read_ldata((@pf (; waveform_windowed = $Tl208SEP.waveform_windowed,
                                        waveform_presummed = $Tl208SEP.waveform_presummed, presum_rate = $Tl208SEP.presum_rate)), l200,
                                  DataTier(:jlpks), filekey, det)
            wvfs_det_dep_bi121fep_wdw = dep_data.waveform_windowed
            wvfs_det_dep_bi121fep_pre = dep_data.waveform_presummed
            presum_rate = first(sep_data.presum_rate)
            wvfs_det_dep_wdw = wvfs_det_dep_bi121fep_wdw
            wvfs_det_dep_pre = wvfs_det_dep_bi121fep_pre
            wvfs_det_sep_wdw = sep_data.waveform_windowed
            wvfs_det_sep_pre = sep_data.waveform_presummed
            wvfs_det_sep_wdw, wvfs_det_sep_pre, wvfs_det_dep_wdw, wvfs_det_dep_pre, presum_rate
        end

        @debug_progress "Computing $det ..." for filter_type in aoe_filter
            if haskey(processed_dict, filter_type)
                continue
            end

            try
                @debug "Optimize $filter_type filter"

                aoe_config_flt = aoe_config_det.aoe_filter[filter_type]

                plot_example_waveforms() = begin
                    fig = Makie.Figure(size = (900, 400))
                    Makie.Label(fig[0, 1:2], get_plottitle(filekey, det, "Example Waveforms"; additional_type = string(filter_type)))
                    for (col, (name, wvfs)) in enumerate(("DEP" => wvfs_det_dep_wdw, "SEP" => wvfs_det_sep_wdw))
                        ax = Makie.Axis(fig[1, col]; title = name, xlabel = "Time", ylabel = "Signal")
                        for wvf in Iterators.take(wvfs, 5)
                            Makie.lines!(ax, ustrip.(wvf.time), ustrip.(wvf.signal))
                        end
                    end
                    save_plot(fig, l200, filekey, det, Symbol("error_dsp_dep_sep_$filter_type"))
                end
                dsp_sep, dsp_dep = @process_step "$filter_type DSP of DEP and SEP" on_error = plot_example_waveforms begin
                    # DSP
                    @debug "Generating DSP AoE grid for SEP and DEP data"
                    dsp_dep = legend_dsp_function("dsp_$(filter_type)_optimization_compressed",
                                                  "dsp.aoe_optimization.aoe_filter.$filter_type")(wvfs_det_dep_wdw, wvfs_det_dep_pre,
                                                                                                  dsp_config_det, pars_tau[det].τ,
                                                                                                  pars_fltoptimization[det];
                                                                                                  f_evaluate_qc = f_evaluate_qc,
                                                                                                  presum_rate = presum_rate)
                    dsp_sep = legend_dsp_function("dsp_$(filter_type)_optimization_compressed",
                                                  "dsp.aoe_optimization.aoe_filter.$filter_type")(wvfs_det_sep_wdw, wvfs_det_sep_pre,
                                                                                                  dsp_config_det, pars_tau[det].τ,
                                                                                                  pars_fltoptimization[det];
                                                                                                  f_evaluate_qc = f_evaluate_qc,
                                                                                                  presum_rate = presum_rate)
                    dsp_sep, dsp_dep
                end

                dep_sep_after_qc = @process_step "$filter_type QC of DEP and SEP" begin
                    # generate simple QC cuts
                    @debug "Apply QC cuts for SEP and DEP"
                    (dep = dsp_dep[ljl_propfunc(qc_string).(dsp_dep)], sep = dsp_sep[ljl_propfunc(qc_string).(dsp_sep)])
                end

                plot_dep_sep_distributions() = begin
                    fig = Makie.Figure(size = (900, 700))
                    Makie.Label(fig[0, 1:2], get_plottitle(filekey, det, "DEP and SEP"; additional_type = string(filter_type)))
                    for (col, (name, data)) in enumerate(("DEP" => dep_sep_after_qc.dep, "SEP" => dep_sep_after_qc.sep))
                        ax_aoe = Makie.Axis(fig[1, col]; title = "$name A/E", xlabel = "A/E", ylabel = "Counts")
                        Makie.hist!(ax_aoe, filter(isfinite, ustrip.(data.aoe)); bins = 100)
                        ax_e = Makie.Axis(fig[2, col]; title = "$name energy", xlabel = "Energy", ylabel = "Counts")
                        Makie.hist!(ax_e, filter(isfinite, ustrip.(data.energy)); bins = 100)
                    end
                    save_plot(fig, l200, filekey, det, Symbol("error_window_length_optimization_$filter_type"))
                end
                result_wl, report_wl = @process_step "$filter_type window length optimization" on_error = plot_dep_sep_distributions begin
                    # fit SG window length
                    @debug "Sweep through window lengths for SEP and DEP and get SEP survival fraction after simple PSD cut on DEP"
                    fit_sf_wl(dep_sep_after_qc.dep.energy, dep_sep_after_qc.dep.aoe, dep_sep_after_qc.sep.energy, dep_sep_after_qc.sep.aoe,
                              getproperty(dsp_config_det, Symbol("a_grid_wl_$(filter_type)")); dep = aoe_config_flt.dep,
                              dep_window = aoe_config_flt.dep_window, sep = aoe_config_flt.sep, sep_window = aoe_config_flt.sep_window,
                              sep_rel_cut = aoe_config_flt.sep_rel_cut, min_aoe_quantile = aoe_config_flt.min_aoe_quantile,
                              max_aoe_quantile = aoe_config_flt.max_aoe_quantile, min_aoe_offset = aoe_config_flt.min_aoe_offset,
                              max_aoe_offset = aoe_config_flt.max_aoe_offset,
                              dep_cut_search_fit_func = Symbol(aoe_config_flt.dep_cut_search_fit_func),
                              sep_cut_search_fit_func = Symbol(aoe_config_flt.sep_cut_search_fit_func))
                end

                p = LegendMakie.lplot(report_wl,
                                      title = get_plottitle(filekey, det, "$(uppercase(string(filter_type))) Filter Optimization"))
                save_plot(p, l200, filekey, det, Symbol("$(filter_type)_sweep"))

                @info """Found optimal window length at $(result_wl.wl) with survival fraction $(round(u"percent", result_wl.sf, digits=2)) for detector $det ($ch)"""

                # write log
                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), filter_type, result_wl.wl, result_wl.sf,
                                   result_wl.n_dep, result_wl.n_sep, "-"))

                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true
                result_wl_dict[filter_type] = result_wl

                yield()
            catch e
                e isa ProcessStepError || @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), filter_type, "-", "-", "-", "-",
                                   "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        return (result = result_wl_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sg = parallel(det_sg_optimization, chinfo, log_nt; timeout = timeout, retry = false,
                         process_name = "$period-$run-process_aoe_optimization_cal")

    @info "Finished SG filter optimization"

    pars_db = create_pars(pars_db, result_sg)
    write_pars(l200.par.rpars.aoeopt[period], run, pars_db)
    write_validity(l200.par.rpars.aoeopt, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_aoe_optimization_cal, result_sg)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sg_filter_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sg))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :aoe_optimization), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_aoe_optimization_cal)
