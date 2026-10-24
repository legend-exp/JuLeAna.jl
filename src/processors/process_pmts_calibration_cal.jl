"""
    process_pmts_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Calibrate the muon-veto PMTs (`pmts`) of one run from the LED calibration (MVC) data.

A run can have more than one MVC file, e.g. a second LED run right after a change of the PMT
high voltages. Each file is calibrated on its own: the earliest file gives the parameters
`rNNN`, every later file `rNNN_after_voltage_change[_k]`, each with a validity entry at the
time of its file, so the latest calibration is the one used for the following data.

For each PMT that is `on` and processable, the raw waveforms of the file are processed with
`dsp_pmts`, the `qc` cut is applied, and the single-photoelectron (1 p.e.) peak of
`pulse_height` is fitted with `LegendSpecFits.pmts_calibration`. A PMT whose fit is not `ok`
keeps the calibration valid before the run, i.e. of an earlier run (`fit.cal_source` names the
MVC file it was fitted on); without one its calibration is `NaN` and the PMT drops out of the
muon cut.

# Inputs
- `raw` tier, category `mvc`, of the run: per file either per-PMT groups `PMTxyz/raw` or the
  unsplit FlashCam table `FCEvent` with all 55 channels. In the latter, the rows of a PMT are
  those of FlashCam channel `daq.fc_channel + 1` of the p03 channelmap, the only channelmap
  that has `fc_channel` (FC 0 is the pulser, FC 54 is not used).
- `dataprod_config(l200).pmt(filekey)`: `default` (DSP settings) and, optionally,
  `calibration` with `default` and per-detector sections (`qc`, `kwargs` for
  `pmts_calibration`). Without it, `qc = "pulse_height > 0"` and the `pmts_calibration`
  defaults are used.
- `l200.par.rpars.pmtcal`: existing results of the run (unless `reprocess` is set) and the
  results valid before the first MVC file of the run for the fallback calibration.

# Outputs
- `l200.par.rpars.pmtcal[period]`, one parameter file per MVC file (see above): per PMT,
  `pulse_height.fit` (`μ`, `μ_err`, `σ`, `chi2ndf`, `n_spe`, `x_min`, `status`,
  `fit_failed`, `cal_source`: the MVC filekey the calibration was fitted on) and
  `pulse_height.cal.func` (`"1/μ * pulse_height * 1e"`),
  with a validity entry at the time of the file.
- Plots per MVC file: `pmt_spe_grid` (spectra and fits of all PMTs) and `pmt_spe_mu1`
  (1 p.e. positions by location; for a later file also those of the file before).
- Run report `pmts_calibration_cal`.

# Keywords
- `reprocess`: discard the existing results of the run and calibrate all PMTs again.
  Otherwise PMTs that already have results are skipped.
- `timeout`: seconds allowed per PMT in `parallel` (0 = no limit).

# Returns
`nothing`.
"""
function process_pmts_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                      timeout::Real = 0)
    @info "Process PMT calibration for period $period and run $run"

    # The LED runs are taken shortly before the run starts, so the run's `cal` filekey is used
    # for all metadata; the LED data is read per MVC filekey.
    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    data_filekeys = sort(collect(search_disk(FileKey, l200.tier[DataTier(:raw), DataCategory(:mvc), period, run])); by = fk -> fk.time)
    isempty(data_filekeys) && throw(ArgumentError("No MVC (LED calibration) raw files for $period-$run"))
    @info "Found $(length(data_filekeys)) MVC file(s): $(join(string.(data_filekeys), ", "))"

    # only PMTs that are on (dead PMTs are off in the statuses from the run they died in)
    chinfo = channelinfo(l200, filekey; system = :pmts, only_processable = true)
    chinfo = chinfo[findall(==(:on), chinfo.usability)]
    @info "Loaded channel info with $(length(chinfo)) PMTs that are on"

    pmt_config = dataprod_config(l200).pmt(filekey)
    dsp_config = pmt_config.default
    calibration_config = merge(PropDict(:default => PropDict(:qc => "pulse_height > 0", :kwargs => PropDict(:energy_var => "pulse_height"))),
                               get(pmt_config, :calibration, PropDict()))
    haskey(pmt_config, :calibration) || @info "No `calibration` section in the PMT config, use the default 1 p.e. fit settings"
    @debug "Loaded calibration config: $(lstring(calibration_config))"

    # energy type of the evt muon cut (pulse_height_cal)
    e_type = :pulse_height

    dets = [c.detector for c in chinfo]
    places = pmt_places(l200, dets)
    fc_channels = pmt_fcevent_channels(l200, dets)

    # fallback for bad fits: latest calibration of an earlier run (never the file before the
    # HV change of the same run, which was taken with other voltages)
    prev_cal = pmtcal_previous_cal(l200.par.rpars.pmtcal, first(data_filekeys), e_type)
    @info "Found fallback calibrations from earlier runs for $(length(prev_cal)) PMTs"

    pmtcal_period_dir = make_par_dir(joinpath(data_path(l200.par.rpars.pmtcal), string(period)))

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("µ1 (LSB)"), Symbol("χ²/ndf"), Symbol("Cal. Func."), Symbol("Fit Status"),
                         :Error)}

    # get start time
    start_time = now()

    results_all = []
    for (i, dfk) in enumerate(data_filekeys)
        outkey = pmtcal_outkey(run, i)
        @info "MVC file $i/$(length(data_filekeys)): $dfk -> pars $outkey"

        rawfile = string(l200.tier[DataTier(:raw), dfk])
        is_fcevent = has_fcevent(rawfile)
        is_fcevent && @info "Raw file has an unsplit FCEvent table, select the PMT rows by FlashCam channel"

        parsfile = joinpath(pmtcal_period_dir, "$(outkey).yaml")
        pars_db = (!reprocess && isfile(parsfile)) ? PropDict(readlprops(parsfile)) : PropDict()
        if reprocess
            @info "Reprocess all detectors"
        end

        function det_pmt_calibration(chinfo_det::NamedTuple)
            det = chinfo_det.detector
            @debug "Processing detector $det"

            nopanel = (det = Symbol(det), place = get(places, Symbol(det), "?"), edges = Float64[], counts = Float64[], popt = Float64[],
                       x_min = NaN, mu1 = NaN, mu1_err = NaN, sig1 = NaN, chi2ndf = NaN, status = :error, error = "")

            if !reprocess && !redo_detector(det) && haskey(pars_db, det)
                @debug "Detector $det already processed, skip"
                fit_pars = get(get(pars_db[det], e_type, PropDict()), :fit, PropDict())
                cal_pars = get(get(pars_db[det], e_type, PropDict()), :cal, PropDict())
                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), get(fit_pars, :μ, "-"),
                                   get(fit_pars, :chi2ndf, "-"), get(cal_pars, :func, "-"), get(fit_pars, :status, "-"),
                                   "Already processed --> skipped."))
                return (result = Dict{Symbol,NamedTuple}(), log = Dict(e_type => log_info), processed = Dict(e_type => false),
                        plotdata = nopanel)
            end

            try
                data_dsp = @process_step "data loader" begin
                    @debug "Load raw data and run the DSP"
                    data_raw = if is_fcevent
                        read_fcevent_rows(rawfile, fc_channels[Symbol(det)])
                    else
                        read_ldata(identity, l200, DataTier(:raw), dfk, det)
                    end
                    dsp_pmts(data_raw, dsp_config)
                end

                calibration_config_det = merge(calibration_config.default, get(calibration_config, det, PropDict()))
                e_uncal = @process_step "$e_type data extraction" begin
                    data_after_qc = data_dsp[findall(ljl_propfunc(calibration_config_det.qc).(data_dsp))]
                    filter(isfinite, collect(getproperty(data_after_qc, e_type)))
                end

                result_cal, report_cal = @process_step "$e_type 1 p.e. fit" begin
                    @debug "Fit the 1 p.e. peak"
                    LegendSpecFits.pmts_calibration(e_uncal; NamedTuple(calibration_config_det.kwargs)...)
                end
                GC.gc()

                # bad fit: calibration of the latest earlier run, NaN if there is none
                cal_func, cal_source = if result_cal.status == :ok
                    result_cal.cal_func, string(dfk)
                elseif haskey(prev_cal, Symbol(det))
                    prev_cal[Symbol(det)]
                else
                    result_cal.cal_func, "none"
                end
                result_cal.status == :ok || @warn "$det: $(result_cal.status), calibration from $cal_source ($cal_func)"

                μ1, μ1_err = mvalue(result_cal.μ), muncert(result_cal.μ)
                result = (cal = (func = cal_func,),
                          fit = (μ = μ1, μ_err = μ1_err, σ = result_cal.σ, chi2ndf = result_cal.chi2ndf, n_spe = result_cal.n_spe,
                                 x_min = result_cal.x_min, status = string(result_cal.status), fit_failed = result_cal.fit_failed,
                                 cal_source = cal_source))
                plotdata = merge(nopanel,
                                 (edges = report_cal.edges, counts = report_cal.counts, popt = report_cal.popt, x_min = report_cal.x_min,
                                  mu1 = μ1, mu1_err = μ1_err, sig1 = result_cal.σ, chi2ndf = result_cal.chi2ndf, status = result_cal.status,
                                  error = result_cal.error))
                log_info = log_nt((det, detector_status(chinfo_det.usability),
                                   result_cal.status == :ok ? process_succeeded : process_warning, μ1,
                                   result_cal.chi2ndf, cal_func, string(result_cal.status),
                                   isempty(result_cal.error) ? "-" : result_cal.error))
                return (result = Dict(e_type => result), log = Dict(e_type => log_info), processed = Dict(e_type => true),
                        plotdata = plotdata)
            catch e
                e isa ProcessStepError || @error "Error in processing detector $det: $(truncate_error(e))"
                log_info = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), "-", "-", "-", "-", truncate_error(e)))
                return (result = Dict{Symbol,NamedTuple}(), log = Dict(e_type => log_info), processed = Dict(e_type => false),
                        plotdata = nopanel)
            end
        end

        # execute in parallel
        result_pmt_calibration = parallel(det_pmt_calibration, chinfo, log_nt; timeout = timeout, retry = false,
                                          process_name = "$period-$run-$outkey-process_pmts_calibration_cal")
        push!(results_all, result_pmt_calibration)

        pars_db = create_pars(pars_db, result_pmt_calibration)
        write_pars(l200.par.rpars.pmtcal[period], Symbol(outkey), pars_db)
        write_validity(l200.par.rpars.pmtcal, dfk, ["$(period)/$(outkey).yaml"])
        @info "Saved pars $outkey to disk"

        # plots of this MVC file: only PMTs processed in this call (skipped ones have no histogram)
        panels = [r.plotdata for (_, r) in result_pmt_calibration if haskey(r, :plotdata) && !isempty(r.plotdata.counts)]
        if isempty(panels)
            @info "No PMT processed for $outkey, no plots"
            continue
        end
        suffix = outkey == string(run) ? "" : chopprefix(outkey, string(run))
        title = "$period-$run$suffix ($(dfk.time))"
        @process_step "1 p.e. fit grid plot" begin
            save_plot(pmt_spe_grid(title, panels), l200, filekey, :pmts, Symbol("pmt_spe_grid$suffix"))
        end
        # after a HV change: µ1 of the file before as open circles
        before = i > 1 ? pmtcal_mu1(joinpath(pmtcal_period_dir, "$(pmtcal_outkey(run, i - 1)).yaml"), e_type) : nothing
        @process_step "1 p.e. position plot" begin
            save_plot(pmt_spe_mu1_overview(title, panels; before = before), l200, filekey, :pmts, Symbol("pmt_spe_mu1$suffix"))
        end
    end
    @info "Finished PMT calibration"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(results_all...)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, pmts_calibration_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    for (dfk, result) in zip(data_filekeys, results_all)
        lreport!(report, "# Results $(dfk)")
        lreport!(report, create_logtbl(result))
    end

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :pmts_calibration_cal), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_pmts_calibration_cal)

