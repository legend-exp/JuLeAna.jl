# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Direction bits of a cell of the line drawing, and the box character of each combination
# (indexed by the bits plus one).
const DIR_N, DIR_S, DIR_E, DIR_W = 0x01, 0x02, 0x04, 0x08
const BOX_CHARS = (' ', '│', '│', '│', '─', '└', '┌', '├', '─', '┘', '┐', '┤', '─', '┴', '┬', '┼')

# Width of the checkbox and the state icon after a processor name: ` [x] ✓`.
const GRAPH_DECOR = 6

"""
    GraphPage()

State of the Graph page of the terminal user interface: the processor under the cursor,
the first displayed row, whether unselected processors are shown, and the
[`ProcessorGraph`](@ref) of the processors of the latest snapshot. The page draws the run-level
processors in a left lane and the partition-level processors in a right lane, one row per
processor in the order [`topological_order`](@ref) gives. Keys are handled by
[`JuLeAna.graph_key!`](@ref) and [`JuLeAna.graph_mouse!`](@ref), the page is drawn by
[`JuLeAna.render_graph`](@ref).

The state icon of a processor is that of the last processing run, or, while `disk` is
`true`, that of its reports and processing history on disk.

The cursor is identified by the processor name, so that it stays on its processor when the
rows change. The graph is rebuilt only when the names, levels, ranks or dependencies of the
processors change.
"""
mutable struct GraphPage
    cursor::Union{Nothing,Symbol}
    # row index of the cursor at the last use, the fallback when the cursor row vanishes
    index::Int
    # index of the first displayed row
    top::Int
    # rows displayed per page at the last render
    height::Int
    show_unselected::Bool
    # whether the state icons show the state on disk instead of the last run
    disk::Bool
    # `(key, graph)` of the processors the graph was built for
    cached::Any
    # area of the block and the part of it that holds the rows at the last render
    rect::Tachikoma.Rect
    list::Tachikoma.Rect
end

function GraphPage()
    return GraphPage(nothing, 1, 1, 1, true, false, nothing, Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0))
end

# The `ProcessorGraph` of the processors in `snap`, rebuilt when their layout changed.
function page_graph!(page::GraphPage, snap)
    key = [(p.name, p.level, p.rank, copy(p.dependencies)) for p in snap.processors]
    if isnothing(page.cached) || page.cached[1] != key
        page.cached = (key, processor_graph(snap.processors))
    end
    return page.cached[2]
end

# Names of the displayed processors in topological order; empty while no session is loaded.
function graph_rows(page::GraphPage, snap)
    (isnothing(snap) || isempty(snap.processors)) && return Symbol[]
    selected = Set(vcat(snap.run_steps, snap.partition_steps))
    return [n for n in topological_order(page_graph!(page, snap)) if page.show_unselected || n in selected]
end

# Index of the cursor row in `rows` (0 if there are none), moving the cursor to the
# nearest row when its row vanished.
function sync_graph_cursor!(page::GraphPage, rows)
    isempty(rows) && return 0
    idx = something(findfirst(==(page.cursor), rows), clamp(page.index, 1, length(rows)))
    page.cursor, page.index = rows[idx], idx
    return idx
end

function move_graph_cursor!(page::GraphPage, rows, idx)
    isempty(rows) && return nothing
    page.index = clamp(idx, 1, length(rows))
    page.cursor = rows[page.index]
    return nothing
end

# The `SelectSteps` command for the processors of `snap` in `chosen`.
function steps_command(snap, chosen)
    return SelectSteps([p.name for p in snap.processors if p.level === :run && p.name in chosen],
                       [p.name for p in snap.processors if p.level === :partition && p.name in chosen])
end

