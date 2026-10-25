# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Icon and theme color of a cell that comes from the processing history.
const HISTORY_ICONS = (failed = "■", stopped = "s", cancelled = "c")
const HISTORY_COLORS = (failed = :error, stopped = :warning, cancelled = :text_dim)

# Width of the cell of a run in characters, and the space between two cells.
const HISTORY_CELL_WIDTH = 3
const HISTORY_CELL_STEP = HISTORY_CELL_WIDTH + 1

# Rows scrolled by one step of the mouse wheel.
const HISTORY_WHEEL_ROWS = 1

# A run column of the History page: the index `p` of its period in `grid.periods`, the run,
# its position `k` (from 0) among the `n` columns of the period and its header text.
struct HistoryColumn
    p::Int
    run::DataRun
    k::Int
    n::Int
    label::String
end

# Text and theme color of a cell as drawn: the icon between spaces, or the slice of the
# bracketed icon that a run column shows of a partition-level cell.
const HistoryLook = NamedTuple{(:text, :color),Tuple{String,Symbol}}

"""
    HistoryPage()

State of the History page of the terminal user interface: the grid of the processing state
of every processor (rows) in every run (columns, grouped by period) as
[`JuLeAna.history_grid`](@ref) returns it, the cursor cell, the scroll position, the open
report and the requests for reading the file system.

The columns are the periods and runs that the session has selected, or, with `all_runs`
(toggled by `a`), all periods and runs of the data production. Everything the drawing needs
about the grid (column headers, row labels, the text and color of each cell) is computed
when the grid, `all_runs` or the selection changes, not when the page is drawn.
Keys are handled by [`JuLeAna.history_key!`](@ref) and [`JuLeAna.history_mouse!`](@ref), the
page is drawn by [`JuLeAna.render_history`](@ref).

The page never reads the file system. It queues requests (see [`JuLeAna.take_requests!`](@ref))
that the interface carries out in the background and answers with [`JuLeAna.history_result!`](@ref).
The cursor is a row and a run column; on a partition-level row the cell is that of the period of the column.
"""
mutable struct HistoryPage
    grid::Union{Nothing,NamedTuple}
    # one `(; p, run)` per run column: index of its period in `grid.periods` and the run
    columns::Vector{HistoryColumn}
    # offset in characters of each column from the first one
    offsets::Vector{Int}
    # whether all runs of the production are shown instead of the selected ones
    all_runs::Bool
    # selected runs of each selected period, as `selected_period_runs` returns them
    selection::Union{Nothing,Dict{DataPeriod,Vector{DataRun}}}
    # label of each row with the marker of partition-level rows, and the widest row name
    labels::Vector{String}
    label_width::Int
    # `looks[row, column]`
    looks::Matrix{HistoryLook}
    # whether a read of the grid is under way
    reading::Bool
    error::Union{Nothing,String}
    # number of the latest read of the grid; answers to older reads are dropped
    generation::Int
    # the controller state the grid was read for
    mark::Any
    # cursor row, cursor column (index into `columns`), first displayed row and column
    row::Int
    col::Int
    top::Int
    left::Int
    # rows displayed per page at the last render
    height::Int
    # path of the open report, its viewer once read, and a message instead of the viewer
    viewer_path::Union{Nothing,String}
    viewer::Union{Nothing,Tachikoma.MarkdownPane}
    viewer_message::Union{Nothing,String}
    const requests::Vector{Any}
    # areas of the page and of the cells at the last render
    rect::Tachikoma.Rect
    cells::Tachikoma.Rect
end

function HistoryPage()
    return HistoryPage(nothing, HistoryColumn[], Int[], false, nothing, String[], 0, Matrix{HistoryLook}(undef, 0, 0), false, nothing, 0,
                       nothing, 1, 1, 1, 1, 1, nothing, nothing, nothing, Any[], Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0))
end

