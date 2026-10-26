# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const PANEL_FIELDS = SETTINGS_FIELDS
const PANEL_BUTTONS = (:connect, :load, :save, :estimate, :transfer)
const PANEL_ITEMS = (PANEL_FIELDS..., PANEL_BUTTONS...)
const FIELD_LABELS = (host = "Host", remote_root = "Remote root", production = "Production", local_root = "Local root",
                      mount_root = "Mount root", staging = "Staging", jobs = "Jobs", selection = "Selection")
const BUTTON_LABELS = (connect = "Connect", load = "Load selection", save = "Save selection", estimate = "Estimate", transfer = "Transfer")

# Width from which the panel uses two columns, and the fewest body rows that justify showing the panel.
const WIDE_PANEL = 100
const MIN_BODY = 6

"""
    FieldEdit(field, text, hint)

A settings field being edited: its name, the text typed so far and the candidates the last Tab listed.
"""
mutable struct FieldEdit
    field::Symbol
    text::String
    hint::String
end

"""
    SyncPage(host, production, options; queue = TaskQueue())
    SyncPage(host, options; queue = TaskQueue())
    SyncPage(settings, queue; host_factory = SSHHost, suggested = false)

The state of the sync screen: a settings panel above the production tree. The first form opens `production`
on `host`. The second has a host but no production yet, and the third has no connection at all (`host`,
`options`, `production` and `root` are `nothing`): [`sync_start!`](@ref) connects to `host_factory(settings.host)`
in the background, lists the productions of the remote root and opens the one the settings name, or the
picker. The first two forms reconnect through a factory that returns their host.

The `Node` tree is the source of truth; the `TreeView` is
rebuilt from it whenever anything changes, because `TreeView` caches its
flattened rows and mutating its nodes in place would leave that cache stale.

Which nodes are open lives in `collapsed`, not in the `TreeNode`s, for the same
reason. `pending` holds the remote paths of listings in flight.

`environment` caches a ready helper environment, and `continuation` is what to do once an environment
check or creation finishes. `step` is the latest progress reading of the running operation and `step_started`
the time it began; `connecting` says a Connect task runs, and `suggested` that the production named in the
settings came from outside the panel, so a production missing on the host is dropped instead of reported.

`settings` holds the text of every panel field; `errors` the reasons the invalid ones are unusable. `focus` is
`:panel` or `:tree`, `cursor` indexes `PANEL_ITEMS`, `edit` is the field being edited and `picking` says the
production list is open. `panel_open` is the wish of the user, `panel_shown` what the last render could fit (it starts `true` until the first
render); `guarded` is the action waiting for the answer of the discard dialog;
`panel_rects` and `summary_rect` are the screen cells of the last render, which mouse handling uses.

The page is given a `TaskQueue` and starts its tasks with ids prefixed `sync:`; the host routes events with that
prefix to [`sync_task!`](@ref). `running` counts the page's own unanswered tasks, because the queue may be shared.
"""
mutable struct SyncPage
    host::Union{Nothing,RemoteHost}
    production::Union{Nothing,Production}
    options::Union{Nothing,Options}
    settings::SyncSettings
    running::Int
    root::Union{Nothing,Node}
    collapsed::Set{String}
    pending::Set{String}
    tree::TreeView
    tasks::TaskQueue
    dirty::Bool
    status::String
    saved::Union{Nothing,String}
    modal::Union{Nothing,Modal}
    modal_kind::Symbol
    input::Union{Nothing,TextInput}
    estimate::Union{Nothing,Estimate}
    productions::Union{Nothing,Vector{String}}
    picker::Union{Nothing,SelectableList}
    environment::Union{Nothing,EnvironmentStatus}
    continuation::Union{Nothing,Function}
    focus::Symbol
    cursor::Int
    edit::Union{Nothing,FieldEdit}
    panel_open::Bool
    panel_shown::Bool
    errors::Dict{Symbol,String}
    remote_default::String
    panel_rects::Vector{Pair{Symbol,Rect}}
    summary_rect::Rect
    picking::Bool
    guarded::Union{Nothing,Function}
    host_factory::Any
    step::Union{Nothing,StepProgress}
    step_started::Float64
    connecting::Bool
    suggested::Bool
end

# Every constructor starts from the same blank state; `root` and `panel_open` are what they differ in.
function blank_page(host, production, options, settings, root, queue, host_factory, panel_open)
    return SyncPage(host, production, options, settings, 0, root, Set{String}(), Set{String}(),
                    # Replaced by rebuild_tree! when there is a production: that needs the page to exist.
                    TreeView(TreeNode("")), queue, false, "", nothing, nothing, :none, nothing, nothing, nothing, nothing, nothing,
                    nothing, :tree, 1, nothing, panel_open, true, Dict{Symbol,String}(), "", Pair{Symbol,Rect}[], Rect(1, 1, 0, 0), false,
                    nothing, host_factory, nothing, 0.0, false, false)
end

function SyncPage(host::RemoteHost, production::Production, options::Options; queue::TaskQueue = TaskQueue())
    m = blank_page(host, production, options, SyncSettings(options), production_tree(host, production), queue, _ -> host, false)
    rebuild_tree!(m)
    m.tree.selected = 1
    return revalidate!(m)
end

function SyncPage(host::RemoteHost, options::Options; queue::TaskQueue = TaskQueue())
    return revalidate!(blank_page(host, nothing, options, SyncSettings(options), nothing, queue, _ -> host, true))
end

function SyncPage(settings::SyncSettings, queue::TaskQueue; host_factory = SSHHost, suggested::Bool = false)
    m = blank_page(nothing, nothing, nothing, settings, nothing, queue, host_factory, true)
    m.suggested = suggested
    return revalidate!(m)
end

"""
    sync_start!(page::SyncPage)::SyncPage

Connect when no production is open and nothing is listed or running, and the settings are valid; otherwise leave the
first reason in the status line. Calling it again while the connection is made or after it was made does nothing.
"""
function sync_start!(m::SyncPage)
    (m.root === nothing && m.productions === nothing && m.running == 0) || return m
    blocked(m) && return m
    return start_connect!(m)
end

"""
    start_connect!(page::SyncPage)::SyncPage

Connect in the background: build the host with the page's `host_factory`, check that rsync is installed, derive the
[`Options`](@ref) from a copy of the settings and list the productions. The result is handled by [`sync_task!`](@ref).
"""
function start_connect!(m::SyncPage)
    m.connecting && (m.status = "busy: connecting to $(m.settings.host); the current settings are used when it is done"; return m)
    s = copy(m.settings)
    factory = m.host_factory
    m.connecting = true
    m.status = "connecting to $(s.host)…"
    spawn!(m, :connect) do
        host = in_step("checking host $(s.host)") do
            return factory(s.host)
        end
        in_step(check_rsync, "checking rsync")
        options = Options(s)
        productions = in_step("listing productions on $(s.host)") do
            return list_productions(host, options.remote_root)
        end
        return (host, options, productions, s)
    end
    return m
end

# Run `f()`; a failure is rethrown with `what` in front of its message, so the error dialog names the step.
function in_step(f, what::AbstractString)
    try
        return f()
    catch err
        err isa InterruptException && rethrow()
        throw(ErrorException(string(what, ": ", sprint(showerror, err))))
    end
end

# Whether another task of the page runs; the status then says what the page is busy with.
function busy!(m::SyncPage)
    m.running > 0 || return false
    m.status = "busy: " * (isempty(m.status) ? "a background task is running" : m.status)
    return true
