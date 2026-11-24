# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const MIN_BODY = 6
const RELOAD_FIELDS = (:host, :remote_root, :production, :local_root, :mount_root)

"""
    SyncPage(host, production, options; queue = TaskQueue())
    SyncPage(host, options; queue = TaskQueue())
    SyncPage(settings, queue; host_factory = SSHHost, suggested = false)

The state of the sync screen: a settings panel above the production tree. The first form opens `production`
on `host`, the second has a host but no production yet, and the third has no connection:
`sync_start!` connects to `host_factory(settings.host)` in the background and opens the production
the settings name, or the picker. The `Node` tree is the source of truth; the `TreeView` is rebuilt from it
on every change. The page starts tasks with ids prefixed `sync:` on `queue`; the host routes their events to
[`sync_task!`](@ref).
"""
Base.@kwdef mutable struct SyncPage
    host::Union{Nothing,RemoteHost} = nothing
    production::Union{Nothing,Production} = nothing
    options::Union{Nothing,Options} = nothing
    settings::SyncSettings = SyncSettings()
    running::Int = 0                                    # unanswered tasks of this page; the queue may be shared
    root::Union{Nothing,Node} = nothing
    collapsed::Set{String} = Set{String}()
    pending::Set{String} = Set{String}()
    tree::TreeView = TreeView(TreeNode(""))
    tasks::TaskQueue = TaskQueue()
    dirty::Bool = false
    status::String = ""
    saved::Union{Nothing,String} = nothing
    modal::Union{Nothing,Modal} = nothing
    modal_kind::Symbol = :none
    input::Union{Nothing,TextInput} = nothing
    estimate::Union{Nothing,Estimate} = nothing
    productions::Union{Nothing,Vector{String}} = nothing
    picker::Union{Nothing,SelectableList} = nothing
    environment::Union{Nothing,EnvironmentStatus} = nothing
    continuation::Union{Nothing,Function} = nothing
    focus::Symbol = :tree
    cursor::Int = 1
    edit::Union{Nothing,Symbol} = nothing
    hint::String = ""
    panel_open::Bool = true                             # the user's wish; panel_shown is what the last render could fit
    panel_shown::Bool = true
    errors::Dict{Symbol,String} = Dict{Symbol,String}()
    remote_default::String = ""
    picking::Bool = false
    guarded::Union{Nothing,Function} = nothing
    host_factory::Any = SSHHost
    step::Union{Nothing,StepProgress} = nothing
    step_started::Float64 = 0.0
    connecting::Bool = false
    suggested::Bool = false
    active::Vector{String} = String[]
    estimated::Union{Nothing,Selection} = nothing
    stop::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
end

function SyncPage(host::RemoteHost, production::Production, options::Options; queue::TaskQueue = TaskQueue())
    m = SyncPage(; host, production, options, settings = SyncSettings(options), root = production_tree(host, production), tasks = queue,
                 host_factory = _ -> host, panel_open = false)
    rebuild_tree!(m)
    m.tree.selected = 1
    return revalidate!(m)
end

function SyncPage(host::RemoteHost, options::Options; queue::TaskQueue = TaskQueue())
    return revalidate!(SyncPage(; host, options, settings = SyncSettings(options), tasks = queue, host_factory = _ -> host))
end

function SyncPage(settings::SyncSettings, queue::TaskQueue; host_factory = SSHHost, suggested::Bool = false)
    return revalidate!(SyncPage(; settings, tasks = queue, host_factory, suggested))
end

function sync_start!(m::SyncPage)
    (m.root === nothing && m.productions === nothing && m.running == 0) || return m
    blocked(m) && return m
    return start_connect!(m)
end

function in_step(f, what::AbstractString)
    try
        return f()
    catch err
        err isa InterruptException && rethrow()
        throw(ErrorException(string(what, ": ", sprint(showerror, err))))
    end
end

function start_connect!(m::SyncPage)
    m.connecting && (m.status = "busy: connecting to $(m.settings.host); the current settings are used when it is done"; return m)
    s = copy(m.settings)
    factory = m.host_factory
    m.connecting = true
    m.status = "connecting to $(s.host)…"
    spawn!(m, :connect) do
        host = in_step(() -> factory(s.host), "checking host $(s.host)")
        in_step(check_rsync, "checking rsync")
        options = Options(s)
        productions = in_step(() -> list_productions(host, options.remote_root), "listing productions on $(s.host)")
        return (host, options, productions, s)
    end
    return m
end

function busy!(m::SyncPage)
    ids = filter(!startswith("sizes:"), m.active)
    m.running > length(m.active) - length(ids) || return false
    m.status = "busy: " * (isempty(m.status) ? (isempty(ids) ? "a background task" : task_description(first(ids))) : m.status)
    return true
end

const TASK_NAMES = Dict("connect" => "connecting", "productions" => "listing productions", "open" => "opening the production",
                        "load" => "loading the selection", "estimate" => "estimating", "transfer" => "transferring",
                        "environment" => "checking the helper environment", "bootstrap" => "creating the helper environment",
                        "listing" => "listing", "detectors" => "inspecting the files of")

function task_description(id::AbstractString)
    kind, path = split_id(id)
    return join(filter(!isempty, [get(TASK_NAMES, kind, kind), basename(path)]), " ")
end

split_id(id::AbstractString) = occursin(':', id) ? Tuple(split(id, ':'; limit = 2)) : (id, "")

function connect!(m::SyncPage)
    (busy!(m) || blocked(m)) && return m
    return discard_guard!(() -> start_connect!(m), m)
