# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Theme color and icon of each report state.
const REPORT_COLORS = (ok = :success, warning = :warning, failed = :error, missing = :text_dim)
const REPORT_ICONS = (ok = "✓", warning = "!", failed = "✗", missing = "–")

# Width of the level column of a group row: `partition`.
const REPORT_LEVEL_WIDTH = 9
# Width of the category column of a group row: `cal` or `phy`.
const REPORT_CATEGORY_WIDTH = 3

# Rows scrolled by one step of the mouse wheel in the failures pane.
const REPORT_WHEEL_LINES = 3

"""
    ReportsPage()

State of the Reports page of the terminal user interface: the reports grouped by processor,
the processing history, the row under the cursor, which groups the user folded or unfolded, the open report and the
requests for reading the file system. The page lists all reports on disk (`source` is
`:all`, [`report_overview`](@ref)), which it starts with, or the reports of the steps of the
current or last processing run (`:run`, rows of [`report_index`](@ref)), and the failures
of the processor under the cursor.
Keys are handled by [`JuLeAna.reports_key!`](@ref) and [`JuLeAna.reports_mouse!`](@ref), the
page is drawn by [`JuLeAna.render_reports`](@ref).

The page never reads the file system. It queues requests (see [`JuLeAna.take_requests!`](@ref))
that the interface carries out in the background and answers with [`JuLeAna.reports_result!`](@ref).
A row is identified by its key, `(group,)` for a group and `(group, period, run)` for a
report, where `group` is `(name, level, category)`, so that the cursor stays on its row
when the list is read anew. `expanded` holds the group keys the user folded (`false`) or
unfolded (`true`); the other groups are unfolded if one of their reports failed.
"""
mutable struct ReportsPage
    # `:all` or `:run`
    source::Symbol
    groups::Vector{Any}
    # path of the processing history file, `nothing` if it does not exist
    history::Union{Nothing,String}
    # whether `groups` holds the result of a read of `source`
    loaded::Bool
    # whether a read of the reports is under way
    reading::Bool
    error::Union{Nothing,String}
    # number of the latest read of the reports; answers to older reads are dropped
    generation::Int
    # whether the page has been visible, and the controller state its data was read for
    visited::Bool
    mark::Any
    cursor::Any
    # row index of the cursor at the last use, the fallback when the cursor row vanishes
    index::Int
    # index of the first displayed row
    top::Int
    # rows displayed per page at the last render
    height::Int
    const expanded::Dict{Any,Bool}
    # 1 for the list of reports, 2 for the failures
    focus::Int
    fail_top::Int
    fail_height::Int
    fail_lines::Int
    # group of the failures shown at the last render
    fail_group::Any
    # failure summaries of the groups, and the groups whose failures are being read
    const summaries::Dict{Any,Any}
    const pending::Set{Any}
    # path of the open report, its viewer once read, and a message instead of the viewer
    viewer_path::Union{Nothing,String}
    viewer::Union{Nothing,Tachikoma.MarkdownPane}
    viewer_message::Union{Nothing,String}
    const requests::Vector{Any}
    # areas of the list block, of its rows and of the failures block at the last render
    rect::Tachikoma.Rect
    list::Tachikoma.Rect
    fail_rect::Tachikoma.Rect
end

function ReportsPage()
    return ReportsPage(:all, Any[], nothing, false, false, nothing, 0, false, nothing, nothing, 1, 1, 1, Dict{Any,Bool}(), 1, 1, 1, 0,
                       nothing, Dict{Any,Any}(), Set{Any}(), nothing, nothing, nothing, Any[], Tachikoma.Rect(1, 1, 0, 0),
                       Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0))
end

"""
    JuLeAna.strip_span_tags(text::AbstractString)

Return `text` without the HTML `<span …>` and `</span>` tags that the processors put around
the colored status words of their reports, so that the words remain.
"""
strip_span_tags(text::AbstractString) = replace(text, r"</?span\b[^>]*>" => "")

# Width of a table in a viewer, in characters; wider tables wrap their long cells.
const REPORT_TABLE_WIDTH = 100

# Narrowest width a wide column is shrunk to.
const REPORT_MIN_COLUMN_WIDTH = 12