end

"""
    connect!(page::SyncPage)::SyncPage

The Connect button: refuse while a setting is invalid, ask before dropping unsaved marks, then
[`start_connect!`](@ref).
"""
function connect!(m::SyncPage)
    busy!(m) && return m
    blocked(m) && return m
    return discard_guard!(m, () -> "Discard the marks on $(m.production.name)?", () -> start_connect!(m))
end

"""
    spawn!(f, page::SyncPage, id)

Run `f()` in the background; its result arrives as a `TaskEvent` with the id `sync:<id>` and is
handled by [`sync_task!`](@ref).
"""
function spawn!(f, m::SyncPage, id)
    m.running += 1
    return spawn_task!(f, m.tasks, Symbol("sync:", id))
end

# The suffix of an error message that names the step it happened in.
step_note(p::Union{Nothing,StepProgress}) = p === nothing ? "" : "\n(in step \"$(p.step)\", $(p.index) of $(p.count))"

"""
    report_to(page::SyncPage)

The step callback of an operation started on the page: it queues each [`StepProgress`](@ref) as a `sync:step`
event, so the page's own state is only touched on its thread.
"""
report_to(m::SyncPage) = (queue = m.tasks; p -> put!(queue.channel, TaskEvent(Symbol("sync:step"), p)))

"""
    request_productions!(m::SyncPage)::SyncPage

List the productions of the remote root in the background; the picker shows
`listing…` until the result arrives.
"""
function request_productions!(m::SyncPage)
    host = m.host
    remote_root = m.options.remote_root
    m.productions = nothing
    m.picker = nothing
    spawn!(() -> list_productions(host, remote_root), m, :productions)
    return m
end

"""
    checkbox(node::Node)::String

The tri-state marker: `[x]` copied, `[~]` linked, `[e]` extracted, `[ ]` untouched, `[-]` for a
node that is untouched itself but has something chosen below it.
"""
function checkbox(node::Node)
    mode = effective_mode(node)
    mode == :copy && return "[x]"
    mode == :link && return "[~]"
    mode == :extract && return "[e]"
    return marked_below(node) ? "[-]" : "[ ]"
end

function marked_below(node::Node)
    node.children === nothing && return false
    return any(child -> child.mode != :none || marked_below(child), node.children)
end

"""
    node_label(node::Node)::String

The text of one tree row. The size column is padded rather than right-aligned to
the pane, because `TreeView` prepends connectors whose width depends on depth.
"""
node_label(node::Node) = string(checkbox(node), " ", rpad(node.label, 28), " ",
                                node.size === nothing ? "…" : format_bytes(node.size))

"""
    build_tree(m::SyncPage, node::Node = m.root)::TreeNode

The `TreeNode` mirror of the inventory. An unlisted directory gets one
placeholder child so that `TreeView` draws an expand arrow for it.
"""
function build_tree(m::SyncPage, node::Node = m.root)
    children = if node.children !== nothing
        [build_tree(m, child) for child in node.children]
    elseif node.kind in (:section, :dir, :detectors)
        [TreeNode(node.remote_path in m.pending ? "…listing" : "…")]
    else
        TreeNode[]
    end
    return TreeNode(node_label(node); children,
                    expanded = node.children !== nothing && !(node.remote_path in m.collapsed),
                    content = node)
end

"""
    rebuild_tree!(m::SyncPage)::SyncPage

Rebuild the `TreeView` from the inventory, keeping the cursor where it was. The
cursor is pulled back to the last row when the tree shrank under it, because a
`TreeView` whose `selected` points past the rows has no selected node at all.
"""
function rebuild_tree!(m::SyncPage)
    selected = m.tree.selected
    offset = m.tree.offset
    m.tree = TreeView(build_tree(m); selected, offset, focused = true,
                      block = Block(title = "Production: $(m.production.name) @ $(m.options.host)"))
    m.tree.selected = min(selected, tree_visible_count(m.tree))
    return m
end

"""
    current_node(m::SyncPage)::Union{Nothing,Node}

The inventory node under the cursor, or `nothing` on a placeholder row.
"""
function current_node(m::SyncPage)
    row = selected_node(m.tree)
    row === nothing && return nothing
    return row.content isa Node ? row.content : nothing
end

"""
    request_expand!(m::SyncPage, node::Node)::SyncPage

Start listing `node` in the background. The listing is built on a detached node
and linked in by [`attach_listing!`](@ref) on the main thread, so nothing the
renderer is reading changes underneath it.

The listing does not wait for directory sizes: the event handler starts a second task
with id `sizes:<path>` once the listing is attached, and the children show `…` until it
reports. That task is not in `m.pending`, so the user can open children meanwhile.

The background task carries `node.remote_path` in its own id, `listing:<path>`,
so that a listing which fails only clears its own entry from `m.pending` and
never disturbs a second listing still in flight.
"""
function request_expand!(m::SyncPage, node::Node)
    (node.children !== nothing || node.remote_path in m.pending) && return m
    node.kind in (:section, :dir) || return m
    push!(m.pending, node.remote_path)
    host = m.host
    production = m.production
    spawn!(m, "listing:" * node.remote_path) do
        scratch = Node(node.label, node.remote_path, node.kind)
        expand!(host, production, scratch; detectors = true, sizes = false)
        return (node, scratch.children)
    end
    m.status = "listing $(node.label)…"
    return rebuild_tree!(m)
end

"""
    attach_listing!(m::SyncPage, listing)::SyncPage
"""
function attach_listing!(m::SyncPage, listing::Tuple{Node,Vector{Node}})
    node, children = listing
    for child in children
        child.parent = node
    end
    node.children = children
    node.local_state = node_local_state(m.production, node)
    delete!(m.pending, node.remote_path)
    delete!(m.collapsed, node.remote_path)
    m.status = ""
    return rebuild_tree!(m)
end

"""
    with_environment!(m::SyncPage, continue_with)::SyncPage

Call `continue_with()` once the remote helper environment is ready. A ready
environment is remembered; otherwise it is checked in the background, and a missing
or incomplete one opens a dialog that shows the command that would create it. While
the check runs the model is in the `:checking` state and accepts no key.
"""
function with_environment!(m::SyncPage, continue_with)
    if m.environment !== nothing
        continue_with()
        return m
    end
    host = m.host
    helper = m.options.helper
    m.continuation = continue_with
    m.modal_kind = :checking
    m.status = "checking the helper environment on $(m.options.host)…"
    spawn!(() -> ensure_environment(host, helper), m, :environment)
    return m
end

"""
    environment_ready!(m::SyncPage, status::EnvironmentStatus)::SyncPage

Remember the ready environment, close any dialog, and run what was waiting for it.
"""
function environment_ready!(m::SyncPage, status::EnvironmentStatus)
    m.environment = status
    m.status = ""
    m.modal = nothing
    m.modal_kind = :none
    continue_with = m.continuation
    m.continuation = nothing
    continue_with === nothing || continue_with()
    return m
end

"""
    start_bootstrap!(m::SyncPage)::SyncPage

Create the helper environment in the background. The dialog accepts no key until it
finishes.
"""
function start_bootstrap!(m::SyncPage)
    host = m.host
    helper = m.options.helper
    m.modal = Modal(title = "Creating the helper environment",
                    message = "running Pkg.add on $(m.options.host); this can take several minutes…",
                    confirm_label = "", cancel_label = "")
    m.modal_kind = :busy
    spawn!(() -> bootstrap_environment!(host, helper), m, :bootstrap)
    return m