end

function spawn!(f, m::SyncPage, id)
    m.running += 1
    push!(m.active, String(id))
    return spawn_task!(f, m.tasks, Symbol("sync:", id))
end

step_note(p::Union{Nothing,StepProgress}) = p === nothing ? "" : "\n(in step \"$(p.step)\", $(p.index) of $(p.count))"

report_to(m::SyncPage) = (queue = m.tasks; p -> put!(queue.channel, TaskEvent(Symbol("sync:step"), p)))

# Each operation has its own flag, so a stop cannot reach a later one.
function stoppable_report!(m::SyncPage)
    stop = m.stop = Threads.Atomic{Bool}(false)
    report = report_to(m)
    return p -> (stop[] && throw(SyncStopped()); report(p))
end

function request_productions!(m::SyncPage)
    host, remote_root = m.host, m.options.remote_root
    m.productions = nothing
    m.picker = nothing
    spawn!(() -> list_productions(host, remote_root), m, :productions)
    return m
end

function checkbox(node::Node)
    mode = effective_mode(node)
    mode == :copy && return "[x]"
    mode == :link && return "[~]"
    mode == :extract && return "[e]"
    return marked_below(node) ? "[-]" : "[ ]"
end

marked_below(node::Node) = node.children !== nothing && any(c -> c.mode != :none || marked_below(c), node.children)

function build_tree(m::SyncPage, node::Node = m.root)
    children = if node.children !== nothing
        [build_tree(m, child) for child in node.children]
    elseif node.kind in (:section, :dir, :detectors)
        [TreeNode(node.remote_path in m.pending ? "…listing" : "…")]
    else
        TreeNode[]
    end
    return TreeNode(string(checkbox(node), " ", rpad(node.label, 28), " ", node.size === nothing ? "…" : format_bytes(node.size)); children,
                    expanded = node.children !== nothing && !(node.remote_path in m.collapsed), content = node)
end

function rebuild_tree!(m::SyncPage)
    selected, offset = m.tree.selected, m.tree.offset
    m.tree = TreeView(build_tree(m); selected, offset, focused = true,
                      block = Block(title = "Production: $(m.production.name) @ $(m.options.host)"))
    m.tree.selected = min(selected, tree_visible_count(m.tree))
    return m
end

function current_node(m::SyncPage)
    row = selected_node(m.tree)
    return row !== nothing && row.content isa Node ? row.content : nothing
end

function with_environment!(m::SyncPage, continue_with)
    if m.environment !== nothing
        continue_with()
        return m
    end
    host, helper = m.host, m.options.helper
    m.continuation = continue_with
    m.modal_kind = :checking
    m.status = "checking the helper environment on $(m.options.host)…"
    spawn!(() -> ensure_environment(host, helper), m, :environment)
    return m
end

function environment_ready!(m::SyncPage, status::EnvironmentStatus)
    m.environment = status
    m.status = ""
    m.modal, m.modal_kind = nothing, :none
    continue_with, m.continuation = m.continuation, nothing
    continue_with === nothing || continue_with()
    return m
end

function start_bootstrap!(m::SyncPage)
    host, helper = m.host, m.options.helper
    open_modal!(m, :busy, "Creating the helper environment", "running Pkg.add on $(m.options.host); this can take several minutes…")
    spawn!(() -> bootstrap_environment!(host, helper), m, :bootstrap)
    return m
end

function request_detectors!(m::SyncPage, node::Node)
    (node.children !== nothing || node.remote_path in m.pending) && return m
    push!(m.pending, node.remote_path)
    host, helper, jobs, run = m.host, m.options.helper, m.options.jobs, node.parent
    steps = Steps([node.whole_files ? "listing runs" : period_level(run) ? "reading first files" : "reading first file"], report_to(m))
    spawn!(() -> (node, detector_nodes(host, helper, run; jobs, steps)), m, "detectors:" * node.remote_path)
    m.status = node.whole_files ? "listing the detector files of $(run.label)…" : "inspecting the files of $(run.label)…"
    return rebuild_tree!(m)
end

function mark!(f, m::SyncPage)
    try
        f()
    catch err
        err isa ArgumentError || rethrow()
        m.status = err.msg
        return m
    end
    m.dirty = true
    m.status = ""
    return rebuild_tree!(m)
end

function open_estimate!(m::SyncPage; confirm::Bool)
    busy!(m) && return m
    selection = Selection(m.production, m.options.host, m.root)
    m.estimated = selection
    host, production, helper, jobs = m.host, m.production, m.options.helper, m.options.jobs
    run = function ()
        report = stoppable_report!(m)
        m.modal_kind = :estimating
        m.status = "estimating…"
        return spawn!(m, :estimate) do
            result = estimate_selection(host, production, selection; helper, jobs, report)
            return (result.estimate, confirm, result.staging, result.free)
        end
    end
    isempty(selection.extract) ? run() : with_environment!(m, run)
    return m
end

function start_transfer!(m::SyncPage)
    host, production, helper, jobs, selection = m.host, m.production, m.options.helper, m.options.jobs, m.estimated
    selection === nothing && error("start_transfer!: no estimated selection; open the estimate first")
    m.estimated = nothing
    report = stoppable_report!(m)
    open_modal!(m, :transfer, "Transferring", "starting…")
    spawn!(() -> apply!(host, production, selection; helper, jobs, report), m, :transfer)
    return m
end

