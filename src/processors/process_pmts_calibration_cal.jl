"""
    process_pmts_calibration_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Calibrate the muon-veto PMTs (`pmts`) of one run from the LED calibration (MVC) data.

A run has one MVC file; files listed in `datasets/ignored_daq_cycles` of the metadata are left out.
A run without MVC files is skipped; then no validity entry is written and the calibration of the
last LED run stays valid. A run with more than one MVC file fails: the files that are not used
have to be listed there or removed first.

For each PMT selected by `detectors` in the processing config and each energy type of the
calibration configuration, the raw waveforms of the file are processed with `dsp_pmts`, the
`qc` cut is applied, and the single-photoelectron (1 p.e.) peak is fitted with
`LegendSpecFits.fit_pmt_spe`. A fit that did not converge or fails one of the `quality` cuts
gets the status warning, with the failed cuts in the report, and is stored with a `NaN`
calibration, so the PMT drops out of the muon cut of this run. With the `report_status` of the
shipped config, a warning of a PMT that is `on` fails the step, so that the fit is looked at. A
PMT whose data or fit fails is not stored and is tried again in the next run of the step;
without parameters, LDM gives it a `NaN` calibration.

# Inputs
- `raw` tier, category `mvc`, of the run, per PMT.
- `dataprod_config(l200).pmt(filekey)`: `default` merged with the per-detector section (DSP
  settings, as in `process_dsp_phy`), and `calibration`: the `default` section merged with the
  per-detector section. It sets `energy_types`, each with `qc`, `fit` (keyword arguments of
  `fit_pmt_spe`) and `quality` (`max_chi2_dof`, `max_μ1_rel_err` (uncertainty of `μ1`
  relative to `μ1`), `μ1_range` and `min_n_1`).
- `l200.par.rpars.pmtcal[period, run]`: existing results of the run (unless `reprocess` is set).

# Outputs
- `l200.par.rpars.pmtcal[period, run]`: per PMT and energy type, `fit`, the result of
  `fit_pmt_spe` (`μ1`, `σ1`, `τ`, `n_exp`, `n_1`, `r2` with uncertainties, `x_min`, and `gof`
  with `converged`, `pvalue`, `chi2` and `dof`, without the covariance matrix and the
  residuals), and `cal.func` (`"1/μ1 * <energy type> * 1e"`, `NaN` for a fit with status
  warning), with a validity entry at the time of the MVC file.
- Plots: `pmt_spe_fit_<energy type>` per PMT (LegendMakie recipe of the fit report).
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
    # for all metadata; the LED data is read from the MVC filekey.
    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    # a run without LED data has no MVC directory
    mvc_path = l200.tier[DataTier(:raw), DataCategory(:mvc), period, run]
    data_filekeys = isdir(mvc_path) ? filter(!in(bad_filekeys(l200)), collect(search_disk(FileKey, mvc_path))) : FileKey[]
    if isempty(data_filekeys)
        @info "No MVC (LED calibration) raw files for $period-$run, skip: the calibration of the last LED run stays valid"
        return flush(stdout)
    end
    length(data_filekeys) == 1 ||
        throw(ArgumentError("$period-$run has $(length(data_filekeys)) MVC files ($(join(string.(data_filekeys), ", "))), " *
                            "but only one is used: list the others in datasets/ignored_daq_cycles of the metadata or remove them"))
    data_filekey = only(data_filekeys)
    @info "Found MVC file $data_filekey"

    chinfo = channelinfo(l200, filekey; system = :pmts) |> detector_filter(processing_config, :process_pmts_calibration_cal)
    @info "Loaded channel info with $(length(chinfo)) PMTs"

    pmt_config = dataprod_config(l200).pmt(filekey)
    haskey(pmt_config, :calibration) || throw(ArgumentError("The PMT config of $filekey has no `calibration` section"))
    calibration_config = pmt_config.calibration
    @debug "Loaded calibration config: $(lstring(calibration_config))"

    make_par_dir(joinpath(data_path(l200.par.rpars.pmtcal), string(period)))
    pars_db = PropDict(l200.par.rpars.pmtcal[period, run])
    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess
        @info "Reprocess all detectors"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Energy Type"), Symbol("µ1"), Symbol("χ²/dof"), :Error)}

    # quality cuts of the config that a fit fails
    function failed_quality_cuts(fit, quality)
        fit.gof.converged || return ["Fit did not converge."]
        messages = String[]
        chi2_dof = fit.gof.chi2 / fit.gof.dof
        chi2_dof <= quality.max_chi2_dof || push!(messages, "χ²/dof $(round(chi2_dof; digits = 2)) > $(quality.max_chi2_dof).")
        muncert(fit.μ1) <= quality.max_μ1_rel_err * mvalue(fit.μ1) ||
            push!(messages,
                  "µ1 uncertainty $(round(muncert(fit.μ1); digits = 2)) > $(round(Int, 100 * quality.max_μ1_rel_err)) % of µ1 " *
                  "($(round(quality.max_μ1_rel_err * mvalue(fit.μ1); digits = 2))).")
        first(quality.μ1_range) < mvalue(fit.μ1) < last(quality.μ1_range) ||
            push!(messages, "µ1 $(round(mvalue(fit.μ1); digits = 2)) outside $(first(quality.μ1_range))-$(last(quality.μ1_range)).")
        mvalue(fit.n_1) >= quality.min_n_1 || push!(messages, "n_1 $(round(Int, mvalue(fit.n_1))) < $(quality.min_n_1).")
        return messages
    end

    function det_pmt_calibration(chinfo_det::NamedTuple)
        det = chinfo_det.detector
        @debug "Processing detector $det"

        calibration_config_det = merge(calibration_config.default, get(calibration_config, det, PropDict()))
        energy_types = Symbol.(collect(keys(calibration_config_det.energy_types)))

        result_dict = Dict{Symbol,NamedTuple}()
        log_info_dict = Dict{Symbol,NamedTuple}()
        processed_dict = Dict{Symbol,Bool}()

        if !reprocess && !redo_detector(det) && haskey(pars_db, det)
            @debug "Detector $det already processed, check missing energy types"
            for e_type in energy_types
                haskey(pars_db[det], e_type) || continue
                fit = pars_db[det][e_type].fit
                # a stored fit that fails the quality cuts stays a warning
                messages = failed_quality_cuts(fit, calibration_config_det.energy_types[e_type].quality)
                log_info_dict[e_type] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(isempty(messages) ? 1 : -1),
                                                e_type, fit.μ1, haskey(fit.gof, :chi2) ? fit.gof.chi2 / fit.gof.dof : "-",
                                                join(["Already processed --> skipped."; messages], " ")))
                processed_dict[e_type] = false
            end
        end
        all(e_type -> haskey(processed_dict, e_type), energy_types) &&
            return (result = result_dict, log = log_info_dict, processed = processed_dict)

        # get data
        data_dsp = @process_step "data loader" begin
            @debug "Load raw data and run the DSP"
            dsp_pmts(read_ldata(identity, l200, DataTier(:raw), data_filekey, det),
                     merge(pmt_config.default, get(pmt_config, det, PropDict())))
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
                    fit_pmt_spe(e_uncal; NamedTuple(e_type_config.fit)...)
                end

                @process_step "$e_type 1 p.e. fit plot" begin
                    p = LegendMakie.lplot(report_fit; xlabel = "$e_type (ADC)",
                                          title = get_plottitle(data_filekey, det, "1 p.e. Fit"; additional_type = string(e_type)))
                    save_plot(p, l200, filekey, det, Symbol("pmt_spe_fit_$(e_type)"))
                end

                # the result of fit_pmt_spe without the arrays of the goodness of fit
                gof_keys = filter(!in((:covmat, :residuals, :residuals_norm, :bin_centers)), keys(result_fit.gof))
                fit = merge(result_fit, (gof = NamedTuple{gof_keys}(result_fit.gof),))
                messages = failed_quality_cuts(fit, e_type_config.quality)
                isempty(messages) || @warn "$det $e_type: $(join(messages, " ")) Calibration NaN."

                result_dict[e_type] = (fit = fit,
                                       cal = (func = isempty(messages) ? "1/$(mvalue(fit.μ1)) * $e_type * 1e" : "NaN * $e_type * 1e",))
                log_info_dict[e_type] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(isempty(messages) ? 1 : -1),
                                                e_type, fit.μ1, haskey(fit.gof, :chi2) ? fit.gof.chi2 / fit.gof.dof : "-",
                                                isempty(messages) ? "-" : join(messages, " ")))
                processed_dict[e_type] = true
            catch e
                e isa ProcessStepError || @error "Error in processing detector $det: $(truncate_error(e))"
                log_info_dict[e_type] = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), e_type, "-", "-",
                                                truncate_error(e)))
                processed_dict[e_type] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pmt_calibration = parallel(det_pmt_calibration, chinfo, log_nt; timeout = timeout, retry = false,
                                      process_name = "$period-$run-process_pmts_calibration_cal")

    pars_db = create_pars(pars_db, result_pmt_calibration)
    write_pars(l200.par.rpars.pmtcal[period], run, pars_db)
    write_validity(l200.par.rpars.pmtcal, data_filekey, (period, run))
    @info "Saved pars to disk"

    # Disabled until legend-exp/LegendMakie.jl#76 is fixed: Makie.Figure and Makie.Axis replace Makie's
    # global current figure and axis, which LegendMakie's recipes of steps running at the same time use.
    # # 1 p.e. positions of all PMTs, by location
    # pmts = sort(collect(chinfo); by = c -> (string(c.location), string(c.detector)))
    # for e_type in unique(Symbol(e_type) for det in keys(pars_db) for e_type in keys(pars_db[det]))
    #     # an overview plot must not decide the status of the step
    #     try
    #         @process_step "$e_type 1 p.e. position plot" begin
    #             fits = [haskey(pars_db, c.detector) && haskey(pars_db[c.detector], e_type) ? pars_db[c.detector][e_type].fit : nothing
    #                     for c in pmts]
    #             ok = [!isnothing(f) &&
    #                   isempty(failed_quality_cuts(f,
    #                                               merge(calibration_config.default,
    #                                               get(calibration_config, c.detector, PropDict())).energy_types[e_type].quality))
    #                   for (c, f) in zip(pmts, fits)]
    #             bad = .!isnothing.(fits) .& .!ok
    #             x = eachindex(pmts)
    #             fig = Makie.Figure(size = (1600, 520))
    #             ax = Makie.Axis(fig[1, 1]; title = "$period-$run ($(data_filekey.time)): 1 p.e. positions", ylabel = "µ1 of $e_type (ADC)",
    #                             xticks = (collect(x), ["$(c.detector) ($(c.location))" for c in pmts]), xticklabelrotation = π / 2)
    #             if any(ok)
    #                 Makie.errorbars!(ax, x[ok], [mvalue(f.μ1) for f in fits[ok]], [muncert(f.μ1) for f in fits[ok]]; color = :black)
    #                 Makie.scatter!(ax, x[ok], [mvalue(f.μ1) for f in fits[ok]]; color = :black, label = "fit ok")
    #             end
    #             any(bad) && Makie.scatter!(ax, x[bad], [mvalue(f.μ1) for f in fits[bad]]; color = :red, label = "fit with warning")
    #             for j in 2:length(pmts)
    #                 pmts[j].location != pmts[j - 1].location && Makie.vlines!(ax, [j - 0.5]; color = :dimgray, linestyle = :dot)
    #             end
    #             Makie.Legend(fig[1, 2], ax; framevisible = false)
    #             save_plot(fig, l200, filekey, :pmts, Symbol("pmt_spe_mu1_$(e_type)"))
    #         end
    #     catch e
    #         @warn "No $e_type 1 p.e. position plot: $(truncate_error(e))"
    #     end
    # end
    @info "Finished PMT calibration"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report,
             StructArray(var"Processor Status" = [master_status(processing_config, :process_pmts_calibration_cal, result_pmt_calibration)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, pmts_calibration_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results $(data_filekey)")
    lreport!(report, create_logtbl(result_pmt_calibration))

    @info "Write log report"
    write_report(get_rreportfilename(l200, filekey, :pmts_calibration_cal), report)
    @info report

    # flush stdout
    return flush(stdout)
end

register_processor!(process_pmts_calibration_cal)