# Lines of at most `width` characters that hold the words of `cell`. A word longer than
# `width` is split.
function wrap_cell(cell::AbstractString, width::Int)
    lines = String[]
    current = ""
    for word in split(cell)
        for piece in (textwidth(word) <= width ? (word,) : (String(p) for p in Iterators.partition(word, width)))
            if isempty(current)
                current = piece
            elseif textwidth(current) + 1 + textwidth(piece) <= width
                current *= " " * piece
            else
                push!(lines, current)
                current = piece
            end
        end
    end
    push!(lines, current)
    return lines
end

"""
    JuLeAna.tables_as_code(text::AbstractString; width = JuLeAna.REPORT_TABLE_WIDTH)

Return `text` with each Markdown table (consecutive lines that start with `|`) replaced by a
fenced code block that holds the table as aligned text, the header followed by a rule. The
Markdown renderer of Tachikoma leaves tables out; a code block shows their cells. HTML tags
in the cells are removed and their text is kept. A table wider than `width` characters is
narrowed by limiting its widest columns, down to at least `JuLeAna.REPORT_MIN_COLUMN_WIDTH`
characters each, and a cell longer than its column continues on the following lines of its row.
"""
function tables_as_code(text::AbstractString; width::Integer = REPORT_TABLE_WIDTH)
    out = String[]
    table = Vector{String}[]
    function flush_table()
        rows = [cells for cells in table if !all(c -> !isempty(c) && all(in((':', '-')), c), cells)]
        table = Vector{String}[]
        isempty(rows) && return nothing
        ncols = maximum(length, rows)
        widths = [maximum((textwidth(r[i]) for r in rows if i <= length(r)); init = 0) for i in 1:ncols]
        # narrow the widest column until the table fits
        while sum(widths) + 2 * (ncols - 1) > width && maximum(widths) > REPORT_MIN_COLUMN_WIDTH
            widths[argmax(widths)] -= 1
        end
        function push_row(r)
            cells = [wrap_cell(get(r, i, ""), max(widths[i], 1)) for i in 1:ncols]
            for k in 1:maximum(length, cells)
                push!(out, rstrip(join((rpad(get(cells[i], k, ""), widths[i]) for i in 1:ncols), "  ")))
            end
        end
        push!(out, "```")
        push_row(first(rows))
        push!(out, join(("─"^w for w in widths), "  "))
        foreach(push_row, rows[2:end])
        push!(out, "```")
        return nothing
    end
    for l in split(text, '\n')
        if startswith(strip(l), "|")
            push!(table, status_text.(table_cells(l)))
        else
            isempty(table) || flush_table()
            push!(out, l)
        end
    end
    isempty(table) || flush_table()
    return join(out, '\n')
end

function report_counts(reports)
    return (; (s => count(r -> r.state === s, reports) for s in (:ok, :warning, :failed, :missing))...)
end

# Groups of the rows of `report_index` by processor, in order of first appearance. Each group
# keeps its rows for `failure_summary`.
function run_groups(rows)
    keys = unique((report_name(r.process), r.level, string(r.category)) for r in rows)
    return Any[let rs = [r for r in rows if (report_name(r.process), r.level, string(r.category)) == key]
                   reports = [(; period = string(r.period), run = isnothing(r.run) ? nothing : string(r.run), r.path, r.state, r.date)
                              for r in rs]
                   (; key, name = display_name(first(rs).process), level = key[2], category = key[3], reports,
                    counts = report_counts(reports), rows = rs)
               end
               for key in keys]
end

# Groups of the entries of `report_overview`; their failures are read on demand.
function overview_groups(overview)
    return Any[(; key = (o.name, o.level, string(o.category)), name = display_name(Symbol(o.name)), o.level, category = string(o.category),
                o.reports, counts = report_counts(o.reports), rows = nothing) for o in overview]
end

# Displayed rows: the processing history if its file exists, then a group row followed by the
# rows of its reports if it is unfolded. The history row is a report row without a group.
function reports_rows(page::ReportsPage)
    rows = @NamedTuple{key::Tuple, report::Bool, entry::Any, group::Any, unfolded::Bool}[]
    isnothing(page.history) ||
        push!(rows, (; key = (:history,), report = true, entry = (; path = page.history), group = nothing, unfolded = true))
    for g in page.groups
        unfolded = get(page.expanded, g.key) do
            return g.counts.failed > 0
        end
        push!(rows, (; key = (g.key,), report = false, entry = g, group = g, unfolded))
        unfolded &&
            append!(rows, (; key = (g.key, r.period, r.run), report = true, entry = r, group = g, unfolded = true) for r in g.reports)
    end
    return rows