"""
    JuLeAna.take_requests!(page::HistoryPage)

Return the requests of `page` for reading the file system and clear them. A request is a
named tuple with `kind` `:grid` (read the grid) or `:open` (read the report file `path`).
[`JuLeAna.read_history_page`](@ref) carries a request out and [`JuLeAna.history_result!`](@ref)
takes its answer.
"""
function take_requests!(page::HistoryPage)
    requests = copy(page.requests)
    empty!(page.requests)
    return requests
end

"""
    JuLeAna.read_history_page(ctrl::DataflowController, request)

Carry out a request of a [`JuLeAna.HistoryPage`](@ref) (see [`JuLeAna.take_requests!`](@ref))
and return `(; request, value)`, or `(; request, error)` with the message of the exception
if the read failed. The value of a `:grid` request is `history_grid(ctrl)` (see
[`JuLeAna.history_grid`](@ref)), that of an `:open` request the viewer of the report file's
text, or `nothing` if there is no such file. The viewer is built here, so that converting the
text does not hold up the interface.
"""
function read_history_page(ctrl::DataflowController, request)
    value = try
        if request.kind === :grid
            history_grid(ctrl)
        else
            isfile(request.path) ? report_viewer(request.path, read(request.path, String)) : nothing
        end
    catch e
        return (; request, error = first(split(sprint(showerror, e), '\n')))
    end
    return (; request, value)
end

# Run number without the leading `r` and zeros, `0` for run 0.
function run_number(run)
    s = lstrip(chopprefix(string(run), "r"), '0')
    return isempty(s) ? "0" : s
end

# The slice of the partition-level cell with `icon` that the `k`-th (from 0) of `n` run
# columns shows: the icon centered between brackets over the width of the `n` columns.
function partition_slot(icon, n, k)
    width = HISTORY_CELL_STEP * n - 1
    left = (width - 3) ÷ 2
    chars = (HISTORY_CELL_STEP * k + 1):min(HISTORY_CELL_STEP * (k + 1), width)
    return String([i == 1 ? '[' : i == width ? ']' : i == left + 2 ? only(icon) : ' ' for i in chars])
end

# Compute the columns, their offsets, the row labels and the looks of the cells of
# `page.grid` for the shown runs: all of them with `page.all_runs`, else the selected ones.
# One extra character separates two periods.
function history_layout!(page::HistoryPage)
    (; grid, selection) = page
    columns = HistoryColumn[]
    for (p, entry) in pairs(grid.periods)
        runs = page.all_runs ? entry.runs : filter(in(get(selection, entry.period, DataRun[])), entry.runs)
        append!(columns,
                HistoryColumn(p, run, k - 1, length(runs), lpad(run_number(run), HISTORY_CELL_WIDTH)) for (k, run) in enumerate(runs))
    end
    offsets = zeros(Int, length(columns))
    for c in 2:length(columns)
        offsets[c] = offsets[c - 1] + HISTORY_CELL_STEP + (columns[c].p != columns[c - 1].p)
    end
    page.columns, page.offsets = columns, offsets
    page.labels = [(row.level === :partition ? "p " : "  ") * history_row_label(row) for row in grid.rows]
    page.label_width = maximum(textwidth(history_row_label(row)) for row in grid.rows; init = 0)
    page.looks = Matrix{HistoryLook}(undef, length(grid.rows), length(columns))
    for (i, row) in pairs(grid.rows), (c, col) in pairs(columns)

        period = grid.periods[col.p].period
        if row.level === :partition
            icon, color = history_look(get(row.cells, (period, nothing), nothing))
            page.looks[i, c] = (; text = partition_slot(icon, col.n, col.k), color)
        else
            icon, color = history_look(get(row.cells, (period, col.run), nothing))
            page.looks[i, c] = (; text = " " * icon * " ", color)
        end
    end
    clamp_history_cursor!(page)
    return nothing
end

# Keep the cursor inside the grid.
function clamp_history_cursor!(page::HistoryPage)
    isnothing(page.grid) && return nothing
    page.row = clamp(page.row, 1, max(1, length(page.grid.rows)))
    page.col = clamp(page.col, 1, max(1, length(page.columns)))
    return nothing
end