"""
    JuLeAna.graph_key!(page::GraphPage, evt::Tachikoma.KeyEvent, snap, send)::Bool

Apply the key event `evt` to `page` for the controller snapshot `snap` (or `nothing`);
`send(cmd)` sends a controller command. Return `true` if the key was used and `false`
otherwise.

  - Up, Down, PageUp, PageDown, Home and End move the cursor over the processors.
  - Space adds the processor under the cursor to the selected steps, or removes it, and
    sends the new selection as [`SelectSteps`](@ref).
  - `d` adds the processors that the selected steps require, as the Setup page does.
  - `h` hides or shows the processors that are not selected.
  - `v` switches the state icons between the last run and the state on disk.
  - Other keys and key releases are not used.
"""
function graph_key!(page::GraphPage, evt::Tachikoma.KeyEvent, snap, send)::Bool
    evt.action == Tachikoma.key_release && return false
    key = evt.key
    rows = graph_rows(page, snap)
    idx = sync_graph_cursor!(page, rows)
    delta = key == :up ? -1 :
            key == :down ? 1 :
            key == :pageup ? -page.height :
            key == :pagedown ? page.height : key == :home ? -length(rows) : key == :end_key ? length(rows) : nothing
    if !isnothing(delta)
        move_graph_cursor!(page, rows, idx + delta)
    elseif key == :char && evt.char == 'h'
        page.show_unselected = !page.show_unselected
    elseif key == :char && evt.char == 'v'
        page.disk = !page.disk
    elseif key == :char && evt.char == ' '
        if idx > 0
            chosen = Set(vcat(snap.run_steps, snap.partition_steps))
            name = rows[idx]
            name in chosen ? delete!(chosen, name) : push!(chosen, name)
            send(steps_command(snap, chosen))
        end
    elseif key == :char && evt.char == 'd'
        if idx > 0
            send(steps_command(snap, required_processors(page_graph!(page, snap), vcat(snap.run_steps, snap.partition_steps))))
        end
    else
        return false
    end
    return true
end

"""
    JuLeAna.graph_mouse!(page::GraphPage, evt::Tachikoma.MouseEvent, snap)::Bool

Apply the mouse event `evt` to `page`: the scroll wheel moves the cursor by one row while
the pointer is inside the block of the last render, and a left click on a processor row
moves the cursor to it. Return `true` if the event was used.
"""
function graph_mouse!(page::GraphPage, evt::Tachikoma.MouseEvent, snap)::Bool
    evt.action == Tachikoma.mouse_press || return false
    if evt.button == Tachikoma.mouse_left
        Base.contains(page.list, evt.x, evt.y) || return false
        rows = graph_rows(page, snap)
        idx = page.top + evt.y - page.list.y
        idx in eachindex(rows) || return false
        move_graph_cursor!(page, rows, idx)
        return true
    elseif evt.button in (Tachikoma.mouse_scroll_up, Tachikoma.mouse_scroll_down)
        Base.contains(page.rect, evt.x, evt.y) || return false
        rows = graph_rows(page, snap)
        idx = sync_graph_cursor!(page, rows)
        move_graph_cursor!(page, rows, idx + (evt.button == Tachikoma.mouse_scroll_up ? -1 : 1))
        return true
    end
    return false
end

# Last-run state of a processor from the states of its steps, or `nothing` if it had none.
function last_run_state(states)
    :running in states && return :running
    :failed in states && return :failed
    all(in(FINAL_STEP_STATES), states) && :done in states && return :done
    (:stopped in states || :cancelled in states) && return :stopped
    return nothing
end

function processor_states(prog)
    by_name = Dict{Symbol,Vector{Symbol}}()
    isnothing(prog) && return Dict{Symbol,Symbol}()
    for e in prog.steps
        push!(get!(Vector{Symbol}, by_name, Symbol(e.step)), e.state)
    end
    return Dict(n => s for (n, states) in by_name for s in (last_run_state(states),) if !isnothing(s))
end

# Declared edges between displayed processors, as `(source row, target row)` pairs sorted
# by source row, then target row.
function graph_edges(g::ProcessorGraph, rows)
    rowof = Dict(n => i for (i, n) in pairs(rows))
    edges = Tuple{Int,Int}[]
    for e in Graphs.edges(g.graph)
        u, v = Graphs.src(e), Graphs.dst(e)
        ru, rv = get(rowof, g.names[u], 0), get(rowof, g.names[v], 0)
        ru > 0 && rv > 0 && push!(edges, (ru, rv))
    end
    return sort!(edges)
