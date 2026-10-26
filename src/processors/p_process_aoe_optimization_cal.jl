"""
    p_process_aoe_optimization_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, max_wvfs::Int=15000, only_first_period::Bool=true)

Optimize the window length of the A/E filters for every detector and `cal` partition that contains `period`.

This is the partition-level counterpart of [`process_aoe_optimization_cal`](@ref). The Tl208 DEP and SEP waveforms of all
`cal` runs in a detector's partition are combined for one optimization per detector, partition and filter type.
Detectors with `low_aoe_status` of `:valid` or `:present` are processed.

# Inputs
- Channel info of the `cal` analysis runs of `period`, merged over the runs by `channelinfo(l200, period, :cal)`, and
  the start filekey of the first run of each partition (selects the configuration).
- Windowed and presummed waveforms of the `Tl208DEP_Bi212FEP` and `Tl208SEP` selections from the `jlpks` tier of the
  `cal` runs in the partition. The configuration entry `n_evts` sets how many events are read per run, and
  `select_random` whether they are chosen randomly.
- `l200.par.ppars.pz[det, part]` (decay times) and `l200.par.ppars.fltopt[det, part]` (energy filter parameters).
- `dataprod_config(l200).dsp(filekey)`: the `default` section merged with the detector section for the DSP settings;
  `aoe_optimization.p_default` merged with `aoe_optimization.p[det]` for `qc`, `n_evts`, `select_random` and the
  `aoe_filter` table (same entries as in `process_aoe_optimization_cal`).
- The QC evaluator of the filekey (`load_qc_evaluator`).

# Outputs
- `l200.par.ppars.aoeopt[det, part]`: per filter type, the selected window length (`wl`), SEP survival fraction
  (`sf`) and the number of DEP and SEP events used (`n_dep`, `n_sep`), plus the validity of `ppars.aoeopt` for `period`.
- One plot per detector, partition and filter type, named `aoe_sweep_<filter type>`, saved only at the debug plot level.
- If `error_plots` is on, a failed DSP of DEP and SEP saves `error_dsp_dep_sep_<filter type>` and a failed window length optimization `error_window_length_optimization_<filter type>`.
- Partition report `aoe_optimization` with the processing status, a metadata table and one result row per detector,
  partition and filter type.

# Keywords
- `reprocess`: Discard the existing `ppars.aoeopt` parameters of each detector and partition and optimize all filter
  types again. Otherwise, filter types that already have results are kept.
- `timeout`: Seconds allowed per detector and partition in `parallel`; `0` means no limit.
- `max_wvfs`: Maximum number of DEP waveforms and of SEP waveforms used per detector and partition (default `15000`).
  If more are loaded, `max_wvfs` of them are selected at random, without repetition and in their original order.
- `only_first_period`: If `true`, a detector whose partition starts in an earlier period is skipped and logged as
  skipped. `run_processing` sets it to `true` when the previous period is also being processed.

# Returns
`true` if at least one detector was skipped because of `only_first_period`, otherwise `false`. `run_processing` uses
this to wait for the same step in the previous period.
"""
function p_process_aoe_optimization_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                                        max_wvfs::Int = 15000, only_first_period::Bool = true)
    @info "Optimize PSD filter for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo_unfolded = channelinfo(l200, period, :cal; system = :geds, only_processable = true, explode_partitions = true) |>
                      filterby(@pf $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    if reprocess
        @info "Reprocess all detectors"
    else
        @info "Only process detectors not in pars_db"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Partition, :Status, Symbol("Filter Type"), Symbol("Window length"),
                         Symbol("Survival Fraction"), Symbol("Number of DEP"), Symbol("Number of SEP"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function det_sg_optimization(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        make_par_dir(joinpath(data_path(l200.par.ppars.aoeopt), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.aoeopt), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.aoeopt[det, part])
        else
            make_par_dir(joinpath(data_path(l200.par.ppars.aoeopt), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        pars_tau = get_values(l200.par.ppars.pz[det, part])
        @debug "Loaded decay times"

        pars_fltoptimization = get_values(l200.par.ppars.fltopt[det, part])
        @debug "Loaded energy optimization parameters"

        dsp_config_pd = dataprod_config(l200).dsp(filekey_det)
        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        optimization_config = dataprod_config(l200).dsp(filekey_det).aoe_optimization
        aoe_config_det = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded optimization config: $(lstring(optimization_config))"

        # extract config
        qc_string = aoe_config_det.qc
        aoe_filter = collect(keys(aoe_config_det.aoe_filter))
        n_evts = aoe_config_det.n_evts
        select_random = aoe_config_det.select_random

        result_wl_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in aoe_filter
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, process_skipped, filter_type, fill("-", 4)...,
                                   "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && !redo_detector(det) && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in aoe_filter
                if haskey(pars_db_det[det], filter_type)
                    log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), filter_type,
                                       pars_db_det[det][filter_type].wl, pars_db_det[det][filter_type].sf,
                                       pars_db_det[det][filter_type].n_dep, pars_db_det[det][filter_type].n_sep,
                                       "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(aoe_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict, validity = validity_det)
        end

        # load data
        wvfs_det_sep_wdw, wvfs_det_sep_pre, wvfs_det_dep_wdw, wvfs_det_dep_pre, presum_rate = @process_step "DEP and SEP data loader" begin
            @debug "Loading Tl208 SEP and DEP data from $(part), select $(ifelse(select_random, "randomly ", ""))$n_evts events from each run"
            # The events of each run are selected by timestamp before reading, so only the
            # selected waveforms are loaded from disk.
            read_peak_selected(peakname) = fast_flatten(map(partinfo_det) do r
                                                            ts = read_ldata(ljl_propfunc("$peakname.timestamp"), l200, DataTier(:jlpks),
                                                                            DataCategory(:cal), r.period, r.run, det)
                                                            n_sel = n_evts == -1 ? length(ts) : min(n_evts, length(ts))
                                                            ts_sel = select_random ? sample(ts, n_sel; replace = false, ordered = true) :
                                                                     ts[begin:(begin + n_sel - 1)]
                                                            read_ldata(peakname, l200, DataTier(:jlpks), DataCategory(:cal), r.period,
                                                                       r.run, det; filterby = @pf $timestamp in ts_sel)
                                                        end)
            dep_data = read_peak_selected(:Tl208DEP_Bi212FEP)
            sep_data = read_peak_selected(:Tl208SEP)
            wvfs_det_dep_bi121fep_wdw = dep_data.waveform_windowed
            wvfs_det_dep_bi121fep_pre = dep_data.waveform_presummed
            presum_rate = first(sep_data.presum_rate)
            # DEP
            wvfs_det_dep_wdw = wvfs_det_dep_bi121fep_wdw
            wvfs_det_dep_pre = wvfs_det_dep_bi121fep_pre
            if length(wvfs_det_dep_pre) > max_wvfs
                @warn "DEP events exceed $max_wvfs, keep only $max_wvfs events"
                sel = sample(eachindex(wvfs_det_dep_pre), max_wvfs; replace = false, ordered = true)
                wvfs_det_dep_pre = wvfs_det_dep_pre[sel]
                wvfs_det_dep_wdw = wvfs_det_dep_wdw[sel]
            end
            # SEP
            wvfs_det_sep_wdw = sep_data.waveform_windowed
            wvfs_det_sep_pre = sep_data.waveform_presummed
            if length(wvfs_det_sep_pre) > max_wvfs
                @warn "SEP events exceed $max_wvfs, keep only $max_wvfs events"
                sel = sample(eachindex(wvfs_det_sep_pre), max_wvfs; replace = false, ordered = true)
                wvfs_det_sep_pre = wvfs_det_sep_pre[sel]
                wvfs_det_sep_wdw = wvfs_det_sep_wdw[sel]
            end
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
                    Makie.Label(fig[0, 1:2],
                                get_plottitle(filekey_det, part, det, "Example Waveforms"; additional_type = string(filter_type)))
                    for (col, (name, wvfs)) in enumerate(("DEP" => wvfs_det_dep_wdw, "SEP" => wvfs_det_sep_wdw))
                        ax = Makie.Axis(fig[1, col]; title = name, xlabel = "Time", ylabel = "Signal")
                        for wvf in Iterators.take(wvfs, 5)
                            Makie.lines!(ax, ustrip.(wvf.time), ustrip.(wvf.signal))
                        end
                    end
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_dsp_dep_sep_$filter_type"))
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
                    Makie.Label(fig[0, 1:2], get_plottitle(filekey_det, part, det, "DEP and SEP"; additional_type = string(filter_type)))
                    for (col, (name, data)) in enumerate(("DEP" => dep_sep_after_qc.dep, "SEP" => dep_sep_after_qc.sep))
                        ax_aoe = Makie.Axis(fig[1, col]; title = "$name A/E", xlabel = "A/E", ylabel = "Counts")
                        Makie.hist!(ax_aoe, filter(isfinite, ustrip.(data.aoe)); bins = 100)
                        ax_e = Makie.Axis(fig[2, col]; title = "$name energy", xlabel = "Energy", ylabel = "Counts")
                        Makie.hist!(ax_e, filter(isfinite, ustrip.(data.energy)); bins = 100)
                    end
                    save_plot(fig, l200, part, filekey_det, det, Symbol("error_window_length_optimization_$filter_type"))
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

                @debug_plot begin
                    p = LegendMakie.lplot(report_wl,
                                          title = get_plottitle(filekey_det, part, det, "Filter Optimization";
                                                                additional_type = string(filter_type)))
                    save_plot(p, l200, part, filekey_det, det, Symbol("aoe_sweep_$(filter_type)"))
                end

                @info """Found optimal window length at $(result_wl.wl) with survival fraction $(round(u"percent", result_wl.sf; digits=2)) for detector $det ($ch)"""

                # write log
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(1), filter_type, result_wl.wl,
                                   result_wl.sf, result_wl.n_dep, result_wl.n_sep, "-"))

                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true
                result_wl_dict[filter_type] = result_wl

                yield()
            catch e
                e isa ProcessStepError || @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), part, ProcessStatus(0), filter_type, "-", "-", "-", "-",
                                   "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end
        # generate detector result
        result_det = (result = result_wl_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_sg_det = Dict{NamedTuple,NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_sg_det)
        write_pars(l200.par.ppars.aoeopt[det], part, pars_db_det)
        write_validity(l200.par.ppars.aoeopt[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sg = parallel(det_sg_optimization, chinfo_unfolded, log_nt; timeout = timeout, retry = false,
                         process_name = "$period-p_process_aoe_optimization_cal")

    @info "Finished SG filter optimization"

    @info "Write $period validity"
    validity_all = create_validity(result_sg)
    write_validity(l200.par.ppars.aoeopt, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_sg)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sg_filter_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sg))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :aoe_optimization), report)
    @info report

    # flush stdout
    flush(stdout)

    # return if any channel was skipped so that the partition is not valid until the lower period is finished
    return any(x -> get(last(x), :skipped, false), values(result_sg))
end

register_processor!(p_process_aoe_optimization_cal)