"""
    JuLeAna.history_result!(page::HistoryPage, answer)

Take the `answer` to a request of `page` as [`JuLeAna.read_history_page`](@ref) returns it.
The answer to a read of the grid replaces the grid of `page`, or sets its `error`, unless
the page has read the grid anew since. The viewer of the report file opens if the report is
still the open one, else it is dropped.
"""
function history_result!(page::HistoryPage, answer)
    (; request) = answer
    failed = haskey(answer, :error)
    if request.kind === :grid
        request.generation == page.generation || return nothing
        page.reading = false
        page.error = failed ? answer.error : nothing
        failed && return nothing
        page.grid = answer.value
        history_layout!(page)
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

# Queue a read of the grid.
function request_history!(page::HistoryPage)
    page.generation += 1
    page.reading = true
    filter!(r -> r.kind !== :grid, page.requests)
    push!(page.requests, (; kind = :grid, page.generation))
    return nothing
end

"""
    JuLeAna.history_visit!(page::HistoryPage, snap)

Queue a read of the grid if the controller snapshot `snap` (or `nothing`) shows a loaded
session or a processing run that started or finished since the shown grid was read. While
no session is loaded the page drops its grid. A change of the selected periods and runs of
`snap` changes the shown columns without a new read.
"""
function history_visit!(page::HistoryPage, snap)
    mark = reports_mark(snap)
    selection = isnothing(mark) ? nothing : selected_period_runs(snap)
    if selection != page.selection
        page.selection = selection
        isnothing(page.grid) || isnothing(selection) || history_layout!(page)
    end
    mark == page.mark && return nothing
    page.mark = mark
    if isnothing(mark)
        page.grid, page.error, page.reading = nothing, nothing, false
        page.generation += 1
        filter!(r -> r.kind !== :grid, page.requests)
    else
        request_history!(page)
    end
    return nothing
end

function close_viewer!(page::HistoryPage)
    page.viewer_path = nothing
    page.viewer = nothing
    page.viewer_message = nothing
    filter!(r -> r.kind !== :open, page.requests)
    return nothing
end

function open_report!(page::HistoryPage, path::AbstractString)
    page.viewer_path, page.viewer, page.viewer_message = String(path), nothing, nothing
    push!(page.requests, (; kind = :open, path = String(path)))
    return nothing
end

"""
    JuLeAna.history_selection(page::HistoryPage)

Return the cell under the cursor of `page` as `(; row, period, run, label, cell)`, where `row` is the
row of the grid, `run` is `nothing` on a partition-level row, `label` is `p02-r008` or `p02`
and `cell` is the entry of the grid or `nothing` if the processor never processed it. Return
`nothing` if the page has no cells.
"""
function history_selection(page::HistoryPage)
    (isnothing(page.grid) || isempty(page.grid.rows) || isempty(page.columns)) && return nothing
    row = page.grid.rows[clamp(page.row, 1, length(page.grid.rows))]
    col = page.columns[clamp(page.col, 1, length(page.columns))]
    period = page.grid.periods[col.p].period
    run = row.level === :partition ? nothing : col.run
    return (; row, period, run, label = isnothing(run) ? string(period) : "$period-$run", cell = get(row.cells, (period, run), nothing))
end

# Spans of the line that describes the cell under the cursor.
function history_detail(page::HistoryPage)
    sel = history_selection(page)
    isnothing(sel) && return Tuple{String,Tachikoma.Style}[]
    (; row, label, cell) = sel
    spans = [(history_row_label(row) * "  ", Tachikoma.tstyle(:text_bright, bold = true)), (label * "  ", Tachikoma.tstyle(:text))]
    if isnothing(cell)
        push!(spans, ("never processed", Tachikoma.tstyle(REPORT_COLORS.missing)))
        return spans
    end
    color = cell.source === :report ? REPORT_COLORS[cell.state] : HISTORY_COLORS[cell.state]
    date = isnothing(cell.date) ? "date unknown" : Dates.format(cell.date, dateformat"yyyy-mm-dd HH:MM") * " UTC"
    source = cell.source === :report ? "report" : "history, log folder $(cell.path)"
    push!(spans, (string(cell.state) * "  ", Tachikoma.tstyle(color)), (date * "  ", Tachikoma.tstyle(:text)),
          (source, Tachikoma.tstyle(:text_dim)))
    return spans
