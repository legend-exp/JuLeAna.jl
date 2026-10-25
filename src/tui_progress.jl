# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Theme color and icon of each step state.
const STATE_COLORS = (waiting = :text_dim, running = :accent, done = :success, failed = :error, skipped = :text_dim, stopped = :warning,
                      cancelled = :warning)
const STATE_ICONS = (waiting = "○", running = "▶", done = "✓", failed = "✗", skipped = "–", stopped = "■", cancelled = "⊘")

# Width of the item bar of a step and of the step bar of a group, in cells.
const STEP_BAR_WIDTH = 20
const GROUP_BAR_WIDTH = 10

"""
    ProgressPage()

State of the Progress page of the terminal user interface: the row under the cursor, the
first displayed row, whether the cursor follows the running step, and which groups the
user folded or unfolded. The page lists the steps of the current or last processing run
grouped by period and run, with the busy workers below. Keys are handled by
[`JuLeAna.progress_key!`](@ref) and [`JuLeAna.progress_mouse!`](@ref), the page is drawn
by [`JuLeAna.render_progress`](@ref).

A row is identified by its key: `(period, run)` for a group and `(period, run, step)` for
a step, so that the cursor stays on its row when the list changes. `expanded` holds the
group keys the user folded (`false`) or unfolded (`true`); the other groups are unfolded
if a step runs, failed or stopped, or has items that were not run.

`open` is the key of the step whose messages pane is shown (`nothing` if closed). The pane
lists the messages that [`step_messages`](@ref) returns for that step; while `pane_follow`
is `true` it shows the newest lines, else it starts at line `pane_top`. While the pane is
open, the cursor moving to another step row switches the pane to that step.
"""
mutable struct ProgressPage
    cursor::Any
    # row index of the cursor at the last use, the fallback when the cursor row vanishes
    index::Int
    # index of the first displayed row
    top::Int
    # rows displayed per page at the last render
    height::Int
    follow::Bool
    const expanded::Dict{Any,Bool}
    # area of the steps block and the part of it that holds the rows at the last render
    rect::Tachikoma.Rect
    list::Tachikoma.Rect
    open::Any
    pane_follow::Bool
    pane_top::Int
    # rows of the pane and number of lines it holds at the last render
    pane_height::Int
    pane_lines::Int
end

function ProgressPage()
    return ProgressPage(nothing, 1, 1, 1, true, Dict{Any,Bool}(), Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0), nothing, true, 1,
                        1, 0)
end

# Displayed rows: a group row followed by the rows of its steps if it is unfolded. A group
# is unfolded as the user left it, else if a step runs, failed, stopped or has items that
# were not run.
function progress_rows(page::ProgressPage, prog)
    rows = @NamedTuple{key::Tuple, step::Bool, entry::Any, unfolded::Bool}[]
    isnothing(prog) && return rows
    by_group = Dict{Any,Vector{Any}}()
    for e in prog.steps
        push!(get!(Vector{Any}, by_group, (e.period, e.run)), e)
    end
    for g in prog.groups
        key = (g.period, g.run)
        steps = get(by_group, key, ())
        unfolded = get(page.expanded, key) do
            return any(e -> e.state in (:running, :failed, :stopped) || e.notrun > 0, steps)
        end
        push!(rows, (; key, step = false, entry = g, unfolded))
        unfolded && append!(rows, (; key = (g.period, g.run, e.step), step = true, entry = e, unfolded = true) for e in steps)
    end
    return rows
end

# Index of the cursor row in `rows` (0 if there are none), moving the cursor to the
# nearest row when its row vanished.
function sync_cursor!(page::ProgressPage, rows)
    isempty(rows) && return 0
    idx = something(findfirst(r -> r.key == page.cursor, rows), clamp(page.index, 1, length(rows)))
    page.cursor, page.index = rows[idx].key, idx
    return idx
end

