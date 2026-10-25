# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    ChecklistItem(key, label::AbstractString; tags = String[])

Selectable entry of a [`JuLeAna.Checklist`](@ref). `key` identifies the item and must be
unique among the items of a checklist, `label` is the displayed text and `tags` are short
strings displayed dimmed at the right end of the row. Labels and tags are searched by the
filter of the checklist.
"""
struct ChecklistItem
    key::Any
    label::String
    tags::Vector{String}

    ChecklistItem(key, label; tags = String[]) = new(key, label, collect(String, tags))
end

"""
    ChecklistGroup(key, label::AbstractString, items::AbstractVector{ChecklistItem};
                   tags = String[], expanded = true)

Group of items of a two-level [`JuLeAna.Checklist`](@ref). A group is never selected
itself: toggling it toggles its visible items. `expanded` states whether the items are
displayed below the group; the checklist changes it when the group is collapsed or
expanded.
"""
mutable struct ChecklistGroup
    const key::Any
    const label::String
    const items::Vector{ChecklistItem}
    const tags::Vector{String}
    expanded::Bool

    function ChecklistGroup(key, label, items; tags = String[], expanded = true)
        return new(key, label, items, collect(String, tags), expanded)
    end
end

"""
    Checklist(entries; title = "", checked = (), focused = true, tag_style = tag -> nothing)

Terminal widget that displays a list of items with checkboxes and lets the user select
any number of them.

`entries` is either a vector of [`JuLeAna.ChecklistItem`](@ref) (flat list) or a vector
of [`JuLeAna.ChecklistGroup`](@ref) (two-level list). Item keys must be unique;
`checked` is an iterable of the keys of the initially selected items and must only
contain keys of items of the checklist. Only items are selected, never groups. The
cursor row is highlighted only while `focused` is `true`. `tag_style(tag::String)`
returns the `Tachikoma.Style` of a tag, or `nothing` for the dimmed default.

Selected boxes are drawn in the success color and group labels in bold primary color.
A group row shows `[x]` if all of its visible items are selected, `[~]` if some are, and
`[ ]` if none are. The title shows the number of selected items out of all items.

# Keys

`Tachikoma.handle_key!(w, evt)` returns `true` if the widget used the key and `false` otherwise.

In normal mode:
  - Up, Down, PageUp, PageDown, Home, End move the cursor.
  - Space toggles the item under the cursor. On a group row it toggles all visible items
    of the group: if all are selected they are deselected, otherwise all are selected.
  - `a` selects and `n` deselects all visible items.
  - Left collapses the group under the cursor (the cursor moves to the group row if it
    is on one of its items), Right expands it, and Enter on a group row toggles it.
  - `/` starts editing the filter.
  - Escape clears a non-empty filter.
  - Other keys are not used.

While editing the filter, every key is used: printable characters are appended,
Backspace deletes the last character, Enter keeps the filter and returns to normal mode,
and Escape clears the filter and returns to normal mode.

The filter keeps the items whose label or any tag contains the filter text, ignoring
case. A group is shown with all its items if its own label or a tag matches, and with
only its matching items if just some of its items match. Visible items are the items
shown under the filter, whether or not their group is collapsed.

# Mouse