end

# Name of a processor row: its short name and category.
history_row_label(row) = display_name(row.process) * " " * string(row.category)

# Move the cursor by `drow` rows and `dcol` columns.
function move_history_cursor!(page::HistoryPage, drow, dcol)
    isnothing(page.grid) && return nothing
    page.row = clamp(page.row + drow, 1, max(1, length(page.grid.rows)))
    page.col = clamp(page.col + dcol, 1, max(1, length(page.columns)))
    return nothing
end

# Move the cursor to the first column of the previous (`step = -1`) or next period.
function move_history_period!(page::HistoryPage, step)
    isempty(page.columns) && return nothing
    p = page.columns[clamp(page.col, 1, length(page.columns))].p
    first_col = findfirst(c -> c.p == p, page.columns)
    if step < 0
        first_col > 1 && (page.col = findfirst(c -> c.p == page.columns[first_col - 1].p, page.columns))
    else
        next = findnext(c -> c.p != p, page.columns, first_col)
        isnothing(next) || (page.col = next)
    end
    return nothing
end

# Whether the cursor row is a partition-level row.
function partition_row(page::HistoryPage)
    sel = history_selection(page)
    return !isnothing(sel) && sel.row.level === :partition
end

"""
    JuLeAna.history_key!(page::HistoryPage, evt::Tachikoma.KeyEvent)::Bool

Apply the key event `evt` to `page`. Return `true` if the key was used and `false`
otherwise.

While a report is open, the viewer uses every key: Up, Down, PageUp, PageDown, Home and End
scroll it, Escape and `q` close it, and other keys are ignored.

Otherwise:

  - Up and Down move the cursor by one row, PageUp and PageDown by a page of rows.
  - Left and Right move the cursor by one run, on a partition-level row by one period.
    Home and End move it to the first and the last run.
  - Enter on a cell that comes from a report opens the report.
  - `r` reads the grid anew.
  - `a` switches between the selected periods and runs of the session (the default) and
    all periods and runs of the data production.
  - Other keys, such as `1` to `7` and `q`, are not used.
"""
function history_key!(page::HistoryPage, evt::Tachikoma.KeyEvent)::Bool
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
    key = evt.key
    if key == :up
        move_history_cursor!(page, -1, 0)
    elseif key == :down
        move_history_cursor!(page, 1, 0)
    elseif key == :pageup
        move_history_cursor!(page, -page.height, 0)
    elseif key == :pagedown
        move_history_cursor!(page, page.height, 0)
    elseif key in (:left, :right)
        step = key == :left ? -1 : 1
        partition_row(page) ? move_history_period!(page, step) : move_history_cursor!(page, 0, step)
    elseif key == :home
        page.col = 1
    elseif key == :end_key
        page.col = max(1, length(page.columns))
    elseif key == :enter
        sel = history_selection(page)
        !isnothing(sel) && !isnothing(sel.cell) && sel.cell.source === :report && open_report!(page, sel.cell.path)
    elseif key == :char && evt.char == 'r'
        request_history!(page)
    elseif key == :char && evt.char == 'a'
        page.all_runs = !page.all_runs
        isnothing(page.grid) || history_layout!(page)
    else
        return false
    end
    return true
end