end

# Index of the cursor row in `rows` (0 if there are none), moving the cursor to the
# nearest row when its row vanished.
function sync_reports_cursor!(page::ReportsPage, rows)
    isempty(rows) && return 0
    idx = something(findfirst(r -> r.key == page.cursor, rows), clamp(page.index, 1, length(rows)))
    page.cursor, page.index = rows[idx].key, idx
    return idx
end

function move_reports_cursor!(page::ReportsPage, rows, idx)
    isempty(rows) && return nothing
    page.index = clamp(idx, 1, length(rows))
    page.cursor = rows[page.index].key
    return nothing
end

# The group of the cursor row, `nothing` if there are no rows.
function cursor_group(page::ReportsPage)
    rows = reports_rows(page)
    idx = sync_reports_cursor!(page, rows)
    return idx == 0 ? nothing : rows[idx].group
end

function scroll_failures!(page::ReportsPage, delta)
    page.fail_top = clamp(page.fail_top + delta, 1, last_top(page.fail_lines, page.fail_height))
    return nothing
end

# Queue a read of the reports of the current source.
function request_reports!(page::ReportsPage)
    page.generation += 1
    page.reading = true
    empty!(page.summaries)
    empty!(page.pending)
    filter!(r -> r.kind !== :index, page.requests)
    push!(page.requests, (; kind = :index, page.source, page.generation))
    return nothing
end

# Queue a read of the failures of the processor under the cursor when the source is all
# reports on disk and they are not known.
function request_failures!(page::ReportsPage)
    page.source === :all || return nothing
    g = cursor_group(page)
    (isnothing(g) || g.counts.failed == 0 || haskey(page.summaries, g.key) || g.key in page.pending) && return nothing
    push!(page.pending, g.key)
    failed = [(r.period, r.run, r.path) for r in g.reports if r.state === :failed]
    push!(page.requests, (; kind = :failures, group = g.key, reports = failed, page.generation))
    return nothing
end

"""
    JuLeAna.take_requests!(page::ReportsPage)

Return the requests of `page` for reading the file system and clear them. A request is a
named tuple with `kind` `:index` (read the reports of `source`), `:failures` (read the failures
of the reports `reports` of the processor `group`) or `:open` (read the report file `path`).
[`JuLeAna.read_reports`](@ref) carries a request out and [`JuLeAna.reports_result!`](@ref)
takes its answer.
"""
function take_requests!(page::ReportsPage)
    requests = copy(page.requests)
    empty!(page.requests)
    return requests
end

"""
    JuLeAna.read_reports(ctrl::DataflowController, request)

Carry out a request of a [`JuLeAna.ReportsPage`](@ref) (see [`JuLeAna.take_requests!`](@ref))
and return `(; request, value)`, or `(; request, error)` with the message of the exception
if the read failed. The value of an `:index` request is the rows of
`report_index(ctrl)` or the entries of `report_overview(ctrl)` (see [`report_index`](@ref)), that of a `:failures`
request the rows `(; process, period, run, failures)` of its reports, and that of an `:open`
request the viewer of the file's text, or `nothing` if there is no such file. The answer to an
`:index` request also has the field `history`, the path of the processing history file
([`JuLeAna.history_path`](@ref)) or `nothing` if the file does not exist. The viewer is built here,
so that converting the text does not hold up the interface.
"""
function read_reports(ctrl::DataflowController, request)
    history = nothing
    value = try
        if request.kind === :index
            rows = request.source === :run ? report_index(ctrl) : report_overview(ctrl)
            session = @lock ctrl.lock ctrl.session
            isnothing(session) && throw(ArgumentError("history_path: no session is loaded"))
            path = history_path(session.l200)
            history = isfile(path) ? path : nothing
            rows
        elseif request.kind === :failures
            [(; process = request.group, period, run, read_report(path).failures) for (period, run, path) in request.reports]
        else
            isfile(request.path) ? report_viewer(request.path, read(request.path, String)) : nothing
        end
    catch e
        return (; request, error = first(split(sprint(showerror, e), '\n')))
    end
    request.kind === :index && return (; request, value, history)
    return (; request, value)
end

