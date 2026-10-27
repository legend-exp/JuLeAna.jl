# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Rows of the options pane: label and the values a row cycles through.
const SETUP_OPTIONS = ((:reprocess, "Reprocess", (nothing, true, false)),
                       (:processor_log_level, "Processor log level", (nothing, Logging.Debug, Logging.Info, Logging.Warn, Logging.Error)),
                       (:processor_plot_level, "Processor plot level", (nothing, :debug, :info)),
                       (:check_dependencies, "Check dependencies", (true, false)),
                       (:analysis_runs_only, "Analysis runs only", (true, false)), (:runmode, "Run mode", (:local, :slurm)))

"""
    SetupPicker(kind::Symbol, items::Vector{String}, cursor::Integer)

Open list of names on the Setup page: `kind` is `:production` or `:dataset`, `cursor` the
index of the chosen item in `items`, and `top` the index of the first item shown at the last render.
"""
mutable struct SetupPicker
    kind::Symbol
    items::Vector{String}
    cursor::Int
    top::Int
end

SetupPicker(kind, items, cursor) = SetupPicker(kind, items, cursor, 1)

"""
    SetupPage()

State of the Setup page of the terminal user interface: a [`JuLeAna.Checklist`](@ref)
of periods with their runs, one of the run-level and one of the partition-level
processors, the options pane, the pane with the production root, the data production and
the dataset, and the
runinfo of the period or run under the cursor of the periods. The checklists are built from the controller
snapshots by [`JuLeAna.sync_setup!`](@ref); keys are handled by
[`JuLeAna.setup_key!`](@ref).

`focus` is the focused pane: 1 periods, 2 run processors, 3 partition processors,
4 options, 5 production pane, where `source` is the chosen line (1 root, 2 production,
3 dataset). `editor` is the open [`JuLeAna.KwargsEditor`](@ref) or [`JuLeAna.RunmodeEditor`](@ref), `confirm` is `:write`
while writing the config waits for confirmation, and `picker` is the open
[`JuLeAna.SetupPicker`](@ref). `root` is the folder the productions are listed under, or
`nothing` for the parent folder of the current data production (see
[`JuLeAna.production_root`](@ref)); `root_edit` is the text of the root while it is edited
in place, `nothing` otherwise, and `root_hint` a message below the lines of the pane (the
completion candidates or the error of the root) with whether it is an error. `choices`
holds the names the pickers list, read by [`JuLeAna.read_choices`](@ref): `nothing` before
they are read, the message of the read error, or a `NamedTuple` with `productions` and
`datasets`.
"""
mutable struct SetupPage
    periods::Checklist
    run_procs::Checklist
    part_procs::Checklist
    focus::Int
    option::Int
    # available periods, runs and processors the checklists were built for
    layout::Any
    editor::Union{Nothing,KwargsEditor,RunmodeEditor}
    confirm::Union{Nothing,Symbol}
    # inside of the options pane at the last render
    options::Tachikoma.Rect
    # runinfo summary (see `dataset_summary`), the message of its read error, or
    # `nothing` before it is read; whether it is read or being read for the loaded session
    dataset::Any
    dataset_requested::Bool
    # set by `N`, taken by the interface, which opens the new-production form
    new_production::Bool
    source::Int
    picker::Union{Nothing,SetupPicker}
    choices::Any
    # what `choices` was read for, see `choices_sync!`
    choices_key::Any
    # inside of the production pane and of the picker list at the last render
    production_area::Tachikoma.Rect
    picker_area::Tachikoma.Rect
    root::Union{Nothing,String}
    root_edit::Union{Nothing,String}
    root_hint::Tuple{String,Bool}
end

function SetupPage()
    return SetupPage(Checklist(ChecklistItem[]; title = "Periods / runs"),
                     Checklist(ChecklistItem[]; title = "Run processors", focused = false, tag_style = setup_tag_style),
                     Checklist(ChecklistItem[]; title = "Partition processors", focused = false, tag_style = setup_tag_style), 1, 1,
                     nothing, nothing, nothing, Tachikoma.Rect(1, 1, 0, 0), nothing, false, false, 1, nothing, nothing, nothing,
                     Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0), nothing, nothing, ("", false))
end

setup_panes(page::SetupPage) = (page.periods, page.run_procs, page.part_procs)