"""
    JuLeAna.progress_key!(page::ProgressPage, evt::Tachikoma.KeyEvent, prog)::Bool

Apply the key event `evt` to `page` for the progress `prog` (as returned by
[`progress`](@ref), or `nothing`). Return `true` if the key was used and `false` otherwise.

  - Up, Down, PageUp, PageDown, Home and End move the cursor and turn following off.
  - Enter on a group row toggles the group. Left folds the group of the cursor row and
    Right unfolds it. Folding a group moves the cursor to the group row. These keys turn
    following off.
  - Enter on a step row opens the messages pane for the step and turns following off;
    Enter on the open step's row closes the pane. Escape closes the pane.
  - While the pane is open, PageUp and PageDown scroll it instead of moving the cursor
    and End shows the newest line. Moving the cursor to another step row switches the
    pane to that step.
  - `f` turns following on: the cursor goes to the first running step and the view scrolls
    to keep it visible. An open pane follows the cursor's step.
  - Other keys are not used.
"""
function progress_key!(page::ProgressPage, evt::Tachikoma.KeyEvent, prog)::Bool
    evt.action == Tachikoma.key_release && return false
    key = evt.key
    if key == :char && evt.char == 'f'
        page.follow = true
        return true
    end
    if !isnothing(page.open)
        if key == :escape
            page.open = nothing
            return true
        elseif key in (:pageup, :pagedown)
            scroll_pane!(page, key == :pageup ? -page.pane_height : page.pane_height)
            return true
        elseif key == :end_key
            page.pane_follow = true
            return true
        end
    end
    rows = progress_rows(page, prog)
    idx = sync_cursor!(page, rows)
    delta = key == :up ? -1 :
            key == :down ? 1 :
            key == :pageup ? -page.height :
            key == :pagedown ? page.height : key == :home ? -length(rows) : key == :end_key ? length(rows) : nothing
    if !isnothing(delta)
        move_cursor!(page, rows, idx + delta)
    elseif key == :enter && idx > 0 && rows[idx].step
        page.open == rows[idx].key ? (page.open = nothing) : switch_pane!(page, rows[idx].key)
        page.follow = false
    elseif key in (:left, :right, :enter)
        if idx > 0
            gkey = rows[idx].key[1:2]
            unfolded = rows[findfirst(r -> r.key == gkey, rows)].unfolded
            unfold = key == :enter ? !unfolded : key == :right
            page.expanded[gkey] = unfold
            unfold || (page.cursor = gkey)
        end
        page.follow = false
    else
        return false
    end
    return true
end

# Move the cursor to row `idx` of `rows`, limited to the existing rows, and stop following.
function move_cursor!(page::ProgressPage, rows, idx)
    page.follow = false
    isempty(rows) && return nothing
    page.index = clamp(idx, 1, length(rows))
    page.cursor = rows[page.index].key
    sync_open!(page, rows[page.index])
    return nothing
end

# Show the messages of the step `key` in the pane, starting at the newest line.
function switch_pane!(page::ProgressPage, key)
    page.open, page.pane_follow, page.pane_top = key, true, 1
    return nothing
end

# Switch an open pane to the step of `row` if it is a step row of another step.
function sync_open!(page::ProgressPage, row)
    isnothing(page.open) || !row.step || row.key == page.open || switch_pane!(page, row.key)
    return nothing
end

# Scroll the pane by `delta` lines; it follows the newest line again at the end.
function scroll_pane!(page::ProgressPage, delta)
    last = last_top(page.pane_lines, page.pane_height)
    top = clamp((page.pane_follow ? last : page.pane_top) + delta, 1, last)
    page.pane_top, page.pane_follow = top, top == last
    return nothing
end

