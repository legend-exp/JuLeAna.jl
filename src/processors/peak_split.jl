# Peak splitting of the `category` data of a run, shared by `process_peak_split_cal` and
# `process_peak_split_phy`: the events of each peak window of the raw config, selected with
# the DAQ energy calibration of the run, go to the `jlpks` file of the detector.
function split_peaks(l200::LegendData, period::DataPeriod, run::DataRun, category::Symbol, process_name::Symbol; reprocess::Bool,
                     timeout::Real, use_cache::Bool)
    @info "Process $category peak splitting for period $period and run $run"

    filekey = start_filekey(l200, (period, run, category))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)
    @debug "Loaded raw config: $(lstring(raw_config))"

    @debug "Load DAQ energy calibration for $period-$run"
    pars_daqecal = PropDict(l200.par.rpars.daqecal[period, run])

    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, :Counts, Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get output directory
    mkpath(l200.tier[:jlpks, category, period, run])

    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), only(runinfo(l200, (period, run, category)).keys))
    isempty(filekeys) && error("No $category filekeys of period $period run $run in the runinfo")
    @info "Found $(length(filekeys)) $category filekeys"

    # flush stdout
    flush(stdout)

    function split_peak_det(chinfo_det::NamedTuple)
        ch = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        raw_config_det = merge(raw_config.default, get(raw_config, det, PropDict()))
        energy_windows = Dict(label => first(window)..last(window) for (label, window) in pairs(raw_config_det.peaks))
        output_filename = l200.tier[:jlpks, filekey, det]
        counts = Dict{Symbol,Int}()
        count_text() = join(("$label = $(counts[label])" for label in sort!(collect(keys(counts)))), ", ")

        if isfile(output_filename) && !reprocess && !redo_detector(det)
            @info "Output file \"$output_filename\" already exists, skipping"
            try
                for label in keys(energy_windows)
                    counts[label] = length(read_ldata(ljl_propfunc("$label.daqenergy"), l200, DataTier(:jlpks), filekey, det))
                end
            catch e
                @error "Error reading peaks from $(basename(output_filename)): $(truncate_error(e))"
                @warn "Filename $(basename(output_filename)) seems broken, remove it."
                rm(output_filename)
            end
            if isfile(output_filename)
                log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), count_text(), "0", "0",
                                  "Already processed --> skipped."))
                return (processed = false, log = log_det)
            end
        end

        haskey(pars_daqecal, det) || throw(ErrorException("No DAQ energy calibration for detector $det in $period-$run"))

        split_timer = TimerOutput()
        @info "Generating output file \"$output_filename\""
        @timeit split_timer "$det" begin
            f_calib = ljl_propfunc(pars_daqecal[det].func)
            @timeit split_timer "Filter Raw" begin
                minimum_energy = minimum(leftendpoint.(values(energy_windows)))
                maximum_energy = maximum(rightendpoint.(values(energy_windows)))
                @debug "Reading raw data for detector $det ($ch) from $(length(filekeys)) files"
                energy_filter = @pf minimum_energy <= f_calib((daqenergy = $daqenergy,)) <= maximum_energy
                slim_data = @process_step "data loader" begin
                    read_ldata(l200, DataTier(:raw), filekeys, det; filterby = energy_filter)
                end
                @process_step "peak file writer" begin
                    write_files(output_filename; use_cache, mode = CreateOrReplace()) do outfile
                        lh5open(outfile, "w") do output
                            for (label, window) in energy_windows
                                @debug "Filtering $label for detector $det ($ch)"
                                peak_data = slim_data |> filterby(@pf f_calib((daqenergy = $daqenergy,)) ∈ window)
                                output[:jlpks, det, label] = peak_data
                                counts[label] = length(peak_data)
                            end
                        end
                    end
                end
                @info "Writing $output_filename"
            end
        end
        GC.gc()

        # create total timer by summing over memory usage and time
        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(split_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(split_timer))

        log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), count_text(), "$total_time", total_allocated, ""))

        @info "Finished processing detector $det ($ch) in $total_time"

        return (result = counts, processed = true, log = log_det)
    end

    # get start time
    start_time = now()

    result_peaksplit = parallel(split_peak_det, chinfo, log_nt; timeout = timeout, retry = false,
                                process_name = "$period-$run-$process_name")

    @info "Finished peak splitting"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_peaksplit)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, peak_splitting_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_peaksplit))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, Symbol(report_name(process_name))), report)
    @info report

    # flush stdout
    return flush(stdout)
end
