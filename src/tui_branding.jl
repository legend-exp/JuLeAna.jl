# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const DOCS_URL = "https://legend-exp.github.io/JuLeAna.jl/stable/"

# Keys listed by the help overlay as `(keys, description)`: Setup page, Graph page, Progress page, Log page, Reports page, History page, all pages.
const HELP_KEYS = (setup = (("Tab  Shift-Tab", "next, previous pane"), ("↑ ↓ PgUp PgDn Home End", "move in a pane"),
                            ("← → Enter", "fold, unfold a period"), ("Space", "check or uncheck the item"), ("a  n", "check all, none"),
                            ("/", "filter the list (Enter keeps, Esc clears)"), ("c  p", "check the cal, phy processors"),
                            ("d", "add the steps that checked steps wait for"), ("e", "edit the keyword arguments of the processor"),
                            ("e", "edit the workers, flags and Julia settings of the run modes (Run mode row of the Options pane)"),
                            ("Space  Enter", "cycle the option in the Options pane; open the picker of the data production or dataset"),
                            ("s", "start processing"), ("x  X", "stop after the running items, stop at once"), ("r", "reload the config"),
                            ("g", "rebuild the dependency graph"), ("W", "start workers"), ("N", "create a new data production"),
                            ("w", "write the settings to the config file"), ("Mouse", "click to check, fold or focus; wheel scrolls")),
                   graph = (("↑ ↓ PgUp PgDn Home End", "move the cursor"), ("Space", "select or deselect the processor"),
                            ("d", "add the steps that selected steps wait for"), ("h", "show or hide unselected processors"),
                            ("v", "state icons of the last run or on disk"), ("Mouse", "click a row, wheel moves the cursor")),
                   workers = (("Tab", "switch between the allocations and the workers"),
                              ("↑ ↓", "select an allocation or worker; scroll SLURM"),
                              ("PgUp PgDn End", "scroll the output; End: newest line"),
                              ("s", "show the workers or SLURM (with SLURM only)"), ("a", "start workers (a new allocation)"),
                              ("c", "cancel the selected running allocation (asks)"), ("C", "cancel all allocations (asks; y confirms)"),
                              ("p", "postpone the cancel of idle allocations"), ("r", "read the overview again"),
                              ("o", "edit the SLURM options: partition, time, nodes, workers, threads, memory"),
                              ("e", "edit the start script (Ctrl-O saves, Esc closes)"),
                              ("Mouse", "click a row, wheel scrolls the output")),
                   progress = (("↑ ↓ PgUp PgDn Home End", "move the cursor"), ("Enter  ← →", "fold, unfold a group"),
                               ("Enter on a step", "messages of the step (again: close)"),
                               ("PgUp PgDn", "scroll the messages while they are open"), ("End", "newest message while they are open"),
                               ("Esc", "close the messages"), ("f", "follow the running step"),
                               ("Mouse", "click a row, wheel moves the cursor")),
                   log = (("↑ ↓ PgUp PgDn Home", "scroll; turns following off"), ("End", "jump to the newest line and follow"),
                          ("f", "follow the newest line"), ("l", "cycle the level: all, warnings, errors"),
                          ("/", "filter the lines (Enter keeps, Esc clears)"), ("Mouse", "wheel scrolls")),
                   reports = (("↑ ↓ PgUp PgDn Home End", "move the cursor; scroll the failures"), ("Enter  ← →", "fold, unfold a group"),
                              ("Enter on a report", "open the report"), ("Tab", "switch between the reports and the failures"),
                              ("a", "all reports on disk or those of the current run"), ("r", "read the reports again"),
                              ("↑ ↓ PgUp PgDn Home End", "scroll an open report"), ("Esc  q", "close the open report"),
                              ("Mouse", "click a row, wheel moves the cursor or scrolls")),
                   history = (("↑ ↓ ← →", "move the cursor; on a partition row ← → move by period"),
                              ("PgUp PgDn Home End", "move by a page of rows; first, last run"),
                              ("Enter on a report", "open the report (history cells have none)"), ("r", "read the grid again"),
                              ("↑ ↓ PgUp PgDn Home End", "scroll an open report"), ("Esc  q", "close the open report"),
                              ("Mouse", "click a cell, wheel moves the cursor")),
                   sync = (("Tab  Shift-Tab", "next, previous field, button; the tree after the last"),
                           ("Enter", "edit a field (Production: choose from the list), press a button, expand a row"),
                           ("Esc", "cancel an edit, close the list, back to the tree"),
                           ("c  o  s", "Connect, Load selection, Save selection"), ("e  t", "estimate, estimate and sync"),
                           ("p", "show or hide the settings"),
                           ("Space  l", "copy, link the row (a detector row of a per-detector tier: its files)"),
                           ("x", "extract the detector row"), ("n", "copy the first N filekeys of a run"),
                           ("Mouse", "click fields, buttons and rows; the wheel scrolls")),
                   common = (("1-$(length(TUI_PAGES))", "open a page"), ("q  Ctrl-C", "quit"), ("?", "show these keys"),
                             ("T", "next color theme, kept for the next start"),
                             ("Ctrl-G", "toggle mouse reporting (off allows selecting text)"),
                             ("Ctrl-Y", "copy the screen as text to the clipboard"),
                             ("Ctrl-T  Ctrl-S", "Tachikoma: color themes, display settings"),
                             ("Ctrl-A  Ctrl-R", "Tachikoma: toggle animations, record the screen")))