function open_modal!(m::SyncPage, kind::Symbol, title, message; confirm = "", cancel = "", kwargs...)
    m.modal = Modal(; title, message, confirm_label = confirm, cancel_label = cancel, kwargs...)
    m.modal_kind = kind
    return m
end

function open_message!(m::SyncPage, title::AbstractString, message::AbstractString; kind::Symbol = :message)
    m.status = ""
    return open_modal!(m, kind, title, message; cancel = "Close")
end

show_error!(m::SyncPage, err) = open_message!(m, "Error", sprint(showerror, err); kind = :error)

function note_error!(m::SyncPage, err)
    m.modal_kind in (:transfer, :busy) || return show_error!(m, err)
    message = first(split(sprint(showerror, err), '\n'))
    m.status = isempty(m.status) ? message : m.status * "; " * message
    return m
end

function apply_prompt!(m::SyncPage)
    node = current_node(m)
    typed = strip(Tachikoma.text(m.input))
    count = tryparse(Int, typed)
    if node === nothing || count === nothing || count < 1
        m.status = "expected a positive number of filekeys, got \"$typed\""
        return m
    end
    first_n_filekeys!(node, count)
    m.input, m.modal_kind = nothing, :none
    m.dirty = true
    m.status = ""
    return rebuild_tree!(m)
end

function refresh_local_state!(m::SyncPage, node::Node = m.root)
    node.children === nothing || foreach(child -> refresh_local_state!(m, child), node.children)
    node.local_state = node_local_state(m.production, node)
    return m
end

function save!(m::SyncPage)
    path = selection_path(m.settings)
    isempty(path) && (m.status = "choose a production before saving"; return path)
    save_selection(path, Selection(m.production, m.options.host, m.root))
    m.saved = path
    m.dirty = false
    m.status = ""
    return path
end

function details(m::SyncPage)
    node = current_node(m)
    size = node === nothing || node.size === nothing ? "…" : format_bytes(node.size)
    lines = String[]
    if node === nothing
    elseif node.kind == :detector && node.whole_files
        lines = [node.label, "files of this detector in the runs of $(node.parent.parent.label)",
                 "held by " * join(basename.(first.(node.holders)), ", "), "size: " * size,
                 "mark: " * (node.mode == :none ? "no" : String(node.mode)), ""]
    elseif node.kind == :detector
        period = period_level(node.parent.parent)
        lines = [node.label,
                 period ? "detector of the runs of $(node.parent.parent.label) ($(length(node.holders)) hold it)" :
                 "HDF5 group of the files in $(node.parent.parent.label)",
                 (period ? "approximate size in the period: " : "size in the first file: ") * size,
                 "extract: " * (node.mode == :extract ? "yes" : effective_mode(node) == :extract ? "yes (whole period)" : "no"), ""]
    elseif node.kind == :detectors && node.whole_files
        lines = [node.label, "enter lists the detector files of every run in $(node.parent.label)", ""]
    elseif node.kind == :detectors
        lines = [node.label,
                 period_level(node.parent) ? "enter lists the detectors of the first file of every run in $(node.parent.label)" :
                 "enter lists the top-level groups of the first file in $(node.parent.label)", ""]
    else
        lines = [node.label, node.remote_path, "local: $(node.local_state)", "size: " * size, ""]
    end
    if node !== nothing && node.kind == :production
        insert!(lines, lastindex(lines), "overlays: " * (isempty(m.production.overlays) ? "none" : join(m.production.overlays, ", ")))
    end
    append!(lines,
            ["space copy   l link   n first N   x extract", "per-detector tiers: space/l mark a detector's files",
             "enter expand/collapse   mouse: click, wheel", "Tab settings   p panel",
             "c connect   o load   s save   e estimate   t sync   q quit"])
    return Paragraph(join(lines, "\n"); block = Block(title = "Details"), wrap = word_wrap)
end

function revalidate!(m::SyncPage)
    s = m.settings
    m.errors = Dict(settings_errors(s; check_paths = true))
    m.remote_default = isfile(s.hosts_file) && s.host in hosts_choices(s.hosts_file) ? host_remote_root(s.hosts_file, s.host) : ""
    return m
end

function blocked(m::SyncPage)
    isempty(m.errors) && return false
    m.status = last(first(settings_errors(m.settings; check_paths = true)))
    return true
end

function change_setting!(m::SyncPage, field::Symbol, text::AbstractString)
    getfield(m.settings, field) == text && return m
    apply = function ()
        setfield!(m.settings, field, String(text))
        revalidate!(m)
        connected = m.host !== nothing || m.root !== nothing
        if !connected || field in (:host, :remote_root) || (field in RELOAD_FIELDS && m.host !== nothing)
            m.productions, m.picker, m.picking = nothing, nothing, false
            blocked(m) || ((m.suggested = false); start_connect!(m))
        elseif isempty(m.errors) && m.options !== nothing
            m.options = Options(m.settings; from = m.options.from, dry_run = m.options.dry_run, yes = m.options.yes)
        end
        return nothing
    end
    field in RELOAD_FIELDS || return (apply(); m)
    return discard_guard!(apply, m)
end

function empty_text(m::SyncPage, field::Symbol)
    field === :remote_root && return isempty(m.remote_default) ? "(not set)" : string("(", m.remote_default, ")")
    field === :staging && return "(host default)"
    field === :mount_root && return "(none)"
    field === :production && return "(choose with Enter)"
    field === :selection &&
        return isempty(selection_path(m.settings)) ? "(default after choosing a production)" : selection_path(m.settings)
    return ""
