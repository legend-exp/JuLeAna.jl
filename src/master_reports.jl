# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const MASTER_REPORT_STATUS = (ok = process_succeeded, warning = process_warning, failed = process_failed)

"""
    JuLeAna.write_master_reports(jlrep::AbstractString)
    JuLeAna.write_master_reports(l200::LegendData)

Write one master report per processor to `<jlrep>/master/<processor>.md` (`jlrep` is
`l200.tier[:jlrep]` for the `LegendData` method) from all reports on disk found by
[`JuLeAna.report_overview`](@ref), whatever periods, runs or processors a session selects.
A master report has one row per run (run level) or period (partition level) with the
processor status of the report (see [`JuLeAna.read_report`](@ref)), its processing date and
a relative link to it. The file name is the current name of the processor, also for reports
of a processor in [`RENAMED_PROCESSORS`](@ref). Existing master reports are replaced.

Return the paths of the written files, sorted.
"""
function write_master_reports(jlrep::AbstractString)
    folder = joinpath(jlrep, "master")
    reports = Dict{Symbol,Vector{Any}}()
    for group in report_overview(jlrep), r in group.reports

        process = Symbol(group.level == :run ? "process_" : "p_process_", group.name)
        push!(get!(reports, get(RENAMED_PROCESSORS, process, process), []), (; r..., group.level, group.category))
    end
    mkpath(folder)
    refreshed = utc_timestamp()
    paths = map(sort!(collect(keys(reports)))) do process
        entries = sort!(reports[process]; by = r -> (r.period, something(r.run, ""), r.category))
        rows = map(entries) do r
            cells = (; Category = r.category, var"Processor Status" = MASTER_REPORT_STATUS[r.state],
                     var"Processing Date" = isnothing(r.date) ? "-" : string(r.date), Report = "[open report]($(relpath(r.path, folder)))")
            return r.level == :run ? (; Period = r.period, Run = r.run, cells...) : (; Period = r.period, cells...)
        end
        counts = join(("$(count(r -> r.state == state, entries)) $state" for state in keys(MASTER_REPORT_STATUS)), ", ")
        report = lreport("# `$process`", "Reports: $(length(entries)) ($counts)", "Last refreshed: $refreshed",
                         "Every processing run refreshes this report; `juleana --refresh-master-reports` refreshes it alone.", rows)
        path = joinpath(folder, "$process.md")
        writelreport(path, report)
        return path
    end
    return paths
end

write_master_reports(l200::LegendData) = write_master_reports(l200.tier[:jlrep])