end

"""
    request_detectors!(m::SyncPage, node::Node)::SyncPage

Inspect, in the background, the first file of the run below `node` (a `:detectors`
row of a run) or the first file of each run of the period below it (a `:detectors`
row of a period). The `:detectors` row of a period of per-detector files is listed
from the directory listings of its runs instead, without the helper. The rows are
built on detached nodes and linked in by the event handler, like a directory listing.
"""
function request_detectors!(m::SyncPage, node::Node)
    (node.children !== nothing || node.remote_path in m.pending) && return m
    push!(m.pending, node.remote_path)
    host = m.host
    helper = m.options.helper
    jobs = m.options.jobs
    run = node.parent
    steps = detector_steps(report_to(m), node)
    spawn!(m, "detectors:" * node.remote_path) do
        return (node, detector_nodes(host, helper, run; jobs, steps))
    end
    m.status = node.whole_files ? "listing the detector files of $(run.label)…" :
               "inspecting the files of $(run.label)…"
    return rebuild_tree!(m)
end

"""
    toggle_extract!(m::SyncPage, node::Node)::SyncPage

Mark the detector row `node` for extraction, or unmark it. A refused mark leaves the
tree unchanged and puts the reason, which names both marks, into the status line.
"""
function toggle_extract!(m::SyncPage, node::Node)
    target = node.mode == :extract ? :none : :extract
    try
        set_mode!(node, target)
    catch err
        err isa ArgumentError || rethrow()
        m.status = err.msg
        return m
    end
    m.dirty = true
    m.status = ""
    return rebuild_tree!(m)
end

"""
    open_estimate!(m::SyncPage; confirm::Bool)::SyncPage

Ask what the selection would actually move, in the background. `confirm` decides
which button the modal opens on: `e` looks, `t` intends to sync. A selection with
extract entries first needs the helper environment.
"""
function open_estimate!(m::SyncPage; confirm::Bool)
    selection = Selection(m.production, m.options.host, m.root)
    m.modal_kind = :estimating
    m.status = "estimating…"
    return isempty(selection.extract) ? run_estimate!(m, selection, confirm) :
           with_environment!(m, () -> run_estimate!(m, selection, confirm))
end

"""
    run_estimate!(m::SyncPage, selection::Selection, confirm::Bool)::SyncPage

The dry run behind [`open_estimate!`](@ref). With extract entries it also asks the
host how much room the staging directory has.
"""
function run_estimate!(m::SyncPage, selection::Selection, confirm::Bool)
    host = m.host
    production = m.production
    helper = m.options.helper
    jobs = m.options.jobs
    report = report_to(m)
    m.modal_kind = :estimating
    m.status = "estimating…"
    spawn!(m, :estimate) do
        result = estimate_selection(host, production, selection; helper, jobs, report)
        return (result.estimate, confirm, result.staging, result.free)
    end
    return m
end

"""
    start_transfer!(m::SyncPage)::SyncPage

Run the transfer in the background. The step report runs on that task and
never touches the model: it pushes a `TaskEvent` like every other result.
"""
function start_transfer!(m::SyncPage)
    host = m.host
    production = m.production
    helper = m.options.helper
    jobs = m.options.jobs
    selection = Selection(production, m.options.host, m.root)
    report = report_to(m)
    m.modal = Modal(title = "Transferring", message = "starting…",
                    confirm_label = "", cancel_label = "")
    m.modal_kind = :transfer
    spawn!(m, :transfer) do
        return apply!(host, production, selection; helper, jobs, report)
    end
    return m
end

"""
    open_prompt!(m::SyncPage, node::Node)::SyncPage

Open the "first N filekeys" prompt for a listed run directory.
"""
function open_prompt!(m::SyncPage, node::Node)
    isempty(filekey_groups(node)) &&
        return show_error!(m, ArgumentError("$(node.label) has no filekey groups; expand a run directory first"))
    m.input = TextInput(label = "N: ", text = "")
    m.modal_kind = :firstn
    m.status = ""
    return m
end

"""
    open_message!(m::SyncPage, title, message)::SyncPage

Show a dialog that only has to be dismissed.
"""
function open_message!(m::SyncPage, title::AbstractString, message::AbstractString)
    m.modal = Modal(; title, message, confirm_label = "", cancel_label = "Close")
    m.modal_kind = :message
    m.status = ""
    return m
end

"""
    show_error!(m::SyncPage, err)::SyncPage

Report a failure and leave the tool usable.
"""
show_error!(m::SyncPage, err) = (open_message!(m, "Error", sprint(showerror, err)); m.modal_kind = :error; m)

"""
    apply_prompt!(m::SyncPage)::SyncPage

Read the number from the prompt and mark that many filekeys. A number that
cannot be used is reported and the prompt stays open.
"""
function apply_prompt!(m::SyncPage)
    node = current_node(m)
    typed = strip(Tachikoma.text(m.input))
    count = tryparse(Int, typed)
    if node === nothing || count === nothing || count < 1
        m.status = "expected a positive number of filekeys, got \"$typed\""
        return m
    end
    first_n_filekeys!(node, count)
    m.input = nothing
    m.modal_kind = :none
    m.dirty = true
    m.status = ""
    return rebuild_tree!(m)
end

"""
    refresh_local_state!(m::SyncPage, node::Node = m.root)::SyncPage

Recompute what is on disk for every listed node, children first so a directory
sees its children's final states.
"""
function refresh_local_state!(m::SyncPage, node::Node = m.root)
    if node.children !== nothing
        for child in node.children
            refresh_local_state!(m, child)
        end
    end
    node.local_state = node_local_state(m.production, node)
    return m
end

"""
    save!(m::SyncPage)::String

Write the selection to the configured path and return it.
"""
function save!(m::SyncPage)
    path = selection_path(m.settings)
    isempty(path) && (m.status = "choose a production before saving"; return path)
    save_selection(path, Selection(m.production, m.settings.host, m.root))
    m.saved = path
    m.dirty = false
    m.status = ""
    return path
end

"""
    toggle_mode!(m::SyncPage, node::Node, mode::Symbol)::SyncPage

Turn `mode` on or off for `node`. A node that carries `mode` itself loses it; one
that only inherits it is excluded from the ancestor's choice by
[`exclude!`](@ref); anything else takes `mode` on. Every branch changes a mode,
which is why the selection is dirty afterwards. A mark that would cover a run already
marked for extraction, or the reverse, is refused with the reason in the status line.
"""
function toggle_mode!(m::SyncPage, node::Node, mode::Symbol)
    inherited = node.mode != mode && effective_mode(node) == mode
    try
        node.mode == mode ? set_mode!(node, :none) : inherited ? exclude!(node) : set_mode!(node, mode)
    catch err
        err isa ArgumentError || rethrow()
        m.status = err.msg
        return m
    end
    m.dirty = true
    m.status = ""
    return rebuild_tree!(m)
end