end

# Track number of each source row of `edges` and the number of tracks. A track spans the
# rows from its source to its last target; the tracks of overlapping spans differ.
function assign_tracks(edges)
    last_target = Dict{Int,Int}()
    for (u, v) in edges
        last_target[u] = max(get(last_target, u, 0), v)
    end
    busy_until = Int[]
    track = Dict{Int,Int}()
    for u in sort!(collect(keys(last_target)))
        k = findfirst(<(u), busy_until)
        if isnothing(k)
            push!(busy_until, 0)
            k = length(busy_until)
        end
        busy_until[k] = last_target[u]
        track[u] = k
    end
    return track, length(busy_until)
end

# Columns of the drawing for name widths `nl` and `nr` and `ntracks` tracks, counted from 1
# at the marker of the left lane: the attachment column `ax` right of the left labels, the
# column `tcol(k)` of track `k`, the marker column `xr` of the right lane and the width.
function graph_columns(nl, nr, ntracks)
    ax = nl + GRAPH_DECOR + 4
    t0 = ax + 2
    xr = ntracks > 0 ? t0 + 2 * (ntracks - 1) + 3 : ax + 4
    return (; ax, xr, tcol = k -> t0 + 2 * (k - 1), width = xr + 1 + nr + GRAPH_DECOR)
end

# Set the drawing cell `(r, c)` to the directions `bits` in addition to the ones it has.
function add_line!(masks, styles, r, c, bits, style)
    masks[r, c] |= bits
    styles[r, c] = style
    return nothing
end

function put_cells!(chars, styles, r, c, text, style)
    for (k, ch) in enumerate(text)
        c + k - 1 <= size(chars, 2) || break
        chars[r, c + k - 1] = ch
        styles[r, c + k - 1] = style
    end
    return nothing
end