"""
    pmtcal_outkey(run::DataRun, i::Integer) -> String

Name of the parameter file of the `i`-th MVC file of `run`: `"rNNN"`, then
`"rNNN_after_voltage_change"`, `"rNNN_after_voltage_change_2"`, ...
"""
function pmtcal_outkey(run::DataRun, i::Integer)
    return i == 1 ? string(run) : i == 2 ? "$(run)_after_voltage_change" : "$(run)_after_voltage_change_$(i - 1)"
end

"""
    pmt_p03_channelmap(l200::LegendData) -> PropDict

The p03 channelmap, the only one with the location and `daq.fc_channel` of the PMTs. The PMTs
and the wiring of the muon-veto FlashCam crate do not change (checked on the LED data of
2026-10-20: exactly the PMTs that are on in the statuses see light).
"""
function pmt_p03_channelmap(l200::LegendData)
    return l200.metadata.hardware.configuration.channelmaps(start_filekey(l200, (DataPeriod(3), DataRun(0), :cal)))
end

"""
    pmt_places(l200::LegendData, dets) -> Dict{Symbol,String}

Location (`"Floor"`, `"Pillbox"`, `"Wall"`) of each PMT in `dets`, `"?"` if unknown.
"""
function pmt_places(l200::LegendData, dets)
    cm = pmt_p03_channelmap(l200)
    return Dict(Symbol(d) => titlecase(string(get(get(cm, Symbol(d), PropDict()), :location, "?"))) for d in dets)