"""
    details(m::SyncPage)::Paragraph

The right-hand pane: what the cursor is on, and the keys.
"""
function details(m::SyncPage)
    node = current_node(m)
    lines = node === nothing ? String[] :
            node.kind == :detector && node.whole_files ?
            [node.label,
             "files of this detector in the runs of $(node.parent.parent.label)",
             "held by " * join(basename.(first.(node.holders)), ", "),
             "size: " * (node.size === nothing ? "…" : format_bytes(node.size)),
             "mark: " * (node.mode == :none ? "no" : String(node.mode)), ""] :
            node.kind == :detector ?
            [node.label,
             period_level(node.parent.parent) ?
             "detector of the runs of $(node.parent.parent.label) ($(length(node.holders)) hold it)" :
             "HDF5 group of the files in $(node.parent.parent.label)",
             (period_level(node.parent.parent) ? "approximate size in the period: " : "size in the first file: ") *
             (node.size === nothing ? "…" : format_bytes(node.size)),
             "extract: " * (node.mode == :extract ? "yes" :
                            effective_mode(node) == :extract ? "yes (whole period)" : "no"), ""] :
            node.kind == :detectors && node.whole_files ?
            [node.label,
             "enter lists the detector files of every run in $(node.parent.label)", ""] :
            node.kind == :detectors ?
            [node.label,
             period_level(node.parent) ?
             "enter lists the detectors of the first file of every run in $(node.parent.label)" :
             "enter lists the top-level groups of the first file in $(node.parent.label)", ""] :
            [node.label, node.remote_path, "local: $(node.local_state)",
             "size: " * (node.size === nothing ? "…" : format_bytes(node.size)), ""]
    if node !== nothing && node.kind == :production
        overlays = m.production.overlays
        insert!(lines, lastindex(lines),
                "overlays: " * (isempty(overlays) ? "none" : join(overlays, ", ")))
    end
    append!(lines,
            ["space copy   l link   n first N   x extract",
             "per-detector tiers: space/l mark a detector's files",
             "enter expand/collapse   mouse: click, wheel",
             "Tab settings and buttons   p panel",
             "c connect   o load   s save   e estimate   t sync   q quit"])
    return Paragraph(join(lines, "\n"); block = Block(title = "Details"), wrap = word_wrap)
end

"""
    status_bar(m::SyncPage)::StatusBar

The running estimate and whatever the tool last had to say on the left, and the
selection file on the right. The right span keeps only the part of the path that
tells the files apart (the name under the default selection directory), because
`StatusBar` gives the left span priority and clips the right one away.
"""
function status_bar(m::SyncPage)
    out = selection_path(m.settings)
    name = startswith(out, default_selection_dir() * "/") ?
           relpath(out, default_selection_dir()) : basename(out)
    return StatusBar(left = [Span(format_estimate(running_estimate(m.root)), tstyle(:text_bright)),
                             Span(isempty(m.status) ? "" : "   " * m.status)],
                     right = [Span((m.saved === nothing ? "unsaved: " : "saved: ") * name)])
end

"""
    render_prompt(m::SyncPage, area::Rect, buf::Buffer)

The "first N filekeys" prompt. `Modal` holds static text and cannot host a
widget, so the prompt is a `Block` with a `TextInput` drawn inside it.
"""
function render_prompt(m::SyncPage, area::Rect, buf::Buffer)
    rect = center(area, 46, 5)
    inner = render(Block(title = "First N filekeys",
                         border_style = tstyle(:accent, bold = true),
                         box = BOX_HEAVY), rect, buf)
    render(m.input, inner, buf)
    return nothing
end

# The buttons left to right as (button, row, column) in rows of at most `width` columns, a button moving to the next row
# when it would not fit.
function button_cells(width::Integer)
    cells = Tuple{Symbol,Int,Int}[]
    row = 0
    x = 0
    for button in PANEL_BUTTONS
        w = textwidth(BUTTON_LABELS[button]) + 4
        if x > 0 && x + w > width
            row += 1
            x = 0
        end
        push!(cells, (button, row, x))
        x += w + 1
    end
    return cells
end

# The rows of the panel's inner area: the field rows, the button rows and the message row.
panel_rows(wide::Bool, width::Integer) = (wide ? 4 : length(PANEL_FIELDS)) + maximum(c -> c[2], button_cells(width)) + 2

"""
    panel_rects(inner::Rect, wide::Bool)::Vector{Pair{Symbol,Rect}}

The one-row cell of every field and button inside the panel's `inner` area. Rendering and mouse
handling both use it, so a click always lands on what was drawn.
"""
function panel_rects(inner::Rect, wide::Bool)
    rects = Pair{Symbol,Rect}[]
    cell(row, col, width, name) = push!(rects, name => Rect(inner.x + col, inner.y + row, max(width, 1), 1))
    w = inner.width
    if wide
        half = w ÷ 2
        cell(0, 0, half - 1, :host)
        cell(0, half, w - half, :remote_root)
        cell(1, 0, w, :production)
        cell(2, 0, half - 1, :local_root)
        cell(2, half, w - half, :mount_root)
        third = w ÷ 3
        cell(3, 0, third - 1, :staging)
        cell(3, third, third - 1, :jobs)
        cell(3, 2 * third, w - 2 * third, :selection)
        row = 4
    else
        for (i, field) in enumerate(PANEL_FIELDS)
            cell(i - 1, 0, w, field)
        end
        row = length(PANEL_FIELDS)
    end
    for (button, button_row, x) in button_cells(w)
        cell(row + button_row, x, textwidth(BUTTON_LABELS[button]) + 4, button)
    end
    return rects
end

"""
    revalidate!(page)

Recompute the reasons fields are invalid (with `check_paths`) and the remote root the hosts file gives
the host. Called after every change of a setting, never per frame.
"""
function revalidate!(m::SyncPage)
    m.errors = Dict(settings_errors(m.settings; check_paths = true))
    s = m.settings
    m.remote_default = isfile(s.hosts_file) && s.host in hosts_choices(s.hosts_file) ? host_remote_root(s.hosts_file, s.host) : ""
    return m
end

"""
    blocked(page)::Bool

Whether an invalid setting forbids Estimate and Transfer. The first reason goes to the status line.
"""
function blocked(m::SyncPage)
    isempty(m.errors) && return false
    m.status = last(first(settings_errors(m.settings; check_paths = true)))
    return true
end

const RELOAD_FIELDS = (:host, :remote_root, :production, :local_root, :mount_root)

"""
    change_setting!(page, field, text)

Store a committed value. A value that is invalid stays in the field and is shown with its reason. The settings the
connection or the open production were built from (`RELOAD_FIELDS`) reconnect through [`reload_for!`](@ref), after
a confirmation when the tree has unsaved marks; Host and Remote root connect even when no tree is loaded.
"""
function change_setting!(m::SyncPage, field::Symbol, text::AbstractString)
    getfield(m.settings, field) == text && return m
    apply = function ()
        setfield!(m.settings, field, String(text))
        revalidate!(m)
        connected = m.host !== nothing || m.root !== nothing
        # Without a connection any setting that makes the settings valid connects; with one, only the connection's own settings reload.
        !connected || field in (:host, :remote_root) || (field in RELOAD_FIELDS && m.host !== nothing) ? reload_for!(m, field) :
        refresh_options!(m)
        return nothing
    end
    field in RELOAD_FIELDS || return (apply(); m)
    return discard_guard!(m, () -> "Discard the marks on $(m.production.name)?", apply)
end

"""
    reload_for!(page, field)

A setting that the connection or the production was built from changed: forget the productions of the old connection
and connect again, which reopens the production when the settings name one. Invalid settings put the first reason in
the status line instead.
"""
function reload_for!(m::SyncPage, field::Symbol)
    m.productions = nothing
    m.picker = nothing
    m.picking = false
    blocked(m) && return m
    m.suggested = false
    return start_connect!(m)
