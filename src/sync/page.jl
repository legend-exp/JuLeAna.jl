# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    SyncPage(host, production, options; queue = TaskQueue())
    SyncPage(host, options; queue = TaskQueue())

The state of the sync screen. The second form starts on the production picker: it lists
the productions of `options.remote_root` in the background, and choosing one
builds the production and switches to the tree screen. `screen` is `:pick` or
`:tree`; `production` and `root` are `nothing` on the picker.

On the tree screen the `Node` tree is the source of truth; the `TreeView` is
rebuilt from it whenever anything changes, because `TreeView` caches its
flattened rows and mutating its nodes in place would leave that cache stale.

Which nodes are open lives in `collapsed`, not in the `TreeNode`s, for the same
reason. `pending` holds the remote paths of listings in flight.

`extracting` is set while the remote helper reduces files, `environment` caches a
ready helper environment, and `continuation` is what to do once an environment
check or creation finishes.

The page is given a `TaskQueue` and starts its tasks with ids prefixed `sync:`; the host routes events with that
prefix to [`sync_task!`](@ref). `running` counts the page's own unanswered tasks, because the queue may be shared.
"""
mutable struct SyncPage
    host::RemoteHost
    production::Union{Nothing,Production}
    options::Options
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
    progress::Union{Nothing,Progress}
    screen::Symbol
    productions::Union{Nothing,Vector{String}}
    picker::Union{Nothing,SelectableList}
    extracting::Union{Nothing,ExtractProgress}
    environment::Union{Nothing,EnvironmentStatus}
    continuation::Union{Nothing,Function}
end

function SyncPage(host::RemoteHost, production::Production, options::Options; queue::TaskQueue = TaskQueue())
    m = SyncPage(host, production, options, SyncSettings(options), 0, production_tree(host, production),
                 Set{String}(), Set{String}(),
                 # Replaced immediately: rebuild_tree! needs the model to exist.
                 TreeView(TreeNode("")), queue,
                 false, "", nothing,
                 nothing, :none, nothing, nothing, nothing,
                 :tree, nothing, nothing, nothing, nothing, nothing)
    rebuild_tree!(m)
    m.tree.selected = 1
    return m
end

function SyncPage(host::RemoteHost, options::Options; queue::TaskQueue = TaskQueue())
    m = SyncPage(host, nothing, options, SyncSettings(options), 0, nothing,
                 Set{String}(), Set{String}(),
                 TreeView(TreeNode("")), queue,
                 false, "", nothing,
                 nothing, :none, nothing, nothing, nothing,
                 :pick, nothing, nothing, nothing, nothing, nothing)
    return request_productions!(m)
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
    spawn!(m, "detectors:" * node.remote_path) do
        return (node, detector_nodes(host, helper, run; jobs))
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
    m.modal_kind = :estimating
    m.status = "estimating…"
    spawn!(m, :estimate) do
        estimate = apply!(host, production, selection; dry_run = true, helper, jobs)
        staging = isempty(selection.extract) ? nothing : staging_dir(host, helper)
        # The staging directory may not exist yet; the estimate creates nothing and
        # asks about the file system of its nearest existing ancestor.
        free = nothing
        if staging !== nothing
            existing = staging
            while !dir_exists(host, existing)
                existing = dirname(existing)
            end
            free = free_bytes(host, existing)
        end
        return (estimate, confirm, staging, free)
    end
    return m
end

"""
    start_transfer!(m::SyncPage)::SyncPage

Run the transfer in the background. The progress callbacks run on that task and
never touch the model: they push a `TaskEvent` like every other result.
"""
function start_transfer!(m::SyncPage)
    host = m.host
    production = m.production
    helper = m.options.helper
    jobs = m.options.jobs
    selection = Selection(production, m.options.host, m.root)
    queue = m.tasks
    m.modal = Modal(title = "Transferring", message = "starting…",
                    confirm_label = "", cancel_label = "")
    m.modal_kind = :transfer
    m.progress = Progress(0, 0.0, "", "")
    m.extracting = isempty(selection.extract) ? nothing : ExtractProgress(0, 0, 0)
    spawn!(m, :transfer) do
        return apply!(host, production, selection; helper, jobs,
                      progress = reading -> put!(queue.channel, TaskEvent(Symbol("sync:progress"), reading)),
                      extract_progress = reading -> put!(queue.channel, TaskEvent(Symbol("sync:extract_progress"), reading)))
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
    path = save_selection(m.options.out, Selection(m.production, m.options.host, m.root))
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
             "enter expand/collapse   s save   mouse: click, wheel",
             "e estimate   t sync   q quit"])
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
    out = m.options.out
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

"""
    render_pick(m::SyncPage, area::Rect, buf::Buffer)

The production picker: the productions found under the remote root, or a
placeholder while the search runs.
"""
function render_pick(m::SyncPage, area::Rect, buf::Buffer)
    rows = split_layout(Layout(Vertical, Constraint[Fill(1), Fixed(1)]), area)
    block = Block(title = "Productions on $(m.options.host)")
    if m.picker === nothing
        render(Paragraph(m.productions === nothing ? "listing…" : "no productions found in $(m.options.remote_root)";
                         block), rows[1], buf)
    else
        render(m.picker, rows[1], buf)
    end
    render(StatusBar(left = [Span(isempty(m.status) ? "↑/↓ move   enter open   r reload   q quit   mouse: click, wheel" : m.status)]),
           rows[2], buf)
    m.modal === nothing || render(m.modal, area, buf)
    return nothing
end

"""
    render_sync(m::SyncPage, area::Rect, buf::Buffer)