`Tachikoma.handle_mouse!(w, evt)` handles clicks and the scroll wheel using the area of the last
`Tachikoma.render(::JuLeAna.Checklist, ...)`.
"""
mutable struct Checklist
    const groups::Vector{ChecklistGroup}
    const grouped::Bool
    const title::String
    const keys::Set{Any}
    const selected::Set{Any}
    const tag_style::Function
    focused::Bool
    filter::String
    editing::Bool
    # index into the visible rows
    cursor::Int
    # index of the first displayed row
    top::Int
    # rows displayed per page at the last render
    page::Int
    # area of the last render and the part of it that holds the rows
    rect::Tachikoma.Rect
    list::Tachikoma.Rect
end

function Checklist(entries; title = "", checked = (), focused = true, tag_style = tag -> nothing)
    if all(e -> e isa ChecklistItem, entries)
        groups = [ChecklistGroup(nothing, "", collect(ChecklistItem, entries))]
        grouped = false
    elseif all(e -> e isa ChecklistGroup, entries)
        groups = collect(ChecklistGroup, entries)
        grouped = true
    else
        throw(ArgumentError("Checklist: entries must be all ChecklistItem or all ChecklistGroup"))
    end
    keys = Set{Any}()
    for group in groups, item in group.items

        item.key in keys && throw(ArgumentError("Checklist: duplicate item key $(repr(item.key))"))
        push!(keys, item.key)
    end
    empty_rect = Tachikoma.Rect(1, 1, 0, 0)
    w = Checklist(groups, grouped, String(title), keys, Set{Any}(), tag_style, focused, "", false, 1, 1, 1, empty_rect, empty_rect)
    return set_checked!(w, checked)
end

function matches_filter(filter, label, tags)
    return isempty(filter) || occursin(filter, lowercase(label)) || any(t -> occursin(filter, lowercase(t)), tags)
end

# One `(group index, item indices)` per group shown under the filter.
function visible_entries(w::Checklist)
    filter = lowercase(w.filter)
    entries = Tuple{Int,Vector{Int}}[]
    for g in eachindex(w.groups)
        group = w.groups[g]
        group_hit = w.grouped && matches_filter(filter, group.label, group.tags)
        idxs = [i for i in eachindex(group.items) if group_hit || matches_filter(filter, group.items[i].label, group.items[i].tags)]
        (group_hit || !isempty(idxs)) && push!(entries, (g, idxs))
    end
    return entries
end

# Displayed rows as `(group index, item index)`; the item index is 0 for a group row.
function visible_rows(w::Checklist)
    rows = Tuple{Int,Int}[]
    for (g, idxs) in visible_entries(w)
        w.grouped && push!(rows, (g, 0))
        (!w.grouped || w.groups[g].expanded) && append!(rows, ((g, i) for i in idxs))
    end
    return rows
end

# Keys of the visible items of group `g`, or of all groups if `g` is `nothing`.
function visible_keys(w::Checklist, g = nothing)
    return [w.groups[gi].items[i].key for (gi, idxs) in visible_entries(w) if isnothing(g) || gi == g for i in idxs]
end

function clamp_cursor!(w::Checklist)
    w.cursor = clamp(w.cursor, 1, max(1, length(visible_rows(w))))
    return w
end

"""
    JuLeAna.checked(w::Checklist)

Keys of the selected items of `w`, in the order of the unfiltered list.
"""
function checked(w::Checklist)
    return [item.key for group in w.groups for item in group.items if item.key in w.selected]
end

"""
    JuLeAna.set_checked!(w::Checklist, keys)

Replace the selection of `w` with the items whose keys are in `keys`. Throws an
`ArgumentError` naming the keys that belong to no item; the selection is unchanged then.
"""
function set_checked!(w::Checklist, keys)
    unknown = [k for k in keys if !(k in w.keys)]
    isempty(unknown) || throw(ArgumentError("Checklist: unknown item keys $(join(repr.(unknown), ", "))"))
    empty!(w.selected)
    union!(w.selected, keys)
    return w
end

"""
    JuLeAna.set_checked!(f::Function, w::Checklist)

Replace the selection of `w` with the items for which `f(item::ChecklistItem)` is `true`.
"""
function set_checked!(f::Function, w::Checklist)
    empty!(w.selected)
    for group in w.groups, item in group.items

        f(item) && push!(w.selected, item.key)
    end
    return w
end

"""
    JuLeAna.current(w::Checklist)