end

"""
    refresh_options!(page)

Rebuild `page.options` from the settings when they are valid, so the next estimate or transfer uses the
new jobs, staging directory and selection path.
"""
function refresh_options!(m::SyncPage)
    (isempty(m.errors) && m.options !== nothing) || return m
    m.options = Options(m.settings; from = m.options.from, dry_run = m.options.dry_run, yes = m.options.yes)
    return m
end

# What an empty field stands for.
function empty_text(m::SyncPage, field::Symbol)
    field === :remote_root && return isempty(m.remote_default) ? "(not set)" : string("(", m.remote_default, ")")
    field === :staging && return "(host default)"
    field === :mount_root && return "(none)"
    field === :production && return "(choose with Enter)"
    field === :selection &&
        return isempty(selection_path(m.settings)) ? "(default after choosing a production)" : selection_path(m.settings)
    return ""
end

function render_panel(m::SyncPage, area::Rect, buf::Buffer, shown::Bool, wide::Bool)
    m.summary_rect = Rect(area.x, area.y, area.width, 1)
    s = m.settings
    if !shown
        empty!(m.panel_rects)
        text = string("▸ ", s.host, "  ", isempty(s.production) ? "(no production)" : s.production, "  ", s.local_root)
        set_string!(buf, area.x, area.y, text, tstyle(:accent); max_x = Tachikoma.right(area))
        return nothing
    end
    inner = render(Block(title = "Settings"), area, buf)
    m.panel_rects = panel_rects(inner, wide)
    for (name, rect) in m.panel_rects
        focused = m.focus == :panel && PANEL_ITEMS[m.cursor] == name
        if name in PANEL_FIELDS
            editing = m.edit !== nothing && m.edit.field == name
            value = getfield(s, name)
            dim = isempty(value) && !editing
            shown_text = editing ? last(m.edit.text * "▏", max(rect.width - 12, 1)) : !isempty(value) ? value : empty_text(m, name)
            style = haskey(m.errors, name) ? tstyle(:error) : editing ? tstyle(:accent) : dim ? tstyle(:text_dim) : tstyle(:text)
            set_string!(buf, rect.x, rect.y, rpad(FIELD_LABELS[name], 12), focused ? tstyle(:accent, bold = true) : tstyle(:text_dim);
                        max_x = Tachikoma.right(rect))
            set_string!(buf, rect.x + 12, rect.y, shown_text, style; max_x = Tachikoma.right(rect))
        else
            set_string!(buf, rect.x, rect.y, string("[ ", BUTTON_LABELS[name], " ]"),
                        focused ? tstyle(:accent, bold = true) : tstyle(:text);
                        max_x = Tachikoma.right(rect))
        end
    end
    field = m.edit !== nothing ? m.edit.field : m.focus == :panel && PANEL_ITEMS[m.cursor] in PANEL_FIELDS ? PANEL_ITEMS[m.cursor] : nothing
    message = field === nothing ? "" : m.edit !== nothing && !isempty(m.edit.hint) ? m.edit.hint : get(m.errors, field, "")
    set_string!(buf, inner.x, Tachikoma.bottom(inner), message, tstyle(haskey(m.errors, something(field, :none)) ? :error : :text_dim);
                max_x = Tachikoma.right(inner))
    return nothing
end

# The production list as an overlay on the body.
function render_picker(m::SyncPage, area::Rect, buf::Buffer)
    m.picker === nothing && return nothing
    height = min(area.height, max(5, length(m.productions) + 2))
    rect = center(area, min(70, area.width), height)
    for y in rect.y:Tachikoma.bottom(rect)
        set_string!(buf, rect.x, y, " "^rect.width, tstyle(:text))
    end
    render(m.picker, rect, buf)
    return nothing
end

# The bottom row: the current step of a long operation (a gauge, or a spinner and the elapsed time when its size is unknown),
# else the status alone without a tree, else the running estimate and the selection file.
function render_progress(m::SyncPage, area::Rect, buf::Buffer)
    p = m.step
    if m.root === nothing && p === nothing
        set_string!(buf, area.x, area.y, isempty(m.status) ? "Connect (c) lists the productions" : m.status, tstyle(:text);
                    max_x = Tachikoma.right(area))
    elseif p === nothing
        render(status_bar(m), area, buf)
    elseif p.total === nothing
        elapsed = round(Int, time() - m.step_started)
        glyph = Tachikoma.SPINNER_BRAILLE[mod1(floor(Int, 8 * time()), length(Tachikoma.SPINNER_BRAILLE))]
        text = string(format_step(p), "  ", glyph, " ", elapsed ÷ 60, ":", lpad(elapsed % 60, 2, '0'))
        set_string!(buf, area.x, area.y, text, tstyle(:accent); max_x = Tachikoma.right(area))
    else
        render(Gauge(p.total == 0 ? 0.0 : p.done / p.total; label = format_step(p)), area, buf)
    end
    return nothing
end

"""
    render_sync(m::SyncPage, area::Rect, buf::Buffer)

Draw the interface into `area`. The area is explicit and nothing assumes it owns
the terminal, so the future Juleana app can host this as one screen.
"""
function render_sync(m::SyncPage, area::Rect, buf::Buffer)
    wide = area.width >= WIDE_PANEL
    rows_needed = panel_rows(wide, area.width - 2)
    shown = m.panel_open && area.height >= rows_needed + 2 + MIN_BODY + 1       # the progress row is the +1
    m.panel_shown = shown
    shown || m.focus != :panel || (m.focus = :tree)
    rows = split_layout(Layout(Vertical, Constraint[Fixed(shown ? rows_needed + 2 : 1), Fill(1), Fixed(1)]), area)
    render_panel(m, rows[1], buf, shown, wide)
    if m.root === nothing
        render(Paragraph(m.running > 0 ? "working…" : "No production is open. Choose one with Enter on the Production field.";
                         block = Block(title = "Production")), rows[2], buf)
    else
        panes = split_layout(Layout(Horizontal, Constraint[Percent(55), Fill(1)]), rows[2])
        render(m.tree, panes[1], buf)
        render(details(m), panes[2], buf)
    end
    render_progress(m, rows[3], buf)
    m.picking && render_picker(m, rows[2], buf)
    m.modal_kind == :firstn && return render_prompt(m, area, buf)
    m.modal === nothing || render(m.modal, area, buf)
    return nothing
end

"""
    sync_hints(page::SyncPage)::Tuple

The keys for a one-line hint bar, as `(key, description)` pairs.
"""
function sync_hints(m::SyncPage)
    sync_text_input(m) && return (("Enter", "apply"), ("Tab", "complete"), ("Esc", "cancel"))
    m.picking && return (("↑↓", "move"), ("Enter", "choose"), ("Esc", "close"), ("r", "reload"))
    m.focus == :panel && return (("Tab", "next"), ("Enter", "edit or press"), ("Esc", "tree"), ("p", "panel"))
    return (("Tab", "settings"), ("Space", "copy"), ("l", "link"), ("x", "extract"), ("n", "first N"), ("e", "estimate"), ("t", "sync"),
            ("s", "save"), ("p", "panel"))
end

# Builds the tree of production `name` in the background.
function open_production!(m::SyncPage, name::AbstractString)
    host = m.host
    options = m.options
    m.status = "opening $name…"
    spawn!(m, :open) do
        production = Production(host, name, options.remote_root, options.local_root; mount_root = options.mount_root)
        return (production, production_tree(host, production))
    end