"""
    JuLeAna.history_mouse!(page::HistoryPage, evt::Tachikoma.MouseEvent)::Bool

Apply the mouse event `evt` to `page`. While a report is open, the viewer gets the event
(the scroll wheel and the scroll bar). Otherwise a left click on a cell moves the cursor
to it and the scroll wheel moves the cursor by one row. Return `true` if the event was used.
"""
function history_mouse!(page::HistoryPage, evt::Tachikoma.MouseEvent)::Bool
    if !isnothing(page.viewer_path)
        return !isnothing(page.viewer) && Tachikoma.handle_mouse!(page.viewer, evt) === true
    end
    evt.action == Tachikoma.mouse_press || return false
    isnothing(page.grid) && return false
    if evt.button == Tachikoma.mouse_left
        Base.contains(page.cells, evt.x, evt.y) || return false
        row = page.top + evt.y - page.cells.y
        row in eachindex(page.grid.rows) || return false
        isempty(page.columns) && return false
        x = evt.x - page.cells.x + page.offsets[clamp(page.left, 1, length(page.columns))]
        col = findlast(<=(x), page.offsets)
        (isnothing(col) || x > page.offsets[col] + HISTORY_CELL_WIDTH - 1) && return false
        page.row, page.col = row, col
        return true
    elseif evt.button in (Tachikoma.mouse_scroll_up, Tachikoma.mouse_scroll_down) && Base.contains(page.rect, evt.x, evt.y)
        move_history_cursor!(page, (evt.button == Tachikoma.mouse_scroll_up ? -1 : 1) * HISTORY_WHEEL_ROWS, 0)
        return true
    end
    return false
end

# Icon and theme color of `cell`; `nothing` stands for a cell that was never processed.
function history_look(cell)
    isnothing(cell) && return REPORT_ICONS.missing, REPORT_COLORS.missing
    return cell.source === :report ? (REPORT_ICONS[cell.state], REPORT_COLORS[cell.state]) :
           (HISTORY_ICONS[cell.state], HISTORY_COLORS[cell.state])
end

# Legend of the icons.
const HISTORY_LEGEND = [("report: ", :text_dim), (REPORT_ICONS.ok * " ok  ", REPORT_COLORS.ok),
                        (REPORT_ICONS.warning * " warning  ", REPORT_COLORS.warning),
                        (REPORT_ICONS.failed * " failed  ", REPORT_COLORS.failed),
                        (REPORT_ICONS.missing * " never  ", REPORT_COLORS.missing), ("history: ", :text_dim),
                        (HISTORY_ICONS.failed * " failed  ", HISTORY_COLORS.failed),
                        (HISTORY_ICONS.stopped * " stopped  ", HISTORY_COLORS.stopped),
                        (HISTORY_ICONS.cancelled * " cancelled  ", HISTORY_COLORS.cancelled), ("[ ] partition", :text_dim)]

