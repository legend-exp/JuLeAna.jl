"""
    process_dsp_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0,
        max_wvfs::Int=10000)

Run the DSP on the `cal` raw data of the HPGe detectors (`geds`) of a run.

For every raw `cal` file of the run, each detector is processed with its DSP configuration, its
pole-zero decay time, and its energy and A/E filter optimization parameters, in three
[`@process_step`](@ref)s: `DSP parameters of <detector> in <filekey>`, `raw data loading of
<detector> in <filekey>` and `DSP of <detector> in <filekey>`. A detector fails, and the
others go on, if the decay time or the optimization parameters are missing, if its DSP
configuration has no `required_fltopt_selection` or `required_aoeopt_selection`, if a
parameter listed in `required_fltopt` (or `required_aoeopt`) is missing for a detector whose
channel info row satisfies `required_fltopt_selection` (or `required_aoeopt_selection`), or if
its raw data or its DSP throws an error. The selections are strings of
`LegendDataManagement.ljl_propfunc` expressions, e.g.
`"usability == :on && (low_aoe_status == :valid || low_aoe_status == :present)"`.
[`run_step`](@ref) with `detectors` and `debug = true` captures each failed step of these
detectors with the variables of the processor, e.g. the raw data of a failed DSP.

# Inputs
- `raw` tier of the `cal` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `dataprod_config(l200).dsp(filekey)`; the `pars_type` of the entry of a detector, else of `default`, `"ppars"` or `"rpars"`,
  selects its parameters below. A detector whose parameters cannot be loaded fails.
- `l200.par[pars_type, :pz]`, `l200.par[pars_type, :fltopt]` and `l200.par[pars_type, :aoeopt]`
- the QC evaluator from `load_qc_evaluator(l200, filekey)`

# Outputs
- `jldsp` tier file for each filekey, with one table per detector
- run report `:dsp_cal`, with one row per filekey (number of processed detectors, failed detectors, time, allocations) and the
  time of each detector summed over the filekeys (see [`JuLeAna.timing_table`](@ref))

# Keywords
- `reprocess`: remove the existing `jldsp` files and process all detectors again; otherwise detectors already present in a file are skipped
- `timeout`: seconds allowed per filekey in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)
- `max_wvfs`: not used by this processor

# Returns
Return `nothing`.
"""
function process_dsp_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         max_wvfs::Int = 10000, use_cache::Bool = true)
    @info "Process DSP for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :cal)).keys))

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found start filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_dsp_cal)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # the parameter type of each detector: `pars_type` of its entry in the DSP config, else of `default`
    pars_types = Dict(det => Symbol(get(get(dsp_config_pd, det, PropDict()), :pars_type, get(dsp_config_pd.default, :pars_type, "")))
                      for det in chinfo.detector)
    issubset(values(pars_types), (:ppars, :rpars)) ||
        throw(ArgumentError("`pars_type` of the DSP config of $filekey must be \"ppars\" or \"rpars\", got $(join(repr.(unique(values(pars_types))), ", "))"))
    @info "Use $(join(unique(values(pars_types)), " and ")) for the DSP parameters"

    # the decay times and optimization parameters of each type in use; a type that cannot be loaded fails its detectors
    pars = Dict(t => try
                    (tau = get_values(l200.par[t, :pz](filekey)),
                     opt = get_values(merge(l200.par[t, :fltopt](filekey), l200.par[t, :aoeopt](filekey))))
                catch e
                    e isa InterruptException && rethrow()
                    e
                end
                for t in unique(values(pars_types)))
    @debug "Loaded decay times and optimization parameters"

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
                        ch = chinfo_det.channel
                        det = chinfo_det.detector

                        # check if channel can be processed
                        detector_selected(det) || continue
                        if "$det" in processed_detectors && !reprocess && !redo_detector(det)
                            @info "Detector $det ($ch) already processed, skip"
                            n_detectors += 1
                            continue
                        end

                        @debug "Processing detector $det ($ch)"
                        @timeit dsp_timer "$det" begin
                            # process data; a failed step fails the detector only
                            outdata_det = try
                                pars_det = pars[pars_types[det]]
                                dsp_config_det = @process_step "DSP parameters of $det in $fk" begin
                                    pars_det isa Exception &&
                                        throw(ArgumentError("cannot load the $(pars_types[det]) parameters: $(truncate_error(pars_det))"))
                                    dsp_config_pd_det = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
                                    haskey(pars_det.tau, det) || throw(ArgumentError("no decay time for $det"))
                                    haskey(pars_det.opt, det) || throw(ArgumentError("no optimization parameters for $det"))
                                    # the required optimization pars of the filters the selections of the detector require
                                    for (selection, required, label) in ((:required_fltopt_selection, :required_fltopt, "energy filter"),
                                                                         (:required_aoeopt_selection, :required_aoeopt, "A/E"))
                                        haskey(dsp_config_pd_det, selection) ||
                                            throw(ArgumentError("no `$selection` in the DSP config of $det"))
                                        ljl_propfunc(dsp_config_pd_det[selection])(chinfo_det) || continue
                                        missing_pars = setdiff(Symbol.(dsp_config_pd_det[required]), keys(pars_det.opt[det]))
                                        isempty(missing_pars) ||
                                            throw(ArgumentError("no $label optimization parameters $(join(missing_pars, ", ")) for $det"))
                                    end
                                    DSPConfig(dsp_config_pd_det)
                                end
                                @debug "Loaded DSP config: $(lstring(dsp_config_det))"
                                raw_data_det = @process_step "raw data loading of $det in $fk" read_ldata(l200, DataTier(:raw), fk, det)
                                @process_step "DSP of $det in $fk" begin
                                    dsp_icpc_compressed(raw_data_det, dsp_config_det, pars_det.tau[det].τ, pars_det.opt[det];
                                                        f_evaluate_qc)
                                end
                            catch e
                                e isa ProcessStepError || rethrow()
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
    lreport!(report, timing_table(result_dsp))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :dsp_cal), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_dsp_cal; output_tiers = [:jldsp])