"""
    JuLeAna.progress_mouse!(page::ProgressPage, evt::Tachikoma.MouseEvent, prog)::Bool

Apply the mouse event `evt` to `page`: the scroll wheel moves the cursor by one row while
the pointer is inside the steps block of the last render, and a left click on a row moves
the cursor to it, folds or unfolds a group row and opens the messages pane for a step row.
Both turn following off. Return `true` if the event was used.
"""
function progress_mouse!(page::ProgressPage, evt::Tachikoma.MouseEvent, prog)::Bool
    if evt.button == Tachikoma.mouse_left && evt.action == Tachikoma.mouse_press
        Base.contains(page.list, evt.x, evt.y) || return false
        rows = progress_rows(page, prog)
        idx = page.top + evt.y - page.list.y
        idx in eachindex(rows) || return false
        move_cursor!(page, rows, idx)
        if rows[idx].step
            page.open == rows[idx].key || switch_pane!(page, rows[idx].key)
        else
            page.expanded[rows[idx].key] = !rows[idx].unfolded
        end
        return true
    elseif evt.button in (Tachikoma.mouse_scroll_up, Tachikoma.mouse_scroll_down) && evt.action == Tachikoma.mouse_press
        Base.contains(page.rect, evt.x, evt.y) || return false
        rows = progress_rows(page, prog)
        idx = sync_cursor!(page, rows)
        move_cursor!(page, rows, idx + (evt.button == Tachikoma.mouse_scroll_up ? -1 : 1))
        return true
    end
    return false
end

"""
    JuLeAna.bar_segments(counts, width::Integer)

Widths in cells of the segments of a bar of `width` cells that shows `counts` (a
non-negative number per segment, in the order shown). The segment boundaries are the
rounded cumulative shares of the total, so the widths add up to `width` (to `0` if all
counts are zero) and a segment is empty only if its share is below half a cell.
"""
function bar_segments(counts, width::Integer)
    total = sum(counts)
    total > 0 || return zeros(Int, length(counts))
    edges = round.(Int, width .* cumsum(counts) ./ total)
    return diff(vcat(0, edges))
end

# Spans of a bar of `width` cells for `counts`, one segment per entry of `cells` (a
# `(character, theme color)` pair).
function bar_spans(counts, cells, width)
    widths = bar_segments(counts, width)
    return [(repeat(cells[i][1], widths[i]), Tachikoma.tstyle(cells[i][2], dim = cells[i][2] == :text_dim))
            for i in eachindex(cells) if widths[i] > 0]
end

clip_text(s, n) = textwidth(s) <= n ? s : n <= 0 ? "" : first(s, n - 1) * "…"

# Draw `spans` (`(text, style)` pairs) from column `x` of row `y`, up to column `x_max`.
# With `background`, the row up to `x_max` gets that style's foreground color as background.
function put_spans!(buf, x, y, x_max, spans, background = nothing)
    if !isnothing(background)
        bg = Tachikoma.Style(; bg = background.fg)
        Tachikoma.set_string!(buf, x, y, " "^max(0, x_max - x + 1), bg; max_x = x_max)
    end
    for (text, style) in spans
        isnothing(background) || (style = Tachikoma.Style(; fg = style.fg, bg = background.fg, bold = style.bold, dim = style.dim))
        Tachikoma.set_string!(buf, x, y, text, style; max_x = x_max)
        x += textwidth(text)
        x > x_max && break
    end
    return nothing
end

# `step_label` with the display name of the processor.
step_display_label(e) = step_label((; e.period, e.run, step = display_name(Symbol(e.step))))

group_label(g) = isnothing(g.run) ? "$(g.period) partitions" : "$(g.period)-$(g.run)"