# The viewer of the report text `text`, titled with the file name.
function report_viewer(path::AbstractString, text::AbstractString)
    pane = Tachikoma.MarkdownPane(tables_as_code(strip_span_tags(text)); block = pane_block(basename(path), true), following = false,
                                  h1_style = Tachikoma.tstyle(:title, bold = true), h2_style = Tachikoma.tstyle(:accent, bold = true),
                                  h3_style = Tachikoma.tstyle(:primary, bold = true), code_style = Tachikoma.tstyle(:success),
                                  text_style = Tachikoma.tstyle(:text), quote_style = Tachikoma.tstyle(:text_dim))
    # a table row wider than the area continues on the next line
    pane.pane.word_wrap = true
    return pane
end

"""
    JuLeAna.reports_result!(page::ReportsPage, answer)

Take the `answer` to a request of `page` as [`JuLeAna.read_reports`](@ref) returns it. The
answer to a read of the reports replaces the groups of `page`, or sets its `error`, unless
the page has read the reports anew since; likewise an answer with failures is dropped if the
groups changed. The viewer of the report file opens if the report is still the open one, else
it is dropped.
"""
function reports_result!(page::ReportsPage, answer)
    (; request) = answer
    failed = haskey(answer, :error)
    if request.kind === :index
        request.generation == page.generation || return nothing
        page.reading = false
        page.error = failed ? answer.error : nothing
        failed && return nothing
        page.history = answer.history
        page.groups = request.source === :run ? run_groups(answer.value) : overview_groups(answer.value)
        page.loaded = true
        request_failures!(page)
    elseif request.kind === :failures
        request.generation == page.generation || return nothing
        delete!(page.pending, request.group)
        if failed
            page.error = answer.error
        else
            rows = answer.value
            page.summaries[request.group] = isempty(rows) ? [] : only(failure_summary(rows)).detectors
        end
    elseif request.path == page.viewer_path
        if failed
            page.viewer_message = answer.error
        elseif isnothing(answer.value)
            page.viewer_message = "No report file: $(request.path)"
        else
            page.viewer = answer.value
        end
    end
    return nothing
end

# What the data of the page was read for: `nothing` while no session is loaded, else the
# start and end of the last processing run.
function reports_mark(snap)
    return isnothing(snap) || snap.state in (:idle, :loading) ? nothing : (snap.outcome, snap.started, snap.finished)
end

"""
    JuLeAna.reports_visit!(page::ReportsPage, snap)

Queue a read of the reports if the page is visible for the first time or the controller
snapshot `snap` (or `nothing`) shows a loaded session or a processing run that started or
finished since the shown reports were read.
"""
function reports_visit!(page::ReportsPage, snap)
    mark = reports_mark(snap)
    if !page.visited || mark != page.mark
        page.visited, page.mark = true, mark
        request_reports!(page)
    end
    return nothing
end

function close_viewer!(page::ReportsPage)
    page.viewer_path = nothing
    page.viewer = nothing
    page.viewer_message = nothing
    filter!(r -> r.kind !== :open, page.requests)
    return nothing
end

function open_report!(page::ReportsPage, path::AbstractString)
    page.viewer_path, page.viewer, page.viewer_message = String(path), nothing, nothing
    push!(page.requests, (; kind = :open, path = String(path)))
    return nothing
end

"""
    JuLeAna.reports_key!(page::ReportsPage, evt::Tachikoma.KeyEvent)::Bool

Apply the key event `evt` to `page`. Return `true` if the key was used and `false`
otherwise.

While a report is open, the viewer uses every key: Up, Down, PageUp, PageDown, Home and End
scroll it, Escape and `q` close it, and other keys are ignored.

Otherwise:

  - Up, Down, PageUp, PageDown, Home and End move the cursor over the groups and reports,
    or scroll the failures while the failures have the focus. Tab and Shift-Tab switch the focus.
  - Enter on a group row toggles the group, on a report row opens the report. Left folds the
    group of the cursor row and moves the cursor to it, Right unfolds it.
  - `a` switches between all reports on disk and the reports of the steps of the current or
    last processing run, and reads them.
  - `r` reads the reports anew.
  - Other keys, such as `1` to `6` and `q`, are not used.
"""
function reports_key!(page::ReportsPage, evt::Tachikoma.KeyEvent)::Bool
    if !isnothing(page.viewer_path)
        evt.action == Tachikoma.key_release && return true
        if evt.key == :escape || (evt.key == :char && evt.char == 'q')
            close_viewer!(page)
        elseif !isnothing(page.viewer)
            Tachikoma.handle_key!(page.viewer, evt)
        end
        return true
    end
    evt.action == Tachikoma.key_release && return false
    used = handle_reports_key!(page, evt)
    request_failures!(page)
    return used
