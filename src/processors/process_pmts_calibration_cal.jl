"""
    process_pmts_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Calibrate the muon-veto PMTs (`pmts`) of one run from the LED calibration (MVC) data.

A run can have more than one MVC file, e.g. a second LED run right after a change of the PMT
high voltages. Each file is calibrated on its own: the earliest file gives the parameters
`rNNN`, every later file `rNNN_after_voltage_change[_k]`, each with a validity entry at the
time of its file, so the latest calibration is the one used for the following data. A run
without MVC files is skipped; then no validity entry is written and the calibration of the
last LED run stays valid.

For each PMT selected by `detectors` in the processing config and each energy type of the
calibration configuration, the raw waveforms of the file are processed with `dsp_pmts`, the
`qc` cut is applied, and the single-photoelectron (1 p.e.) peak is fitted with
`LegendSpecFits.fit_pmt_spe`. The fit is `ok` if it passes the `quality` cuts; otherwise, or if
the PMT fails, its calibration is `NaN` and the PMT drops out of the muon cut of this run.

# Inputs
- `raw` tier, category `mvc`, of the run, per PMT.
- `dataprod_config(l200).pmt(filekey)`: `default` merged with the per-detector section (DSP
  settings, as in `process_dsp_phy`), and `calibration`: the `default` section merged with the
  per-detector section. It sets `energy_types`, each with `qc`, `fit` (keyword arguments of
  `fit_pmt_spe`; lists become tuples) and `quality` (`max_chi2_dof`, `max_μ1_err`,
  `μ1_range` and `min_n_1`).
- `l200.par.rpars.pmtcal[period]`: existing results of the run (unless `reprocess` is set).

# Outputs
- `l200.par.rpars.pmtcal[period]`, one parameter file per MVC file (see above): per PMT and
  energy type, `fit` (`μ1`, `σ1`, `τ`, `n_exp`, `n_1`, `r2` with uncertainties, `x_min`,
  `pvalue`, `chi2`, `dof`, `status`) and `cal.func` (`"1/μ1 * <energy type> * 1e"`, `NaN` unless
  the status is `ok`), with a validity entry at the time of the file.
- Plots per MVC file: `pmt_spe_fit_<energy type>` per PMT, and for all PMTs
  `pmt_spe_grid_<energy type>` (when all of them were fitted in this call) and
  `pmt_spe_mu1_<energy type>` (1 p.e. positions by location; for a later file also those of
  the file before).
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
    if isempty(data_filekeys)
        @info "No MVC (LED calibration) raw files for $period-$run, skip: the calibration of the last LED run stays valid"
        return flush(stdout)
    end
    @info "Found $(length(data_filekeys)) MVC file(s): $(join(string.(data_filekeys), ", "))"

    chinfo = channelinfo(l200, filekey; system = :pmts) |> detector_filter(processing_config, :process_pmts_calibration_cal)
    @info "Loaded channel info with $(length(chinfo)) PMTs"

    pmt_config = dataprod_config(l200).pmt(filekey)
    haskey(pmt_config, :calibration) || throw(ArgumentError("The PMT config of $filekey has no `calibration` section"))
    calibration_config = pmt_config.calibration
    @debug "Loaded calibration config: $(lstring(calibration_config))"

    pmtcal_period_dir = make_par_dir(joinpath(data_path(l200.par.rpars.pmtcal), string(period)))

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Energy Type"), Symbol("µ1"), Symbol("χ²/dof"), Symbol("Fit Status"),
                         :Error)}

    # get start time
    start_time = now()

    results_all = []
    for (i, dfk) in enumerate(data_filekeys)
        outkey = pmtcal_outkey(run, i)
        @info "MVC file $i/$(length(data_filekeys)): $dfk -> pars $outkey"

        parsfile = joinpath(pmtcal_period_dir, "$(outkey).yaml")
        pars_db = (!reprocess && isfile(parsfile)) ? PropDict(readlprops(parsfile)) : PropDict()
        if reprocess
            @info "Reprocess all detectors"
        end

        function det_pmt_calibration(chinfo_det::NamedTuple)
            det = chinfo_det.detector
            @debug "Processing detector $det"

            calibration_config_det = merge(calibration_config.default, get(calibration_config, det, PropDict()))
            energy_types = Symbol.(collect(keys(calibration_config_det.energy_types)))

            result_dict = Dict{Symbol,NamedTuple}()
            log_info_dict = Dict{Symbol,NamedTuple}()
            processed_dict = Dict{Symbol,Bool}()
            report_dict = Dict{Symbol,Any}()

            if !reprocess && !redo_detector(det) && haskey(pars_db, det)
                @debug "Detector $det already processed, check missing energy types"
                for e_type in energy_types
                    # only results with a fit status; older ones are calibrated again
                    fit_pars = haskey(pars_db[det], e_type) ? get(pars_db[det][e_type], :fit, PropDict()) : PropDict()
                    haskey(fit_pars, :status) || continue
                    log_info_dict[e_type] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), e_type, fit_pars.μ1,
                                                    fit_pars.chi2 / fit_pars.dof, fit_pars.status, "Already processed --> skipped."))
                    processed_dict[e_type] = false
                end
            end
            all(e_type -> haskey(processed_dict, e_type), energy_types) &&
                return (result = result_dict, log = log_info_dict, processed = processed_dict, reports = report_dict)

            # failure of the PMT as a whole: NaN calibration for all energy types
            data_dsp = try
                @process_step "data loader" begin
                    @debug "Load raw data and run the DSP"
                    dsp_pmts(read_ldata(identity, l200, DataTier(:raw), dfk, det),
                             merge(pmt_config.default, get(pmt_config, det, PropDict())))
                end
            catch e
                e isa ProcessStepError || @error "Error in loading detector $det: $(truncate_error(e))"
                for e_type in energy_types
                    haskey(processed_dict, e_type) && continue
                    result_dict[e_type] = pmtcal_failed_result(e_type, "fit_failed")
                    log_info_dict[e_type] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), e_type, "-", "-",
                                                    "fit_failed", truncate_error(e)))
                    processed_dict[e_type] = true
                end
                return (result = result_dict, log = log_info_dict, processed = processed_dict, reports = report_dict)
            end

            for e_type in energy_types
                haskey(processed_dict, e_type) && continue
                e_type_config = calibration_config_det.energy_types[e_type]
                try
                    e_uncal = @process_step "$e_type data extraction" begin
                        data_after_qc = data_dsp[findall(ljl_propfunc(e_type_config.qc).(data_dsp))]
                        filter(isfinite, collect(getproperty(data_after_qc, e_type)))
                    end

                    result_fit, report_fit = @process_step "$e_type 1 p.e. fit" begin
                        @debug "Fit the 1 p.e. peak of $e_type"
                        fit_pmt_spe(e_uncal; pmtcal_fit_kwargs(e_type_config.fit)...)
                    end

                    status = pmtcal_fit_status(result_fit, e_type_config.quality)
                    status == :ok || @warn "$det $e_type: fit status $status, calibration NaN"

                    result_dict[e_type] = pmtcal_result(result_fit, status, e_type)
                    log_info_dict[e_type] = log_nt((det, detector_status(chinfo_det.usability),
                                                    status == :ok ? process_succeeded : process_warning, e_type, result_fit.μ1,
                                                    result_fit.gof.chi2 / result_fit.gof.dof, string(status), "-"))
                    processed_dict[e_type] = true
                    report_dict[e_type] = report_fit
                catch e
                    e isa ProcessStepError || @error "Error in processing detector $det: $(truncate_error(e))"
                    result_dict[e_type] = pmtcal_failed_result(e_type, "fit_failed")
                    log_info_dict[e_type] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), e_type, "-", "-",
                                                    "fit_failed", truncate_error(e)))
                    processed_dict[e_type] = true
                end

                # a failed plot must not discard the fit
                haskey(report_dict, e_type) || continue
                try
                    @process_step "$e_type 1 p.e. fit plot" begin
                        p = LegendMakie.lplot(report_dict[e_type];
                                              title = get_plottitle(dfk, det, "1 p.e. Fit"; additional_type = string(e_type)))
                        save_plot(p, l200, filekey, det, Symbol("pmt_spe_fit_$(e_type)$(pmtcal_suffix(outkey, run))"))
                    end
                catch e
                    e isa ProcessStepError || @error "Error in plotting detector $det: $(truncate_error(e))"
                end
            end

            return (result = result_dict, log = log_info_dict, processed = processed_dict, reports = report_dict)
        end

        # execute in parallel
        result_pmt_calibration = parallel(det_pmt_calibration, chinfo, log_nt; timeout = timeout, retry = false,
                                          process_name = "$period-$run-$outkey-process_pmts_calibration_cal")
        push!(results_all, result_pmt_calibration)

        pars_db = pmtcal_fill_missing(create_pars(pars_db, result_pmt_calibration), chinfo, calibration_config)
        write_pars(l200.par.rpars.pmtcal[period], Symbol(outkey), pars_db)
        write_validity(l200.par.rpars.pmtcal, dfk, ["$(period)/$(outkey).yaml"])
        @info "Saved pars $outkey to disk"

        # plots of all PMTs of this file
        energy_types = unique(Symbol(e_type) for det in keys(pars_db) for e_type in keys(pars_db[det]))
        before = i > 1 ? pmtcal_read_pars(joinpath(pmtcal_period_dir, "$(pmtcal_outkey(run, i - 1)).yaml")) : nothing
        suffix = pmtcal_suffix(outkey, run)
        title = "$period-$run$suffix ($(dfk.time))"
        for e_type in energy_types
            # the grid needs the fit reports, which only the PMTs run in this call have; PMTs
            # whose fit failed get an empty panel
            reports = Dict(itr.detector => res.reports[e_type]
                           for (itr, res) in result_pmt_calibration
                           if haskey(res, :reports) && haskey(res.reports, e_type))
            skipped = any(res -> haskey(res, :processed) && res.processed isa AbstractDict && !get(res.processed, e_type, true),
                          last.(result_pmt_calibration))
            if length(result_pmt_calibration) == length(chinfo) && !skipped
                @process_step "$e_type 1 p.e. fit grid plot" begin
                    save_plot(pmt_spe_grid(title, chinfo, reports, pars_db, e_type), l200, filekey, :pmts,
                              Symbol("pmt_spe_grid_$(e_type)$suffix"))
                end
            else
                @info "Not all PMTs run in this call, no $e_type grid plot"
            end
            @process_step "$e_type 1 p.e. position plot" begin
                save_plot(pmt_spe_mu1_overview(title, chinfo, pars_db, e_type; before = before), l200, filekey, :pmts,
                          Symbol("pmt_spe_mu1_$(e_type)$suffix"))
            end
        end
    end
    @info "Finished PMT calibration"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_pmts_calibration_cal, results_all...)]))
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

# suffix of the plot names of a parameter file: "" for the first file of the run
pmtcal_suffix(outkey::AbstractString, run::DataRun) = chopprefix(outkey, string(run))

"""
    pmtcal_fit_kwargs(fit_config) -> NamedTuple

