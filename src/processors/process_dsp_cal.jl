"""
    process_dsp_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0,
        max_wvfs::Int=10000, use_partition_pars::Bool=true)

Run the DSP on the `cal` raw data of the HPGe detectors (`geds`) of a run.

For every raw `cal` file of the run, each detector is processed with its DSP configuration, its
pole-zero decay time, and its energy and A/E filter optimization parameters. A detector is
skipped and reported as failed if the decay time or the optimization parameters are missing,
if its DSP configuration has no `required_fltopt_selection` or `required_aoeopt_selection`, if
a parameter listed in `required_fltopt` (or `required_aoeopt`) is missing for a detector whose
channel info row satisfies `required_fltopt_selection` (or `required_aoeopt_selection`), or if
its DSP throws an error. The selections are strings of `LegendDataManagement.ljl_propfunc`
expressions, e.g.
`"usability == :on && (low_aoe_status == :valid || low_aoe_status == :present)"`.

# Inputs
- `raw` tier of the `cal` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `dataprod_config(l200).dsp(filekey)`
- `l200.par[pars_type, :pz]`, `l200.par[pars_type, :fltopt]` and `l200.par[pars_type, :aoeopt]`, with `pars_type` being `:ppars` if `use_partition_pars` is `true` and `:rpars` otherwise
- the QC evaluator from `load_qc_evaluator(l200, filekey)`

# Outputs
- `jldsp` tier file for each filekey, with one table per detector
- run report `:dsp_cal`, with one row per filekey (number of processed detectors, failed detectors, time, allocations)

# Keywords
- `reprocess`: remove the existing `jldsp` files and process all detectors again; otherwise detectors already present in a file are skipped
- `timeout`: seconds allowed per filekey in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)
- `max_wvfs`: not used by this processor
- `use_partition_pars`: read the decay time and optimization parameters from the partition-level parameters (`:ppars`) instead of the run-level parameters (`:rpars`)

# Returns
Return `nothing`.
"""
function process_dsp_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         max_wvfs::Int = 10000, use_partition_pars::Bool = true, use_cache::Bool = true)
    @info "Process DSP for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :cal)).keys))

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found start filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_dsp_cal)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    pars_type = ifelse(use_partition_pars, :ppars, :rpars)
    @info "Use $(ifelse(use_partition_pars, "partition", "run"))-based pars from $pars_type for DSP optimization parameters"

    pars_tau = get_values(l200.par[pars_type, :pz](filekey))
    @debug "Loaded decay times"

    pars_fltoptimization = get_values(merge(l200.par[pars_type, :fltopt](filekey), l200.par[pars_type, :aoeopt](filekey)))
    @debug "Loaded optimization parameters"

    if reprocess
        @info "Reprocess all filekeys and detectors"
    else
        @info "Only reprocess filekeys and detectors that are not processed yet"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"),
                         Symbol("Total Allocated"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function filekey_dsp(fk::FileKey)
        dsp_timer = TimerOutput()
        # raw and dsp filename
        rawfilename = l200.tier[:raw, fk]
        @info "Processing file: $(basename(rawfilename))"
        dspfilename = l200.tier[:jldsp, fk]
        @info "Using output file: $(basename(dspfilename))"
        # number of processed detectors
        n_detectors = 0
        # detector ids of failed detectors
        failed_detectors = DetectorId[]
        # start processing
        write_files(dspfilename; use_cache, mode = CreateOrModify()) do outfilename
            @timeit dsp_timer "Startup" begin
                if reprocess && isfile(dspfilename)
                    @info "Reprocess $(basename(dspfilename)), remove old DSP."
                    rm(outfilename, force = true)
                end
            end

            # open output file
            lh5open(outfilename, "cw") do outdata
                # get processed detectors
                processed_detectors = stored_detectors(outdata, "jldsp")

                @info "Start DSP"
                @timeit dsp_timer "DSP" begin
                    # loop over detectors
                    @debug_progress "Filekey: $fk" for chinfo_det in chinfo
                        ch=chinfo_det.channel
                        det=chinfo_det.detector

                        dsp_config_pd_det=merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
                        dsp_config_det=DSPConfig(dsp_config_pd_det)
                        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

                        # check if channel can be processed
                        detector_selected(det)||continue
                        if "$det" in processed_detectors&&!reprocess&&!redo_detector(det)
                            @info "Detector $det ($ch) already processed, skip"
                            n_detectors+=1
                            continue
                        end

                        # check for decay time
                        if !haskey(pars_tau, det)
                            @warn "No decay time for detector $det, skip detector $ch"
                            push!(failed_detectors, det)
                            continue
                        end
                        # check if channel has values for RT and FT for different filters
                        if !haskey(pars_fltoptimization, det)
                            @warn "No optimization parameters for detector $det, skip detector $ch"
                            push!(failed_detectors, det)
                            continue
                        end

                        # check if detector has all required optimization pars of the filters its selections require
                        missing_pars=false
                        for (selection, required, label) in ((:required_fltopt_selection, :required_fltopt, "energy filter"),
                                                             (:required_aoeopt_selection, :required_aoeopt, "A/E"))
                            if !haskey(dsp_config_pd_det, selection)
                                @warn "No `$selection` in the DSP config for detector $det, skip detector $ch"
                                missing_pars=true
                                break
                            end
                            ljl_propfunc(dsp_config_pd_det[selection])(chinfo_det)||continue
                            if !all(haskey.(Ref(pars_fltoptimization[det]), Symbol.(dsp_config_pd_det[required])))
                                @warn "Not all required $label optimization parameters for detector $det, skip detector $ch"
                                missing_pars=true
                                break
                            end
                        end
                        if missing_pars
                            push!(failed_detectors, det)
                            continue
                        end

                        @debug "Processing detector $det ($ch)"
                        @timeit dsp_timer "DSP $det" begin
                            # process data
                            outdata_det = nothing
                            try
                                raw_data_det = read_ldata(l200, DataTier(:raw), fk, det)
                                outdata_det = dsp_icpc_compressed(raw_data_det, dsp_config_det, pars_tau[det].τ, pars_fltoptimization[det];
                                                                  f_evaluate_qc = f_evaluate_qc)
                            catch e
                                if e isa TaskFailedException
                                    e = e.task.exception
                                end
                                @error "Error processing detector $det ($ch) in $(fk): $(truncate_error(e))"
                                push!(failed_detectors, det)
                                continue
                            end
                            # save data to hdf5
                            "$det" in processed_detectors && delete_entry!(outdata, "jldsp/$det")
                            outdata[:jldsp, det] = outdata_det
                            # count number of detectors processed and Successful
                            n_detectors += 1
                            # flush streams
                            flush(stdout)
                            flush(stderr)
                        end
                    end
                end
            end
            @info "Finished processing file: $(basename(rawfilename))"
            # return number of processed detectors and failed detectors
        end
        if n_detectors == 0
            @warn "No detectors processed in $(basename(rawfilename))"
        end

        # create total timer by summing over memory usage and time
        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))

        # create log
        log_fk = log_nt((fk, ProcessStatus(ifelse(isempty(failed_detectors), 1, 0)), "$(n_detectors)/$(length(chinfo))",
                         string.(failed_detectors), total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_dsp = parallel(filekey_dsp, filekeys, log_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_dsp_cal")

    @info "Finished DSP for period $period and run $run"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_dsp_cal, result_dsp)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, dsp_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_dsp))
    lreport!(report, "# Total Timing")
    lreport!(report, "```")
    lreport!(report, "$(get_totalTimer(result_dsp))")
    lreport!(report, "```")

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :dsp_cal), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_dsp_cal; output_tiers = [:jldsp])
