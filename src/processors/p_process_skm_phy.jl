"""
    p_process_skm_phy(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, timeout::Real=0, only_first_period::Bool=true)

Create the skimmed event tier (`jlskm`) of the `phy` analysis runs of `period`, one file per run.

For each run, all `jlevt` files of the run (except filekeys listed as bad) are read and only events that are neither pulser nor forced triggers are kept, and that have `ged_pmt.is_valid_muon`, `geds.is_valid_qc`, `geds.is_valid_trig`, `geds.is_valid_hit`, `geds.multiplicity == 1` and `geds.max_e_cusp_ctc_cal > 500.0u"keV"`. The report lists the fraction of the selected events that pass the PSD cut, the LAr cut, and both. The total exposure of the period is logged.

# Inputs
- `jlevt` tier of the `phy` filekeys listed in the runinfo for each analysis run in `period` (run info `phy.is_analysis_run`).
- Channel info of the `geds` system for the `phy` analysis runs of `period`, merged over the runs by `channelinfo(l200, period, :phy)`, and the bad-filekey list from `bad_filekeys(l200)`.

# Outputs
- `jlskm` tier: one file per run (named by the start filekey of the run), table `jlskm`.
- Partition report `:skm_phy` (Main Log, Metadata, Results table with one row per run).

# Keywords
- `reprocess`: recreate the `jlskm` file of each run, removing existing ones. If `false`, existing files are kept and only the survival fractions are read for the report.
- `timeout`: seconds allowed per run in `parallel` (0 = no limit).
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `true`)
- `only_first_period`: accepted for a uniform call signature; it has no effect in this processor.

# Returns
Always `false`: no run is skipped, so `run_processing` does not wait for this step in the previous period.
"""
function p_process_skm_phy(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false, timeout::Real = 0,
                           only_first_period::Bool = true, use_cache::Bool = true)
    @info "Event skimmed tier for runs containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, period, :phy; system = :geds) |> detector_filter(processing_config, :p_process_skm_phy)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    exposure = get_exposure(l200, chinfo.detector, period; is_analysis_run = true,
                            check_pf = @pf $processable && $usability == :on && $psd_usability == :on && $det_type != :coax)
    @info "Total exposure: $(round(unit(exposure), exposure, digits=2))"

    if reprocess
        @info "Reprocess all runs"
    else
        @info "Only process runs not found"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("SF of Events after PSD"), Symbol("SF of Events after LAr"),
                         Symbol("SF of Events after LAr & PSD"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool

    # flush stdout
    flush(stdout)

    function skm_fk(fk::FileKey)
        r = fk.run
        p = fk.period

        filekeys = filter(!in(bad_filekeys(l200; load_key = :all)), only(runinfo(l200, (p, r, :phy)).keys))
        @info "Found $(length(filekeys)) filekeys for run $r in period $p"

        @info "Processing run $r in period $p"
        dsp_timer = TimerOutput()
        skmfilename = l200.tier[:jlskm, fk]
        @info "Using output file: $(basename(skmfilename))"

        # start processing
        n_psd, n_lar, n_larpsd = 0.0u"percent", 0.0u"percent", 0.0u"percent"
        skipped = false
        write_files(skmfilename; use_cache, mode = CreateOrModify()) do outfilename
            if reprocess && isfile(outfilename)
                @info "Reprocess $(basename(skmfilename)), remove old Evt."
                rm(outfilename, force = true)
                rm(skmfilename, force = true)
            elseif isfile(outfilename)
                @info "File $(basename(skmfilename)) already exists, skip"
                skm_data = read_ldata((@pf (; is_valid_psd = $geds.is_valid_psd, is_valid_lar = $ged_spm.is_valid_lar)), l200,
                                      DataTier(:jlskm), fk)
                n_psd = mean(skm_data.is_valid_psd) * 100u"percent"
                n_lar = mean(skm_data.is_valid_lar) * 100u"percent"
                n_larpsd = mean(skm_data.is_valid_psd .&& skm_data.is_valid_lar) * 100u"percent"
                skipped = true
                return
            end

            # open output file
            @timeit dsp_timer "Evt" begin
                # generate evt level table
                skm_sel_pf = @pf !$aux.pulser.aux_trig &&
                                 !$aux.forcedtrigger.aux_trig &&
                                 $ged_pmt.is_valid_muon &&
                                 $geds.is_valid_qc &&
                                 $geds.is_valid_trig &&
                                 $geds.is_valid_hit &&
                                 $geds.multiplicity == 1 &&
                                 $geds.max_e_cusp_ctc_cal > 500.0u"keV"
                out_t = @process_step "event table loading of $fk" begin
                    read_ldata(l200, DataTier(:jlevt), filekeys; filterby = skm_sel_pf)
                end
                # get number of forced, physical and pulser triggers
                n_psd = mean(out_t.geds.is_valid_psd) * 100u"percent"
                @debug "SF after PSD: $(round(u"percent", n_psd, digits=2))"
                n_lar = mean(out_t.ged_spm.is_valid_lar) * 100u"percent"
                @debug "SF after LAr: $(round(u"percent", n_lar, digits=2))"
                n_larpsd = mean(out_t.geds.is_valid_psd .&& out_t.ged_spm.is_valid_lar) * 100u"percent"
                @debug "SF after LAr & PSD: $(round(u"percent", n_larpsd, digits=2))"
                lh5open(outfilename, "cw") do ds
                    ds[:jlskm] = LegendEventAnalysis._fix_vov(out_t)
                end
            end

            @info "Finished processing $(basename(skmfilename))"
        end

        # create total timer by summing over memory usage and time
        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))

        # create log
        log_fk = log_nt((fk, ProcessStatus(1), n_psd, n_lar, n_larpsd, total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = !skipped)
    end

    # get start time
    start_time = now()

    result_skm = parallel(skm_fk, rinfo.phy.startkey, log_nt; timeout = timeout, retry = false, process_name = "$period-p_process_skm_phy")

    @info "Finished skimmed file processing"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :p_process_skm_phy, result_skm)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, skm_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_skm))

    @info "Write log report"
    write_report(get_preportfilename(l200, filekey, :skm_phy), report)
    @info report

    # flush stdout
    flush(stdout)

    return false
end

register_processor!(p_process_skm_phy; output_tiers = [:jlskm], detector_selection = false)