# Selected runs of each selected period in `snap` that are in the dataset.
function selected_period_runs(snap)
    return Dict(p => (snap.runs isa AbstractDict ? intersect(snap.available_runs[p], get(snap.runs, p, snap.available_runs[p])) :
                      isnothing(snap.runs) ? snap.available_runs[p] : intersect(snap.available_runs[p], snap.runs))
                for p in snap.periods if haskey(snap.available_runs, p))
end

# Style of a processor tag in the checklists: category, rank.
function setup_tag_style(tag)
    tag == "cal" && return Tachikoma.tstyle(:primary)
    tag == "phy" && return Tachikoma.tstyle(:secondary)
    startswith(tag, "rank ") && return Tachikoma.tstyle(:text_dim)
    return nothing
end

processor_tags(p) = [string(p.category), "rank $(lpad(p.rank, 2, '0'))"]

"""
    JuLeAna.sync_setup!(page::SetupPage, snap; pending::Bool = false)

Bring `page` in line with the controller snapshot `snap`. The checklists are rebuilt when
the available periods, runs or processors change, keeping their cursor and filter
otherwise. Unless commands of the page are `pending`, the checked items are set to the
selection of `snap`.
"""
function sync_setup!(page::SetupPage, snap; pending::Bool = false)
    (isnothing(snap) || isempty(snap.processors)) && return page
    layout = (snap.available_periods, snap.available_runs,
              [(p.name, p.level, p.category, p.rank, p.enabled, p.dependencies) for p in snap.processors])
    if layout != page.layout
        selected = Set(snap.periods)
        groups = [ChecklistGroup(p, string(p), [ChecklistItem((p, r), string(r)) for r in snap.available_runs[p]];
                                 tags = [(n = length(snap.available_runs[p]); n == 1 ? "1 run" : "$n runs")], expanded = p in selected)
                  for p in snap.available_periods]
        items(level) = [ChecklistItem(p.name, display_name(p.name); tags = processor_tags(p)) for p in snap.processors if p.level === level]
        focused = page.focus
        page.periods = Checklist(groups; title = "Periods / runs", focused = focused == 1)
        page.run_procs = Checklist(items(:run); title = "Run processors", focused = focused == 2, tag_style = setup_tag_style)
        page.part_procs = Checklist(items(:partition); title = "Partition processors", focused = focused == 3, tag_style = setup_tag_style)
        page.layout = layout
        pending = false
    end
    if !pending
        set_checked!(page.periods, [(p, r) for (p, runs) in selected_period_runs(snap) for r in runs])
        set_checked!(page.run_procs, snap.run_steps)
        set_checked!(page.part_procs, snap.partition_steps)
    end
    return page
end

# The `SelectRuns` command for the periods and runs checked on `page`.
function period_selection(page::SetupPage, snap)
    chosen = Dict{DataPeriod,Vector{DataRun}}()
    for (p, r) in checked(page.periods)
        push!(get!(chosen, p, DataRun[]), r)
    end
    return SelectRuns(Dict(p => (length(runs) == length(snap.available_runs[p]) ? nothing : runs) for (p, runs) in chosen))
end

function steps_selection(page::SetupPage)
    return SelectSteps(checked(page.run_procs), checked(page.part_procs))
end

option_value(snap, key) = getproperty(snap, key)

function option_command(key, value)
    key === :reprocess && return SetReprocess(value)
    key === :processor_log_level && return SetProcessorLogLevel(value)
    key === :processor_plot_level && return SetProcessorPlotLevel(value)
    key === :check_dependencies && return SetCheckDependencies(value)
    key === :runmode && return SetRunmode(value)
    return SetAnalysisRunsOnly(value)
end

