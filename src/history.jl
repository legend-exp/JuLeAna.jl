# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const HISTORY_TITLE = "# Processing history"
const HISTORY_COLUMNS = ["Processor", "Level", "Category", "Period", "Run", "Outcome", "Started (UTC)", "Finished (UTC)",
                         "Items ok/failed/not run"]
const HISTORY_TIME_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

"""
    JuLeAna.history_path(l200::LegendData)

Return the path of the processing history of the data production `l200`: `history.md` in
the `jllog` tier.
"""
history_path(l200::LegendData) = joinpath(l200.tier[:jllog], "history.md")

format_history_time(t) = isnothing(t) ? "–" : Dates.format(t, HISTORY_TIME_FORMAT)
parse_history_time(s) = s == "–" ? nothing : DateTime(s, HISTORY_TIME_FORMAT)

"""
    JuLeAna.history_section(entry)

Return the Markdown section of the processing history for the processing run `entry`, a
`NamedTuple` with the fields of the entries [`JuLeAna.read_history`](@ref) returns.
"""
function history_section(entry)
    io = IOBuffer()
    println(io, "## ", format_history_time(entry.started), " UTC, ", entry.user, "@", entry.host, ": ", entry.outcome)
    println(io)
    println(io, "Finished: ", format_history_time(entry.finished), " UTC  ")
    metadata = get(entry, :metadata, nothing)
    println(io, "Log folder: ", entry.log_path, isnothing(entry.software) && isnothing(metadata) ? "" : "  ")
    isnothing(entry.software) || println(io, "Software: ", entry.software, isnothing(metadata) ? "" : "  ")
    isnothing(metadata) || println(io, "Metadata: ", metadata)
    println(io)
    println(io, "| ", join(HISTORY_COLUMNS, " | "), " |")
    println(io, "|", repeat("---|", length(HISTORY_COLUMNS)))
    for s in entry.steps
        cells = [string(s.process), string(s.level), string(s.category), string(s.period), isnothing(s.run) ? "–" : string(s.run),
                 string(s.outcome), format_history_time(s.started), format_history_time(s.finished), "$(s.done)/$(s.failed)/$(s.notrun)"]
        println(io, "| ", join(cells, " | "), " |")
    end
    return String(take!(io))
end

"""
    JuLeAna.append_history(path::AbstractString, entry)

Append the section of the processing run `entry` (see [`JuLeAna.history_section`](@ref)) to
the processing history file `path`, creating the file with its title if it does not
exist. The section is written with a single write.
"""
function append_history(path::AbstractString, entry)
    mkpath(dirname(path))
    text = (isfile(path) ? "\n" : HISTORY_TITLE * "\n\n") * history_section(entry)
    open(io -> write(io, text), path, "a")
    return path
end

"""
    JuLeAna.read_history(path::AbstractString)

Read the processing history file `path` written by [`JuLeAna.append_history`](@ref) and
return its processing runs in the order they were written, an empty vector if the file
does not exist. Each run is a `NamedTuple` `(; started, finished, user, host, outcome,
log_path, software, metadata, steps)` with `outcome` a `Symbol`, `software` the description of the
software (see [`JuLeAna.software_version`](@ref)) or `nothing` for a section without one,
`metadata` the record of the metadata (`setup/metadata/<name>`, see
[`JuLeAna.record_metadata`](@ref)) or `nothing` for a section without one, the times as `DateTime` (UTC, to the second)
or `nothing`,
and `steps` a vector of `(; process, level, category, period, run, outcome, started,
finished, done, failed, notrun)` with `period` a `DataPeriod` and `run` a `DataRun`, or
`nothing` for a partition-level step.

Throws an `ArgumentError` naming the file and line of a line that does not follow the
format.
"""
function read_history(path::AbstractString)
    entries = NamedTuple[]
    isfile(path) || return entries
    malformed(i, line) = throw(ArgumentError("read_history: line $i of $path does not follow the history format: $(repr(line))"))
    current = nothing
    flush!() = isnothing(current) || push!(entries, current)
    for (i, line) in enumerate(eachline(path))
        if startswith(line, "## ")
            flush!()
            m = match(r"^## (.+) UTC, (.+)@(.+): (\w+)$", line)
            isnothing(m) && malformed(i, line)
            current = (; started = parse_history_time(m[1]), finished = nothing, user = String(m[2]), host = String(m[3]),
                       outcome = Symbol(m[4]), log_path = "", software = nothing, metadata = nothing, steps = NamedTuple[])
        elseif isnothing(current) || isempty(strip(line)) || line == HISTORY_TITLE
            isnothing(current) && !isempty(strip(line)) && line != HISTORY_TITLE && malformed(i, line)
        elseif startswith(line, "Finished: ")
            current = merge(current, (; finished = parse_history_time(strip(chopsuffix(chopprefix(line, "Finished: "), "UTC  ")))))
        elseif startswith(line, "Log folder: ")
            current = merge(current, (; log_path = String(chopsuffix(chopprefix(line, "Log folder: "), "  "))))
        elseif startswith(line, "Software: ")
            current = merge(current, (; software = String(chopsuffix(chopprefix(line, "Software: "), "  "))))
        elseif startswith(line, "Metadata: ")
            current = merge(current, (; metadata = String(chopprefix(line, "Metadata: "))))
        elseif startswith(line, "|")
            cells = strip.(split(strip(line, '|'), '|'))
            length(cells) == length(HISTORY_COLUMNS) || malformed(i, line)
            (cells == HISTORY_COLUMNS || all(c -> c == "---", cells)) && continue
            counts = tryparse.(Int, split(cells[9], '/'))
            (length(counts) == 3 && !any(isnothing, counts)) || malformed(i, line)
            push!(current.steps,
                  (; process = Symbol(cells[1]), level = Symbol(cells[2]), category = Symbol(cells[3]), period = DataPeriod(cells[4]),
                   run = cells[5] == "–" ? nothing : DataRun(cells[5]), outcome = Symbol(cells[6]), started = parse_history_time(cells[7]),
                   finished = parse_history_time(cells[8]), done = counts[1], failed = counts[2], notrun = counts[3]))
        else
            malformed(i, line)
        end
    end
    flush!()
    return entries