function group_spans(g, label_width, expanded)
    c = g.counts
    done = c.done + c.skipped
    counts = [done, c.failed, c.stopped + c.cancelled, c.running, c.waiting]
    cells = (('█', :success), ('█', :error), ('█', :warning), ('█', :accent), ('░', :text_dim))
    text = "$done/$(g.nsteps) done" *
           (c.failed > 0 ? ", $(c.failed) failed" : "") *
           (c.stopped > 0 ? ", $(c.stopped) stopped" : "") *
           (c.cancelled > 0 ? ", $(c.cancelled) cancelled" : "")
    return [((expanded ? "▾ " : "▸ ") * rpad(clip_text(group_label(g), label_width), label_width) * " ",
             Tachikoma.tstyle(:primary, bold = true)), bar_spans(counts, cells, GROUP_BAR_WIDTH)...,
            (" " * lpad(round(Int, 100 * g.fraction), 3) * "%  ", Tachikoma.tstyle(:text)), (text, Tachikoma.tstyle(:text_dim))]
end

function step_spans(e, name_width)
    color = STATE_COLORS[e.state]
    spans = [("  ", Tachikoma.tstyle(:text)), (STATE_ICONS[e.state] * " ", Tachikoma.tstyle(color)),
             (rpad(clip_text(display_name(Symbol(e.step)), name_width), name_width) * " ", Tachikoma.tstyle(:text_bright))]
    if e.total == 0
        push!(spans, (rpad(string(e.state), STEP_BAR_WIDTH), Tachikoma.tstyle(color)))
    else
        cells = (('█', :success), ('█', :error), ('▒', :warning), ('░', :text_dim))
        counts = [e.done, e.failed, e.notrun, max(0, e.total - e.done - e.failed - e.notrun)]
        append!(spans, bar_spans(counts, cells, STEP_BAR_WIDTH))
        push!(spans, (" $(e.done)/$(e.total)", Tachikoma.tstyle(:text)))
        e.failed > 0 && push!(spans, ("  $(e.failed) failed", Tachikoma.tstyle(:error)))
        e.notrun > 0 && push!(spans, ("  $(e.notrun) not run", Tachikoma.tstyle(:warning)))
    end
    isempty(e.workers) || push!(spans, ("  w " * join(e.workers, ","), Tachikoma.tstyle(:text_dim)))
    isnothing(e.rate) || push!(spans, ("  " * string(round(e.rate * 60, digits = 1)) * "/min", Tachikoma.tstyle(:text_dim)))
    isnothing(e.eta) || push!(spans, ("  ETA " * format_duration(e.eta), Tachikoma.tstyle(:text_dim)))
    return spans
end

# The two lines at the top: overall bar with elapsed time and ETA, and the step counts.
function render_overview(prog, area, buf)
    area.height >= 1 || return nothing
    isnothing(prog) && return nothing
    c = prog.counts
    total = sum(c)
    done = c.done + c.skipped
    label = "$(round(Int, 100 * prog.fraction))%  $done/$total steps done" * (c.failed > 0 ? ", $(c.failed) failed" : "")
    time_text = if isnothing(prog.started)
        ""
    else
        elapsed = format_duration(seconds_between(prog.started, something(prog.finished, now(UTC))))
        "  elapsed $elapsed" * (isnothing(prog.eta) ? "" : "  ETA " * format_duration(prog.eta))
    end
    bar_width = clamp(area.width - textwidth(time_text), min(10, area.width), 50)
    Tachikoma.render(Tachikoma.Gauge(prog.fraction; label, filled_style = Tachikoma.tstyle(:success),
                                     label_style = Tachikoma.tstyle(:text_bright, bold = true)),
                     Tachikoma.Rect(area.x, area.y, bar_width, 1), buf)
    Tachikoma.set_string!(buf, area.x + bar_width, area.y, time_text, Tachikoma.tstyle(:text_dim); max_x = Tachikoma.right(area))
    if area.height >= 2
        spans = []
        for state in STEP_STATES
            n = c[state]
            n > 0 && push!(spans, ("$state $n  ", Tachikoma.tstyle(STATE_COLORS[state])))
        end
        put_spans!(buf, area.x, area.y + 1, Tachikoma.right(area), spans)
    end
    return nothing
end