end

function handle_reports_key!(page::ReportsPage, evt::Tachikoma.KeyEvent)
    key = evt.key
    if key in (:tab, :backtab)
        page.focus = 3 - page.focus
    elseif key == :char && evt.char == 'a'
        page.source = page.source === :all ? :run : :all
        page.groups, page.loaded, page.error = Any[], false, nothing
        page.cursor, page.index, page.top = nothing, 1, 1
        request_reports!(page)
    elseif key == :char && evt.char == 'r'
        request_reports!(page)
    elseif key in (:up, :down, :pageup, :pagedown, :home, :end_key)
        if page.focus == 2
            delta = key == :up ? -1 :
                    key == :down ? 1 :
                    key == :pageup ? -page.fail_height :
                    key == :pagedown ? page.fail_height : key == :home ? -page.fail_lines : page.fail_lines
            scroll_failures!(page, delta)
        else
            rows = reports_rows(page)
            idx = sync_reports_cursor!(page, rows)
            delta = key == :up ? -1 :
                    key == :down ? 1 :
                    key == :pageup ? -page.height : key == :pagedown ? page.height : key == :home ? -length(rows) : length(rows)
            move_reports_cursor!(page, rows, idx + delta)
        end
    elseif key in (:left, :right, :enter) && page.focus == 1
        rows = reports_rows(page)
        idx = sync_reports_cursor!(page, rows)
        idx == 0 && return true
        if key == :enter && rows[idx].report
            open_report!(page, rows[idx].entry.path)
        elseif isnothing(rows[idx].group)
            return true
        else
            g = rows[idx].group
            unfold = key == :enter ? !rows[idx].unfolded : key == :right
            page.expanded[g.key] = unfold
            unfold || (page.cursor = (g.key,); page.index = findfirst(r -> r.key == page.cursor, rows))
        end
    else
        return false
    end
    return true
end

"""
    JuLeAna.reports_mouse!(page::ReportsPage, evt::Tachikoma.MouseEvent)::Bool

Apply the mouse event `evt` to `page`. While a report is open, the viewer gets the event
(the scroll wheel and the scroll bar). Otherwise the scroll wheel moves the cursor by one
row over the list of reports and scrolls the failures over the failures block, and a left
click on a row moves the cursor to it and folds or unfolds a group row. Return `true` if the
event was used.
"""
function reports_mouse!(page::ReportsPage, evt::Tachikoma.MouseEvent)::Bool
    if !isnothing(page.viewer_path)
        return !isnothing(page.viewer) && Tachikoma.handle_mouse!(page.viewer, evt) === true
    end
    evt.action == Tachikoma.mouse_press || return false
    used = false
    if evt.button == Tachikoma.mouse_left
        if Base.contains(page.list, evt.x, evt.y)
            rows = reports_rows(page)
            idx = page.top + evt.y - page.list.y
            if idx in eachindex(rows)
                page.focus = 1
                move_reports_cursor!(page, rows, idx)
                rows[idx].report || (page.expanded[rows[idx].group.key] = !rows[idx].unfolded)
                used = true
            end
        end
    elseif evt.button in (Tachikoma.mouse_scroll_up, Tachikoma.mouse_scroll_down)
        sign = evt.button == Tachikoma.mouse_scroll_up ? -1 : 1
        if Base.contains(page.rect, evt.x, evt.y)
            rows = reports_rows(page)
            move_reports_cursor!(page, rows, sync_reports_cursor!(page, rows) + sign)
            used = true
        elseif Base.contains(page.fail_rect, evt.x, evt.y)
            scroll_failures!(page, sign * REPORT_WHEEL_LINES)
            used = true
        end
    end
    request_failures!(page)
    return used
end

function report_group_spans(g, name_width, unfolded, with_missing)
    c = g.counts
    spans = [((unfolded ? "▾ " : "▸ ") * rpad(clip_text(g.name, name_width), name_width) * " ", Tachikoma.tstyle(:primary, bold = true)),
             (rpad(string(g.level), REPORT_LEVEL_WIDTH) * "  ", Tachikoma.tstyle(:text_dim)),
             (rpad(g.category, REPORT_CATEGORY_WIDTH) * "  ", something(setup_tag_style(g.category), Tachikoma.tstyle(:text_dim))),
             ("ok $(c.ok)", Tachikoma.tstyle(REPORT_COLORS.ok)), ("  warn $(c.warning)", Tachikoma.tstyle(REPORT_COLORS.warning)),
             ("  fail $(c.failed)", Tachikoma.tstyle(REPORT_COLORS.failed))]
    with_missing && push!(spans, ("  miss $(c.missing)", Tachikoma.tstyle(REPORT_COLORS.missing)))
    return spans