"""
    JuLeAna.setup_key!(page::SetupPage, evt::Tachikoma.KeyEvent, snap, send)

Handle the key `evt` on the Setup page and return whether it was used. `snap` is the
latest controller snapshot (or `nothing`) and `send(cmd)` sends a controller command.

An open kwargs or run mode editor gets every key (see [`JuLeAna.kwargs_key!`](@ref) and
[`JuLeAna.runmode_key!`](@ref)); while writing
the config waits for confirmation, `y` sends [`WriteConfig`](@ref) for the config folder
of the data production and any other key cancels. An open picker gets every key: Up and
Down move the cursor, Enter sends [`SelectProduction`](@ref) or [`SelectDataset`](@ref) for the chosen
name unless it is the current one, and Escape closes the picker. While the production root is edited
every key goes to its text (see [`JuLeAna.root_key!`](@ref)). Otherwise the focused checklist gets the key
first; a change of its selection sends `SelectRuns` or `SelectSteps`. Then: Tab and Shift-Tab move between the panes; in a processor pane
`c` and `p` select the `cal` and `phy` processors of the pane, `d` adds the steps
the selected steps wait for and `e` opens the settings editor (see [`JuLeAna.kwargs_key!`](@ref)) for the processor under the
cursor; in the options pane Up and Down choose a row, Space or
Enter cycles its value and `e` on the Run mode row opens the editor of the settings of the run modes; in the production pane Up and Down choose the root, the production or the
dataset, Space or Enter edits the root in place or opens the picker of the production or dataset
once the names are read; `s` starts processing, `x` stops it after the running items, `X`
stops it without waiting for them, `r` reloads the config, `g` rebuilds the
dependency graph, `W` starts a worker allocation with [`AddWorkers`](@ref) and `w` asks to write
the current settings to `config/processing_config.yaml` of the data production. `N` sets
`page.new_production`, which asks the interface to open the new-production form (see
[`JuLeAna.ProductionForm`](@ref)); the checklists use `n` to uncheck all items.
"""
function setup_key!(page::SetupPage, evt::Tachikoma.KeyEvent, snap, send)
    evt.action == Tachikoma.key_release && return false
    if !isnothing(page.editor)
        close = page.editor isa KwargsEditor ? kwargs_key!(page.editor, evt, snap, send) : runmode_key!(page.editor, evt, snap, send)
        close === :close && (page.editor = nothing)
        return true
    end
    if !isnothing(page.root_edit)
        root_key!(page, evt)
        return true
    end
    if page.confirm === :write
        evt.key == :char && evt.char == 'y' && !isnothing(snap) && send(WriteConfig())
        page.confirm = nothing
        return true
    end
    if !isnothing(page.picker)
        picker_key!(page, evt, snap, send)
        return true
    end
    panes = setup_panes(page)
    if page.focus <= length(panes)
        list = panes[page.focus]
        before = checked(list)
        if Tachikoma.handle_key!(list, evt)
            if checked(list) != before && !isnothing(snap)
                send(page.focus == 1 ? period_selection(page, snap) : steps_selection(page))
            end
            return true
        end
    end
    key, char = evt.key, evt.char
    if key == :tab || key == :backtab
        page.focus = mod1(page.focus + (key == :tab ? 1 : -1), length(panes) + 2)
        for (i, list) in pairs(panes)
            list.focused = i == page.focus
        end
    elseif page.focus in (2, 3) && key == :char && char in ('c', 'p') && !isnothing(snap)
        category = char == 'c' ? :cal : :phy
        level = page.focus == 2 ? :run : :partition
        names = Set(p.name for p in snap.processors if p.level === level && p.category === category)
        set_checked!(item -> item.key in names, panes[page.focus])
        send(steps_selection(page))
    elseif page.focus in (2, 3) && key == :char && char == 'd' && !isnothing(snap)
        chosen = required_processors(processor_graph(snap.processors), vcat(checked(page.run_procs), checked(page.part_procs)))
        set_checked!(item -> item.key in chosen, page.run_procs)
        set_checked!(item -> item.key in chosen, page.part_procs)
        send(steps_selection(page))
    elseif page.focus in (2, 3) && key == :char && char == 'e' && !isnothing(current(panes[page.focus]))
        page.editor = KwargsEditor(current(panes[page.focus]).key)
    elseif page.focus == 4 && key == :char && char == 'e' && SETUP_OPTIONS[page.option][1] === :runmode && !isnothing(snap)
        page.editor = RunmodeEditor()
    elseif key == :char && char == 'w' && !isnothing(snap) && !isnothing(snap.config_file)
        page.confirm = :write
    elseif page.focus == 4 && key in (:up, :down)
        page.option = clamp(page.option + (key == :up ? -1 : 1), 1, length(SETUP_OPTIONS))
    elseif page.focus == 4 && (key == :enter || (key == :char && char == ' ')) && !isnothing(snap)
        cycle_option(page, snap, send)
    elseif page.focus == 5 && key in (:up, :down)
        page.source = clamp(page.source + (key == :up ? -1 : 1), 1, 3)
    elseif page.focus == 5 && (key == :enter || (key == :char && char == ' '))
        open_line!(page, snap)
    elseif key == :char && char == 's'
        send(StartProcessing())
    elseif key == :char && char == 'x'
        send(StopProcessing())
    elseif key == :char && char == 'X'
        send(StopProcessing(; force = true))
    elseif key == :char && char == 'r'
        send(ReloadConfig())
    elseif key == :char && char == 'g'
        send(ResetDependencyGraph())
    elseif key == :char && char == 'W'
        send(AddWorkers())
    elseif key == :char && char == 'N'
        page.new_production = true
    else
        return false
    end
    return true