Keyword arguments of `fit_pmt_spe` from the `fit` section of the calibration config; lists
(e.g. `hist_range: [0, 100]`) become tuples.
"""
pmtcal_fit_kwargs(fit_config) = NamedTuple(k => (v isa AbstractVector ? Tuple(v) : v) for (k, v) in pairs(fit_config))

"""
    pmtcal_fit_status(result, quality) -> Symbol

`:ok` if the 1 p.e. fit `result` of `fit_pmt_spe` converged and passes the `quality` section
of the calibration config (`max_chi2_dof`, `max_μ1_err`, `μ1_range`, `min_n_1`), otherwise
`:bad_fit`.
"""
function pmtcal_fit_status(result, quality)
    μ1_lo, μ1_hi = quality.μ1_range
    passed = result.gof.converged && result.gof.chi2 / result.gof.dof <= quality.max_chi2_dof && muncert(result.μ1) <= quality.max_μ1_err &&
             μ1_lo < mvalue(result.μ1) < μ1_hi && mvalue(result.n_1) >= quality.min_n_1
    return passed ? :ok : :bad_fit
end

"""
    pmtcal_result(result, status::Symbol, e_type::Symbol) -> NamedTuple

Parameters of one PMT and energy type: the fit results and the calibration function, `NaN`
unless `status` is `:ok`.
"""
function pmtcal_result(result, status::Symbol, e_type::Symbol)
    μ1 = mvalue(result.μ1)
    fit = merge(NamedTuple(k => result[k] for k in (:μ1, :σ1, :τ, :n_exp, :n_1, :r2)),
                (x_min = result.x_min, pvalue = result.gof.pvalue, chi2 = result.gof.chi2, dof = result.gof.dof, status = string(status)))
    return (fit = fit, cal = (func = status == :ok ? "1/$μ1 * $e_type * 1e" : "NaN * $e_type * 1e",))
end

"""
    pmtcal_failed_result(e_type::Symbol, status::AbstractString) -> NamedTuple