# Version of this package as `v1.2.3`, read once.
const VERSION_TEXT = Ref("")
function juleana_version()
    isempty(VERSION_TEXT[]) && (VERSION_TEXT[] = "v" * string(pkgversion(JuLeAna)))
    return VERSION_TEXT[]
end

# Color of a logo color name: the outline takes the text color of the theme.
function logo_color(name::Symbol)
    name === :outline && return Tachikoma.theme().text
    name === :red && return TITLE_COLORS[1]
    name === :green && return TITLE_COLORS[2]
    name === :purple && return TITLE_COLORS[3]
    return throw(ArgumentError("logo: unknown color $(repr(name))"))
end

# Row of a logo as a vector of `(text, color name)` segments.
logo_segments(row::AbstractString) = [(row, :outline)]
logo_segments(row) = row

"""
    JuLeAna.logo_size(rows)

Width in terminal cells and number of rows of the logo `rows`, as in
[`JuLeAna.render_logo`](@ref).
"""
function logo_size(rows)
    return (maximum(row -> sum(s -> textwidth(s[1]), logo_segments(row); init = 0), rows; init = 0), length(rows))
end

"""
    JuLeAna.render_logo(rows, x, y, buf::Tachikoma.Buffer; max_x, max_y)

Draw the logo `rows` with its top left cell at column `x` and row `y` of `buf`, clipped at
column `max_x` and row `max_y` (default: the edges of `buf`). Each row is a string in the
text color of the theme or a vector of `(text, color)` segments with the color `:outline`
(the text color of the theme), `:red`, `:green` or `:purple`. Spaces are transparent: they
leave the cell as it is.
"""
function render_logo(rows, x::Integer, y::Integer, buf::Tachikoma.Buffer; max_x::Integer = Tachikoma.right(buf.area),
                     max_y::Integer = Tachikoma.bottom(buf.area))
    for (j, row) in enumerate(rows)
        cy = y + j - 1
        cx = x
        for (text, name) in logo_segments(row)
            style = Tachikoma.Style(; fg = logo_color(name))
            for char in text
                if char != ' ' && cx <= max_x && cy <= max_y && cx >= buf.area.x && cy >= buf.area.y
                    Tachikoma.set_char!(buf, cx, cy, char, style)
                end
                cx += textwidth(char)
            end
        end
    end
    return nothing
end

