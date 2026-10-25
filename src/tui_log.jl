# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Lines scrolled per notch of the mouse wheel.
const LOG_WHEEL_LINES = 3

# Title and minimum level of each setting of the level filter, in the order of `l`.
const LOG_PAGE_LEVELS = (("all", Logging.Info), ("warnings", Logging.Warn), ("errors", Logging.Error))

"""
    LogPage()

State of the Log page of the terminal user interface: whether the view follows the newest
line, the index of the first displayed line, the level filter and the text filter. The page
lists the entries of a [`JuLeAna.MessageBuffer`](@ref) (see [`JuLeAna.message_entries`](@ref)).
Keys are handled by [`JuLeAna.log_key!`](@ref) and [`JuLeAna.log_mouse!`](@ref), the page
is drawn by [`JuLeAna.render_log`](@ref).

The level filter shows the records of at least the level `min_level`. The text filter
`filter` shows the records with a line that contains it, ignoring case. A record is
shown with all of its lines. `top` indexes the shown lines and is used while `follow` is
`false`.
"""
mutable struct LogPage
    follow::Bool
    top::Int
    min_level::LogLevel
    filter::String
    # whether keys edit the text filter
    editing::Bool
    # lines displayed per page at the last render
    height::Int
    # area of the block at the last render
    rect::Tachikoma.Rect
end

LogPage() = LogPage(true, 1, Logging.Info, "", false, 1, Tachikoma.Rect(1, 1, 0, 0))

# Indices of the entries that pass the level and text filters of `page`: all lines of the
# records that have the minimum level and a line containing the filter text.
function shown_entries(page::LogPage, entries)
    needle = lowercase(page.filter)
    shown = Int[]
    i = firstindex(entries)
    while i <= lastindex(entries)
        j = i
        while j < lastindex(entries) && entries[j + 1].record == entries[i].record
            j += 1
        end
        if entries[i].level >= page.min_level && (isempty(needle) || any(k -> occursin(needle, lowercase(entries[k].text)), i:j))
            append!(shown, i:j)
        end
        i = j + 1
    end
    return shown
end

# First displayed line when the view shows the last of `n` lines in `height` rows.
last_top(n, height) = max(1, n - height + 1)

# Scroll by `delta` lines and stop following. The scroll starts from the lines displayed
# at the last render.
function scroll_log!(page::LogPage, entries, delta)
    n = length(shown_entries(page, entries))
    top = page.follow ? last_top(n, page.height) : page.top
    page.top = clamp(top + delta, 1, last_top(n, page.height))
    page.follow = false
    return nothing
end

function handle_log_filter_key!(page::LogPage, evt::Tachikoma.KeyEvent)
    if evt.key == :char && isprint(evt.char)
        page.filter *= evt.char
    elseif evt.key == :backspace
        page.filter = chop(page.filter)
    elseif evt.key == :enter
        page.editing = false
    elseif evt.key == :escape
        page.filter = ""
        page.editing = false
    end
    return nothing
end

"""
    JuLeAna.log_key!(page::LogPage, evt::Tachikoma.KeyEvent, entries)::Bool

Apply the key event `evt` to `page` for the message entries `entries` (see
[`JuLeAna.message_entries`](@ref)). Return `true` if the key was used and `false`
otherwise.

  - Up, Down, PageUp, PageDown and Home scroll and turn following off.
  - End shows the newest line and turns following on. `f` turns following on.
  - `l` cycles the level filter: all records, warnings and errors, errors.
  - `/` starts editing the text filter.
  - Other keys are not used.

While editing the filter, every key is used: printable characters are appended,
Backspace deletes the last character, Enter keeps the filter and returns to normal mode,
and Escape clears the filter and returns to normal mode.
"""
function log_key!(page::LogPage, evt::Tachikoma.KeyEvent, entries)::Bool
    evt.action == Tachikoma.key_release && return false
    if page.editing
        handle_log_filter_key!(page, evt)
        return true
    end
    key = evt.key
    if key == :up
        scroll_log!(page, entries, -1)
    elseif key == :down
        scroll_log!(page, entries, 1)
    elseif key == :pageup
        scroll_log!(page, entries, -page.height)
    elseif key == :pagedown
        scroll_log!(page, entries, page.height)
    elseif key == :home
        page.top, page.follow = 1, false
    elseif key == :end_key || (key == :char && evt.char == 'f')
        page.follow = true
    elseif key == :char && evt.char == 'l'
        i = findfirst(l -> l[2] == page.min_level, LOG_PAGE_LEVELS)
        page.min_level = LOG_PAGE_LEVELS[mod1(something(i, 0) + 1, length(LOG_PAGE_LEVELS))][2]
    elseif key == :char && evt.char == '/'
        page.editing = true
    else
        return false
    end
    return true
