"""
    process_evt_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0, subsystems::Vector{Symbol}=[:geds, :spms, :pmts, :aux])

Build the event tier (`jlevt`) of the `phy` run from the `jldsp` files, combining the listed subsystems.

For each `phy` filekey of the run listed in the runinfo, the `jldsp` file must exist. The DSP data of the detectors of all `subsystems` are read, calibrated and combined into one event table by `calibrate_all`, including the cut flags. Per file the log counts forced triggers, pulser triggers and physical triggers (events with `geds.is_valid_qc` and more than one entry in `geds.trig_e_det`). If the PMT output is not empty and `:pmts` is in `subsystems`, a separate PMT file (`jlpmt` tier) is written.

# Inputs
- `jldsp` tier of the `phy` filekeys of the run listed in the runinfo.
- Channel info of every system in `subsystems` and the calibration parameters used by `calibrate_all`.

# Outputs
- `jlevt` tier: one file per `phy` filekey, table `jlevt`.
- `jlpmt` tier: one file per filekey with PMT data, table `jlpmt`.
- Run report `:evt_phy` (Main Log, Metadata, Results table with one row per filekey, Total Timing).

# Keywords
- `reprocess`: recreate the `jlevt` file (and the `jlpmt` file) of each filekey, removing existing ones. If `false`, existing `jlevt` files are kept and only their trigger counts are read for the report.
- `timeout`: seconds allowed per filekey in `parallel` (0 = no limit). Failed filekeys are retried (`retry=true`).
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)
- `subsystems`: systems included in the event table, default `[:geds, :spms, :pmts, :aux]`.

# Returns
`nothing`.
"""
function process_evt_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false, timeout::Real = 0,
                         subsystems::Vector{Symbol} = [:geds, :spms, :pmts, :aux], use_cache::Bool = true)
    @info "Process events for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, :phy)).keys))

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found start filekey $filekey"

    if reprocess
        @info "Reprocess all filekeys"
    else
        @info "Only reprocess filekeys that are not processed yet"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("Number of Physical Trigger"), Symbol("Number of Forced Trigger"),
                         Symbol("Number of Pulser Trigger"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function filekey_evt(fk::FileKey)
        dsp_timer = TimerOutput()
        dspfilename = l200.tier[:jldsp, fk]
        @info "Processing file: $(basename(dspfilename))"
        evtfilename = l200.tier[:jlevt, fk]
        pmtevtfilename = l200.tier[:jlpmt, fk]
        @info "Using output file: $(basename(evtfilename))"
        # number of forced, pulser and physical triggers
        n_forced, n_pulser, n_phy = 0, 0, 0
        skipped = false
        # start processing
        write_files(evtfilename; use_cache, mode = CreateOrModify()) do outfilename
            if reprocess && isfile(outfilename)
                @info "Reprocess $(basename(evtfilename)), remove old Evt."
                rm(outfilename, force = true)
                rm(evtfilename, force = true)
            elseif isfile(outfilename)
                @info "File $(basename(evtfilename)) already exists, skip"
                evt_counts = read_ldata((@pf (; is_forced = $aux.forcedtrigger.aux_trig, is_pulser = $aux.pulser_wvf.aux_trig,
                                              is_valid_qc = $geds.is_valid_qc, trig_e_det = $geds.trig_e_det)), l200, DataTier(:jlevt), fk)
                n_forced = count(evt_counts.is_forced)
                n_pulser = count(evt_counts.is_pulser)
                n_phy = count(evt_counts.is_valid_qc .&& length.(evt_counts.trig_e_det) .> 1)
                skipped = true
                return
            end

            # open output file
            @timeit dsp_timer "Evt" begin
                dsp_detectors = unique(reduce(vcat, [channelinfo(l200, fk; system).detector for system in subsystems]))
                dsp_data = read_ldata(l200, DataTier(:jldsp), fk, dsp_detectors; ignore_missing = true)
                # generate evt level table
                out_t, pmts_out_t = @process_step "event table calibration of $fk" begin
                    calibrate_all(l200, fk, dsp_data; subsystems)
                end
                # get number of forced, physical and pulser triggers
                n_forced = count(out_t.aux.forcedtrigger.aux_trig)
                @debug "Number of forced triggers: $n_forced"
                n_pulser = count(out_t.aux.pulser_wvf.aux_trig)
                @debug "Number of pulser triggers: $n_pulser"
                n_phy = count(out_t.geds.is_valid_qc .&& length.(out_t.geds.trig_e_det) .> 1)
                @debug "Number of physical triggers: $n_phy"
                lh5open(outfilename, "cw") do ds
                    ds[:jlevt] = out_t
                end
                # write pmt evt file
                if !isempty(pmts_out_t) && (:pmts in subsystems)
                    write_files(pmtevtfilename; use_cache, mode = CreateOrModify()) do pmtoutfilename
                        # Remove cached PMT file if reprocess is enabled
                        if reprocess && isfile(pmtoutfilename)
                            @info "Reprocess $(basename(pmtevtfilename)), remove old PMT."
                            rm(pmtoutfilename, force = true)
                            rm(pmtevtfilename, force = true)
                        end
                        lh5open(pmtoutfilename, "cw") do ds
                            ds[:jlpmt] = pmts_out_t
                        end
                    end
                end
            end

            @info "Finished processing $(basename(evtfilename))"
        end

        # create total timer by summing over memory usage and time
        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))

        # create log
        log_fk = log_nt((fk, ProcessStatus(1), n_phy, n_forced, n_pulser, total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = !skipped)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_evt = parallel(filekey_evt, filekeys, log_nt; timeout = timeout, retry = true, process_name = "$period-$run-process_evt_phy")

    @info "Finished Evt for period $period and run $run"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_evt_phy, result_evt)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, evt_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_evt))
    lreport!(report, "# Total Timing")
    lreport!(report, "```")
    lreport!(report, "$(get_totalTimer(result_evt))")
    lreport!(report, "```")

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :evt_phy), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_evt_phy; output_tiers = [:jlevt, :jlpmt], detector_selection = false)