end

function move_focus!(m::SyncPage, step::Int)
    items = m.panel_open && m.panel_shown ? length(PANEL_ITEMS) : 0
    position = m.focus == :tree ? (step > 0 ? 0 : items + 1) : m.cursor
    position += step
    if 1 <= position <= items
        m.focus = :panel
        m.cursor = position
    else
        m.focus = :tree
    end
    return m
end

function panel_key!(m::SyncPage, e::KeyEvent)
    if e.key in (:up, :left)
        m.cursor = max(1, m.cursor - 1)
    elseif e.key in (:down, :right)
        m.cursor = min(length(PANEL_ITEMS), m.cursor + 1)
    elseif e.key == :enter
        activate!(m, PANEL_ITEMS[m.cursor])
    elseif e.key == :escape
        m.focus = :tree
    else
        return false
    end
    return true
end

# A field starts an edit (the Production field opens the picker); a button acts.
function activate!(m::SyncPage, name::Symbol)
    name === :production && return open_picker!(m)
    if name in PANEL_FIELDS
        m.edit = FieldEdit(name, getfield(m.settings, name), "")
    elseif name === :connect
        connect!(m)
    elseif name === :load
        load_selection!(m)
    elseif name === :save
        needs_production!(m) || save!(m)
    elseif name === :estimate
        needs_production!(m) || blocked(m) || open_estimate!(m; confirm = false)
    elseif name === :transfer
        needs_production!(m) || blocked(m) || open_estimate!(m; confirm = true)
    end
    return m
end

"""
    needs_production!(page)::Bool

Whether an action that needs an open production has to be refused; the reason goes to the status line. The tree keys,
Save, Estimate and Transfer call it, so a page without a production never reaches code that needs one.
"""
function needs_production!(m::SyncPage)
    m.production === nothing || return false
    m.status = m.host === nothing ? "Connect first (c, or Enter on Production)" : "Open a production first (Enter on Production)"
    return true
end

function edit_key!(m::SyncPage, e::KeyEvent)
    edit = m.edit
    edit.hint = ""
    if e.key == :escape
        m.edit = nothing
    elseif e.key == :enter
        m.edit = nothing
        change_setting!(m, edit.field, edit.text)
    elseif e.key == :backspace
        edit.text = chop(edit.text)
    elseif e.key == :tab
        complete_field!(m, edit)
    elseif e.key == :char && isprint(e.char)
        edit.text *= e.char
    end
    return m
end

# Tab in a field: local folders for the two local roots, the hosts file for the host.
function complete_field!(m::SyncPage, edit::FieldEdit)
    if edit.field in (:local_root, :mount_root)
        completed, candidates = complete_path(edit.text)
        edit.text = completed
        length(candidates) > 1 && (edit.hint = join(first(candidates, 8), "  "))
    elseif edit.field === :host
        candidates = filter(startswith(edit.text), hosts_choices(m.settings.hosts_file))
        isempty(candidates) && return m
        common = first(candidates)
        for c in candidates
            common = join(first(p) for p in Iterators.takewhile(p -> p[1] == p[2], zip(common, c)))
        end
        edit.text = common
        length(candidates) > 1 && (edit.hint = join(candidates, "  "))
    end
    return m
end

"""
    open_picker!(page)

Open the production list; when the productions are not known yet, or the last listing found none, list them
first and open the list when they arrive.
"""
function open_picker!(m::SyncPage)
    busy!(m) && return m
    m.host === nothing && return connect!(m)
    if m.productions === nothing
        request_productions!(m)
        return m
    end
    if isempty(m.productions)
        m.status = "no productions found in $(m.options.remote_root)"
        return m
    end
    m.picker = SelectableList(m.productions; focused = true, block = Block(title = "Productions on $(m.settings.host)"))
    m.picking = true
    return m
end

# Rows of the picker move; Enter chooses; Escape closes; r lists the productions again. Without a picker the key does nothing.
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

"""
    choose_production!(page)

Open the production under the picker's cursor. Unsaved marks of the production on display are only dropped
after a confirmation.
"""
function choose_production!(m::SyncPage)
    name = m.productions[m.picker.selected]
    m.picking = false
    blocked(m) && return m
    return discard_guard!(m, () -> "Discard the marks on $(m.production.name)?", () -> open_production!(m, name))
end

"""
    discard_guard!(page, question, action; confirm = "Discard")

Run `action()` now, or after the user confirms `question()` when the loaded tree has unsaved marks.
"""
function discard_guard!(m::SyncPage, question, action; confirm::AbstractString = "Discard")
    if m.dirty && m.root !== nothing
        m.guarded = action
        m.modal = Modal(title = "Unsaved marks", message = question(), confirm_label = confirm, cancel_label = "Keep", selected = :cancel)
        m.modal_kind = :discard
    else
        action()
    end
    return m
end

"""
    load_selection!(page)

The Load selection button: read the file at [`selection_path`](@ref), asking first when the tree has unsaved marks.
"""
function load_selection!(m::SyncPage)
    needs_production!(m) && return m
    busy!(m) && return m
    blocked(m) && return m
    path = selection_path(m.settings)
    isfile(path) || (m.status = "no selection file $path"; return m)
    return discard_guard!(m, () -> "Replace the marks on $(m.production.name) with\n$path?", () -> start_load!(m, path);
                          confirm = "Replace")
end

"""
    start_load!(page, path)

Apply the selection file `path` to a fresh tree in the background. The page swaps its own tree for the fresh one only
when the whole file applied, so a failing load leaves no partial marks.
"""
function start_load!(m::SyncPage, path::AbstractString)
    host, production, options = m.host, m.production, m.options
    report = report_to(m)
    m.status = "loading $path…"
    spawn!(m, :load) do
        selection = load_selection(path, production)
        fresh = production_tree(host, production)
        apply_selection!(host, production, fresh, selection; helper = options.helper, jobs = options.jobs,
                         steps = Steps(["listing directories"], report))
        return (fresh, String(path))
    end
    return m
end

# Lists an unlisted directory, collapses an open row when `collapse` is set, and
# otherwise reopens a collapsed one.
function expand_or_collapse!(m::SyncPage, node::Node; collapse::Bool)
    if node.children === nothing
        node.kind != :detectors ? request_expand!(m, node) :
        node.whole_files ? request_detectors!(m, node) :
        with_environment!(m, () -> request_detectors!(m, node))
    elseif collapse && !(node.remote_path in m.collapsed)
        push!(m.collapsed, node.remote_path)
        rebuild_tree!(m)
    else
        delete!(m.collapsed, node.remote_path)
        rebuild_tree!(m)
    end
    return m
end

# Why space and l do nothing on `node`, or `nothing` when they act on it: a `detectors`
# row has no path of its own, and the rows of HDF5 groups can only be extracted.
function detector_hint(node::Node)
    node.kind == :detectors && return node.whole_files ?
                                      "space and l mark a detector below this row" : "use x on detector rows"
    node.kind == :detector && !node.whole_files && return "use x on detector rows"
    return nothing
end

# Applies a mouse event to a list-like widget of `n` rows (TreeView or
# SelectableList) and returns true when it is a click on the row that was already
# selected. A click elsewhere selects its row. The wheel scrolls one row and keeps
# the selection inside the window, because rendering scrolls back to the selection.
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