# Draw the grid of `page` into `inner`, the area inside the block.
function render_history_grid(page::HistoryPage, inner, buf)
    x_max = Tachikoma.right(inner)
    (; rows, periods) = page.grid
    if isempty(rows) || isempty(page.columns)
        Tachikoma.set_string!(buf, inner.x, inner.y, "No processors or runs.", Tachikoma.tstyle(:text_dim); max_x = x_max)
        return nothing
    end
    height = inner.height - 4
    height < 1 && return nothing
    name_width = clamp(page.label_width + 2, 4, max(4, inner.width ÷ 3))
    gx, gy = inner.x + name_width + 1, inner.y + 2
    avail = x_max - gx + 1
    avail < HISTORY_CELL_WIDTH && return nothing
    clamp_history_cursor!(page)
    offsets, columns = page.offsets, page.columns
    # scroll to keep the cursor visible
    fits(first, c) = offsets[c] - offsets[first] + HISTORY_CELL_WIDTH <= avail
    page.left = clamp(page.left, 1, length(columns))
    page.col < page.left && (page.left = page.col)
    while !fits(page.left, page.col) && page.left < page.col
        page.left += 1
    end
    page.top = clamp(page.top, 1, max(1, length(rows) - height + 1))
    page.row < page.top && (page.top = page.row)
    page.row > page.top + height - 1 && (page.top = page.row - height + 1)
    page.height = height
    page.cells = Tachikoma.Rect(gx, gy, avail, height)
    last_col = something(findlast(c -> fits(page.left, c), page.left:length(columns)), 1) + page.left - 1
    shift = offsets[page.left]
    # headers: the period over its runs, then the run numbers
    c = page.left
    while c <= last_col
        p, first_c = columns[c].p, c
        c = min(last_col, c + columns[c].n - columns[c].k - 1)
        x = gx + offsets[first_c] - shift
        span = offsets[c] - offsets[first_c] + HISTORY_CELL_WIDTH
        Tachikoma.set_string!(buf, x, inner.y, clip_text(string(periods[p].period), span),
                              Tachikoma.tstyle(isodd(p) ? :primary : :accent, bold = true); max_x = x_max)
        c += 1
    end
    dim = Tachikoma.tstyle(:text_dim)
    for c in page.left:last_col
        Tachikoma.set_string!(buf, gx + offsets[c] - shift, inner.y + 1, columns[c].label, dim; max_x = x_max)
    end
    highlight = Tachikoma.tstyle(:border)
    cursor_p = columns[page.col].p
    for r in 0:(height - 1)
        i = page.top + r
        i <= length(rows) || break
        y = gy + r
        name = clip_text(page.labels[i], name_width)
        Tachikoma.set_string!(buf, inner.x, y, name, Tachikoma.tstyle(i == page.row ? :text_bright : :text, bold = i == page.row);
                              max_x = x_max)
        partition = rows[i].level === :partition
        for c in page.left:last_col
            x = gx + offsets[c] - shift
            (; text, color) = page.looks[i, c]
            selected = i == page.row && (partition ? columns[c].p == cursor_p : c == page.col)
            span = [(text, Tachikoma.tstyle(color, bold = !partition))]
            put_spans!(buf, x, y, min(x_max, x + textwidth(text) - 1), span, selected ? highlight : nothing)
        end
    end
    legend = [(text, Tachikoma.tstyle(color)) for (text, color) in HISTORY_LEGEND]
    put_spans!(buf, inner.x, Tachikoma.bottom(inner) - 1, x_max, legend)
    put_spans!(buf, inner.x, Tachikoma.bottom(inner), x_max, history_detail(page))
    return nothing
end

"""
    JuLeAna.render_history(page::HistoryPage, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the History page into `area` of `buf`. The grid has a row per processor, named after
the processor and its category (`p ` marks a partition-level processor), and a column per
run with the period over its runs. A run cell shows an icon: for a report `✓` ok, `!`
warning or `✗` failed; for a step of the processing history that left no newer report `■`
failed, `s` stopped or `c` cancelled; `–` if the processor never processed the run. A
partition-level cell spans the runs of its period, as `[ ✓ ]`. The cell under the cursor
is highlighted, the grid scrolls to keep it visible while the names stay in place, and the
last two lines show the legend and the description of the cell under the cursor: processor, period and run,
state, processing date in UTC and source. While no session is loaded or a read is under way the page says so, and
the error of a failed read replaces the grid. The title says whether the columns are the
selected runs or all runs (`a`).

While a report is open the viewer, a `Tachikoma.MarkdownPane` titled with the file name, fills
the whole area.
"""
function render_history(page::HistoryPage, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    page.rect = area
    page.cells = Tachikoma.Rect(area.x, area.y, 0, 0)
    page.height = 1
    if !isnothing(page.viewer_path)
        render_viewer(page, area, buf)
        return nothing
    end
    (area.width < 3 || area.height < 3) && return nothing
    title = "History, " * (page.all_runs ? "all runs" : "selected runs") * (page.reading && !isnothing(page.grid) ? " (reading…)" : "")
    inner = Tachikoma.render(pane_block(title, true), area, buf)
    x_max = Tachikoma.right(inner)
    message(text, color) = Tachikoma.set_string!(buf, inner.x, inner.y, text, Tachikoma.tstyle(color); max_x = x_max)
    if !isnothing(page.error)
        message(page.error, :error)
    elseif isnothing(page.mark)
        message("No session loaded.", :text_dim)
    elseif isnothing(page.grid)
        message("Reading history…", :text_dim)
    else
        render_history_grid(page, inner, buf)
    end
    return nothing
end