end

"""
    JuLeAna.log_mouse!(page::LogPage, evt::Tachikoma.MouseEvent, entries)::Bool

Apply the mouse event `evt` to `page`: the scroll wheel scrolls by three lines and turns
following off while the pointer is inside the block of the last render. Return `true` if
the event was used.
"""
function log_mouse!(page::LogPage, evt::Tachikoma.MouseEvent, entries)::Bool
    if evt.button in (Tachikoma.mouse_scroll_up, Tachikoma.mouse_scroll_down) && evt.action == Tachikoma.mouse_press
        Base.contains(page.rect, evt.x, evt.y) || return false
        scroll_log!(page, entries, evt.button == Tachikoma.mouse_scroll_up ? -LOG_WHEEL_LINES : LOG_WHEEL_LINES)
        return true
    end
    return false
end

# Spans of the line `text` of a record of `level`: the time stamp dimmed, the parts that
# contain the lowercase filter text `needle` highlighted.
function log_line_spans(text::AbstractString, level::LogLevel, needle::AbstractString)
    color = level >= Logging.Error ? :error : level >= Logging.Warn ? :warning : :text
    base, dim, hit = Tachikoma.tstyle(color), Tachikoma.tstyle(:text_dim), Tachikoma.tstyle(:accent, bold = true)
    stamp = occursin(r"^\d\d:\d\d:\d\d", text) ? 8 : 0
    lower = lowercase(text)
    # a lowercase form of another length cannot be matched by position
    hits = isempty(needle) || ncodeunits(lower) != ncodeunits(text) ? UnitRange{Int}[] : findall(needle, lower)
    spans = Tuple{String,Tachikoma.Style}[]
    function plain!(a, b)
        a <= min(b, stamp) && push!(spans, (text[a:min(b, stamp)], dim))
        return max(a, stamp + 1) <= b && push!(spans, (text[max(a, stamp + 1):b], base))
    end
    pos = 1
    for r in hits
        plain!(pos, prevind(text, first(r)))
        push!(spans, (text[r], hit))
        pos = nextind(text, last(r))
    end
    plain!(pos, lastindex(text))
    return spans
end

"""
    JuLeAna.render_log(page::LogPage, entries, area::Tachikoma.Rect, buf::Tachikoma.Buffer;
        capacity = typemax(Int), log_path = nothing)

Draw the Log page into `area` of `buf` from the message entries `entries` (see
[`JuLeAna.message_entries`](@ref)): a block that lists the lines passing the filters of
`page`, colored by level, and a line with the number of lines shown. The title shows the
level filter, the text filter and whether the view follows the newest line. While `page`
follows, the last lines are displayed. Long lines are cut at the edge of the block.

If `entries` holds `capacity` lines, older lines were dropped, and the bottom line points
to the log file of this process in the directory `log_path` (if not `nothing`).
"""
function render_log(page::LogPage, entries, area::Tachikoma.Rect, buf::Tachikoma.Buffer; capacity::Integer = typemax(Int),
                    log_path = nothing)
    page.rect = area
    page.height = 1
    level_name = LOG_PAGE_LEVELS[something(findfirst(l -> l[2] == page.min_level, LOG_PAGE_LEVELS), 1)][1]
    title = "Log  ($level_name)" *
            (page.editing || !isempty(page.filter) ? "  filter: " * page.filter * (page.editing ? "▏" : "") : "") *
            (page.follow ? "  (following)" : "")
    (area.width < 3 || area.height < 3) && return nothing
    inner = Tachikoma.render(pane_block(clip_text(title, max(0, area.width - 6)), true), area, buf)
    x_max = Tachikoma.right(inner)
    dim = Tachikoma.tstyle(:text_dim)
    if isempty(entries)
        Tachikoma.set_string!(buf, inner.x, inner.y, "No messages yet.", dim; max_x = x_max)
        return nothing
    end
    shown = shown_entries(page, entries)
    height = max(1, inner.height - 1)
    page.height = height
    page.top = page.follow ? last_top(length(shown), height) : clamp(page.top, 1, last_top(length(shown), height))
    needle = lowercase(page.filter)
    for r in 0:(height - 1)
        i = page.top + r
        i <= length(shown) || break
        e = entries[shown[i]]
        put_spans!(buf, inner.x, inner.y + r, x_max, log_line_spans(e.text, e.level, needle))
    end
    inner.height >= 2 || return nothing
    status = "$(length(shown)) of $(length(entries)) lines"
    length(entries) >= capacity && (status *= "  older lines in " * (isnothing(log_path) ? "head.log" : process_log_file(log_path)))
    Tachikoma.set_string!(buf, inner.x, Tachikoma.bottom(inner), clip_text(status, inner.width), dim; max_x = x_max)
    return nothing
end