end

function render_panel(m::SyncPage, area::Rect, buf::Buffer, shown::Bool)
    s = m.settings
    if !shown
        text = string("▸ ", s.host, "  ", isempty(s.production) ? "(no production)" : s.production, "  ", s.local_root)
        set_string!(buf, area.x, area.y, text, tstyle(:accent); max_x = Tachikoma.right(area))
        return nothing
    end
    inner = render(Block(title = "Settings"), area, buf)
    for (i, name) in enumerate(SETTINGS_FIELDS)
        rect = Rect(inner.x, inner.y + i - 1, inner.width, 1)
        if m.edit === name
            render(m.input, rect, buf)
            continue
        end
        value = getfield(s, name)
        label_style = m.focus == :panel && m.cursor == i ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        style = haskey(m.errors, name) ? tstyle(:error) : isempty(value) ? tstyle(:text_dim) : tstyle(:text)
        set_string!(buf, rect.x, rect.y, rpad(FIELD_LABELS[name], 12), label_style; max_x = Tachikoma.right(rect))
        set_string!(buf, rect.x + 12, rect.y, isempty(value) ? empty_text(m, name) : value, style; max_x = Tachikoma.right(rect))
    end
    field = m.edit !== nothing ? m.edit : m.focus == :panel ? SETTINGS_FIELDS[m.cursor] : nothing
    message = get(filter(!isempty, [m.hint, m.edit === nothing ? "" : m.input.error_msg, get(m.errors, field, "")]), 1, "")
    set_string!(buf, inner.x, Tachikoma.bottom(inner), message, tstyle(isempty(m.hint) && !isempty(message) ? :error : :text_dim);
                max_x = Tachikoma.right(inner))
    return nothing
end

function render_progress(m::SyncPage, area::Rect, buf::Buffer)
    p = m.step
    line(text, style) = set_string!(buf, area.x, area.y, text, tstyle(style); max_x = Tachikoma.right(area))
    if m.root === nothing && p === nothing
        line(isempty(m.status) ? "Connect (c) lists the productions" : m.status, :text)
    elseif p === nothing
        out = selection_path(m.settings)
        name = startswith(out, config_dir() * "/") ? relpath(out, config_dir()) : basename(out)
        render(StatusBar(left = [Span(format_estimate(running_estimate(m.root)), tstyle(:text_bright)),
                                 Span(isempty(m.status) ? "" : "   " * m.status)],
                         right = [Span((m.saved === nothing ? "unsaved: " : "saved: ") * name)]), area, buf)
    elseif m.stop[] && sync_running(m)
        line(string("stopping…  ", format_step(p)), :warning)
    elseif p.total === nothing
        elapsed = round(Int, time() - m.step_started)
        glyph = Tachikoma.SPINNER_BRAILLE[mod1(floor(Int, 8 * time()), length(Tachikoma.SPINNER_BRAILLE))]
        line(string(format_step(p), "  ", glyph, " ", elapsed ÷ 60, ":", lpad(elapsed % 60, 2, '0')), :accent)
    else
        render(Gauge(p.total == 0 ? 0.0 : p.done / p.total; label = format_step(p)), area, buf)
    end
    return nothing
end

"""
    render_sync(m::SyncPage, area::Rect, buf::Buffer)

Draw the interface into `area`; nothing assumes it owns the terminal.
"""
function render_sync(m::SyncPage, area::Rect, buf::Buffer)
    rows_needed = length(SETTINGS_FIELDS) + 1
    shown = m.panel_open && area.height >= rows_needed + 2 + MIN_BODY + 1
    m.panel_shown = shown
    shown || m.focus != :panel || (m.focus = :tree)
    rows = split_layout(Layout(Vertical, Constraint[Fixed(shown ? rows_needed + 2 : 1), Fill(1), Fixed(1)]), area)
    render_panel(m, rows[1], buf, shown)
    if m.root === nothing
        render(Paragraph(m.running > 0 ? "working…" : "No production is open. Choose one with Enter on the Production field.";
                         block = Block(title = "Production")), rows[2], buf)
    else
        panes = split_layout(Layout(Horizontal, Constraint[Percent(55), Fill(1)]), rows[2])
        render(m.tree, panes[1], buf)
        render(details(m), panes[2], buf)
    end
    render_progress(m, rows[3], buf)
    if m.picking && m.picker !== nothing
        rect = center(rows[2], min(70, rows[2].width), min(rows[2].height, max(5, length(m.productions) + 2)))
        foreach(y -> set_string!(buf, rect.x, y, " "^rect.width, tstyle(:text)), rect.y:Tachikoma.bottom(rect))
        render(m.picker, rect, buf)
    end
    if m.modal_kind == :firstn
        rect = center(area, 46, 5)
        render(m.input, render(Block(title = "First N filekeys", border_style = tstyle(:accent, bold = true), box = BOX_HEAVY), rect, buf),
               buf)
    elseif m.modal !== nothing
        render(m.modal, area, buf)
        m.step === nothing || render_progress(m, rows[3], buf)
    end
    return nothing
end

function sync_hints(m::SyncPage)
    sync_text_input(m) && return (("Enter", "apply"), ("Tab", "complete"), ("Esc", "cancel"))
    m.picking && return (("↑↓", "move"), ("Enter", "choose"), ("Esc", "close"), ("r", "reload"))
    m.focus == :panel && return (("Tab", "next"), ("Enter", "edit"), ("Esc", "tree"), ("p", "panel"))
    return (("Tab", "settings"), ("Space", "copy"), ("l", "link"), ("x", "extract"), ("n", "first N"), ("e", "estimate"), ("t", "sync"),
            ("s", "save"), ("p", "panel"))
