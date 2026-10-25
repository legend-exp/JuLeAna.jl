# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    JuLeAna.dataset_summary(l200::LegendData)

Return the runinfo of `l200` per period and run: a `Dict` from `(period, run)` to the
data categories of the run that have file keys, in the column order of the runinfo. Each
category is a `NamedTuple` with

- `category`: the category as a `Symbol`, e.g. `:cal` or `:phy`,
- `nkeys`: the number of file keys,
- `livetime`: the livetime in seconds, `NaN` where the runinfo has none,
- `start`: the `DateTime` (UTC) of the first file key, `nothing` without one,
- `analysis`: whether the run is an analysis run of this category.
"""
function dataset_summary(l200::LegendData)
    return Dict((row.period, row.run) => [(; category, nkeys = length(c.keys), livetime = ustrip(u"s", c.livetime),
                                           start = ismissing(c.startkey) ? nothing : DateTime(c.startkey.time), analysis = c.is_analysis_run)
                                          for (category, c) in pairs(row) if c isa NamedTuple && length(c.keys) > 0]
                for row in runinfo(l200))
end

"""
    JuLeAna.period_summary(summary, period)

Return the totals of `period` in `summary`, as returned by [`JuLeAna.dataset_summary`](@ref),
per category, in the order the categories first occur in the runs of the period: a vector
of `NamedTuple`s with `category`, `nruns` (runs with file keys of the category), `nkeys`,
`livetime` (the sum of the known livetimes in seconds, `NaN` if no run has one), `start`
(the earliest start, or `nothing`) and `nanalysis` (the number of analysis runs).
"""
function period_summary(summary, period)
    runs = sort!([run for (p, run) in keys(summary) if p == period])
    totals = Dict{Symbol,Any}()
    order = Symbol[]
    for run in runs, c in summary[(period, run)]

        t = get!(totals, c.category) do
            push!(order, c.category)
            return (; category = c.category, nruns = 0, nkeys = 0, livetime = NaN, start = nothing, nanalysis = 0)
        end
        totals[c.category] = (; t.category, nruns = t.nruns + 1, nkeys = t.nkeys + c.nkeys,
                              livetime = isnan(c.livetime) ? t.livetime : isnan(t.livetime) ? c.livetime : t.livetime + c.livetime,
                              start = isnothing(c.start) ? t.start : isnothing(t.start) ? c.start : min(t.start, c.start),
                              nanalysis = t.nanalysis + c.analysis)
    end
    return [totals[c] for c in order]
end