# Mouse input is ignored while a dialog is up or work is pending, so a click can
# never answer a dialog. Clicks on the tree go through the same code as enter.
function mouse!(m::SyncPage, e::MouseEvent)
    m.modal_kind == :none || return m
    if m.picking
        (m.running > 0 || m.picker === nothing) && return m
        mouse_list!(m.picker, length(m.productions), e) && choose_production!(m)
        return m
    end
    m.root === nothing && return m
    e.button == mouse_left && e.action == mouse_press && Base.contains(m.tree.last_area, e.x, e.y) && (m.focus = :tree)
    if mouse_list!(m.tree, tree_visible_count(m.tree), e)
        node = current_node(m)
        node === nothing || expand_or_collapse!(m, node; collapse = true)
    end
    return m
end

function key!(m::SyncPage, e::KeyEvent)
    # The transfer dialog has no buttons to answer, and Modal.handle_key!
    # returns :cancel on :escape unconditionally regardless of what labels
    # the modal carries; letting any key reach it would dismiss the dialog
    # while apply! keeps running underneath, opening the door to a second,
    # concurrent transfer.
    m.modal_kind in (:transfer, :busy, :checking) && return m

    # The prompt owns the keyboard while it is up; TextInput handles neither
    # :enter nor :escape, so those two are decided here.
    if m.modal_kind == :firstn
        e.key == :enter && return apply_prompt!(m)
        if e.key == :escape
            m.input = nothing
            m.modal_kind = :none
            return m
        end
        handle_key!(m.input, e)
        return m
    end

    if m.modal !== nothing
        answer = handle_key!(m.modal, e)
        answer === false && return m
        answer == :none && return m
        if m.modal_kind == :estimate && answer == :confirm
            return start_transfer!(m)
        end
        if m.modal_kind == :bootstrap
            answer == :confirm && return start_bootstrap!(m)
            m.continuation = nothing
        end
        if m.modal_kind == :discard
            action = m.guarded
            m.guarded = nothing
            m.modal = nothing
            m.modal_kind = :none
            answer == :confirm && action()
            return m
        end
        m.modal = nothing
        m.modal_kind = :none
        return m
    end

    m.modal_kind == :estimating && return m   # waiting on the dry run

    m.edit !== nothing && return edit_key!(m, e)
    m.picking && return picker_key!(m, e)
    e.key in (:tab, :backtab) && return move_focus!(m, e.key == :tab ? 1 : -1)
    if m.focus == :panel
        panel_key!(m, e) && return m
        (e.key == :char && e.char in ('e', 't', 's', 'p', 'c', 'o')) || return m     # the tree keys need the tree focus
    end
    m.root === nothing && e.key == :char && e.char in (' ', 'l', 'n', 'x', 's', 'e', 't', 'o') && (needs_production!(m); return m)

    node = current_node(m)

    # :up, :down, :home and :end_key are the only keys TreeView gets. It also
    # binds space, enter, left and right to expand/collapse, which would flip
    # TreeNode.expanded behind the model's back.
    if e.key in (:up, :down, :home, :end_key)
        handle_key!(m.tree, e)
        return m
    end

    if e.key == :enter || e.key == :right
        node === nothing && return m
        return expand_or_collapse!(m, node; collapse = e.key == :enter)
    end

    if e.key == :left
        node === nothing && return m
        push!(m.collapsed, node.remote_path)
        return rebuild_tree!(m)
    end

    e.key == :char || return m

    if e.char == ' '
        if node !== nothing && (hint = detector_hint(node)) !== nothing
            m.status = hint
        elseif node !== nothing
            toggle_mode!(m, node, :copy)
        end
    elseif e.char == 'l'
        if m.production.mount_root === nothing
            m.status = "link mode needs a mount root; set Mount root"
        elseif node !== nothing && (hint = detector_hint(node)) !== nothing
            m.status = hint
        elseif node !== nothing
            toggle_mode!(m, node, :link)
        end
    elseif e.char == 'n'
        if node !== nothing && node.kind in (:detectors, :detector)
            m.status = "n applies to run directories, not detector rows"
        elseif node !== nothing
            open_prompt!(m, node)
        end
    elseif e.char == 'x'
        if node !== nothing && node.kind == :detector
            if covering_extract(node) !== nothing && node.mode != :extract
                m.status = "extracted for the whole period; unmark $(node.label) on the period's detectors row first"
            else
                toggle_extract!(m, node)
            end
        else
            m.status = "x extracts a detector: open the detectors row of a run or period and move onto one"
        end
    elseif e.char == 'e'
        blocked(m) || open_estimate!(m; confirm = false)
    elseif e.char == 't'
        blocked(m) || open_estimate!(m; confirm = true)
    elseif e.char == 's'
        save!(m)
    elseif e.char == 'c'
        connect!(m)
    elseif e.char == 'o'
        load_selection!(m)
    elseif e.char == 'p'
        m.panel_open = !m.panel_open
        m.panel_open || m.focus != :panel || (m.focus = :tree)
    end
    return m
end

sync_text_input(m::SyncPage) = m.modal_kind == :firstn || m.edit !== nothing

ctrl_c(e::KeyEvent) = e.key == :ctrl_c || (e.key == :ctrl && e.char == 'c')

host_key(e::KeyEvent) = ctrl_c(e) || (e.key == :char && (e.char in ('q', '?', 'T') || isdigit(e.char)))

sync_modal_open(m::SyncPage) = m.modal !== nothing || m.modal_kind != :none

"""
    shielded(f, page, fallback)

Run `f()`. Any exception but an interrupt goes to the page's error dialog and `fallback` is returned, so a fault in
the page is loud and never ends a host interface that embeds the page.
"""
function shielded(f, m::SyncPage, fallback)
    try
        return f()
    catch err
        err isa InterruptException && rethrow()
        if m.modal_kind in (:transfer, :busy)
            # The transfer dialog stays; the fault goes to the status line. `show_error!` below is not shielded: a fault in
            # it propagates, so reporting a fault can never loop.
            message = first(split(sprint(showerror, err), '\n'))
            m.status = isempty(m.status) ? message : m.status * "; " * message
        else
            m.edit = nothing
            show_error!(m, err)
        end
        return fallback
    end
end

"""
    sync_key!(page::SyncPage, evt::KeyEvent)::Bool

Handle a key. Returns `false` without acting for Ctrl-C, and for the other keys the host owns (`q`, `?`, `T` and
digits) unless a text prompt or a dialog is open (a dialog takes every key but Ctrl-C), and `true` for every
other key it handles; a key it does not know also returns `true`, so no other component reacts to it. An
exception is shown in the error dialog and the key counts as handled.
"""
function sync_key!(m::SyncPage, e::KeyEvent)
    ctrl_c(e) && return false
    return shielded(m, true) do
        # Only while nothing modal is open do the host's keys reach the host; a dialog takes everything but Ctrl-C.
        (host_key(e) && !sync_text_input(m) && !sync_modal_open(m)) && return false
        key!(m, e)
        return true
    end
end