end

function open_production!(m::SyncPage, name::AbstractString)
    host, options = m.host, m.options
    m.status = "opening $name…"
    return spawn!(m, :open) do
        production = Production(host, name, options.remote_root, options.local_root; mount_root = options.mount_root)
        return (production, production_tree(host, production))
    end
end

function move_focus!(m::SyncPage, step::Int)
    items = m.panel_open && m.panel_shown ? length(SETTINGS_FIELDS) : 0
    position = (m.focus == :tree ? (step > 0 ? 0 : items + 1) : m.cursor) + step
    m.focus = 1 <= position <= items ? :panel : :tree
    m.focus == :panel && (m.cursor = position)
    return m
end

function panel_key!(m::SyncPage, e::KeyEvent)
    if e.key in (:up, :left, :down, :right)
        m.cursor = clamp(m.cursor + (e.key in (:up, :left) ? -1 : 1), 1, length(SETTINGS_FIELDS))
    elseif e.key == :enter
        field = SETTINGS_FIELDS[m.cursor]
        field === :production && return open_picker!(m)
        m.edit = field
        m.input = TextInput(label = rpad(FIELD_LABELS[field], 12), label_style = tstyle(:accent, bold = true),
                            text = getfield(m.settings, field),
                            validator = text -> (s = copy(m.settings); setfield!(s, field, text); field_error(s, field; check_paths = true)))
    elseif e.key == :escape
        m.focus = :tree
    else
        return false
    end
    return true
end

function needs_production!(m::SyncPage)
    m.production === nothing || return false
    m.status = m.host === nothing ? "Connect first (c, or Enter on Production)" : "Open a production first (Enter on Production)"
    return true
end

function edit_key!(m::SyncPage, e::KeyEvent)
    field, text = m.edit, Tachikoma.text(m.input)
    m.hint = ""
    if e.key == :escape
        m.edit = nothing
    elseif e.key == :enter
        m.edit = nothing
        change_setting!(m, field, text)
    elseif e.key == :tab
        if field in (:local_root, :mount_root)
            text, candidates = complete_path(text)
        elseif field === :host
            candidates = filter(startswith(text), hosts_choices(m.settings.hosts_file))
            isempty(candidates) && return m
            text = reduce((a, b) -> join(first(p) for p in Iterators.takewhile(p -> p[1] == p[2], zip(a, b))), candidates)
        else
            return m
        end
        Tachikoma.set_text!(m.input, text)
        length(candidates) > 1 && (m.hint = join(first(candidates, 8), "  "))
    else
        handle_key!(m.input, e)
    end
    return m
end

function show_picker!(m::SyncPage, productions = m.productions)
    m.productions = productions
    m.picking = !isempty(productions)
    if m.picking
        m.picker = SelectableList(productions; focused = true, block = Block(title = "Productions on $(m.options.host)"))
    else
        m.status = "no productions found in $(m.options.remote_root)"
    end
    return m
end

function open_picker!(m::SyncPage)
    busy!(m) && return m
    m.host === nothing && return connect!(m)
    m.productions === nothing && return request_productions!(m)
    return show_picker!(m)
end

function picker_key!(m::SyncPage, e::KeyEvent)
    m.picker === nothing && return m
    if e.key in (:up, :down, :home, :end_key)
        handle_key!(m.picker, e)
    elseif e.key == :enter
        choose_production!(m)
    elseif e.key == :escape
        m.picking = false
    elseif e.key == :char && e.char == 'r' && m.running == 0
        m.picking = false
        request_productions!(m)
    end
    return m
end

function choose_production!(m::SyncPage)
    name = m.productions[m.picker.selected]
    m.picking = false
    blocked(m) && return m
    return discard_guard!(() -> open_production!(m, name), m)
end

function discard_guard!(action, m::SyncPage; replace_with::Union{Nothing,AbstractString} = nothing)
    if m.dirty && m.root !== nothing
        m.guarded = action
        question = replace_with === nothing ? "Discard the marks on $(m.production.name)?" :
                   "Replace the marks on $(m.production.name) with\n$replace_with?"
        open_modal!(m, :discard, "Unsaved marks", question; confirm = replace_with === nothing ? "Discard" : "Replace", cancel = "Keep",
                    selected = :cancel)
    else
        action()
    end
    return m
end

function load_selection!(m::SyncPage)
    (needs_production!(m) || busy!(m) || blocked(m)) && return m
    path = selection_path(m.settings)
    isfile(path) || (m.status = "no selection file $path"; return m)
    host, production, options, report = m.host, m.production, m.options, report_to(m)
    return discard_guard!(m; replace_with = path) do
        m.status = "loading $path…"
        spawn!(m, :load) do
            selection = load_selection(path, production; host = options.host)
            fresh = production_tree(host, production)
            apply_selection!(host, production, fresh, selection; helper = options.helper, jobs = options.jobs,
                             steps = Steps(["listing directories"], report))
            return (fresh, String(path))
        end
    end
end

