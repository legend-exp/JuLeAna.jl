# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Reports are Markdown files written by the processors, one per run (run level) or one per
# period (partition level). The functions in this file only read them: no function creates
# a folder or a file, so they are safe to call on a production data folder.

# The name of a report: the processor name without the `process_` / `p_process_` prefix.
# A processor listed in `RENAMED_PROCESSORS` additionally drops its `_cal` suffix: the
# report files keep the name the processor had before the suffix was added.
function report_name(process::Symbol)
    name = chopprefix(chopprefix(string(process), "p_process_"), "process_")
    return process in values(RENAMED_PROCESSORS) ? String(chopsuffix(name, "_cal")) : String(name)
end

# the cells of a Markdown table row
table_cells(line::AbstractString) = strip.(split(strip(strip(line), '|'), "|"))

# the text of a status cell without the HTML markup around it
status_text(cell::AbstractString) = strip(replace(cell, r"<[^>]*>" => ""))

const PROCESSOR_STATES = Dict("Success" => :ok, "Warning" => :warning, "Failure" => :failed)

"""
    report_path(jlrep::AbstractString, process::Symbol, level::Symbol, period, run, category; setup = "l200")
    report_path(l200::LegendData, process::Symbol, level::Symbol, period, run, category; setup = "l200")

Return the path of the report written by the processor `process`. `jlrep` is the
report tier folder, `l200.tier[:jlrep]` for the `LegendData` method. `level` is `:run`
for `<jlrep>/rreport/<category>/<period>/<run>/<setup>-<period>-<run>-<category>-<name>.md`
and `:partition` for `<jlrep>/preport/<period>/<category>/<setup>-<period>-<category>-<name>.md`,
where `<name>` is the processor name without its `process_` or `p_process_` prefix and
without the `_cal` suffix of the processors in [`RENAMED_PROCESSORS`](@ref).
`run` is not used for the partition level. The file system is not accessed.
"""
function report_path(jlrep::AbstractString, process::Symbol, level::Symbol, period, run, category; setup = "l200")
    name = report_name(process)
    if level == :run
        return joinpath(jlrep, "rreport", string(category), string(period), string(run), "$setup-$period-$run-$category-$name.md")
    elseif level == :partition
        return joinpath(jlrep, "preport", string(period), string(category), "$setup-$period-$category-$name.md")
    end
    return throw(ArgumentError("report level must be :run or :partition, got $(repr(level))"))
end

function report_path(l200::LegendData, process::Symbol, level::Symbol, period, run, category; kwargs...)
    return report_path(l200.tier[:jlrep], process, level, period, run, category; kwargs...)
end