end

"""
    JuLeAna.setup_mouse!(page::SetupPage, evt::Tachikoma.MouseEvent, snap, send)

Pass the mouse event `evt` to the checklist under the pointer, focus that pane, and send
the new selection if it changed. A left click in the options pane focuses it; on an
option row it also chooses the row and sends its next value. A left click in the
production pane focuses it and edits the root or opens the picker of the line. While the root is edited, a
click is used without effect. While a picker is open, a
left click on an item chooses it and every other event is used without effect. Return whether the event
was used.
"""
function setup_mouse!(page::SetupPage, evt::Tachikoma.MouseEvent, snap, send)
    (isnothing(page.editor) && isnothing(page.confirm)) || return false
    isnothing(page.root_edit) || return true
    if !isnothing(page.picker)
        picker = page.picker
        if evt.button == Tachikoma.mouse_left && evt.action == Tachikoma.mouse_press && Base.contains(page.picker_area, evt.x, evt.y)
            i = picker.top + evt.y - page.picker_area.y
            if i in eachindex(picker.items)
                picker.cursor = i
                picker_choose!(page, snap, send)
            end
        end
        return true
    end
    panes = setup_panes(page)
    function focus!(i)
        page.focus = i
        for (j, other) in pairs(panes)
            other.focused = j == i
        end
    end
    for (i, list) in pairs(panes)
        before = checked(list)
        Tachikoma.handle_mouse!(list, evt) || continue
        focus!(i)
        if checked(list) != before && !isnothing(snap)
            send(i == 1 ? period_selection(page, snap) : steps_selection(page))
        end
        return true
    end
    if evt.button == Tachikoma.mouse_left && evt.action == Tachikoma.mouse_press && Base.contains(page.options, evt.x, evt.y)
        focus!(length(panes) + 1)
        row = evt.y - page.options.y + 1
        if !isnothing(snap) && !isempty(snap.processors) && row in eachindex(SETUP_OPTIONS)
            page.option = row
            cycle_option(page, snap, send)
        end
        return true
    end
    if evt.button == Tachikoma.mouse_left && evt.action == Tachikoma.mouse_press && Base.contains(page.production_area, evt.x, evt.y)
        focus!(length(panes) + 2)
        page.source = clamp(evt.y - page.production_area.y + 1, 1, 3)
        open_line!(page, snap)
        return true
    end
    return false
end

# Start editing the root (`page.source == 1`), or open the picker of the production
# (`page.source == 2`) or the dataset once the names are read, with the cursor on the
# current name.
function open_line!(page::SetupPage, snap)
    if page.source == 1
        page.root_edit, page.root_hint = production_root(page), ("", false)
        return nothing
    end
    page.choices isa NamedTuple || return nothing
    kind = page.source == 2 ? :production : :dataset
    if kind === :production
        current = current_production()
        folder = isnothing(current) ? "" : joinpath(last(current), first(current))
        items = page.choices.productions
        cursor = findfirst(n -> abspath(joinpath(production_root(page), n)) == folder, items)
    else
        items = page.choices.datasets
        cursor = findfirst(==(dataset_name(snap)), items)
    end
    page.picker = SetupPicker(kind, items, something(cursor, 1))
    return nothing
end

"""
    JuLeAna.production_root(page::SetupPage)

Return the folder the productions of the Setup page are listed under: `page.root` if it was
set, else the parent folder of the current data production, or `""` if none is set.
"""
function production_root(page::SetupPage)
    isnothing(page.root) || return page.root
    current = current_production()
    return isnothing(current) ? "" : last(current)
end