function expand_or_collapse!(m::SyncPage, node::Node; collapse::Bool)
    if node.children === nothing && node.kind in (:section, :dir)
        node.remote_path in m.pending && return m
        push!(m.pending, node.remote_path)
        host, production = m.host, m.production
        spawn!(m, "listing:" * node.remote_path) do
            scratch = Node(node.label, node.remote_path, node.kind)
            expand!(host, production, scratch; detectors = true, sizes = false)
            return (node, scratch.children)
        end
        m.status = "listing $(node.label)…"
        rebuild_tree!(m)
    elseif node.children === nothing
        node.kind == :detectors &&
            (node.whole_files ? request_detectors!(m, node) : with_environment!(m, () -> request_detectors!(m, node)))
    elseif collapse && !(node.remote_path in m.collapsed)
        push!(m.collapsed, node.remote_path)
        rebuild_tree!(m)
    else
        delete!(m.collapsed, node.remote_path)
        rebuild_tree!(m)
    end
    return m
end

# The wheel scrolls one row and keeps the selection in the window, because rendering scrolls back to it.
function mouse_list!(w, n::Int, e::MouseEvent)
    Base.contains(w.last_area, e.x, e.y) || return false
    hit = list_hit(e, w.last_area, w.offset, n)
    if hit > 0
        activate = hit == w.selected
        w.selected = hit
        return activate
    end
    height = w.last_area.height
    offset = list_scroll(e, w.offset, n, height)
    if offset != w.offset
        w.offset = offset
        w.selected = clamp(w.selected, offset + 1, offset + height)
    end
    return false
end

function mark_key!(m::SyncPage, node, mode::Symbol)
    node === nothing && return m
    if node.kind == :detectors && node.whole_files
        m.status = "space and l mark a detector below this row"
    elseif node.kind in (:detectors, :detector) && !node.whole_files
        m.status = "use x on detector rows"
    else
        inherited = node.mode != mode && effective_mode(node) == mode
        mark!(() -> node.mode == mode ? set_mode!(node, :none) : inherited ? exclude!(node) : set_mode!(node, mode), m)
    end
    return m
end

function extract_key!(m::SyncPage, node)
    if node === nothing || node.kind != :detector
        m.status = "x extracts a detector: open the detectors row of a run or period and move onto one"
    elseif covering_extract(node) !== nothing && node.mode != :extract
        m.status = "extracted for the whole period; unmark $(node.label) on the period's detectors row first"
    else
        mark!(() -> set_mode!(node, node.mode == :extract ? :none : :extract), m)
    end
    return m
end

function first_n_key!(m::SyncPage, node)
    node === nothing && return m
    if node.kind in (:detectors, :detector)
        m.status = "n applies to run directories, not detector rows"
    elseif isempty(filekey_groups(node))
        show_error!(m, ArgumentError("$(node.label) has no filekey groups; expand a run directory first"))
    else
        m.input = TextInput(label = "N: ", text = "")
        m.modal_kind = :firstn
        m.status = ""
    end
    return m
end

const TREE_KEYS = Dict{Char,Function}(' ' => (m, node) -> mark_key!(m, node, :copy),
                                      'l' =>
                                          (m, node) -> m.production.mount_root === nothing ?
                                                       (m.status = "link mode needs a mount root; set Mount root") :
                                                       mark_key!(m, node, :link),
                                      'n' => first_n_key!, 'x' => extract_key!,
                                      'e' => (m, _) -> blocked(m) || open_estimate!(m; confirm = false),
                                      't' => (m, _) -> blocked(m) || open_estimate!(m; confirm = true),
                                      's' => (m, _) -> save!(m), 'c' => (m, _) -> connect!(m), 'o' => (m, _) -> load_selection!(m),
                                      'p' => (m, _) -> (m.panel_open = !m.panel_open; m.panel_open || (m.focus = :tree)))

function modal_key!(m::SyncPage, e::KeyEvent)
    answer = handle_key!(m.modal, e)
    (answer === false || answer == :none) && return m
    m.modal_kind == :estimate && answer == :confirm && return start_transfer!(m)
    if m.modal_kind == :bootstrap
        answer == :confirm && return start_bootstrap!(m)
        m.continuation = nothing
    end
    action = m.modal_kind == :discard ? m.guarded : nothing
    m.guarded = nothing
    m.modal, m.modal_kind = nothing, :none
    answer == :confirm && action !== nothing && action()
    return m
end

function key!(m::SyncPage, e::KeyEvent)
    # The transfer dialog has no buttons and Modal.handle_key! returns :cancel on :escape, which would dismiss it while
    # apply! keeps running.
    m.modal_kind in (:transfer, :busy, :checking) && return m
    if m.modal_kind == :firstn
        e.key == :enter && return apply_prompt!(m)
        if e.key == :escape
            m.input, m.modal_kind = nothing, :none
        else
            handle_key!(m.input, e)
        end
        return m
    end
    m.modal !== nothing && return modal_key!(m, e)
    m.modal_kind == :estimating && return m
    m.edit !== nothing && return edit_key!(m, e)
    m.picking && return picker_key!(m, e)
    e.key in (:tab, :backtab) && return move_focus!(m, e.key == :tab ? 1 : -1)
    if m.focus == :panel
        panel_key!(m, e) && return m
        (e.key == :char && e.char in ('e', 't', 's', 'p', 'c', 'o')) || return m
    end
    m.root === nothing && e.key == :char && e.char in (' ', 'l', 'n', 'x', 's', 'e', 't', 'o') && (needs_production!(m); return m)
    node = current_node(m)
    # TreeView also binds space, enter, left and right to expand/collapse, which would flip TreeNode.expanded behind the model's back.
    if e.key in (:up, :down, :home, :end_key)
        handle_key!(m.tree, e)
    elseif e.key in (:enter, :right)
        node === nothing || expand_or_collapse!(m, node; collapse = e.key == :enter)
    elseif e.key == :left
        node === nothing || (push!(m.collapsed, node.remote_path); rebuild_tree!(m))
    elseif e.key == :char && haskey(TREE_KEYS, e.char)
        TREE_KEYS[e.char](m, node)
    end
    return m