function render_steps(page::ProgressPage, prog, area, buf)
    page.rect = area
    page.list = Tachikoma.Rect(area.x, area.y, 0, 0)
    page.height = 1
    block = pane_block(page.follow ? "Steps (following)" : "Steps", true)
    (area.width < 3 || area.height < 3) && return nothing
    inner = Tachikoma.render(block, area, buf)
    page.list = inner
    page.height = max(1, inner.height)
    rows = progress_rows(page, prog)
    if isempty(rows)
        Tachikoma.set_string!(buf, inner.x, inner.y, "No processing run yet.", Tachikoma.tstyle(:text_dim); max_x = Tachikoma.right(inner))
        return nothing
    end
    if page.follow
        running = findfirst(e -> e.state === :running, prog.steps)
        if !isnothing(running)
            e = prog.steps[running]
            # a group the user folded shows the group row instead of the running step
            key = (e.period, e.run, e.step)
            page.cursor = any(r -> r.key == key, rows) ? key : (e.period, e.run)
        end
    end
    idx = sync_cursor!(page, rows)
    sync_open!(page, rows[idx])
    height = inner.height
    page.top = clamp(page.top, 1, max(1, length(rows) - height + 1))
    idx < page.top && (page.top = idx)
    idx > page.top + height - 1 && (page.top = idx - height + 1)

    label_width = clamp(maximum(textwidth(group_label(r.entry)) for r in rows if !r.step), 1, max(1, inner.width ÷ 3))
    name_width = clamp(maximum(textwidth(display_name(Symbol(e.step))) for e in prog.steps), 1,
                       max(1, min(28, inner.width - STEP_BAR_WIDTH - 12)))
    highlight = Tachikoma.tstyle(:border)
    x_max = Tachikoma.right(inner)
    for r in 0:(height - 1)
        row = page.top + r
        row <= length(rows) || break
        entry = rows[row]
        spans = entry.step ? step_spans(entry.entry, name_width) : group_spans(entry.entry, label_width, entry.unfolded)
        put_spans!(buf, inner.x, inner.y + r, x_max, spans, row == idx ? highlight : nothing)
    end
    return nothing
end

function render_busy(busy, area, buf)
    block = Tachikoma.Block(title = "Busy workers ($(length(busy)))", border_style = Tachikoma.tstyle(:border),
                            title_style = Tachikoma.tstyle(:title))
    (area.width < 3 || area.height < 3) && return nothing
    inner = Tachikoma.render(block, area, buf)
    if isempty(busy)
        Tachikoma.set_string!(buf, inner.x, inner.y, "none", Tachikoma.tstyle(:text_dim); max_x = Tachikoma.right(inner))
        return nothing
    end
    labels = [step_display_label(b) for b in busy]
    label_width = min(maximum(textwidth, labels), max(1, inner.width ÷ 3))
    t = now(UTC)
    for (r, (b, label)) in enumerate(zip(busy, labels))
        r <= inner.height || break
        spans = [(rpad("w " * string(b.worker), 5), Tachikoma.tstyle(:accent)),
                 (rpad(clip_text(label, label_width), label_width) * "  ", Tachikoma.tstyle(:text)),
                 (b.item * "  ", Tachikoma.tstyle(:text)), (format_duration(seconds_between(b.since, t)), Tachikoma.tstyle(:text_dim))]
        b.abandoned && push!(spans, ("  abandoned", Tachikoma.tstyle(:warning)))
        put_spans!(buf, inner.x, inner.y + r - 1, Tachikoma.right(inner), spans)
    end
    return nothing
end

# Local time of the UTC time `t`.
local_time(t::DateTime) = t + round(now() - now(UTC), Dates.Minute)