"""
    read_report(path::AbstractString)

Read the report at `path` and return a `NamedTuple` with the fields

- `path`: the given path.
- `state`: `:missing` if there is no file at `path`. Otherwise the `Processor Status`
  table of the report (`Success` is `:ok`, `Warning` is `:warning`, `Failure` is
  `:failed`) or, if the report has none, `:failed` if any entry failed, else `:warning`
  if any entry has a warning, else `:ok`.
- `date`: the `DateTime` of the `Time of processing:` or `Date of processing:` line, or
  `nothing` if there is no such line or it holds no ISO 8601 timestamp.
- `n_entries`, `n_failed`, `n_warnings`: the number of entries, of failed entries and of
  entries with a warning. An entry is a row of a table with a `Status` column, per
  detector and filter type for the fit reports and per filekey for the DSP reports. An
  entry fails when its status cell contains `Failure` and has a warning when it contains
  `Warning`.
- `failures`: a vector of `(label, error)` pairs of strings, one per failed entry. The
  label is the detector, the failed detectors of a DSP report (one pair per detector), or
  else the first cell of the row, followed by `(filter or energy type, partition)` when the
  row has such columns. The error joins the non-empty cells of the columns whose header
  contains `Error`.

An unknown value in the `Processor Status` table throws an `ArgumentError`.
"""
function read_report(path::AbstractString)
    failures = Tuple{String,String}[]
    n_entries = n_failed = n_warnings = 0
    date = nothing
    processor_state = nothing
    if !isfile(path)
        return (; path = String(path), state = :missing, date, n_entries, n_failed, n_warnings, failures)
    end

    # consecutive table rows form a table: header row, separator row, data rows
    tables = Vector{Vector{Vector{String}}}()
    in_table = false
    for line in eachline(path)
        if startswith(strip(line), "|")
            in_table || push!(tables, Vector{Vector{String}}())
            push!(last(tables), table_cells(line))
            in_table = true
            continue
        end
        in_table = false
        m = match(r"^\s*(?:Time|Date) of processing:\s*(\S+)", line)
        isnothing(m) || (date = tryparse(DateTime, chopsuffix(m.captures[1], "Z")))
    end

    for table in tables
        length(table) >= 2 && all(c -> !isempty(c) && all(in((':', '-')), c), table[2]) || continue
        header = table[1]
        rows = @view table[3:end]
        if header == ["Processor Status"]
            for cells in rows
                text = status_text(only(cells))
                haskey(PROCESSOR_STATES, text) || throw(ArgumentError("unknown processor status $(repr(text)) in report $path"))
                processor_state = PROCESSOR_STATES[text]
            end
            continue
        end
        # only tables with a status column hold results, the metadata table is skipped
        i_status = findfirst(isequal("Status"), header)
        isnothing(i_status) && continue
        i_det = findfirst(in(("Detector", "Failed Detectors")), header)
        i_type = findfirst(in(("Filter Type", "Energy Type")), header)
        i_part = findfirst(isequal("Partition"), header)
        # every error-like column: the fit reports have "Error", the aoe/lq cut reports
        # have "CalError" and "CutError"
        i_errs = findall(h -> occursin("Error", h), header)
        for cells in rows
            length(cells) == length(header) || continue
            n_entries += 1
            status = status_text(cells[i_status])
            occursin("Warning", status) && (n_warnings += 1)
            occursin("Failure", status) || continue
            n_failed += 1
            labels = if isnothing(i_det) || cells[i_det] in ("", "-")
                [first(cells)]
            elseif header[i_det] == "Failed Detectors"
                [m.captures[1] for m in eachmatch(r"\"([^\"]+)\"", cells[i_det])]
            else
                [cells[i_det]]
            end
            # the type and the partition distinguish several entries per detector
            suffix = join([cells[i] for i in (i_type, i_part) if !isnothing(i) && !(cells[i] in ("", "-"))], ", ")
            isempty(suffix) || (labels = labels .* " ($suffix)")
            err = join([cells[i] for i in i_errs if !(cells[i] in ("", "-"))], " | ")
            append!(failures, [(l, err) for l in labels])
        end
    end

    state = if !isnothing(processor_state)
        processor_state
    elseif n_failed > 0
        :failed
    elseif n_warnings > 0
        :warning
    else
        :ok
    end
    return (; path = String(path), state, date, n_entries, n_failed, n_warnings, failures)
end

"""
    report_index(jlrep::AbstractString, processors, period_runs; setup = "l200")
    report_index(l200::LegendData, processors, periods, runs; setup = "l200")

Read the reports of every processor in `processors` (anything with the fields `name`,
`level` and `category`, such as [`ProcessorSpec`](@ref)) for every `period => runs` pair
in `period_runs`, and return one row per report. A run-level processor has one report per
run of `runs`, a partition-level processor one per period (the runs are not used). The
`LegendData` method takes the report folder from `l200.tier[:jlrep]` and the runs of each
period in `periods` from `processable_runs(l200, period, runs)`.

A row is the `NamedTuple` `(; process, level, category, period, run, path, state, date,
n_entries, n_failed, n_warnings, failures)` with the fields of [`read_report`](@ref) and
`run = nothing` for the partition level. A report that does not exist has
`state = :missing`. Nothing is created in the file system.
"""
function report_index(jlrep::AbstractString, processors, period_runs; setup = "l200")
    rows = []
    for spec in processors, (period, runs) in period_runs

        (; name, level, category) = spec
        for run in (level == :partition ? (nothing,) : runs)
            path = report_path(jlrep, name, level, period, run, category; setup)
            push!(rows, (; process = name, level, category, period, run, read_report(path)...))
        end
    end
    return rows
end

function report_index(l200::LegendData, processors, periods, runs; kwargs...)
    return report_index(l200.tier[:jlrep], processors, [period => processable_runs(l200, period, runs) for period in periods]; kwargs...)
end

# the label of the run (`p03-r001`) or of the period for the partition level
row_label(row) = isnothing(row.run) ? string(row.period) : "$(row.period)-$(row.run)"