# The full logo if it fits `width` x `height` cells, else the name in block letters, else `nothing`.
function fitting_logo(width::Integer, height::Integer)
    for rows in (TEXT_LOGO, LOGO_LETTERS)
        w, h = logo_size(rows)
        w <= width && h <= height && return rows
    end
    return nothing
end

# The name `JuLeAna` in the colors of the logo.
function logo_name_spans()
    return [(part, Tachikoma.Style(; fg = TITLE_COLORS[i], bold = true)) for (i, part) in enumerate(("Ju", "Le", "Ana"))]
end

# `nothing` while the session loads, `:loaded` once it is loaded and `:failed` if loading failed.
function load_outcome(snap)
    isnothing(snap) && return nothing
    snap.state in (:idle, :loading) || return :loaded
    return isnothing(snap.last_error) ? nothing : :failed
end

# Whether the startup screen is shown: from `start!` until the session has loaded and
# `splash_seconds` have passed.
function splash_active(m::JuLeAnaTUI)
    m.splash || return false
    # with the new-production form open and no session to load, the screen ends after `splash_seconds`
    waiting = isnothing(load_outcome(m.snap)) && !(!isnothing(m.production) && !isnothing(m.snap) && m.snap.state === :idle)
    return waiting || time() - m.started_at < m.splash_seconds
end

