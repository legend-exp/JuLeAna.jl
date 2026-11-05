"""
    load_qc_evaluator(l200::LegendData, filekey::FileKey)

Return the ML quality-cut evaluator for `filekey`. The ML quality cut is disabled: return
`missing` and log an info message. The DSP processors skip the Haar wavelet classification
when the evaluator is `missing` and set `qc_label` to `-1`.
"""
function load_qc_evaluator(l200::LegendData, filekey::FileKey)
    @info "The ML quality cut is disabled - skipping ML QC for $filekey"
    return missing
end

# Report row of a filekey survival fraction that deviates from the other filekeys (`qc_filekey_stability!`)
const QCStabilityWarning = NamedTuple{(:Detector, :Filekey, :Selection, Symbol("Efficiency (%)"), Symbol("Reference (%)"), :Events,
                                       Symbol("Reference events"), Symbol("Deviation (σ)")),
                                      Tuple{DetectorId,FileKey,Symbol,Float64,Float64,Int,Int,Float64}}

"""
    qc_filekey_stability!(filekey_summary::PropDict, det::DetectorId, filekeys::AbstractVector{FileKey},
                          included::AbstractVector{Bool}, selections; stability_sigma::Real, title::AbstractString)

Compare the survival fraction of each filekey in `filekey_summary` with that of the other
`included` filekeys, for each selection `(; name, n, k, monitor, label, color)` in `selections`:
`n` and `k` name the event and passing-event counts in the filekey summary. The deviation is the
p-value of an exact count test (hypergeometric, conditioned on the total counts) in Gaussian
standard deviations; it is stored with the reference under `stability` of each filekey summary.

Return the deviations above `stability_sigma` of the included filekeys of the `monitor`ed
selections as `QCStabilityWarning` rows, and a figure of the survival fractions per filekey.
"""
function qc_filekey_stability!(filekey_summary::PropDict, det::DetectorId, filekeys::AbstractVector{FileKey},
                               included::AbstractVector{Bool}, selections; stability_sigma::Real, title::AbstractString)
    summaries = [filekey_summary[Symbol(fk)] for fk in filekeys]
    foreach(summary -> summary[:stability] = PropDict(), summaries)
    hours = [(fk.time.unixtime - first(filekeys).time.unixtime) / 3600 for fk in filekeys]
    warnings = QCStabilityWarning[]
    fig = Makie.Figure(size = (1000, 450))
    ax = Makie.Axis(fig[1, 1]; title, xlabel = "Filekey start since $(first(filekeys).time) (h)", ylabel = "Survival fraction (%)")
    for s in selections
        n, k = getproperty.(summaries, s.n), getproperty.(summaries, s.k)
        sf = k ./ n
        total_n, total_k = sum(n[included]), sum(k[included])
        flagged = falses(length(filekeys))
        for i in eachindex(filekeys)
            ref_n, ref_k = total_n - included[i] * n[i], total_k - included[i] * k[i]
            sigma = NaN
            if n[i] > 0 && ref_n > 0
                null = Hypergeometric(k[i] + ref_k, n[i] + ref_n - k[i] - ref_k, n[i])
                p = min(cdf(null, k[i]), ccdf(null, k[i] - 1), 0.5)
                sigma = sign(sf[i] - ref_k / ref_n) * -quantile(Normal(), max(p, floatmin(Float64)))
            end
            flagged[i] = s.monitor && included[i] && abs(sigma) > stability_sigma
            summaries[i].stability[s.name] = PropDict(:reference => 100 * ref_k / ref_n, :reference_events => ref_n, :sigma => sigma,
                                                      :flagged => flagged[i], :available => isfinite(sigma))
            flagged[i] &&
                push!(warnings, QCStabilityWarning((det, filekeys[i], s.name, 100 * sf[i], 100 * ref_k / ref_n, n[i], ref_n, sigma)))
        end
        Makie.scatterlines!(ax, hours, 100 .* sf; color = s.color, label = s.label)
        total_n > 0 && Makie.hlines!(ax, 100 * total_k / total_n; color = s.color, linestyle = :dash)
        any(flagged) && Makie.scatter!(ax, hours[flagged], 100 .* sf[flagged]; color = :red, marker = :xcross, markersize = 15,
                                       label = "Deviation > $(stability_sigma)σ")
    end
    all(included) || Makie.vlines!(ax, hours[.!included]; color = :gray, linestyle = :dash, label = "Removed filekey")
    Makie.axislegend(ax; position = :lb, unique = true)
    LegendMakie.add_watermarks!(final = true)
    return warnings, fig
end

"""
    plot_qc_survival_fractions(flag_names::AbstractVector{Symbol}, series; title::AbstractString)

Plot the survival fractions of the QC flags `flag_names` for each `(label, survival_fractions, color)`
in `series`, where `survival_fractions` has a unitful survival fraction per flag name.
"""
function plot_qc_survival_fractions(flag_names::AbstractVector{Symbol}, series; title::AbstractString)
    x = collect(eachindex(flag_names))
    fig = Makie.Figure(size = (800, 500))
    ax = Makie.Axis(fig[1, 1]; title, xlabel = "QC flag", ylabel = "Survival fraction (%)", xticks = (x, string.(flag_names)),
                    xticklabelrotation = π / 3)
    for (i, (label, survival_fractions, color)) in enumerate(series)
        sf = [mvalue(ustrip(u"percent", getproperty(survival_fractions, flag_name))) for flag_name in flag_names]
        Makie.scatter!(ax, x .+ 0.3 * (i - (length(series) + 1) / 2), sf; color, label)
    end
    length(series) > 1 && Makie.axislegend(ax; position = :lb)
    LegendMakie.add_watermarks!(final = true)
    return fig
end