The [`JuLeAna.ChecklistItem`](@ref) or [`JuLeAna.ChecklistGroup`](@ref) under the cursor
of `w`, or `nothing` if no rows are visible.
"""
function current(w::Checklist)
    rows = visible_rows(w)
    isempty(rows) && return nothing
    g, i = rows[clamp(w.cursor, firstindex(rows), lastindex(rows))]
    return i == 0 ? w.groups[g] : w.groups[g].items[i]
end

# Toggle the item or the visible items of the group at row `idx`.
function toggle_row!(w::Checklist, idx)
    rows = visible_rows(w)
    isempty(rows) && return nothing
    g, i = rows[idx]
    if i != 0
        k = w.groups[g].items[i].key
        k in w.selected ? delete!(w.selected, k) : push!(w.selected, k)
    else
        ks = visible_keys(w, g)
        all(in(w.selected), ks) ? setdiff!(w.selected, ks) : union!(w.selected, ks)
    end
    return nothing
end

function handle_filter_key!(w::Checklist, evt::Tachikoma.KeyEvent)
    if evt.key == :char && isprint(evt.char)
        w.filter *= evt.char
    elseif evt.key == :backspace
        w.filter = chop(w.filter)
    elseif evt.key == :enter
        w.editing = false
    elseif evt.key == :escape
        w.filter = ""
        w.editing = false
    end
    return clamp_cursor!(w)
end

"""
    Tachikoma.handle_key!(w::JuLeAna.Checklist, evt::Tachikoma.KeyEvent)::Bool

Apply the key event `evt` to `w` as described for [`JuLeAna.Checklist`](@ref). Return
`true` if the widget used the key and `false` otherwise.
"""
function Tachikoma.handle_key!(w::Checklist, evt::Tachikoma.KeyEvent)::Bool
    evt.action == Tachikoma.key_release && return false
    if w.editing
        handle_filter_key!(w, evt)
        return true
    end
    rows = visible_rows(w)
    n = length(rows)
    key = evt.key
    if key == :up
        w.cursor -= 1
    elseif key == :down
        w.cursor += 1
    elseif key == :pageup
        w.cursor -= w.page
    elseif key == :pagedown
        w.cursor += w.page
    elseif key == :home
        w.cursor = 1
    elseif key == :end_key
        w.cursor = n
    elseif key == :char && evt.char == ' '
        toggle_row!(w, clamp_cursor!(w).cursor)
    elseif key == :char && evt.char == 'a'
        union!(w.selected, visible_keys(w))
    elseif key == :char && evt.char == 'n'
        setdiff!(w.selected, visible_keys(w))
    elseif key == :char && evt.char == '/'
        w.editing = true
    elseif key == :escape && !isempty(w.filter)
        w.filter = ""
    elseif key in (:left, :right, :enter) && w.grouped && n > 0
        g, i = rows[clamp(w.cursor, 1, n)]
        if key == :left
            w.groups[g].expanded = false
            w.cursor = findfirst(==((g, 0)), visible_rows(w))
        elseif key == :right && i == 0
            w.groups[g].expanded = true
        elseif key == :enter && i == 0
            w.groups[g].expanded = !w.groups[g].expanded
        else
            return false
        end
    else
        return false
    end
    clamp_cursor!(w)
    return true
end

"""
    Tachikoma.handle_mouse!(w::JuLeAna.Checklist, evt::Tachikoma.MouseEvent)::Bool