end

function report_counts_text(c, with_missing)
    return "ok $(c.ok)  warn $(c.warning)  fail $(c.failed)" * (with_missing ? "  miss $(c.missing)" : "")
end

function history_spans()
    return [("▪ ", Tachikoma.tstyle(:primary, bold = true)), ("Processing history", Tachikoma.tstyle(:primary, bold = true))]
end

report_label(r) = isnothing(r.run) ? r.period : "$(r.period)-$(r.run)"

function report_spans(r, label_width)
    state = r.state
    color = Tachikoma.tstyle(REPORT_COLORS[state])
    spans = [("    ", Tachikoma.tstyle(:text)),
             (rpad(clip_text(report_label(r), label_width), label_width) * "  ", Tachikoma.tstyle(:text_bright)),
             (rpad(REPORT_ICONS[state] * " " * string(state), 9), color)]
    isnothing(r.date) || push!(spans, ("  " * Dates.format(r.date, dateformat"mm-dd HH:MM") * "Z", Tachikoma.tstyle(:text_dim)))
    return spans
end

# Widths of the name and the counts of the group rows.
function report_columns(page::ReportsPage)
    return (; name = maximum(textwidth(g.name) for g in page.groups),
            counts = maximum(textwidth(report_counts_text(g.counts, page.source === :run)) for g in page.groups))
end

function render_report_list(page::ReportsPage, area, buf)
    page.rect = area
    page.list = Tachikoma.Rect(area.x, area.y, 0, 0)
    page.height = 1
    (area.width < 3 || area.height < 3) && return nothing
    with_missing = page.source === :run
    inner = Tachikoma.render(pane_block(with_missing ? "Reports (current run)" : "Reports (all on disk)", page.focus == 1), area, buf)
    x_max = Tachikoma.right(inner)
    dim = Tachikoma.tstyle(:text_dim)
    if !isnothing(page.error)
        Tachikoma.set_string!(buf, inner.x, inner.y, page.error, Tachikoma.tstyle(:error); max_x = x_max)
        return nothing
    end
    if !page.loaded
        Tachikoma.set_string!(buf, inner.x, inner.y, "Reading reports…", dim; max_x = x_max)
        return nothing
    end
    rows = reports_rows(page)
    if isempty(rows)
        Tachikoma.set_string!(buf, inner.x, inner.y, with_missing ? "No processing run yet." : "No reports.", dim; max_x = x_max)
        return nothing
    end
    height = max(1, inner.height - (inner.height >= 3))
    page.list = Tachikoma.Rect(inner.x, inner.y, inner.width, height)
    page.height = height
    idx = sync_reports_cursor!(page, rows)
    page.top = clamp(page.top, 1, max(1, length(rows) - height + 1))
    idx < page.top && (page.top = idx)
    idx > page.top + height - 1 && (page.top = idx - height + 1)

    name_width = clamp(report_columns(page).name, 1,
                       max(8, inner.width - 4 - REPORT_LEVEL_WIDTH - 2 - REPORT_CATEGORY_WIDTH - report_columns(page).counts))
    label_width = clamp(maximum((textwidth(report_label(r)) for g in page.groups for r in g.reports); init = 1), 1, max(1, inner.width ÷ 3))
    highlight = Tachikoma.tstyle(:border)
    for r in 0:(height - 1)
        row = page.top + r
        row <= length(rows) || break
        entry = rows[row]
        spans = isnothing(entry.group) ? history_spans() :
                entry.report ? report_spans(entry.entry, label_width) :
                report_group_spans(entry.entry, name_width, entry.unfolded, with_missing)
        put_spans!(buf, inner.x, inner.y + r, x_max, spans, row == idx ? highlight : nothing)
    end
    if inner.height >= 3
        status = page.reading ? "Reading reports…" :
                 "$(length(page.groups)) processors, $(sum(length(g.reports) for g in page.groups)) reports"
        Tachikoma.set_string!(buf, inner.x, Tachikoma.bottom(inner), status, dim; max_x = x_max)
    end
    return nothing
end