end

# History outcomes of a step that show on the grid: the step did not leave a report of its own.
const HISTORY_GRID_OUTCOMES = (:failed, :stopped, :cancelled)

"""
    JuLeAna.history_grid(processors, period_runs, overview, history)

Combine the reports on disk and the processing history into one cell per processor and
run (run level) or period (partition level).

`processors` are anything with the fields `name`, `level` and `category`, such as
[`ProcessorSpec`](@ref), in the order of the rows. `period_runs` is a vector of
`period => runs` pairs with `DataPeriod`s and vectors of `DataRun`s, the columns.
`overview` is the result of [`JuLeAna.report_overview`](@ref), `history` that of
[`JuLeAna.read_history`](@ref).

Return `(; periods, rows)` with `periods` the vector of `(; period, runs)` and `rows` one
`(; process, level, category, cells)` per processor. `cells` is a `Dict` from
`(period, run)`, with `run = nothing` for the partition level, to
`(; state, date, source, path)`:

- `source = :report`: the report on disk, `state` `:ok`, `:warning` or `:failed`, `date`
  its processing date (or `nothing`) and `path` the report file.
- `source = :history`: a step of the history that failed, was stopped or was cancelled,
  `state` its outcome, `date` the end of the step (or, for a step that never started, the
  end of its processing run) and `path` the log folder of its processing run. The last
  such step in the history replaces the report when it ended after the report's
  processing date or there is no dated report; a step that never started only fills a
  cell without a report.

A cell without a report and without such a step is missing from `cells`. Reports and steps
of processors, periods or runs that are not in the arguments are ignored.
"""
function history_grid(processors, period_runs, overview, history)
    reports = Dict{Any,Any}()
    for group in overview, r in group.reports

        reports[(group.name, group.level, group.category, r.period, r.run)] = r
    end
    latest = Dict{Any,Any}()
    for entry in history, s in entry.steps

        s.outcome in HISTORY_GRID_OUTCOMES || continue
        # the history is in chronological order, so a later step replaces an earlier one
        date = something(s.finished, s.started, entry.finished, Some(nothing))
        latest[(s.process, s.level, s.category, s.period, s.run)] = (; state = s.outcome, date, source = :history, path = entry.log_path,
                                                                     ran = !isnothing(s.started))
    end
    rows = map(processors) do spec
        (; name, level, category) = spec
        cells = Dict{Any,Any}()
        for (period, runs) in period_runs, run in (level == :partition ? (nothing,) : runs)

            r = get(reports, (report_name(name), level, string(category), string(period), isnothing(run) ? nothing : string(run)), nothing)
            report = isnothing(r) ? nothing : (; r.state, r.date, source = :report, r.path)
            h = get(latest, (name, level, category, period, run), nothing)
            newer = !isnothing(h) &&
                    (isnothing(report) || (h.ran && (isnothing(report.date) || (!isnothing(h.date) && h.date > report.date))))
            cell = newer ? (; h.state, h.date, h.source, h.path) : report
            isnothing(cell) || (cells[(period, run)] = cell)
        end
        return (; process = name, level, category, cells)
    end
    return (; periods = [(; period, runs = collect(runs)) for (period, runs) in period_runs], rows)
end

"""
    JuLeAna.disk_counts(row, period_runs)

Count the cells of `row`, a row of [`JuLeAna.history_grid`](@ref), in the runs of
`period_runs` (pairs or a `Dict` of `period => runs`); a partition-level row has one cell
per period. Return `(; ok, warning, failed, missing, total)`: `failed` counts the cells in
state `:failed`, from a report or the history, `missing` the cells without a report and
those of a stopped or cancelled step, `total` all counted cells.
"""
function disk_counts(row, period_runs)
    counts = Dict(:ok => 0, :warning => 0, :failed => 0, :missing => 0)
    for (period, runs) in period_runs, run in (row.level === :partition ? (nothing,) : runs)

        cell = get(row.cells, (period, run), nothing)
        state = isnothing(cell) || cell.state in (:stopped, :cancelled) ? :missing : cell.state
        counts[state] += 1
    end
    return (; ok = counts[:ok], warning = counts[:warning], failed = counts[:failed], missing = counts[:missing],
            total = sum(values(counts)))
end

"""
    JuLeAna.disk_state(counts)

Return the state of a processor on disk from its [`JuLeAna.disk_counts`](@ref): `:failed`
if a cell failed, else `:missing` if a cell is missing, else `:warning` if a cell has a
warning, else `:ok`; `nothing` if there are no cells.
"""
function disk_state(counts)
    return counts.total == 0 ? nothing : counts.failed > 0 ? :failed : counts.missing > 0 ? :missing : counts.warning > 0 ? :warning : :ok
end