"""
    JuLeAna.root_key!(page::SetupPage, evt::Tachikoma.KeyEvent)

Handle the key `evt` while the production root of `page` is edited in `page.root_edit`.
Printable characters are appended and Backspace removes the last one. Tab completes the
text with [`JuLeAna.complete_path`](@ref): it extends the text by the common prefix of the
folders it matches and, if there are several, shows up to 8 of them in `page.root_hint`.
Enter sets the root to the text, with `~` expanded, if that is an existing absolute folder,
which makes the productions be read again, and shows an error and keeps editing otherwise.
Escape ends the edit and keeps the root. Every other key is ignored.
"""
function root_key!(page::SetupPage, evt::Tachikoma.KeyEvent)
    text, key, char = page.root_edit, evt.key, evt.char
    page.root_hint = ("", false)
    if key == :escape
        page.root_edit = nothing
    elseif key == :enter
        expanded = text == "~" || startswith(text, "~/") ? homedir() * text[2:end] : text
        if !isabspath(expanded) || !isdir(expanded)
            page.root_hint = ("Not an existing absolute folder", true)
        else
            page.root, page.root_edit, page.choices = expanded == "/" ? expanded : chopsuffix(abspath(expanded), "/"), nothing, nothing
        end
    elseif key == :tab
        completed, candidates = complete_path(text)
        page.root_edit = completed
        if length(candidates) > 1
            shown = first(candidates, 8)
            page.root_hint = (join(shown, "  ") *
                              (length(candidates) > length(shown) ? "  and $(length(candidates) - length(shown)) more" : ""), false)
        end
    elseif key == :backspace
        page.root_edit = chop(text)
    elseif key == :char && isprint(char)
        page.root_edit = text * char
    end
    return nothing
end

dataset_name(snap) = isnothing(snap) ? "default" : snap.dataset

# Handle a key of the open picker of `page`.
function picker_key!(page::SetupPage, evt::Tachikoma.KeyEvent, snap, send)
    picker = page.picker
    if evt.key in (:up, :down)
        picker.cursor = clamp(picker.cursor + (evt.key == :up ? -1 : 1), 1, length(picker.items))
    elseif evt.key == :enter
        picker_choose!(page, snap, send)
    elseif evt.key == :escape
        page.picker = nothing
    end
    return nothing
end

# Close the picker of `page` and send the command for the item under its cursor, unless
# that is the current production or dataset.
function picker_choose!(page::SetupPage, snap, send)
    picker = page.picker
    page.picker = nothing
    name = picker.items[picker.cursor]
    if picker.kind === :production
        current = current_production()
        folder = abspath(joinpath(production_root(page), name))
        folder == (isnothing(current) ? "" : joinpath(last(current), first(current))) || send(SelectProduction(folder))
    else
        name == dataset_name(snap) || send(SelectDataset(Symbol(name)))
    end
    return nothing
end

# Send the next value of the option row `page.option`.
function cycle_option(page::SetupPage, snap, send)
    option, _, values = SETUP_OPTIONS[page.option]
    i = something(findfirst(==(option_value(snap, option)), values), 0)
    send(option_command(option, values[mod1(i + 1, length(values))]))
    return nothing
end

function format_option(value)
    return value === nothing ? "config" :
           value isa LogLevel ? only(name for (name, level) in LOG_LEVELS if level == value) :
           value === true ? "yes" : value === false ? "no" : string(value)
end

# Lines of the summary of what a start would process.
function setup_summary(snap)
    period_runs = selected_period_runs(snap)
    nruns = sum(length, values(period_runs); init = 0)
    nperiods = count(!isempty, values(period_runs))
    return ["Periods: $nperiods" *
            (nperiods == 0 ? "" : " (" * join(string.(sort!([p for (p, r) in period_runs if !isempty(r)])), ", ") * ")"), "Runs: $nruns",
            "Run steps: $(length(snap.run_steps)) × $nruns runs", "Partition steps: $(length(snap.partition_steps)) × $nperiods periods"]
end

