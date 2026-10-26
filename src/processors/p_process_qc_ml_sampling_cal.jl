"""
    p_process_qc_ml_sampling_cal(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, only_first_period::Bool=true) -> Bool

Draw the QC machine-learning training sample of the `cal` data of `period` and cluster it with affinity
propagation. The processor writes the unlabeled parameter entry of the training filekey and its validity.
`p_process_qc_ml_sampling_phy` does the same for the `phy` data.

The training filekey `fk` is `training_filekey(l200, period, DataCategory(:cal))`. The processor reads the QC ML config
`dataprod_config(l200).qc(fk).ml`, scans the raw files of all analysis runs of `period` for the configured
detectors, draws the sample by the selection rules of the config and clusters its waveforms. The entry holds the
sample description, the clustering and one label per cluster exemplar, all `UNLABELED`.

# Inputs
- `raw` tier of the analysis runs of `period`
- `dataprod_config(l200).qc(fk).ml`

# Outputs
- `jlqml` tier: the sample file of `fk` (`qc_sample_filename(l200, fk)`)
- `rpars/ml/<qc_pars_entry_name(fk)>` in the primary parameter directory, and its validity for the category
- plots `qcml_sample_selection` and `qcml_rule_matches` of all configured detectors
- partition report `qc_ml_sampling_cal` (`qc_ml_sampling_phy`)

The processor throws if `l200.par.rpars.ml` does not resolve to the primary parameter directory after the entry is written.

# Keywords
- `reprocess`: draw the sample again. Without it, an existing entry is kept and the processor skips. With it, an
  existing entry is replaced only if all its exemplar labels are `UNLABELED`; otherwise the processor throws, and
  the entry has to be removed by hand.
- `only_first_period`: accepted for a uniform call signature; it has no effect, the sample is drawn once per period.

# Returns
Always `false`: nothing is skipped because of an earlier period.
"""
function p_process_qc_ml_sampling_cal(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false,
                                      only_first_period::Bool = true)
    fk = training_filekey(l200, period, DataCategory(:cal))
    report = qc_ml_sampling(l200, fk; reprocess)
    isnothing(report) || write_report(get_preportfilename(l200, fk, :qc_ml_sampling_cal), report)
    return false
end

# Draw and cluster the training sample of `fk` and write its entry; return the report, or
# `nothing` if the entry exists and `reprocess` is `false`.
function qc_ml_sampling(l200::LegendData, fk::FileKey; reprocess::Bool)
    @info "Draw the QC ML training sample of $(fk.period) $(fk.category), training filekey $fk"

    cfg = qc_ml_config(l200, fk)
    @info "Loaded QC ML config: $(length(cfg.detectors)) detectors, n_max = $(cfg.n_max)"

    entry_path = qc_pars_entry_path(l200, fk)
    if isfile(entry_path)
        if !reprocess
            @info "QC ML entry $entry_path exists --> skipped"
            return nothing
        end
        existing = readlprops(entry_path)
        haskey(existing, :exemplar_labels) && all(==(UNLABELED), existing.exemplar_labels) ||
            throw(ErrorException("QC ML entry $entry_path is labeled or has no exemplar_labels; it is never overwritten, remove it by hand to draw a new sample"))
        @info "Reprocess unlabeled QC ML entry $entry_path"
    end

    start_time = now()
    filekeys = raw_filekeys(l200, fk.period, fk.category)
    @info "Drawing from $(length(filekeys)) raw files of runs $(join(unique(string(k.run) for k in filekeys), ", "))"
    rng = Xoshiro(Int(get(cfg, :seed, 1)))
    sample, cluster, pars, scan = run_qc_sampling(l200, fk, cfg; rng, filekeys)
    sampling_time = canonicalize(now() - start_time)
    @info "Affinity propagation scan: best damp = $(scan.best.damp), preference = $(scan.best.preference)"

    # `l200.par.rpars.ml` resolves to the metadata override directory as long as the primary
    # parameter directory has no `rpars/ml`; the check follows the creation of the entry.
    entry_name = qc_pars_entry_name(fk)
    make_par_dir(dirname(entry_path))
    write_pars(entry_path, pars)
    pars_db = l200.par.rpars.ml
    ml_dir = dirname(dirname(entry_path))
    if WRITE_PARS[] && data_path(pars_db) != ml_dir
        throw(ErrorException("l200.par.rpars.ml resolves to $(data_path(pars_db)), not to $ml_dir; no validity written"))
    end
    write_validity(pars_db, fk, entry_name; category = fk.category)
    @info "Saved QC ML entry $entry_path with validity from $(fk.time)"

    n_clusters = length(cluster.exemplars)
    @info "Sampling and clustering done in $sampling_time: $(length(sample)) rows, $n_clusters clusters (converged: $(cluster.converged), $(cluster.iterations) iterations)"
    @info "Rows per stratum: $(join(("$s = $n" for (s, n) in pairs(pars.sample.n_per_stratum)), ", "))"
    for d in cfg.detectors
        matched = pars.sample.n_matched[Symbol(d)]
        @info "$d: $(pars.sample.n_scan[Symbol(d)]) scan rows, rule matches $(join(("$r = $n" for (r, n) in pairs(matched)), ", "))"
    end

    plot_qc_ml_sampling(l200, fk, cfg, filekeys, sample, pars)

    # create log report
    detector_tbl = StructArray([(; Detector = string(d), Rows = count(==(DetectorId(string(d))), sample.detector),
                                 var"Scan rows" = pars.sample.n_scan[Symbol(d)], pairs(pars.sample.n_matched[Symbol(d)])...)
                                for d in cfg.detectors])
    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [process_succeeded]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qc_ml_sampling_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(fk))
    lreport!(report, "# Results")
    lreport!(report,
             "Entry `$entry_name`: $(length(sample)) rows from $(length(filekeys)) raw files, $n_clusters clusters (converged: $(cluster.converged)).")
    lreport!(report,
             StructArray(Stratum = string.(collect(keys(pars.sample.n_per_stratum))), Rows = collect(values(pars.sample.n_per_stratum))))
    lreport!(report, detector_tbl)

    @info report
    flush(stdout)
    return report
