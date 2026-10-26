function p_process_filter_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)

    @info "Optimize filter for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    if reprocess @info "Reprocess all detectors" else @info "Only process detectors not in pars_db" end

    # create log line Tuple
    log_cols = (:Detector, :Channel, :Partition, :Status, Symbol("Filter Type"), :Objective, Symbol("Rise Time"), Symbol("Flat-Top Time"), :FWHM, :W90, Symbol("Legacy RT"), Symbol("Legacy FT"), :Converged, Symbol("Crosscheck Warning"), :Error)
    log_nt = NamedTuple{log_cols}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period, :cal; unfold_partitions=true)

    # flush stdout
    flush(stdout)

    function det_filter_optimization(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @debug "Processing detector $det ($ch)"
        
        mkpath(joinpath(data_path(l200.par.ppars.fltopt), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.fltopt[det]), "$part.yaml"))
            PropDict(l200.par.ppars.fltopt[det, part])
        else
            mkpath(joinpath(data_path(l200.par.ppars.fltopt), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"
    
        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        pars_tau = get_values(PropDict(l200.par.ppars.pz[det, part]))
        @debug "Loaded decay times"

        # A/E filter optimization pars of this partition, empty if the detector has none yet
        aoeopt_filename = joinpath(data_path(l200.par.ppars.aoeopt), "$det", "$part.yaml")
        pars_aoeopt_det = isfile(aoeopt_filename) ? get_values(PropDict(l200.par.ppars.aoeopt[det, part])) : PropDict()

        dsp_config_pd = dataprod_config(l200).dsp(filekey_det)
        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        optimization_config = dataprod_config(l200).dsp(filekey_det).flt_optimization
        optimization_config_det = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded optimization config: $(lstring(optimization_config_det))"
        
        # extract config
        n_evts        = optimization_config_det.n_evts
        max_wvfs      = optimization_config_det.max_wvfs
        select_random = optimization_config_det.select_random
        e_filter      = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in e_filter
                log_info = log_nt((det, ch, part, ProcessStatus(1), filter_type, fill("-", length(log_cols) - 6)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db_det[det], filter_type) && !(all(k -> haskey(pars_db_det[det][filter_type], k), (:objective, :w90, :ct_spread, :joint_search, :legacy)) && haskey(pars_db_det[det][filter_type].legacy, :rt) && haskey(pars_db_det[det][filter_type].legacy, :ft))
                    @info "Detector $det, filter $filter_type: pars from the previous method, re-optimizing"
                elseif haskey(pars_db_det[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    pars_flt = pars_db_det[det][filter_type]
                    log_info_dict[filter_type] = log_nt((det, ch, part, ProcessStatus(1), filter_type, pars_flt.objective, pars_flt.rt, pars_flt.ft, pars_flt.fwhm, pars_flt.w90, pars_flt.legacy.rt, pars_flt.legacy.ft, get(pars_flt, :converged, "-"), "-", "Already processed --> skipped."))
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict, validity = validity_det)
        end

        haskey(pars_tau, det) && haskey(pars_tau[det], :τ) || throw(ErrorException("Detector $det has no decay time τ in the pz pars of partition $part"))
        haskey(pars_aoeopt_det, det) && !(haskey(pars_aoeopt_det[det], :sg) && haskey(pars_aoeopt_det[det].sg, :wl)) &&
            throw(ErrorException("Detector $det has no SG window length sg.wl in the aoeopt pars of partition $part"))

        # SG window length of the A/E crosscheck: aoeopt pars of this partition, else the DSP config default
        sg_wl, sg_wl_source = if haskey(pars_aoeopt_det, det)
            pars_aoeopt_det[det].sg.wl, "aoeopt pars"
        else
            dsp_config_det.default_flt_param.sg, "DSP config default"
        end
        @info "Detector $det ($part): SG window length $sg_wl from $sg_wl_source"

        @debug "Loading peak data from $(part), select $(ifelse(select_random, "randomly", "")) $n_evts events from each run"
        results = try
            run_filter_optimization_channel(
                peakname -> load_peak_waveforms(l200, partinfo_det, det, peakname, max_wvfs; n_evts),
                filter(!in(keys(processed_dict)), e_filter), dsp_config_det, optimization_config_det, pars_tau[det].τ,
                f_evaluate_qc, sg_wl, sg_wl_source;
                f_title = (label, flt) -> get_plottitle(filekey_det, part, det, label; additional_type=string(flt)),
                f_save = (fig, name) -> savelfig(LegendMakie.lsavefig, fig, l200, part, filekey_det, det, name),
                f_tablepath = flt -> replace(LegendDataManagement.LDMUtils.get_pltfilename(l200, part, filekey_det.setup, filekey_det.category, det, Symbol("fltopt_tables_$(flt)")), r"\.png$" => ".lh5")
            )
        catch e
            e isa InterruptException && rethrow()
            @error "Filter optimization of $det in $(part) failed: $(truncate_error(e))"
            throw(LoadError(string(part), 154, "Filter optimization of $det in $(part) failed: $(truncate_error(e))"))
        end

        for (filter_type, res) in results
            if res isa Exception
                log_info_dict[filter_type] = log_nt((det, ch, part, ProcessStatus(0), filter_type, fill("-", length(log_cols) - 6)..., truncate_error(res)))
                processed_dict[filter_type] = false
            else
                log_info_dict[filter_type] = log_nt((det, ch, part, ProcessStatus(1), filter_type, res.log.objective, res.pars.rt, res.pars.ft, res.pars.fwhm, res.pars.w90, res.log.legacy_rt, res.log.legacy_ft, get(res.pars, :converged, "-"), res.log.crosscheck_warning, "-"))
                result_rt_ft_dict[filter_type] = res.pars
                processed_dict[filter_type] = true
            end
        end

        # generate detector result
        result_det = (result = result_rt_ft_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_flt_det = Dict{NamedTuple, NamedTuple}(chinfo_det => result_det)
        
        # a re-optimized filter replaces its previous entry, so fields of an earlier method do not survive the merge
        for filter_type in keys(result_rt_ft_dict)
            if haskey(pars_db_det, det) && haskey(pars_db_det[det], filter_type)
                @info "Detector $det, filter $filter_type: replacing the previous pars entry"
                delete!(pars_db_det[det], filter_type)
            end
        end
        pars_db_det = create_pars(pars_db_det, result_flt_det)
        writelprops(l200.par.ppars.fltopt[det], part, pars_db_det)
        writevalidity(l200.par.ppars.fltopt[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_flt = parallel(chinfo_unfolded, det_filter_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished filter optimization"

    @info "Write $period validity"
    validity_all = create_validity(result_flt)
    writevalidity(l200.par.ppars.fltopt, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, flt_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_flt))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_flt))
end