"""
    JuLeAna.dataset_lines(page::SetupPage)

Return the title and the lines, as vectors of `(text, style)` spans, of the box with the
runinfo of the period or run under the cursor of the periods of `page`. A run shows one
line per category with file keys: the number of file keys, the livetime, and `no
analysis` if it is not an analysis run of the category. A period shows the totals of its
runs per category (see [`JuLeAna.period_summary`](@ref)) with the number of runs. The
first line is the earliest start time. The box has as many lines as the period with the
most categories needs.
"""
function dataset_lines(page::SetupPage)
    dim, text, bright = Tachikoma.tstyle(:text_dim), Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_bright)
    summary, entry = page.dataset, current(page.periods)
    summary isa AbstractString && return (; title = "Dataset", lines = [[("runinfo: " * summary, Tachikoma.tstyle(:error))]])
    isnothing(summary) && return (; title = "Dataset", lines = [[("Reading the runinfo…", dim)]])
    # a period has at least as many categories as any of its runs
    ncategories = maximum(p -> length(unique(c.category for ((q, _), run) in summary if q == p for c in run)),
                          unique(first.(keys(summary))); init = 1)
    # lines of a box with one line per category plus the start line
    padded(lines) = vcat(lines, fill([("", text)], max(0, ncategories + 1 - length(lines))))
    isnothing(entry) && return (; title = "Dataset", lines = padded(Vector{Tuple{String,Tachikoma.Style}}[]))
    category_span(c) = (rpad(string(c), 4), Tachikoma.tstyle(c === :cal ? :primary : c === :phy ? :secondary : :accent))
    livetime(seconds) = isnan(seconds) ? "–" : format_duration(seconds)
    count_text(n, what) = n == 1 ? "1 $what" : "$n $(what)s"
    function start_line(entries)
        starts = [e.start for e in entries if !isnothing(e.start)]
        return [("Start ", dim), (isempty(starts) ? "–" : Dates.format(minimum(starts), dateformat"yyyy-mm-dd HH:MM") * " UTC", bright)]
    end
    if entry isa ChecklistGroup
        period = entry.key
        totals = period_summary(summary, period)
        isempty(totals) && return (; title = "Dataset $period", lines = padded([[("not in the runinfo", Tachikoma.tstyle(:warning))]]))
        nruns = count(((p, _),) -> p == period, keys(summary))
        lines = [vcat(start_line(totals), [("  " * count_text(nruns, "run"), dim)])]
        for t in totals
            push!(lines,
                  [category_span(t.category), (lpad(count_text(t.nruns, "run"), 8), text), (lpad(count_text(t.nkeys, "key"), 10), text),
                   ("  " * livetime(t.livetime), bright),
                   (t.nanalysis == t.nruns ? "" : "  $(t.nanalysis) analysis", Tachikoma.tstyle(:warning))])
        end
        return (; title = "Dataset $period", lines = padded(lines))
    end
    period, run = entry.key
    categories = get(summary, (period, run), nothing)
    isnothing(categories) &&
        return (; title = "Dataset $period-$run", lines = padded([[("not in the runinfo", Tachikoma.tstyle(:warning))]]))
    lines = [start_line(categories)]
    for c in categories
        push!(lines,
              [category_span(c.category), (lpad(count_text(c.nkeys, "key"), 8), text), ("  " * livetime(c.livetime), bright),
               (c.analysis ? "" : "  no analysis", Tachikoma.tstyle(:warning))])
    end
    return (; title = "Dataset $period-$run", lines = padded(lines))
end

"""
    JuLeAna.find_productions(root)

Return the sorted paths, relative to the folder `root`, of the folders under `root` that
hold a `config.json` or `config.yaml`; `"."` is `root` itself. The search is breadth-first
with one `readdir` per folder, goes at most 4 levels below `root`, skips hidden folders and
symbolic links, and does not descend into a folder that holds a config file. Folders that
cannot be read are skipped.
"""
function find_productions(root::AbstractString)
    found, level = String[], [""]
    for depth in 0:4
        next = String[]
        for rel in level
            dir = joinpath(root, rel)
            names = try
                readdir(dir)
            catch e
                e isa Base.IOError || rethrow()
                continue
            end
            if "config.json" in names || "config.yaml" in names
                push!(found, isempty(rel) ? "." : rel)
            elseif depth < 4
                for n in names
                    path = joinpath(dir, n)
                    startswith(n, ".") || islink(path) || !isdir(path) || push!(next, joinpath(rel, n))
                end
            end
        end
        level = next
    end
    return sort!(found)
end

"""
    JuLeAna.read_choices(ctrl::DataflowController, root)

Read the names the pickers of the Setup page list, and return them as a `NamedTuple` with
`productions`, the data productions under the folder `root` (see
[`JuLeAna.find_productions`](@ref)), and `datasets`, `"default"` and the names in the
metadata `datasets/runlists` of the loaded session. Throws if `root` is empty or the run
lists cannot be read.
"""
function read_choices(ctrl::DataflowController, root::AbstractString)
    isempty(root) && throw(ArgumentError("no production root is set"))
    productions = find_productions(root)
    session = @lock ctrl.lock ctrl.session
    datasets = isnothing(session) ? String[] : string.(keys(session.l200.metadata.datasets.runlists))
    return (; productions, datasets = sort!(unique!(vcat("default", datasets))))