"""
    JuLeAna.render_graph(page::GraphPage, snap, prog, area::Tachikoma.Rect, buf::Tachikoma.Buffer; grid = nothing)

Draw the Graph page into `area` of `buf` from the controller snapshot `snap`, the
progress `prog` (as returned by [`progress`](@ref), or `nothing`) and the grid of the
reports and the processing history `grid` (as returned by [`JuLeAna.history_grid`](@ref),
or `nothing` while it is not read).

Run-level processors are in the left lane and partition-level processors in the right
lane, one row per processor in topological order, labeled with its [`display_name`](@ref) and category. A processor shows `[x]` if it is a
selected step, else `[ ]`, and the icon of its state in the last run: running, failed,
done, or stopped. While `page.disk` is `true` the icon is instead the
[`JuLeAna.disk_state`](@ref) of the processor over the selected periods and runs of `snap`:
`✗` failed, `–` missing, `!` warning or `✓` ok, and the last line also shows the counts of
the processor under the cursor. Unselected processors are dim, and are left out while `page.show_unselected`
is `false`. Each declared dependency is an edge from the required processor down to
the one that waits for it, in the space between the lanes, also between processors of the
same lane; every processor with edges to later processors has a vertical track there, and
tracks with overlapping spans have different columns.

The processor under the cursor is bold; the processors it requires are yellow and the
processors that require it are purple, as are the edges between them. The view scrolls to keep
the cursor row visible, and the last line shows the number of required and requiring
processors and the tags of the processor under the cursor. Names are cut with `…` if the
area is too narrow.
"""
function render_graph(page::GraphPage, snap, prog, area::Tachikoma.Rect, buf::Tachikoma.Buffer; grid = nothing)
    page.rect = area
    page.list = Tachikoma.Rect(area.x, area.y, 0, 0)
    page.height = 1
    (area.width < 3 || area.height < 3) && return nothing
    dim = Tachikoma.tstyle(:text_dim)
    title = "Processor graph" *
            (page.disk ? (isnothing(grid) ? ", on disk (reading…)" : ", on disk") : "") *
            (page.show_unselected ? "" : " (unselected hidden)")
    inner = Tachikoma.render(pane_block(title, true), area, buf)
    x_max = Tachikoma.right(inner)
    if isnothing(snap) || isempty(snap.processors)
        Tachikoma.set_string!(buf, inner.x, inner.y, "Loading the session…", dim; max_x = x_max)
        return nothing
    end
    g = page_graph!(page, snap)
    rows = graph_rows(page, snap)
    n = length(rows)
    if n == 0
        Tachikoma.set_string!(buf, inner.x, inner.y, "No processor is selected.", dim; max_x = x_max)
        return nothing
    end
    idx = sync_graph_cursor!(page, rows)
    cursor = rows[idx]

    info_line = inner.height >= 3
    height = max(0, inner.height - 1 - info_line)
    view_height = max(1, height)
    page.height = view_height
    page.list = Tachikoma.Rect(inner.x, inner.y + 1, inner.width, height)
    page.top = clamp(page.top, 1, max(1, n - view_height + 1))
    idx < page.top && (page.top = idx)
    idx > page.top + view_height - 1 && (page.top = idx - view_height + 1)

    spec = Dict(p.name => p for p in snap.processors)
    node = Dict(name => i for (i, name) in pairs(g.names))
    lane_left(name) = g.levels[node[name]] === :run
    required = setdiff(required_processors(g, [cursor]), [cursor])
    dependents = setdiff(dependent_processors(g, [cursor]), [cursor])
    selected = Set(vcat(snap.run_steps, snap.partition_steps))
    counts = Dict{Symbol,Any}()
    if page.disk && !isnothing(grid)
        period_runs = selected_period_runs(snap)
        for row in grid.rows
            counts[row.process] = disk_counts(row, period_runs)
        end
    end
    states = page.disk ? Dict(n => s for (n, c) in counts for s in (disk_state(c),) if !isnothing(s)) : processor_states(prog)
    icons, colors = page.disk ? (REPORT_ICONS, REPORT_COLORS) : (STATE_ICONS, STATE_COLORS)

    label = Dict(r => "$(display_name(r)) $(spec[r].category)" for r in rows)
    nl = maximum((textwidth(label[r]) for r in rows if lane_left(r)); init = 0)
    nr = maximum((textwidth(label[r]) for r in rows if !lane_left(r)); init = 0)
    edges = graph_edges(g, rows)
    track, ntracks = assign_tracks(edges)
    cols = graph_columns(nl, nr, ntracks)
    while cols.width > inner.width && max(nl, nr) > 4
        nl >= nr ? (nl -= 1) : (nr -= 1)
        cols = graph_columns(nl, nr, ntracks)
    end
    (; ax, xr, tcol, width) = cols

    masks = zeros(UInt8, n, width)
    chars = fill(' ', n, width)
    styles = fill(Tachikoma.Style(), n, width)

    for (lane, col) in ((true, 1), (false, xr))
        lane_rows = [i for (i, r) in pairs(rows) if lane_left(r) == lane]
        isempty(lane_rows) && continue
        for r in first(lane_rows):last(lane_rows)
            add_line!(masks, styles, r, col, DIR_N | DIR_S, Tachikoma.tstyle(:border))
        end
    end

    # Edges between highlighted nodes take the highlight color; those are drawn last.
    function edge_color(u, v)
        a, b = rows[u], rows[v]
        (a in required || a == cursor) && (b in required || b == cursor) && return :warning
        (a in dependents || a == cursor) && (b in dependents || b == cursor) && return :secondary
        return :text_dim
    end
    plain = filter(e -> edge_color(e...) === :text_dim, edges)
    arrows = Tuple{Int,Int,Char,Tachikoma.Style}[]
    for (u, v) in vcat(plain, setdiff(edges, plain))
        style = Tachikoma.tstyle(edge_color(u, v))
        c = tcol(track[u])
        if lane_left(rows[u])
            foreach(x -> add_line!(masks, styles, u, x, DIR_E | DIR_W, style), ax:(c - 1))
            add_line!(masks, styles, u, c, DIR_W | DIR_S, style)
        else
            foreach(x -> add_line!(masks, styles, u, x, DIR_E | DIR_W, style), (c + 1):(xr - 1))
            add_line!(masks, styles, u, c, DIR_E | DIR_S, style)
        end
        foreach(r -> add_line!(masks, styles, r, c, DIR_N | DIR_S, style), (u + 1):(v - 1))
        if lane_left(rows[v])
            foreach(x -> add_line!(masks, styles, v, x, DIR_E | DIR_W, style), (ax + 1):(c - 1))
            add_line!(masks, styles, v, c, DIR_N | DIR_W, style)
            push!(arrows, (v, ax, '◀', style))
        else
            foreach(x -> add_line!(masks, styles, v, x, DIR_E | DIR_W, style), (c + 1):(xr - 2))
            add_line!(masks, styles, v, c, DIR_N | DIR_E, style)
            push!(arrows, (v, xr - 1, '▶', style))
        end
    end
    for i in eachindex(masks)
        masks[i] == 0 || (chars[i] = BOX_CHARS[masks[i] + 1])
    end
    for (r, c, char, style) in arrows
        chars[r, c] = char
        styles[r, c] = style
    end

    for (r, name) in pairs(rows)
        left = lane_left(name)
        x = left ? 1 : xr
        highlighted = name == cursor ? :accent : name in required ? :warning : name in dependents ? :secondary : nothing
        checked = name in selected
        name_style = isnothing(highlighted) ? Tachikoma.tstyle(checked ? :text : :text_dim) :
                     Tachikoma.tstyle(highlighted; bold = name == cursor, dim = !checked && name != cursor)
        put_cells!(chars, styles, r, x, "●", name_style)
        put_cells!(chars, styles, r, x + 2, rpad(clip_text(label[name], left ? nl : nr), left ? nl : nr), name_style)
        label_x = x + 2 + (left ? nl : nr)
        put_cells!(chars, styles, r, label_x, checked ? " [x]" : " [ ]", Tachikoma.tstyle(checked ? :text : :text_dim))
        state = get(states, name, nothing)
        isnothing(state) || put_cells!(chars, styles, r, label_x + 4, " " * icons[state], Tachikoma.tstyle(colors[state]))
    end

    Tachikoma.set_string!(buf, inner.x, inner.y, "Run processors", dim; max_x = min(x_max, inner.x + xr - 3))
    Tachikoma.set_string!(buf, inner.x + xr - 1, inner.y, "Partition processors", dim; max_x = x_max)
    highlight = Tachikoma.tstyle(:border)
    for r in 0:(height - 1)
        row = page.top + r
        row <= n || break
        for c in 1:inner.width
            cell_style = c <= width ? styles[row, c] : Tachikoma.Style()
            char = c <= width ? chars[row, c] : ' '
            row == idx &&
                (cell_style = Tachikoma.Style(; fg = cell_style.fg, bg = highlight.fg, bold = cell_style.bold, dim = cell_style.dim))
            Tachikoma.set_char!(buf, inner.x + c - 1, inner.y + 1 + r, char, cell_style)
        end
    end
    if info_line
        p = spec[cursor]
        spans = Tuple{String,Tachikoma.Style}[("$(display_name(cursor)): requires $(length(required)), required by $(length(dependents))",
                                               dim)]
        for tag in processor_tags(p)
            push!(spans, ("  ", dim), (tag, something(setup_tag_style(tag), dim)))
        end
        if haskey(counts, cursor)
            c = counts[cursor]
            push!(spans, ("  on disk:", dim))
            for state in (:ok, :warning, :failed, :missing)
                getproperty(c, state) > 0 && push!(spans, (" $(getproperty(c, state)) $state", Tachikoma.tstyle(REPORT_COLORS[state])))
            end
            push!(spans, (" of $(c.total)", dim))
        end
        put_spans!(buf, inner.x, Tachikoma.bottom(inner), x_max, spans)
    end
    return nothing
end