Apply the mouse event `evt` to `w`. A left button press on a row moves the cursor to the
row and toggles it like Space does. The scroll wheel moves the cursor by one row while
the pointer is inside the area of the last render. Return `true` if the event was used.
"""
function Tachikoma.handle_mouse!(w::Checklist, evt::Tachikoma.MouseEvent)::Bool
    if evt.button == Tachikoma.mouse_left && evt.action == Tachikoma.mouse_press
        Base.contains(w.list, evt.x, evt.y) || return false
        idx = w.top + evt.y - w.list.y
        idx <= length(visible_rows(w)) || return false
        w.cursor = idx
        toggle_row!(w, idx)
        return true
    elseif evt.button in (Tachikoma.mouse_scroll_up, Tachikoma.mouse_scroll_down) && evt.action == Tachikoma.mouse_press
        Base.contains(w.rect, evt.x, evt.y) || return false
        w.cursor += evt.button == Tachikoma.mouse_scroll_up ? -1 : 1
        clamp_cursor!(w)
        return true
    end
    return false
end

# Border of a pane: the focused pane has a heavy border in the focus color and a title
# marked with `▶`, the others a thin border and a dim title.
function pane_block(title, focused::Bool)
    return focused ?
           Tachikoma.Block(; title = "▶ " * title, box = Tachikoma.BOX_HEAVY, border_style = Tachikoma.tstyle(:border_focus, bold = true)) :
           Tachikoma.Block(; title, title_style = Tachikoma.tstyle(:text_dim), border_style = Tachikoma.tstyle(:border))
end

"""
    Tachikoma.render(w::JuLeAna.Checklist, rect::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw `w` into `rect` of `buf`. The view scrolls to keep the cursor row visible. Rows
never extend beyond `rect`: long labels are shortened, and the tags of a row are dropped
if they would leave less than a short label.
"""
function Tachikoma.render(w::Checklist, rect::Tachikoma.Rect, buf::Tachikoma.Buffer)
    n_all = length(w.keys)
    title = strip("$(w.title)  $(length(w.selected))/$n_all selected")
    # the title with its padding and focus marker must fit between the corners
    title_room = rect.width - 5 - 2 * w.focused
    block = pane_block(textwidth(title) <= title_room ? title : first(title, max(0, title_room - 1)) * "…", w.focused)
    w.rect = rect
    w.list = Tachikoma.Rect(rect.x, rect.y, 0, 0)
    w.page = 1
    (rect.width < 3 || rect.height < 3) && return nothing
    area = Tachikoma.render(block, rect, buf)
    show_filter = w.editing || !isempty(w.filter)
    height = area.height - show_filter
    w.list = Tachikoma.Rect(area.x, area.y, area.width, max(0, height))
    w.page = max(1, height)

    rows = visible_rows(w)
    clamp_cursor!(w)
    w.top = clamp(w.top, 1, max(1, length(rows) - height + 1))
    w.cursor < w.top && (w.top = w.cursor)
    w.cursor > w.top + height - 1 && (w.top = w.cursor - height + 1)

    text = Tachikoma.tstyle(:text)
    dim = Tachikoma.tstyle(:text_dim)
    highlight = Tachikoma.tstyle(:accent, bold = true)
    x_max = Tachikoma.right(area)
    clip(s, n) = textwidth(s) <= n ? s : n <= 0 ? "" : first(s, n - 1) * "…"
    selected_in(g, idxs) = count(i -> w.groups[g].items[i].key in w.selected, idxs)
    entries = Dict(visible_entries(w))
    for r in 0:(height - 1)
        row = w.top + r
        row <= length(rows) || break
        g, i = rows[row]
        y = area.y + r
        if i == 0
            group = w.groups[g]
            idxs = entries[g]
            n_sel = selected_in(g, idxs)
            box = n_sel == 0 ? "[ ]" : n_sel == length(idxs) ? "[x]" : "[~]"
            indent = group.expanded ? "▾ " : "▸ "
            label, tags = group.label, group.tags
            label_style = Tachikoma.tstyle(:primary, bold = true)
        else
            item = w.groups[g].items[i]
            box = item.key in w.selected ? "[x]" : "[ ]"
            indent = w.grouped ? "  " : ""
            label, tags = item.label, item.tags
            label_style = text
        end
        box_style = box == "[x]" ? Tachikoma.tstyle(:success) : box == "[~]" ? Tachikoma.tstyle(:warning) : dim
        at_cursor = w.focused && row == w.cursor
        at_cursor && (label_style = highlight)
        tag_text = join(tags, "  ")
        room = area.width - textwidth(indent) - 4
        tag_room = room - textwidth(tag_text) - 2
        if !isempty(tag_text) && tag_room >= min(textwidth(label), 8)
            label = clip(label, tag_room)
            tx = x_max - textwidth(tag_text) + 1
            for tag in tags
                tx = Tachikoma.set_string!(buf, tx, y, tag, something(w.tag_style(tag), dim); max_x = x_max) + 2
            end
        else
            label = clip(label, room)
        end
        x = Tachikoma.set_string!(buf, area.x, y, indent, label_style; max_x = x_max)
        x = Tachikoma.set_string!(buf, x, y, box, at_cursor ? Tachikoma.Style(; fg = box_style.fg, bold = true) : box_style; max_x = x_max)
        Tachikoma.set_string!(buf, x, y, " " * label, label_style; max_x = x_max)
    end
    if show_filter && area.height >= 1
        Tachikoma.set_string!(buf, area.x, Tachikoma.bottom(area), clip("/" * w.filter * (w.editing ? "▏" : ""), area.width),
                              Tachikoma.tstyle(:accent); max_x = x_max)
    end
    return nothing
end