end

# Read the choices of the pickers in a background task when the data production, the
# production root or the loaded state of the session changed since the last read; the value is the choices or
# the message of the read error, tagged with what it was read for.
function choices_sync!(m)
    page, ctrl = m.setup, m.ctrl
    m.snap.state === :loading && return nothing
    root = production_root(page)
    key = (current_production(), m.snap.state === :idle, root)
    key == page.choices_key && return nothing
    page.choices_key = key
    Tachikoma.spawn_task!(m.queue, :choices) do
        value = try
            read_choices(ctrl, root)
        catch e
            @error "Reading the data productions and datasets failed" exception = (e, catch_backtrace())
            first(split(sprint(showerror, e), '\n'))
        end
        return (key, value)
    end
    return nothing
end

# Lines of the production pane: the root, the data production and the dataset, the hint or
# error of the root, and the read error of the choices if there is one.
function production_lines(page::SetupPage, snap)
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    production = current_production()
    names = (isnothing(production) ? "not set" : first(production), dataset_name(snap))
    lines = Vector{Tuple{String,Tachikoma.Style}}[]
    editing = !isnothing(page.root_edit)
    root = editing ? page.root_edit : production_root(page)
    # the end of a long path stays visible, with room for the label and the cursor
    room = page.production_area.width - 8
    names = (editing && 0 < room < textwidth(root) ? "…" * last(root, room - 1) : root, names...)
    for (i, (label, name)) in enumerate(zip(("Root: ", "Production: ", "Dataset: "), names))
        chosen = page.focus == 5 && i == page.source
        push!(lines,
              [(label, chosen ? Tachikoma.tstyle(:accent, bold = true) : text), (name, Tachikoma.tstyle(:text_bright, bold = chosen)),
               (i == 1 && editing ? "█" : "", Tachikoma.tstyle(:accent))])
    end
    hint, failed = page.root_hint
    isempty(hint) || push!(lines, [(hint, failed ? Tachikoma.tstyle(:error) : dim)])
    page.choices isa AbstractString && push!(lines, [(page.choices, Tachikoma.tstyle(:error))])
    return lines
end

