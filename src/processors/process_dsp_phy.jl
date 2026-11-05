"""
    process_dsp_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0,
        max_wvfs::Int=10000)

Run the DSP on the `phy` raw data of a run for the additional detectors, PMTs, SiPMs (`spms`) and HPGe detectors (`geds`).

For every raw `phy` file of the run, the channel groups are processed in this order: the
detectors listed under `additional_detectors` in the DSP configuration, the PMTs, the SiPMs
(with their per-detector thresholds), and the HPGe detectors (with their pole-zero decay time
and energy and A/E filter optimization parameters). Each detector is processed in
[`@process_step`](@ref)s: `DSP parameters of <detector> in <filekey>` for all but the
PMTs, then `raw data loading of <detector> in <filekey>` and `DSP of <detector> in
<filekey>`. A detector fails, and the others go on, if its parameters are missing, or if its
raw data or its DSP throws an error. An HPGe detector also fails if its DSP configuration has
no `required_fltopt_selection` or `required_aoeopt_selection`, or if a parameter listed in
`required_fltopt` (or `required_aoeopt`) is missing for a detector whose channel info row
satisfies `required_fltopt_selection` (or `required_aoeopt_selection`). The selections are
strings of `LegendDataManagement.ljl_propfunc` expressions, e.g.
`"usability == :on && (low_aoe_status == :valid || low_aoe_status == :present)"`. A PMT
without raw data in a file is skipped and counts as processed. [`run_step`](@ref) with
`detectors` and `debug = true` captures each failed step of these detectors with the
variables of the processor, e.g. the raw data of a failed DSP.

# Inputs
- `raw` tier of the `phy` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `dataprod_config(l200).dsp(filekey)`, `dataprod_config(l200).sipm(filekey)` and `dataprod_config(l200).pmt(filekey)`
- the decay time, the optimization parameters and the SiPM thresholds of each detector from
  `get_dsp_pars(l200, filekey, detector, pars_cat)` with `pars_cat` `:pz`, `:fltopt`, `:aoeopt` and `:sipmopt`, read from the
  `pars_type` that the DSP config sets for the detector, e.g. `ppars` or `rpars`. A detector whose parameters cannot be loaded
  fails.
- the QC evaluator from `load_qc_evaluator(l200, filekey)`

# Outputs
- `jldsp` tier file for each filekey, with one table per detector
- run report `:dsp_phy`, with one row per filekey (number of processed detectors, failed detectors, time, allocations) and the
  time of each detector summed over the filekeys (see [`JuLeAna.timing_table`](@ref))

# Keywords
- `reprocess`: remove the existing `jldsp` files and process all detectors again; otherwise detectors already present in a file are skipped
- `timeout`: seconds allowed per filekey in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)
- `max_wvfs`: not used by this processor

# Returns
Return `nothing`.
"""
function process_dsp_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         max_wvfs::Int = 10000, use_cache::Bool = true)
    @info "Process DSP for period $period and run $run"

    filekeys = run_filekeys(l200, period, run, :phy)

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found start filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds) |> detector_filter(processing_config, :process_dsp_phy)
    chinfo_sipm = channelinfo(l200, filekey; system = :spms) |> detector_filter(processing_config, :process_dsp_phy)
    chinfo_pmts = channelinfo(l200, filekey; system = :pmts) |> detector_filter(processing_config, :process_dsp_phy)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"
    dsp_meta_sipm = dataprod_config(l200).sipm(filekey)
    @debug "Loaded SiPM DSP config: $(lstring(dsp_meta_sipm))"
    dsp_meta_pmt = dataprod_config(l200).pmt(filekey)
    @debug "Loaded PMT DSP config: $(lstring(dsp_meta_pmt))"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

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
                if reprocess && isfile(outfilename)
                    @info "Reprocess $(basename(outfilename)), remove old DSP."
                    rm(outfilename, force = true)
                end
            end

            # open output file
            lh5open(outfilename, "cw") do outdata
                # get processed detectors
                processed_detectors = stored_detectors(outdata, "jldsp")

                @info "Start DSP"
                @timeit dsp_timer "DSP" begin
                    if haskey(dsp_config_pd, :additional_detectors)
                        # process additional detectors
                        for det in DetectorId.(keys(dsp_config_pd.additional_detectors))
                            ch = channelinfo(l200, filekey, det).channel

                            # check if detector can be processed
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
                                    dsp_config_det = @process_step "DSP parameters of $det in $fk" begin
                                        DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
                                    end
                                    @debug "Loaded DSP config: $(lstring(dsp_config_det))"
                                    raw_data_det = @process_step "raw data loading of $det in $fk" read_ldata(l200, DataTier(:raw), fk, det)
                                    @process_step "DSP of $det in $fk" begin
                                        legend_dsp_function(dsp_config_pd.additional_detectors[Symbol(det)],
                                                            "dsp.additional_detectors.$det")(raw_data_det, dsp_config_det)
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
                            end
                        end
                    end

                    # loop over detectors
                    @debug_progress "Filekey PMTS: $fk" for chinfo_det in chinfo_pmts
                        ch = chinfo_det.channel
                        det = chinfo_det.detector

                        # check if detector can be processed
                        detector_selected(det) || continue
                        if "$det" in processed_detectors && !reprocess && !redo_detector(det)
                            @info "Detector $det ($ch) already processed, skip"
                            n_detectors += 1
                            continue
                        end

                        @debug "Processing detector $det ($ch)"
                        @timeit dsp_timer "$det" begin
                            # get metadata
                            dsp_meta_det = merge(dsp_meta_pmt.default, get(dsp_meta_pmt, det, PropDict()))
                            # process data; a failed step fails the detector only
                            outdata_det = try
                                raw_data_det = @process_step "raw data loading of $det in $fk" begin
                                    read_ldata(l200, DataTier(:raw), fk, det; ignore_missing = true)
                                end
                                if isnothing(raw_data_det)
                                    @warn "No raw data found for PMT detector $det ($ch) in $fk, skip"
                                    n_detectors += 1
                                    continue
                                end
                                @process_step "DSP of $det in $fk" dsp_pmts(raw_data_det, dsp_meta_det)
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

                    # loop over detectors
                    @debug_progress "Filekey SiPM: $fk" for chinfo_det in chinfo_sipm
                        ch = chinfo_det.channel
                        det = chinfo_det.detector

                        # check if detector can be processed
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
                                dsp_meta_det, pars_sipm_det = @process_step "DSP parameters of $det in $fk" begin
                                    thresholds = get_dsp_pars(l200, filekey, det, :sipmopt)
                                    isempty(thresholds) && throw(ArgumentError("no thresholds for $det"))
                                    (merge(dsp_meta_sipm.default, get(dsp_meta_sipm, det, PropDict())), thresholds)
                                end
                                raw_data_det = @process_step "raw data loading of $det in $fk" read_ldata(l200, DataTier(:raw), fk, det)
                                @process_step "DSP of $det in $fk" dsp_sipm_compressed(raw_data_det, dsp_meta_det, pars_sipm_det)
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

                    # loop over detectors
                    @debug_progress "Filekey HPGe: $fk" for chinfo_det in chinfo
                        ch = chinfo_det.channel
                        det = chinfo_det.detector

                        # check if detector can be processed
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
                                dsp_config_det, pars_tau_det, pars_opt_det = @process_step "DSP parameters of $det in $fk" begin
                                    dsp_config_pd_det = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
                                    tau = get_dsp_pars(l200, filekey, det, :pz)
                                    opt = merge(get_dsp_pars(l200, filekey, det, :fltopt), get_dsp_pars(l200, filekey, det, :aoeopt))
                                    isempty(tau) && throw(ArgumentError("no decay time for $det"))
                                    isempty(opt) && throw(ArgumentError("no optimization parameters for $det"))
                                    # the required optimization pars of the filters the selections of the detector require
                                    for (selection, required, label) in ((:required_fltopt_selection, :required_fltopt, "energy filter"),
                                                                         (:required_aoeopt_selection, :required_aoeopt, "A/E"))
                                        haskey(dsp_config_pd_det, selection) ||
                                            throw(ArgumentError("no `$selection` in the DSP config of $det"))
                                        ljl_propfunc(dsp_config_pd_det[selection])(chinfo_det) || continue
                                        missing_pars = setdiff(Symbol.(dsp_config_pd_det[required]), keys(opt))
                                        isempty(missing_pars) ||
                                            throw(ArgumentError("no $label optimization parameters $(join(missing_pars, ", ")) for $det"))
                                    end
                                    (DSPConfig(dsp_config_pd_det), tau, opt)
                                end
                                @debug "Loaded DSP config: $(lstring(dsp_config_det))"
                                raw_data_det = @process_step "raw data loading of $det in $fk" read_ldata(l200, DataTier(:raw), fk, det)
                                @process_step "DSP of $det in $fk" begin
                                    dsp_icpc_compressed(raw_data_det, dsp_config_det, pars_tau_det.τ, pars_opt_det;
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
        end
        if n_detectors == 0
            @warn "No detectors processed in $(basename(rawfilename))"
        end

        # create total timer by summing over memory usage and time
        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))

        # create log
        log_fk = log_nt((fk, ProcessStatus(ifelse(isempty(failed_detectors), 1, 0)),
                         "$(n_detectors)/$(length(chinfo)+length(get(dsp_config_pd, :additional_detectors, []))+length(chinfo_sipm)+length(chinfo_pmts))",
                         string.(failed_detectors), total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_dsp = parallel(filekey_dsp, filekeys, log_nt; timeout = timeout, retry = false, process_name = "$period-$run-process_dsp_phy")

    @info "Finished DSP for period $period and run $run"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_dsp_phy, result_dsp)]))
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
    write_report(get_rreportfilename(l200, filekey, :dsp_phy), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_dsp_phy; output_tiers = [:jldsp],
                    items = (_, l200, period, run) -> run_filekeys(l200, period, run, :phy))
