function process_filter_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Optimize filter for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    pars_tau = get_values(l200.par.rpars.pz[period, run])
    @debug "Loaded decay times"

    aoeopt_filename = joinpath(data_path(l200.par.rpars.aoeopt), string(period), "$run.yaml")
    pars_aoeopt = isfile(aoeopt_filename) ? get_values(PropDict(l200.par.rpars.aoeopt[period, run])) : PropDict()
    @debug "Loaded A/E filter optimization pars of $(length(keys(pars_aoeopt))) detectors"

    optimization_config = dataprod_config(l200).dsp(filekey).flt_optimization
    @debug "Loaded optimization config: $(lstring(optimization_config))"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.fltopt), string(period)))
    pars_db = PropDict(l200.par.rpars.fltopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" else @info "Only process detectors not in pars_db" end

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # create log line Tuple
    log_cols = (:Detector, :Channel, :Status, Symbol("Filter Type"), :Objective, Symbol("Rise Time"), Symbol("Flat-Top Time"), :FWHM, :W90, Symbol("Legacy RT"), Symbol("Legacy FT"), :Converged, Symbol("Crosscheck Warning"), :Error)
    log_nt = NamedTuple{log_cols}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function det_filter_optimization(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        optimization_config_det = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        e_filter      = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if !reprocess && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db[det], filter_type) && !(all(k -> haskey(pars_db[det][filter_type], k), (:objective, :w90, :legacy, :converged)) && haskey(pars_db[det][filter_type].legacy, :rt) && haskey(pars_db[det][filter_type].legacy, :ft))
                    @info "Detector $det, filter $filter_type: pars from the previous method, re-optimizing"
                elseif haskey(pars_db[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    pars_flt = pars_db[det][filter_type]
                    log_info_dict[filter_type] = log_nt((det, ch, ProcessStatus(1), filter_type, pars_flt.objective, pars_flt.rt, pars_flt.ft, pars_flt.fwhm, pars_flt.w90, pars_flt.legacy.rt, pars_flt.legacy.ft, pars_flt.converged, "-", "Already processed --> skipped."))
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict)
        end

        filename = l200.tier[:jlpks, filekey, det]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip detector $det"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end
        yield()

        haskey(pars_tau, det) && haskey(pars_tau[det], :τ) || throw(ErrorException("Detector $det has no decay time τ in the pz pars of $period-$run"))
        haskey(pars_aoeopt, det) && !(haskey(pars_aoeopt[det], :sg) && haskey(pars_aoeopt[det].sg, :wl)) &&
            throw(ErrorException("Detector $det has no SG window length sg.wl in the aoeopt pars of $period-$run"))

        # SG window length of the A/E crosscheck: aoeopt pars of this run, else the DSP config default
        sg_wl, sg_wl_source = if haskey(pars_aoeopt, det)
            pars_aoeopt[det].sg.wl, "aoeopt pars"
        else
            dsp_config_det.default_flt_param.sg, "DSP config default"
        end
        @info "Detector $det: SG window length $sg_wl from $sg_wl_source"

        results = run_filter_optimization_channel(
            peakname -> load_peak_waveforms(l200, filekey, det, peakname, optimization_config_det.max_wvfs),
            filter(!in(keys(processed_dict)), e_filter), dsp_config_det, optimization_config_det, pars_tau[det].τ,
            f_evaluate_qc, sg_wl, sg_wl_source;
            f_title = (label, flt) -> get_plottitle(filekey, det, label; additional_type=string(flt)),
            f_save = (fig, name) -> savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, name),
            f_tablepath = flt -> replace(LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, Symbol("fltopt_tables_$(flt)")), r"\.png$" => ".lh5")
        )

        for (filter_type, res) in results
            if res isa Exception
                log_info_dict[filter_type] = log_nt((det, ch, ProcessStatus(0), filter_type, fill("-", length(log_cols) - 5)..., truncate_error(res)))
                processed_dict[filter_type] = false
            else
                log_info_dict[filter_type] = log_nt((det, ch, ProcessStatus(1), filter_type, res.log.objective, res.pars.rt, res.pars.ft, res.pars.fwhm, res.pars.w90, res.log.legacy_rt, res.log.legacy_ft, res.pars.converged, res.log.crosscheck_warning, "-"))
                result_rt_ft_dict[filter_type] = res.pars
                processed_dict[filter_type] = true
            end
        end

        # return results
        return (result = result_rt_ft_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_flt = parallel(chinfo, det_filter_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished filter optimization"

    pars_db = create_pars(pars_db, result_flt)
    writelprops(l200.par.rpars.fltopt[period], run, pars_db)
    writevalidity(l200.par.rpars.fltopt, filekey, (period, run))
    @info "Saved pars to disk"

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
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)
end