end

"""
    pmt_fcevent_channels(l200::LegendData, dets) -> Dict{Symbol,Int}

FlashCam channel of each PMT in `dets` in the `FCEvent` table: `daq.fc_channel + 1` of the
p03 channelmap (FC 0 is the pulser).
"""
function pmt_fcevent_channels(l200::LegendData, dets)
    cm = pmt_p03_channelmap(l200)
    return Dict(Symbol(d) => Int(cm[Symbol(d)].daq.fc_channel) + 1 for d in dets if haskey(cm, Symbol(d)))
end

# traces per event of the muon-veto FlashCam crate
const MVC_N_FC_CHANNELS = 55

"""
    has_fcevent(rawfile::AbstractString)::Bool

`true` if `rawfile` holds the unsplit FlashCam table `FCEvent` (all channels in one table).
"""
function has_fcevent(rawfile::AbstractString)
    lh = lh5open(rawfile, "r")
    try
        return haskey(lh, "FCEvent")
    finally
        close(lh)
    end
end

"""
    read_fcevent_rows(rawfile::AbstractString, fc::Integer) -> Table

The rows of FlashCam channel `fc` of the `FCEvent` table in `rawfile`, with the columns
`dsp_pmts` reads.
"""
function read_fcevent_rows(rawfile::AbstractString, fc::Integer)
    lh = lh5open(rawfile, "r")
    try
        tbl = lh["FCEvent"]
        chan = tbl.channel[:]
        rows = (fc + 1):MVC_N_FC_CHANNELS:length(chan)   # regular layout: channels 0..54 per event
        if isempty(rows) || !all(==(fc), view(chan, rows))
            rows = findall(==(fc), chan)
        end
        return Table(waveform = tbl.waveform[rows], timestamp = tbl.timestamp[rows], channel = tbl.channel[rows],
                     eventnumber = tbl.eventnumber[rows], daqenergy = tbl.daqenergy[rows])
    finally
        close(lh)
    end