end

"""
    plot_qc_ml_sampling(l200, fk, cfg, filekeys, sample, pars)

Save the figures `qcml_sample_selection` and `qcml_rule_matches` of the training
sample of `fk` with [`save_plot`](@ref).

- Sample selection, per detector: the daqenergy distribution of the candidate
  pool, of the rows the aux-trigger flags excluded and of the selected rows,
  and up to 20 baseline-subtracted waveforms of every stratum present.
- Rule matches, per detector: how many of the scan rows each rule selects,
  against the number of scan rows (dashed).
"""
function plot_qc_ml_sampling(l200::LegendData, fk::FileKey, cfg::PropDict, filekeys::AbstractVector{FileKey}, sample, pars::PropDict)
    blmean = read_sample(qc_sample_filename(l200, fk))[4].blmean
    strata_present = sort(unique(sample.stratum))
    excluded_names = Symbol.(get(cfg.strata, :exclude, String[]))
    n_cols = 4
    n_rows = 1 + cld(length(strata_present), n_cols)
    fig = Makie.Figure(size = (380 * n_cols, 320 * n_rows * length(cfg.detectors)))
    for (k, d) in enumerate(cfg.detectors)
        det = DetectorId(string(d))
        gl = fig[k, 1] = Makie.GridLayout()
        cand = scan_candidates(l200, filekeys, det, get(cfg.strata, :aux_triggers, PropDict());
                               ts_window = Float64(cfg.strata.ts_window) * u"µs")
        excluded = reduce((a, name) -> a .| getproperty(cand, name), excluded_names; init = falses(length(cand)))
        pool = .!excluded
        in_sample = sample.detector .== det
        sel_e = sample.daqenergy[in_sample]

        e_edges = range(0, max(maximum(cand.daqenergy), maximum(sel_e), 1); length = 101)
        ax = Makie.Axis(gl[1, 1:n_cols]; xlabel = "daqenergy (ADC)", ylabel = "events", yscale = log10,
                        title = get_plottitle(fk, det,
                                              "QC ML sample: $(count(in_sample)) selected of $(count(pool)) pool rows in $(length(filekeys)) files"))
        Makie.hist!(ax, cand.daqenergy[pool]; bins = e_edges, color = (:gray, 0.6), label = "pool")
        any(excluded) && Makie.hist!(ax, cand.daqenergy[excluded]; bins = e_edges, color = (:seagreen, 0.5),
                                     label = "excluded ($(join(excluded_names, ", ")))")
        Makie.hist!(ax, sel_e; bins = e_edges, color = (:orangered, 0.8), label = "selected")
        Makie.axislegend(ax; position = :rt)

        for (j, s) in enumerate(strata_present)
            idx = findall(i -> in_sample[i] && sample.stratum[i] == s, eachindex(sample.stratum))
            ax = Makie.Axis(gl[1 + cld(j, n_cols), mod1(j, n_cols)]; xlabel = "time (µs)", ylabel = "ADC − blmean",
                            title = "$d $s: $(length(idx)) rows")
            # evenly spaced over the stratum's rows, at most 20
            for i in idx[unique(round.(Int, range(1, length(idx), length = min(20, length(idx)))))]
                wf = sample.waveform[i]
                Makie.lines!(ax, ustrip.(u"µs", wf.time), wf.signal .- blmean[i]; color = (:steelblue, 0.35), linewidth = 1.0)
            end
        end
    end
    save_plot(fig, l200, fk, :all, :qcml_sample_selection)

    rule_names = [String(r.name) for r in cfg.strata.rules]
    fig = Makie.Figure(size = (900, 380 * length(cfg.detectors)))
    for (k, d) in enumerate(cfg.detectors)
        n_scan = pars.sample.n_scan[Symbol(d)]
        counts = [pars.sample.n_matched[Symbol(d)][Symbol(r)] for r in rule_names]
        ax = Makie.Axis(fig[k, 1]; ylabel = "scan rows matched", yscale = log10, limits = (nothing, (0.5, 2 * n_scan)),
                        xticks = (eachindex(rule_names), rule_names), xticklabelrotation = π / 4,
                        title = get_plottitle(fk, DetectorId(string(d)), "QC ML rule matches among $n_scan scan rows"))
        # a bar of zero matches is drawn at 0.6 so that it stays visible on the log axis
        Makie.barplot!(ax, eachindex(rule_names), max.(counts, 0.6); color = :steelblue, fillto = 0.5)
        Makie.text!(ax, eachindex(rule_names), max.(counts, 0.6); text = string.(counts), align = (:center, :bottom), fontsize = 11)
        Makie.hlines!(ax, [n_scan]; color = :black, linestyle = :dash)
    end
    save_plot(fig, l200, fk, :all, :qcml_rule_matches)
    return nothing
end

register_processor!(p_process_qc_ml_sampling_cal; output_tiers = [:jlqml], detector_selection = false)