end

sync_text_input(m::SyncPage) = m.modal_kind == :firstn || m.edit !== nothing

ctrl_c(e::KeyEvent) = e.key == :ctrl_c || (e.key == :ctrl && e.char == 'c')

sync_modal_open(m::SyncPage) = m.modal !== nothing || m.modal_kind != :none

sync_at_rest(m::SyncPage) = !sync_modal_open(m) && m.edit === nothing && !m.picking && m.focus == :tree

function shielded(f, m::SyncPage, fallback)
    try
        return f()
    catch err
        err isa InterruptException && rethrow()
        # Reporting is not shielded, so a fault in it propagates and cannot loop.
        m.modal_kind in (:transfer, :busy) || (m.edit = nothing)
        note_error!(m, err)
        return fallback
    end
end

"""
    sync_key!(page::SyncPage, evt::KeyEvent)::Bool

Handle a key. Returns `false` for Ctrl-C and for the keys the host owns (`q`, `?`, `T`, digits) unless a text
prompt is open or a dialog waits for an answer, and `true` for every other key, known or not. An exception is
shown in the error dialog and the key counts as handled.
"""
function sync_key!(m::SyncPage, e::KeyEvent)
    ctrl_c(e) && return false
    return shielded(m, true) do
        ((e.key == :char && (e.char in ('q', '?', 'T') || isdigit(e.char))) && !sync_text_input(m) &&
         (!sync_modal_open(m) || sync_running(m))) && return false
        key!(m, e)
        return true
    end
end

"""
    sync_mouse!(page::SyncPage, evt::MouseEvent)::Bool

Handle a mouse event; `false` while a dialog is open or a field is edited, `true` otherwise. Clicks on the tree act
like Enter.
"""
function sync_mouse!(m::SyncPage, e::MouseEvent)
    m.modal_kind == :none && m.modal === nothing && m.edit === nothing || return false
    return shielded(m, true) do
        if m.picking
            (m.running > 0 || m.picker === nothing) && return true
            mouse_list!(m.picker, length(m.productions), e) && choose_production!(m)
        elseif m.root !== nothing
            e.button == mouse_left && e.action == mouse_press && Base.contains(m.tree.last_area, e.x, e.y) && (m.focus = :tree)
            if mouse_list!(m.tree, tree_visible_count(m.tree), e)
                node = current_node(m)
                node === nothing || expand_or_collapse!(m, node; collapse = true)
            end
        end
        return true
    end
end

sync_dirty(m::SyncPage) = m.dirty
sync_busy(m::SyncPage) = m.modal_kind in (:transfer, :busy)
sync_running(m::SyncPage) = m.modal_kind in (:checking, :estimating, :transfer, :busy)
sync_stoppable(m::SyncPage) = m.modal_kind in (:estimating, :transfer) && !m.stop[]

function sync_stop!(m::SyncPage)
    m.stop[] = true
    m.status = "stopping…"
    m.modal === nothing || open_modal!(m, m.modal_kind, m.modal.title, "stopping…")
    return m
end

"""
    sync_task!(page::SyncPage, evt::TaskEvent)::Bool

Handle the result of a background task of the page; `false` for an id without the prefix `sync:`. A result that
arrives while no task of the page runs is a mixed-up task id and is shown in the error dialog.
"""
function sync_task!(m::SyncPage, e::TaskEvent)
    startswith(String(e.id), "sync:") || return false
    return shielded(m, true) do
        id = chopprefix(String(e.id), "sync:")
        if id != "step"
            m.running > 0 || error("the result :$id arrived while no sync task runs; a task id was mixed up")
            m.running -= 1
            i = findfirst(==(id), m.active)
            i === nothing || deleteat!(m.active, i)
        end
        task!(m, id, e.value)
        return true
    end
end

function task_listing!(m::SyncPage, path, value)
    if value isa Exception
        delete!(m.pending, path)
        return note_error!(m, value)
    end
    node, children = value
    attach!(node, children).local_state = node_local_state(m.production, node)
    delete!(m.pending, node.remote_path)
    delete!(m.collapsed, node.remote_path)
    m.status = ""
    rebuild_tree!(m)
    dirs = [c.remote_path for c in children if c.kind == :dir]
    host = m.host
    isempty(dirs) || spawn!(() -> (node, Dict(zip(dirs, dir_sizes(host, dirs)))), m, "sizes:" * node.remote_path)
    return m
end

function task_sizes!(m::SyncPage, path, value)
    if value isa Exception
        m.modal_kind == :none && return show_error!(m, value)
        m.status = string("sizes of ", basename(path), ": ", sprint(showerror, value))
        return m
    end
    node, bytes = value
    node.children === nothing && return m
    foreach(child -> child.kind == :dir && (child.size = bytes[child.remote_path]), node.children)
    return rebuild_tree!(m)
end