# Draw the open picker of `page` centered in `area`.
function render_picker(page::SetupPage, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    picker = page.picker
    text = Tachikoma.tstyle(:text)
    title = picker.kind === :production ? "Data production" : "Dataset"
    width = min(area.width, max(40, maximum(textwidth, picker.items; init = 0) + 6))
    box = Tachikoma.center(area, width, min(area.height, length(picker.items) + 4))
    for y in box.y:Tachikoma.bottom(box), x in box.x:Tachikoma.right(box)

        Tachikoma.set_char!(buf, x, y, ' ', text)
    end
    inner = Tachikoma.render(Tachikoma.Block(title = title, border_style = Tachikoma.tstyle(:border_focus)), box, buf)
    list = Tachikoma.Rect(inner.x, inner.y, inner.width, max(0, inner.height - 1))
    page.picker_area = list
    picker.top = clamp(picker.cursor - list.height ÷ 2, 1, max(1, length(picker.items) - list.height + 1))
    for row in 1:min(list.height, length(picker.items) - picker.top + 1)
        i = picker.top + row - 1
        Tachikoma.set_string!(buf, list.x + 1, list.y + row - 1, (i == picker.cursor ? "▶ " : "  ") * picker.items[i],
                              i == picker.cursor ? Tachikoma.tstyle(:accent, bold = true) : text; max_x = Tachikoma.right(list))
    end
    Tachikoma.set_string!(buf, inner.x + 1, Tachikoma.bottom(inner), "Enter: choose   Esc: close", Tachikoma.tstyle(:text_dim);
                          max_x = Tachikoma.right(inner))
    return nothing
end

"""
    JuLeAna.render_setup(page::SetupPage, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the Setup page into `area`: periods and runs on the left, the run and partition
processors in the middle, and on the right the options with a summary of what a start
would process and the largest logo that fits below it (centered at the bottom of the
pane), the data production and dataset, and the runinfo of the period or run under the
cursor of the periods (see [`JuLeAna.dataset_lines`](@ref)); the production pane shows
[`JuLeAna.production_root`](@ref), the data production and the dataset. The open picker is drawn over the page.
"""
function render_setup(page::SetupPage, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    columns = Tachikoma.Layout(Tachikoma.Horizontal, [Tachikoma.Percent(28), Tachikoma.Percent(42), Tachikoma.Fill()])
    left, middle, right = Tachikoma.split_layout(columns, area)
    Tachikoma.render(page.periods, left, buf)
    nrun, npart = length(page.run_procs.keys), length(page.part_procs.keys)
    procs = Tachikoma.Layout(Tachikoma.Vertical, [Tachikoma.Fill(max(1, nrun + 2)), Tachikoma.Fill(max(1, npart + 2))])
    top, bottom = Tachikoma.split_layout(procs, middle)
    Tachikoma.render(page.run_procs, top, buf)
    Tachikoma.render(page.part_procs, bottom, buf)

    info, production = dataset_lines(page), production_lines(page, snap)
    options, production_pane, dataset_pane = Tachikoma.split_layout(Tachikoma.Layout(Tachikoma.Vertical,
                                                                                     [Tachikoma.Fill(),
                                                                                      Tachikoma.Fixed(min(length(production) + 2,
                                                                                                          right.height ÷ 3)),
                                                                                      Tachikoma.Fixed(min(length(info.lines) + 2,
                                                                                                          right.height ÷ 3))]), right)
    page.production_area = Tachikoma.render(pane_block("Production", page.focus == 5), production_pane, buf)
    for (i, spans) in pairs(production)
        y = page.production_area.y + i - 1
        y > Tachikoma.bottom(page.production_area) && break
        put_spans!(buf, page.production_area.x, y, Tachikoma.right(page.production_area), spans)
    end
    inner = Tachikoma.render(pane_block(info.title, false), dataset_pane, buf)
    for (i, spans) in pairs(info.lines)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        put_spans!(buf, inner.x, y, Tachikoma.right(inner), spans)
    end

    block = pane_block("Options", page.focus == 4)
    inner = Tachikoma.render(block, options, buf)
    page.options = inner
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    lines = Vector{Tuple{String,Tachikoma.Style}}[]
    if isnothing(snap) || isempty(snap.processors)
        push!(lines,
              [(!isnothing(snap) && get(snap, :state, nothing) === :idle ? "No session loaded. N: new data production" :
                "Loading the session…", dim)])
    else
        for (i, (key, label, _)) in pairs(SETUP_OPTIONS)
            value = option_value(snap, key)
            chosen = page.focus == 4 && i == page.option
            value_color = value === true ? :success : value === false ? :error : :text_dim
            push!(lines,
                  [("$label: ", chosen ? Tachikoma.tstyle(:accent, bold = true) : text),
                   (format_option(value), Tachikoma.tstyle(value_color, bold = chosen))])
        end
        push!(lines, [("", text)])
        for line in setup_summary(snap)
            head, tail = split(line, ": "; limit = 2)
            push!(lines, [(head * ": ", dim), (tail, Tachikoma.tstyle(:text_bright))])
        end
    end
    for (i, spans) in pairs(lines)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        put_spans!(buf, inner.x, y, Tachikoma.right(inner), spans)
    end
    logo = fitting_logo(inner.width, inner.height - length(lines) - 1)
    if !isnothing(logo)
        w, h = logo_size(logo)
        render_logo(logo, inner.x + (inner.width - w) ÷ 2, Tachikoma.bottom(inner) - h + 1, buf; max_x = Tachikoma.right(inner),
                    max_y = Tachikoma.bottom(inner))
    end
    page.editor isa KwargsEditor && render_kwargs(page.editor, snap, area, buf)
    page.editor isa RunmodeEditor && render_runmode(page.editor, snap, area, buf)
    isnothing(page.picker) || render_picker(page, area, buf)
    if page.confirm === :write && !isnothing(snap)
        Tachikoma.render(Tachikoma.Modal(; title = "Write config",
                                         message = "Write the current settings to\nconfig/processing_config.yaml\nin the data production?\nAn existing file is kept as processing_config.yaml.bak.\n\ny: write   any other key: cancel",
                                         confirm_label = "", cancel_label = ""), area, buf)
    end
    return nothing
end