Draw the interface into `area`. The area is explicit and nothing assumes it owns
the terminal, so the future Juleana app can host this as one screen.
"""
function render_sync(m::SyncPage, area::Rect, buf::Buffer)
    m.screen == :pick && return render_pick(m, area, buf)
    rows = split_layout(Layout(Vertical, Constraint[Fill(1), Fixed(1)]), area)
    panes = split_layout(Layout(Horizontal, Constraint[Percent(55), Fill(1)]), rows[1])
    render(m.tree, panes[1], buf)
    render(details(m), panes[2], buf)
    if m.progress === nothing
        render(status_bar(m), rows[2], buf)
    else
        x = m.extracting
        render(Gauge(x === nothing ? m.progress.fraction : (x.total == 0 ? 0.0 : x.done / x.total);
                     label = x === nothing ?
                             string(format_bytes(m.progress.bytes), "  ", m.progress.rate, "  ETA ", m.progress.eta) :
                             string("extracting ", x.done, "/", x.total, " files  ", format_bytes(x.bytes))),
               rows[2], buf)
    end
    m.modal_kind == :firstn && return render_prompt(m, area, buf)
    m.modal === nothing || render(m.modal, area, buf)
    return nothing
end

"""
    sync_hints(page::SyncPage)::Tuple

The keys for a one-line hint bar, as `(key, description)` pairs.
"""
function sync_hints(m::SyncPage)
    m.screen == :pick && return (("↑↓", "move"), ("Enter", "open"), ("r", "reload"))
    sync_text_input(m) && return (("Enter", "apply"), ("Esc", "cancel"))
    return (("Space", "copy"), ("l", "link"), ("x", "extract"), ("n", "first N"), ("e", "estimate"), ("t", "sync"), ("s", "save"))
end

# Builds the tree of the picked production in the background.
function open_production!(m::SyncPage)
    name = m.productions[m.picker.selected]
    host = m.host
    options = m.options
    m.status = "opening $name…"
    spawn!(m, :open) do
        production = Production(host, name, options.remote_root, options.local_root;
                                mount_root = options.mount_root)
        return (production, production_tree(host, production))
    end
end

# Keys on the picker screen. Input is ignored while the production is being opened,
# so that a second enter cannot start a second build.
function update_pick!(m::SyncPage, e::KeyEvent)
    m.running > 0 && return m
    (e.key == :char && e.char == 'r') && return request_productions!(m)
    m.picker === nothing && return m
    if e.key in (:up, :down, :home, :end_key)
        handle_key!(m.picker, e)
    elseif e.key == :enter
        open_production!(m)
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
    if m.screen == :pick
        (m.running > 0 || m.picker === nothing) && return m
        mouse_list!(m.picker, length(m.productions), e) && open_production!(m)
        return m
    end
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
        m.modal = nothing
        m.modal_kind = :none
        return m
    end

    m.modal_kind == :estimating && return m   # waiting on the dry run

    m.screen == :pick && return update_pick!(m, e)

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
            m.status = "link mode needs a mount root; restart with --mount-root PATH"
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
        open_estimate!(m; confirm = false)
    elseif e.char == 't'
        open_estimate!(m; confirm = true)
    elseif e.char == 's'
        save!(m)
    end
    return m
end

sync_text_input(m::SyncPage) = m.modal_kind == :firstn

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
    return shielded(m, true) do
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
        if !(id in ("progress", "extract_progress"))
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
        e.value isa Exception && return show_error!(m, e.value)
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
        m.progress = nothing
        m.extracting = nothing
        m.continuation = nothing
        if m.screen == :pick
            m.status = ""
            id == "productions" && (m.productions = String[])
        end
        return show_error!(m, e.value)
    end

    if id == "productions"
        m.productions = e.value
        isempty(e.value) || (m.picker = SelectableList(e.value; focused = true,
                                                       block = Block(title = "Productions on $(m.options.host)")))
        return m
    elseif id == "open"
        m.production, m.root = e.value
        o = m.options
        name = m.production.name
        m.options = Options(o.host, o.remote_root, o.local_root, o.mount_root, name,
                            isempty(o.out) ? default_selection_path(name) : o.out,
                            o.from, o.dry_run, o.yes, o.jobs, o.helper)
        m.screen = :tree
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
    elseif id == "progress"
        m.extracting = nothing
        m.progress = e.value
        return m
    elseif id == "extract_progress"
        m.extracting = e.value
        return m
    elseif id == "transfer"
        m.progress = nothing
        m.extracting = nothing
        refresh_local_state!(m)
        rebuild_tree!(m)
        return open_message!(m, "Transfer complete", summary_text(e.value))
    end
    return error("unexpected background result :$id; every task this page starts must be handled here")
end