# Lines of the failures pane: per detector its name, the runs it failed in and its errors.
function failure_lines(page::ReportsPage, g)
    dim = Tachikoma.tstyle(:text_dim)
    g.counts.failed == 0 && return [[("No failures.", dim)]]
    detectors = if haskey(page.summaries, g.key)
        page.summaries[g.key]
    elseif page.source === :run
        page.summaries[g.key] = only(failure_summary(g.rows)).detectors
    else
        return [[("Reading failures…", dim)]]
    end
    isempty(detectors) && return [[("No failures.", dim)]]
    noun = g.level === :partition ? "period" : "run"
    lines = Vector{Tuple{String,Tachikoma.Style}}[]
    for d in detectors
        n = length(d.labels)
        push!(lines,
              [(d.detector, Tachikoma.tstyle(:text_bright, bold = true)),
               ("  $n $noun" * (n == 1 ? "" : "s") * ": " * join(d.labels, ", "), Tachikoma.tstyle(:text))])
        for err in d.errors
            push!(lines, [("    " * replace(err, '\n' => ' '), Tachikoma.tstyle(:error))])
        end
    end
    return lines
end

function render_failures(page::ReportsPage, area, buf)
    page.fail_rect = area
    page.fail_height, page.fail_lines = 1, 0
    (area.width < 3 || area.height < 3) && return nothing
    g = page.loaded && isnothing(page.error) ? cursor_group(page) : nothing
    title = isnothing(g) ? "Failures" : "Failures: $(g.name) $(g.level) $(g.category)"
    inner = Tachikoma.render(pane_block(clip_text(title, max(0, area.width - 6)), page.focus == 2), area, buf)
    isnothing(g) && return nothing
    if g.key != page.fail_group
        page.fail_top, page.fail_group = 1, g.key
    end
    lines = failure_lines(page, g)
    page.fail_height, page.fail_lines = inner.height, length(lines)
    page.fail_top = clamp(page.fail_top, 1, last_top(length(lines), inner.height))
    for r in 0:(inner.height - 1)
        page.fail_top + r <= length(lines) || break
        put_spans!(buf, inner.x, inner.y + r, Tachikoma.right(inner), lines[page.fail_top + r])
    end
    return nothing
end

function render_viewer(page, area, buf)
    if !isnothing(page.viewer)
        Tachikoma.render(page.viewer, area, buf)
        return nothing
    end
    (area.width < 3 || area.height < 3) && return nothing
    inner = Tachikoma.render(pane_block(basename(page.viewer_path), true), area, buf)
    message = something(page.viewer_message, "Reading report…")
    style = Tachikoma.tstyle(isnothing(page.viewer_message) ? :text_dim : :error)
    Tachikoma.set_string!(buf, inner.x, inner.y, message, style; max_x = Tachikoma.right(inner))
    return nothing
end

"""
    JuLeAna.render_reports(page::ReportsPage, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the Reports page into `area` of `buf`. The left block, about 45% of the width, lists the
reports grouped by processor: a group row shows the fold arrow, the name, the level, the
category and the number of reports that are ok, have warnings, failed and (for the current run) are missing; the
rows of an unfolded group show the period and run, the state and the processing date in UTC. The
right block shows the failures of the processor under the cursor, per detector the runs it
failed in and its distinct errors. The block with the focus has a heavy border. While a read is
under way the page says `Reading reports…`, and the error of a failed read replaces the list.

While a report is open the viewer, a `Tachikoma.MarkdownPane` titled with the file name, fills
the whole area; a missing file shows `No report file: <path>`.
"""
function render_reports(page::ReportsPage, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    if !isnothing(page.viewer_path)
        render_viewer(page, area, buf)
        return nothing
    end
    # 45% of the width, more (up to 60%) if the group rows need it
    left_width = round(Int, 0.45 * area.width)
    if page.loaded && isnothing(page.error) && !isempty(page.groups)
        cols = report_columns(page)
        left_width = clamp(2 + 2 + cols.name + 1 + REPORT_LEVEL_WIDTH + 2 + REPORT_CATEGORY_WIDTH + 2 + cols.counts + 2, left_width,
                           round(Int, 0.6 * area.width))
    end
    render_report_list(page, Tachikoma.Rect(area.x, area.y, left_width, area.height), buf)
    render_failures(page, Tachikoma.Rect(area.x + left_width, area.y, area.width - left_width, area.height), buf)
    return nothing
end