# The messages pane of the open step `page.open`: the error of a failed step, then its
# messages with time and level, colored by level. `msgs` holds the messages read for a step key.
function render_pane(page::ProgressPage, prog, msgs, area, buf)
    key = page.open
    page.pane_height, page.pane_lines = 1, 0
    (area.width < 3 || area.height < 3) && return nothing
    messages = msgs.key == key ? msgs.messages : nothing
    count = isnothing(messages) ? "" : ": $(length(messages)) " * (length(messages) == 1 ? "message" : "messages")
    label = step_display_label((; period = key[1], run = key[2], step = key[3]))
    inner = Tachikoma.render(pane_block(clip_text(label * count, max(0, area.width - 6)), false), area, buf)
    index = isnothing(prog) ? nothing : findfirst(e -> (e.period, e.run, e.step) == key, prog.steps)
    entry = isnothing(index) ? nothing : prog.steps[index]
    lines = Vector{Tuple{String,Tachikoma.Style}}[]
    if !isnothing(entry) && entry.state === :failed && !isnothing(entry.error)
        append!(lines, [(String(l), Tachikoma.tstyle(:error))] for l in first(split(entry.error, '\n'), 3))
    end
    for msg in something(messages, ()), (i, l) in enumerate(split(msg.text, '\n'))

        stamp = i == 1 ? Dates.format(local_time(msg.time), dateformat"HH:MM:SS") * " " * rpad(string(msg.level), 5) * " " : " "^15
        push!(lines, log_line_spans(stamp * l, msg.level, ""))
    end
    if isempty(lines)
        text = isnothing(messages) ? "Reading messages…" : "No messages from this step."
        push!(lines, [(text, Tachikoma.tstyle(:text_dim))])
    end
    page.pane_height, page.pane_lines = inner.height, length(lines)
    last = last_top(length(lines), inner.height)
    page.pane_top = page.pane_follow ? last : clamp(page.pane_top, 1, last)
    for r in 0:(inner.height - 1)
        page.pane_top + r <= length(lines) || break
        put_spans!(buf, inner.x, inner.y + r, Tachikoma.right(inner), lines[page.pane_top + r])
    end
    return nothing
end

"""
    JuLeAna.render_progress(page::ProgressPage, prog, busy, msgs, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the Progress page into `area` of `buf` from the progress `prog` (as returned by
[`progress`](@ref), or `nothing`), the busy workers `busy` (see [`busy_workers`](@ref)) and
`msgs`, a named tuple with the step `key` and the `messages` that [`step_messages`](@ref)
returned for it. The page shows the overall progress and the step counts, a block with the
steps grouped by period and run, and a block with the busy workers. While `page` follows,
the cursor moves to the first running step. The view scrolls to keep the cursor row visible.

While `page.open` is a step key, the lower half of the space between the overview and the
busy workers (if at least 5 rows) shows the messages pane of that step: the error of a
failed step, then the messages oldest first with local time and level, colored by level.
It shows the newest lines while `page.pane_follow` is `true`. `msgs` is used only if its
`key` is `page.open`, else the pane says that the messages are being read.
"""
function render_progress(page::ProgressPage, prog, busy, msgs, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    busy_height = max(3, min(length(busy), 8) + 2)
    layout = Tachikoma.Layout(Tachikoma.Vertical, [Tachikoma.Fixed(2), Tachikoma.Fill(), Tachikoma.Fixed(busy_height)])
    top, middle, bottom = Tachikoma.split_layout(layout, area)
    pane_height = isnothing(page.open) ? 0 : middle.height ÷ 2
    pane_height >= 5 || (pane_height = 0)
    steps_height = middle.height - pane_height
    render_overview(prog, top, buf)
    render_steps(page, prog, Tachikoma.Rect(middle.x, middle.y, middle.width, steps_height), buf)
    if pane_height > 0
        render_pane(page, prog, msgs, Tachikoma.Rect(middle.x, middle.y + steps_height, middle.width, pane_height), buf)
    else
        page.pane_height, page.pane_lines = 1, 0
    end
    render_busy(busy, bottom, buf)
    return nothing
end