"""
    sync_mouse!(page::SyncPage, evt::MouseEvent)::Bool

Handle a mouse event; `false` while a dialog is open, `true` otherwise.
"""
function sync_mouse!(m::SyncPage, e::MouseEvent)
    m.modal_kind == :none && m.modal === nothing || return false
    m.edit === nothing || return false
    return shielded(m, true) do
        if e.button == mouse_left && e.action == mouse_press
            if Base.contains(m.summary_rect, e.x, e.y)
                m.panel_open = !m.panel_open
                m.panel_open || m.focus != :panel || (m.focus = :tree)
                return true
            end
            for (name, rect) in (m.picking ? Pair{Symbol,Rect}[] : m.panel_rects)
                Base.contains(rect, e.x, e.y) || continue
                m.focus = :panel
                m.cursor = findfirst(==(name), PANEL_ITEMS)
                activate!(m, name)
                return true
            end
        end
        mouse!(m, e)
        return true
    end
end

"""
    sync_task!(page::SyncPage, evt::TaskEvent)::Bool

Handle the result of a background task of the page. Returns `false` for an id without the prefix `sync:`.
A result that arrives while no task of the page runs is a mixed-up task id and is shown in the error dialog.
"""
function sync_task!(m::SyncPage, e::TaskEvent)
    startswith(String(e.id), "sync:") || return false
    return shielded(m, true) do
        id = chopprefix(String(e.id), "sync:")
        if id != "step"
            m.running > 0 || error("the result :$id arrived while no sync task runs; a task id was mixed up")
            m.running -= 1
        end
        task!(m, id, e)
        return true
    end
end

sync_dirty(m::SyncPage) = m.dirty
sync_busy(m::SyncPage) = m.modal_kind in (:transfer, :busy)

function task!(m::SyncPage, id::AbstractString, e::TaskEvent)
    if startswith(id, "listing:")
        path = chopprefix(id, "listing:")
        if e.value isa Exception
            delete!(m.pending, path)
            return show_error!(m, e.value)
        end
        attach_listing!(m, e.value)
        node, children = e.value
        dirs = [c.remote_path for c in children if c.kind == :dir]
        if !isempty(dirs)
            host = m.host
            spawn!(m, "sizes:" * node.remote_path) do
                return (node, Dict(zip(dirs, dir_sizes(host, dirs))))
            end
        end
        return m
    end

    if startswith(id, "sizes:")
        if e.value isa Exception
            # A dialog the user is working in stays open; the failure goes to the status line.
            m.modal_kind == :none && return show_error!(m, e.value)
            m.status = string("sizes of ", basename(chopprefix(id, "sizes:")), ": ",
                              sprint(showerror, e.value))
            return m
        end
        node, bytes = e.value
        node.children === nothing && return m
        for child in node.children
            child.kind == :dir && (child.size = bytes[child.remote_path])
        end
        return rebuild_tree!(m)
    end

    if startswith(id, "detectors:")
        path = chopprefix(id, "detectors:")
        delete!(m.pending, path)
        failed = m.step
        m.step = nothing
        e.value isa Exception &&
            return show_error!(m, failed === nothing ? e.value : ErrorException(sprint(showerror, e.value) * step_note(failed)))
        node, children = e.value
        attach_detectors!(node, children)
        delete!(m.collapsed, path)
        m.status = ""
        if !has_detectors(node)
            deleteat!(node.parent.children, findfirst(c -> c === node, node.parent.children))
            m.status = "the files of $(node.parent.label) have no per-detector groups"
        end
        return rebuild_tree!(m)
    end

    if e.value isa Exception
        failed = m.step
        id == "connect" && (m.connecting = false)
        m.step = nothing
        m.continuation = nothing
        text = sprint(showerror, e.value) * step_note(failed)
        id == "productions" && (m.productions = nothing)
        show_error!(m, ErrorException(text))
        # The dialog clears the status; once it is dismissed the page says why it has no production.
        id == "productions" && (m.status = "no productions found in $(m.options.remote_root)")
        return m
    end

    if id == "step"
        (m.step === nothing || m.step.step != e.value.step) && (m.step_started = time())
        m.step = e.value
        return m
    elseif id == "connect"
        m.connecting = false
        host, options, productions, used = e.value
        # Settings that changed while the connection was made describe another connection: drop this one.
        if !all(field -> getfield(used, field) == getfield(m.settings, field), fieldnames(SyncSettings))
            return blocked(m) ? m : start_connect!(m)
        end
        m.host, m.options, m.productions = host, options, productions
        name = m.settings.production
        if isempty(name)
            return open_picker!(m)
        elseif name in m.productions
            return open_production!(m, name)
        elseif m.suggested
            m.settings.production = ""
            m.suggested = false
            revalidate!(m)
            m.status = "$name is not a production on $(m.settings.host)"
            return open_picker!(m)
        end
        return show_error!(m, ArgumentError("production $name is not on $(m.options.host) below $(m.options.remote_root)"))
    elseif id == "load"
        fresh, path = e.value
        m.step = nothing
        m.root = fresh
        empty!(m.collapsed)
        empty!(m.pending)
        m.dirty = false
        m.saved = path
        m.status = "loaded $path"
        rebuild_tree!(m)
        m.tree.selected = 1
        return m
    end

    if id == "productions"
        m.productions = e.value
        if isempty(e.value)
            m.picking = false
            m.status = "no productions found in $(m.options.remote_root)"
        else
            m.picker = SelectableList(e.value; focused = true, block = Block(title = "Productions on $(m.options.host)"))
            m.picking = true
        end
        return m
    elseif id == "open"
        production, root = e.value
        # Everything that can fail is built before the page changes, so a refused open leaves the page as it was.
        settings = deepcopy(m.settings)
        settings.production = production.name
        options = Options(settings; from = m.options.from, dry_run = m.options.dry_run, yes = m.options.yes)
        m.production, m.root, m.settings, m.options = production, root, settings, options
        revalidate!(m)
        m.step = nothing
        m.suggested = false
        m.dirty = false
        m.saved = nothing
        empty!(m.collapsed)
        empty!(m.pending)
        m.status = ""
        rebuild_tree!(m)
        m.tree.selected = 1
        return m
    end

    if id == "environment"
        status = e.value
        environment_ready(status) && return environment_ready!(m, status)
        m.status = ""
        m.modal = Modal(title = "Create the helper environment",
                        message = string("Extraction needs HDF5 and ParallelProcessingTools in\n",
                                         status.project, " on ", m.options.host, ".\nCreate it with:\n\n",
                                         Base.shell_escape(bootstrap_command(m.host, m.options.helper))),
                        confirm_label = "Create", cancel_label = "Cancel", selected = :confirm)
        m.modal_kind = :bootstrap
        return m
    elseif id == "bootstrap"
        return environment_ready!(m, e.value)
    end

    if id == "estimate"
        estimate, confirm, staging, free = e.value
        m.estimate = estimate
        m.step = nothing
        m.modal = Modal(title = "Estimate",
                        message = string(format_estimate(estimate), "\n",
                                         "from ", m.options.host, ":", m.production.remote_root, "\n",
                                         "into ", m.production.local_root,
                                         staging === nothing ? "" :
                                         string("\nstaging ", staging, ": ", format_bytes(free), " free"),
                                         isempty(estimate.not_in_run) ? "" :
                                         string("\nnot in run: ", format_not_in_run(estimate.not_in_run))),
                        confirm_label = "Sync", cancel_label = "Close",
                        selected = confirm ? :confirm : :cancel)
        m.modal_kind = :estimate
        m.status = ""
        return m
    elseif id == "transfer"
        m.step = nothing
        refresh_local_state!(m)
        rebuild_tree!(m)
        return open_message!(m, "Transfer complete", summary_text(e.value))
    end
    return error("unexpected background result :$id; every task this page starts must be handled here")
end