end

"""
    pmtcal_previous_cal(props_db, filekey::FileKey, e_type::Symbol) -> Dict{Symbol,Tuple{String,String}}

The calibrations in `props_db` valid just before `filekey` that are not `NaN`:
`det => (cal func, source)`. The source is the `cal_source` of the parameters, the MVC
filekey the calibration was fitted on. Empty if no parameters are valid before `filekey`.
"""
function pmtcal_previous_cal(props_db, filekey::FileKey, e_type::Symbol)
    t = DateTime(string(filekey.time), dateformat"yyyymmdd\THHMMSS\Z") - Second(1)
    before = FileKey(replace(string(filekey), string(filekey.time) => Dates.format(t, dateformat"yyyymmdd\THHMMSS\Z")))
    pars = try
        PropDict(props_db(before))
    catch e
        @debug "No PMT calibration valid before $filekey: $(truncate_error(e))"
        PropDict()
    end
    prev = Dict{Symbol,Tuple{String,String}}()
    for (det, pars_det) in pars
        pars_det isa PropDict || continue
        pars_e = get(pars_det, e_type, PropDict())
        func = get(get(pars_e, :cal, PropDict()), :func, nothing)
        (func isa AbstractString && !occursin("NaN", func)) || continue
        prev[Symbol(det)] = (func, string(get(get(pars_e, :fit, PropDict()), :cal_source, "pmtcal valid before $filekey")))
    end
    return prev
end

"""
    pmtcal_mu1(parsfile::AbstractString, e_type::Symbol) -> Union{Nothing,Dict{Symbol,Float64}}

The fitted 1 p.e. positions `μ` of the PMTs in the parameter file `parsfile`, `nothing` if
the file does not exist.
"""
function pmtcal_mu1(parsfile::AbstractString, e_type::Symbol)
    isfile(parsfile) || return nothing
    pars = readlprops(parsfile)
    return Dict(Symbol(d) => Float64(get(get(get(pars[d], e_type, PropDict()), :fit, PropDict()), :μ, NaN)) for d in keys(pars))
end