Parameters of a PMT whose data or fit failed: `NaN` fit results and calibration function.
"""
function pmtcal_failed_result(e_type::Symbol, status::AbstractString)
    fit = merge(NamedTuple(k => NaN for k in (:μ1, :σ1, :τ, :n_exp, :n_1, :r2, :x_min, :pvalue, :chi2, :dof)), (status = status,))
    return (fit = fit, cal = (func = "NaN * $e_type * 1e",))
end

"""
    pmtcal_fill_missing(pars_db, chinfo, calibration_config) -> PropDict

`pars_db` with a `NaN` result (status `fit_failed`) for each selected PMT and energy type
that has none, e.g. after a timeout or a lost worker.
"""
function pmtcal_fill_missing(pars_db, chinfo, calibration_config)
    for chinfo_det in chinfo
        det = chinfo_det.detector
        detector_selected(det) || continue
        energy_types = Symbol.(collect(keys(merge(calibration_config.default, get(calibration_config, det, PropDict())).energy_types)))
        missing_types = filter(e_type -> !(haskey(pars_db, det) && haskey(pars_db[det], e_type)), energy_types)
        isempty(missing_types) && continue
        @warn "$det: no result for $(join(missing_types, ", ")), calibration NaN"
        pars_db = create_pars(pars_db,
                              [chinfo_det =>
                                   (result = Dict(e_type => pmtcal_failed_result(e_type, "fit_failed") for e_type in missing_types),
                                    processed = true)])
    end
    return pars_db
end

"""
    pmtcal_read_pars(parsfile::AbstractString) -> Union{Nothing,PropDict}

The parameters in `parsfile`, `nothing` if the file does not exist.
"""
pmtcal_read_pars(parsfile::AbstractString) = isfile(parsfile) ? PropDict(readlprops(parsfile)) : nothing