function task_detectors!(m::SyncPage, path, value)
    delete!(m.pending, path)
    failed, m.step = m.step, nothing
    value isa Exception && return note_error!(m, failed === nothing ? value : ErrorException(sprint(showerror, value) * step_note(failed)))
    node, children = value
    attach_detectors!(node, children)
    delete!(m.collapsed, path)
    m.status = ""
    if isempty(children)
        deleteat!(node.parent.children, findfirst(c -> c === node, node.parent.children))
        m.status = "the files of $(node.parent.label) have no per-detector groups"
    end
    return rebuild_tree!(m)
end

function task_connect!(m::SyncPage, _, value)
    m.connecting = false
    host, options, productions, used = value
    # Settings that changed during the connection describe another connection.
    all(field -> getfield(used, field) == getfield(m.settings, field), fieldnames(SyncSettings)) ||
        return blocked(m) ? m : start_connect!(m)
    m.host, m.options, m.productions = host, options, productions
    m.environment = nothing
    name = m.settings.production
    isempty(name) && return open_picker!(m)
    name in productions && return open_production!(m, name)
    if m.suggested
        m.settings.production = ""
        m.suggested = false
        revalidate!(m)
        m.status = "$name is not a production on $(m.settings.host)"
        return open_picker!(m)
    end
    return show_error!(m, ArgumentError("production $name is not on $(m.options.host) below $(m.options.remote_root)"))
end

function reset_tree!(m::SyncPage, status::AbstractString = "")
    m.step, m.dirty, m.status = nothing, false, status
    empty!(m.collapsed)
    empty!(m.pending)
    rebuild_tree!(m)
    m.tree.selected = 1
    return m
end

function task_load!(m::SyncPage, _, value)
    m.root, m.saved = value
    return reset_tree!(m, "loaded $(m.saved)")
end

function task_open!(m::SyncPage, _, value)
    production, root = value
    # Everything that can fail is built before the page changes.
    settings = deepcopy(m.settings)
    settings.production = production.name
    options = Options(settings; from = m.options.from, dry_run = m.options.dry_run, yes = m.options.yes)
    m.production, m.root, m.settings, m.options = production, root, settings, options
    revalidate!(m)
    m.suggested, m.saved = false, nothing
    return reset_tree!(m)
end

function task_environment!(m::SyncPage, _, status)
    environment_ready(status) && return environment_ready!(m, status)
    m.status = ""
    message = string("Extraction needs HDF5 and ParallelProcessingTools in\n", status.project, " on ", m.options.host,
                     ".\nCreate it with:\n\n", Base.shell_escape(bootstrap_command(m.host, m.options.helper)))
    return open_modal!(m, :bootstrap, "Create the helper environment", message; confirm = "Create", cancel = "Cancel", selected = :confirm)
end

function task_estimate!(m::SyncPage, _, (estimate, confirm, staging, free))
    m.estimate = estimate
    m.step = nothing
    message = string(format_estimate(estimate), "\nfrom ", m.options.host, ":", m.production.remote_root, "\ninto ",
                     m.production.local_root,
                     staging === nothing ? "" : string("\nstaging ", staging, ": ", format_bytes(free), " free"),
                     isempty(estimate.not_in_run) ? "" : string("\nnot in run: ", format_not_in_run(estimate.not_in_run)))
    m.status = ""
    return open_modal!(m, :estimate, "Estimate", message; confirm = "Sync", cancel = "Close", selected = confirm ? :confirm : :cancel)
end

function task_transfer!(m::SyncPage, _, result)
    m.step = nothing
    refresh_local_state!(m)
    rebuild_tree!(m)
    return open_message!(m, "Transfer complete", summary_text(result))
end

function task_stopped!(m::SyncPage, id)
    m.step = nothing
    m.modal, m.modal_kind, m.continuation, m.estimated = nothing, :none, nothing, nothing
    if id == "transfer"
        refresh_local_state!(m)
        rebuild_tree!(m)
        m.status = "transfer stopped; the next run resumes from the staged files"
    else
        m.status = "estimate stopped"
    end
    return m
end

function task_failed!(m::SyncPage, id, err)
    failed, m.step, m.continuation = m.step, nothing, nothing
    id == "connect" && (m.connecting = false)
    text = ErrorException(sprint(showerror, err) * step_note(failed))
    id == "productions" && (m.productions = nothing)
    id in ("transfer", "bootstrap") ? show_error!(m, text) : note_error!(m, text)
    id == "productions" && (m.status = "no productions found in $(m.options.remote_root)")
    return m
end

const TASK_HANDLERS = Dict("listing" => task_listing!, "sizes" => task_sizes!, "detectors" => task_detectors!,
                           "step" =>
                               (m, _, p) -> ((m.step === nothing || m.step.step != p.step) && (m.step_started = time()); m.step = p; m),
                           "connect" => task_connect!, "load" => task_load!, "productions" => (m, _, found) -> show_picker!(m, found),
                           "open" => task_open!, "environment" => task_environment!,
                           "bootstrap" => (m, _, status) -> environment_ready!(m, status), "estimate" => task_estimate!,
                           "transfer" => task_transfer!)

function task!(m::SyncPage, id::AbstractString, value)
    kind, path = split_id(id)
    handler = get(TASK_HANDLERS, kind) do
        return error("unexpected background result :$id; every task this page starts must be handled here")
    end
    kind in ("listing", "sizes", "detectors") && return handler(m, path, value)
    # An estimate that ends before a stop can act is stopped as well: the question it would open was declined.
    (value isa SyncStopped || (id == "estimate" && m.stop[] && !(value isa Exception))) && return task_stopped!(m, id)
    value isa Exception && return task_failed!(m, id, value)
    return handler(m, path, value)
end