# Draw the startup screen into `area`: the logo, version, docs link and load state, centered.
# The logo is the full logo or the name in block letters, whichever fits above the text; with
# neither, the name is a line of text.
function render_splash(m::JuLeAnaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    dim = Tachikoma.tstyle(:text_dim)
    outcome = load_outcome(m.snap)
    spinner = string(Tachikoma.SPINNER_BRAILLE[mod1(m.ticks, length(Tachikoma.SPINNER_BRAILLE))])
    state = isnothing(outcome) ? [(spinner * " ", Tachikoma.tstyle(:warning)), ("Loading the session…", Tachikoma.tstyle(:text))] :
            outcome === :loaded ? [("Session loaded", Tachikoma.tstyle(:success))] :
            [("Loading the session failed", Tachikoma.tstyle(:error, bold = true))]
    lines = [[(juleana_version(), dim)], [(DOCS_URL, Tachikoma.tstyle(:accent; underline = true, hyperlink = DOCS_URL))], [("", dim)],
             state]
    logo = fitting_logo(area.width, area.height - 1 - length(lines))
    isnothing(logo) && pushfirst!(lines, logo_name_spans(), [("", dim)])
    logo_h = isnothing(logo) ? 0 : logo_size(logo)[2] + 1
    y = area.y + max(0, (area.height - logo_h - length(lines)) ÷ 2)
    if !isnothing(logo)
        w, h = logo_size(logo)
        render_logo(logo, area.x + (area.width - w) ÷ 2, y, buf; max_x = Tachikoma.right(area), max_y = Tachikoma.bottom(area))
        y += h + 1
    end
    for spans in lines
        y > Tachikoma.bottom(area) && break
        width = sum(s -> textwidth(s[1]), spans)
        put_spans!(buf, area.x + max(0, (area.width - width) ÷ 2), y, Tachikoma.right(area), spans)
        y += 1
    end
    return nothing
end

# Name and root of the data production named by `LEGEND_DATA_CONFIG` (the last file, see
# `data_config_files`): the folder that holds its data config, and its parent. `nothing` if
# the variable is not set.
function current_production()
    haskey(ENV, "LEGEND_DATA_CONFIG") || return nothing
    folder = dirname(abspath(last(data_config_files())))
    return (basename(folder), dirname(folder))
end

# Draw the name `JuLeAna` with the version, and below it the current data production, right
# aligned at the right end of the tab row `area`. Both lines need to fit right of the tabs;
# the root path of the production is clipped from the left, and nothing is drawn if even the
# first line does not fit.
function render_corner_logo(m::JuLeAnaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    used = isempty(m.tabs._tab_rects) ? area.x - 1 : maximum(Tachikoma.right, m.tabs._tab_rects)
    right = Tachikoma.right(area)
    available = right - used - 1
    title = vcat(logo_name_spans(), [(" " * juleana_version(), Tachikoma.tstyle(:text_dim))])
    title_width = sum(s -> textwidth(s[1]), title)
    title_width <= available || return nothing
    put_spans!(buf, right - title_width + 1, area.y, right, title)
    area.height >= 2 || return nothing
    production = current_production()
    spans = if isnothing(production)
        [("no data production", Tachikoma.tstyle(:text_dim))]
    else
        name, root = production
        room = available - textwidth(name) - 2
        root = textwidth(root) <= room ? root : room >= 2 ? "…" * last(root, room - 1) : ""
        isempty(root) ? [(name, Tachikoma.tstyle(:text))] : [(name, Tachikoma.tstyle(:text)), ("  " * root, Tachikoma.tstyle(:text_dim))]
    end
    width = sum(s -> textwidth(s[1]), spans)
    width <= available && put_spans!(buf, right - width + 1, area.y + 1, right, spans)
    return nothing
end

# Draw the key help of the visible page of `m` as a panel centered in `area`.
function render_help(m::JuLeAnaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    sections = Tuple{String,Any}[]
    m.page == 1 && push!(sections, ("Setup page", HELP_KEYS.setup))
    m.page == 2 && push!(sections, ("Graph page", HELP_KEYS.graph))
    m.page == 3 && push!(sections, ("Workers page", HELP_KEYS.workers))
    m.page == 4 && push!(sections, ("Progress page", HELP_KEYS.progress))
    m.page == 5 && push!(sections, ("Log page", HELP_KEYS.log))
    m.page == 6 && push!(sections, ("Reports page", HELP_KEYS.reports))
    m.page == 7 && push!(sections, ("History page", HELP_KEYS.history))
    m.page == 8 && push!(sections, ("Sync page", HELP_KEYS.sync))
    push!(sections, ("All pages", HELP_KEYS.common))
    key_width = maximum(textwidth(k) for (_, entries) in sections for (k, _) in entries) + 2
    lines = Vector{Tuple{String,Tachikoma.Style}}[]
    for (title, entries) in sections
        push!(lines, [(title, Tachikoma.tstyle(:accent, bold = true))])
        for (keys, description) in entries
            push!(lines, [("  " * rpad(keys, key_width), Tachikoma.tstyle(:warning, bold = true)), (description, Tachikoma.tstyle(:text))])
        end
        push!(lines, [("", Tachikoma.tstyle(:text))])
    end
    push!(lines,
          [(juleana_version() * "  ", Tachikoma.tstyle(:text_dim)),
           (DOCS_URL, Tachikoma.tstyle(:accent; underline = true, hyperlink = DOCS_URL))])
    push!(lines, [("Esc, ? or q closes this panel", Tachikoma.tstyle(:text_dim))])
    width = maximum(sum(s -> textwidth(s[1]), spans) for spans in lines) + 4
    rect = Tachikoma.center(area, min(width + 2, area.width), min(length(lines) + 2, area.height))
    for row in rect.y:Tachikoma.bottom(rect), col in rect.x:Tachikoma.right(rect)

        Tachikoma.set_char!(buf, col, row, ' ', Tachikoma.RESET)
    end
    inner = Tachikoma.render(Tachikoma.Block(; title = "Keys", border_style = Tachikoma.tstyle(:accent),
                                             title_style = Tachikoma.tstyle(:title)), rect, buf)
    # the version, link and closing hint stay visible; the key list is cut
    footer = lines[(end - 1):end]
    body = first(lines[1:(end - 2)], max(0, inner.height - length(footer)))
    for (i, spans) in pairs(vcat(body, footer))
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        put_spans!(buf, inner.x + 1, y, Tachikoma.right(inner), spans)
    end
    return nothing
end