"""
    failure_summary(rows)

Group the failed entries of `rows` (rows of [`report_index`](@ref)) by processor. Return a
vector with one `(; process, detectors)` per processor, in order of first appearance, where
`detectors` is a vector sorted by name of `(; detector, labels, errors)`: the detector name
without the `(filter type, partition)` suffix of its entry, the unique labels of the runs
(`"p03-r001"`) or periods in which it failed and its unique non-empty errors. The failures
are the `failures` of the rows, so no file is read.
"""
function failure_summary(rows)
    processes = unique(row.process for row in rows)
    return map(processes) do process
        failed = Dict{String,NamedTuple{(:labels, :errors),Tuple{Vector{String},Vector{String}}}}()
        for row in rows, (label, err) in row.failures

            row.process == process || continue
            entry = get!(() -> (; labels = String[], errors = String[]), failed, first(split(label, " (")))
            push!(entry.labels, row_label(row))
            isempty(err) || push!(entry.errors, err)
        end
        detectors = [(; detector, labels = unique(e.labels), errors = unique(e.errors))
                     for (detector, e) in sort!(collect(failed); by = first)]
        return (; process, detectors)
    end
end

"""
    report_overview(jlrep::AbstractString; processors = ())
    report_overview(l200::LegendData; processors = ())

Read all reports below the report folder `jlrep` (`l200.tier[:jlrep]` for the `LegendData`
method), in the folders `rreport/<category>/<period>/<run>/` and
`preport/<period>/<category>/`, and group them by report name, level and category. Files
that do not follow the naming scheme of [`report_path`](@ref) are skipped. Nothing is
created in the file system.

Return a vector, sorted by level (run before partition), rank, name and category, of
`(; name, level, category, nreports, counts, last_date, latest_path, reports)`.
`counts` is `(; ok, warning, failed)`, the number of reports in each [`read_report`](@ref)
state. `last_date` and `latest_path` are the processing date of the latest report and its
path, `nothing` if no report has a date. `reports` is a vector of
`(; period, run, path, state, date)` sorted by period and run, with the period and the run
as strings and `run = nothing` for the partition level.

`processors` is anything with the fields `name`, `level` and `rank`, such as the
[`ProcessorSpec`](@ref)s of the processing config. The rank of a report is the rank of the
processor of its level whose report name (see [`report_path`](@ref)) is the name of the report;
reports of processors that are not in `processors` come last in their level, ordered by name.
"""
function report_overview(jlrep::AbstractString; processors = ())
    groups = Dict{Tuple{Symbol,String,String},Vector{Any}}()
    subdirs(dir) = isdir(dir) ? [d for d in readdir(dir) if isdir(joinpath(dir, d))] : String[]
    function scan(dir, level, period, run, category)
        isdir(dir) || return
        # <setup>-<period>-<run>-<category>-<name>.md
        prefix = level == :run ? "$period-$run-$category-" : "$period-$category-"
        for file in readdir(dir)
            endswith(file, ".md") || continue
            rest = last(split(chopsuffix(file, ".md"), "-"; limit = 2))
            startswith(rest, prefix) && length(rest) > length(prefix) || continue
            path = joinpath(dir, file)
            report = read_report(path)
            push!(get!(groups, (level, chopprefix(rest, prefix), category), []), (; period, run, path, report.state, report.date))
        end
    end
    for category in subdirs(joinpath(jlrep, "rreport")), period in subdirs(joinpath(jlrep, "rreport", category)),
        run in subdirs(joinpath(jlrep, "rreport", category, period))

        scan(joinpath(jlrep, "rreport", category, period, run), :run, period, run, category)
    end
    for period in subdirs(joinpath(jlrep, "preport")), category in subdirs(joinpath(jlrep, "preport", period))

        scan(joinpath(jlrep, "preport", period, category), :partition, period, nothing, category)
    end

    overview = map(collect(groups)) do ((level, name, category), reports)
        sort!(reports; by = r -> (r.period, something(r.run, "")))
        dated = filter(r -> !isnothing(r.date), reports)
        latest = isempty(dated) ? nothing : argmax(r -> r.date, dated)
        counts = (; ok = count(r -> r.state == :ok, reports), warning = count(r -> r.state == :warning, reports),
                  failed = count(r -> r.state == :failed, reports))
        return (; name, level, category, nreports = length(reports), counts, last_date = isnothing(latest) ? nothing : latest.date,
                latest_path = isnothing(latest) ? nothing : latest.path, reports)
    end
    ranks = Dict((spec.level, report_name(spec.name)) => spec.rank for spec in processors)
    return sort!(overview; by = o -> (o.level == :partition, get(ranks, (o.level, o.name), typemax(Int)), o.name, o.category))
end

report_overview(l200::LegendData; kwargs...) = report_overview(l200.tier[:jlrep]; kwargs...)
