"""
    Node(label, remote_path, kind; size, children, mode, parent, local_state, holders)

One row of the inventory tree.

`kind` is `:production` (the tree root), `:section` (one configured path key),
`:dir`, `:group` (one filekey or one detector tier file, standing for the files that
belong to it), `:file`, `:detectors` (the lazily listed per-detector view of a run or
period directory) or `:detector` (one detector of the files of that directory).

`children === nothing` means "not listed yet", which is different from an empty
directory. `mode` is the mode chosen explicitly on this node; the mode that
actually applies is [`effective_mode`](@ref), which falls back to the ancestors.
`holders` is set on the `:detector` rows of a period: the run directories that hold
the detector, each with its number of filekey files.
"""
mutable struct Node
    label::String
    remote_path::String
    kind::Symbol
    size::Union{Nothing,Int}
    children::Union{Nothing,Vector{Node}}
    mode::Symbol
    parent::Union{Nothing,Node}
    local_state::Symbol
    holders::Vector{Pair{String,Int}}
end

Node(label::AbstractString, remote_path::AbstractString, kind::Symbol;
     size = nothing, children = nothing, mode::Symbol = :none,
     parent = nothing, local_state::Symbol = :missing,
     holders = Pair{String,Int}[]) =
    Node(label, remote_path, kind, size, children, mode, parent, local_state, holders)

# A LEGEND tier file name: setup, period, run, category, an id, and the tier.
# The id is either a timestamp (one file per filekey) or a detector name (one
# file per detector); which one decides how the directory is grouped.
const _tier_file_expr = r"^[a-z][a-z0-9]*-p[0-9]{2}-r[0-9]{3}-[a-z]+-(.+)-tier_[a-z0-9]+\.[a-z0-9]+$"

"""
    tier_file_id(name::AbstractString)

`(:filekey, timestamp)` or `(:detector, detector_name)` for a LEGEND tier file
name, and `nothing` for anything else. A name that does not match is not an
error: READMEs and scratch files legitimately sit in a run directory.
"""
function tier_file_id(name::AbstractString)
    m = match(_tier_file_expr, name)
    m === nothing && return nothing
    id = String(m[1])
    LegendDataManagement._can_convert_to(Timestamp, id) && return (:filekey, id)
    LegendDataManagement._can_convert_to(DetectorId, id) && return (:detector, id)
    nothing
end

"""
    group_children(entries, dir)::Vector{Node}

Turn one directory listing into tree rows: directories first, then one `:group`
per filekey in timestamp order, then one `:group` per detector by name, then the
files that carry no LEGEND id.
"""
function group_children(entries::AbstractVector{DirEntry}, dir::AbstractString)
    dirs = Node[]
    filekeys = Node[]
    detectors = Node[]
    plain = Node[]
    for entry in entries
        path = joinpath(dir, entry.name)
        if entry.kind == :dir
            push!(dirs, Node(entry.name, path, :dir))
            continue
        end
        file = Node(entry.name, path, :file; size = entry.size)
        id = tier_file_id(entry.name)
        if id === nothing
            push!(plain, file)
            continue
        end
        # The group holds the single file it stands for, so that groups and files
        # are handled identically everywhere downstream.
        group = Node(id[2], path, :group; size = entry.size, children = [file])
        file.parent = group
        push!(id[1] == :filekey ? filekeys : detectors, group)
    end
    sort!(dirs; by = n -> n.label)
    sort!(filekeys; by = n -> Timestamp(n.label).unixtime)
    sort!(detectors; by = n -> n.label)
    sort!(plain; by = n -> n.label)
    vcat(dirs, filekeys, detectors, plain)
end

"""
    production_tree(h::RemoteHost, p::Production)::Node

The tree root: the production's `config.json` followed by one `:section` per
configured path key, in key order.
"""
function production_tree(h::RemoteHost, p::Production)
    dir = joinpath(p.remote_root, p.name)
    entries = list_dir(h, dir)
    i = findfirst(e -> e.name == "config.json", entries)
    i === nothing && throw(ArgumentError("no config.json in $dir"))
    root = Node("Production: $(p.name)", dir, :production)
    children = Node[Node("config.json", joinpath(dir, "config.json"), :file;
                         size = entries[i].size)]
    for (key, path) in p.roots
        push!(children, Node(key, path, :section))
    end
    for child in children
        child.parent = root
    end
    root.children = children
    root.local_state = node_local_state(p, root)
    root
end

"""
    expand!(h::RemoteHost, p::Production, node::Node; detectors = false)::Node

List `node` if it has not been listed yet, size its directory children with one
call, and refresh its local state. With `detectors`, a run directory, or a period directory with a run
directory that holds filekey files, also gets its `:detectors` child. Returns `node`.
"""
function expand!(h::RemoteHost, p::Production, node::Node; detectors::Bool = false)
    node.children === nothing || return node
    node.kind in (:section, :dir) || throw(ArgumentError(
        "a :$(node.kind) node cannot be expanded: $(node.label)"))
    children = group_children(list_dir(h, node.remote_path), node.remote_path)
    dirs = [c for c in children if c.kind == :dir]
    if !isempty(dirs)
        sizes = dir_sizes(h, [c.remote_path for c in dirs])
        for i in eachindex(dirs, sizes)
            dirs[i].size = sizes[i]
        end
    end
    for child in children
        child.parent = node
    end
    node.children = children
    # A run directory has filekey files; a period directory has a run directory that does.
    if detectors && (!isempty(filekey_groups(node)) ||
                     any(run -> !isempty(filekey_files(h, run.remote_path)), run_dirs(node)))
        ensure_detectors!(node)
    end
    node.local_state = node_local_state(p, node)
    node
end

"""
    node_local_state(p::Production, node::Node)::Symbol

`:linked` when a symlink stands at the node's local path, `:present` when the
data is there, `:partial` when a listed directory has some of its children, and
`:missing` otherwise.
"""
function node_local_state(p::Production, node::Node)
    path = to_local(p, node.remote_path)
    islink(path) && return :linked
    isfile(path) && return :present
    isdir(path) || return :missing
    node.children === nothing && return isempty(readdir(path)) ? :missing : :present
    # Detector rows have no path on the host, so they carry no local state.
    states = [node_local_state(p, c) for c in node.children if c.kind ∉ (:detectors, :detector)]
    all(==(:missing), states) && return :missing
    all(s -> s in (:present, :linked), states) ? :present : :partial
end

"""
    filekey_groups(node::Node)::Vector{Node}

The filekey groups among `node`'s children, in timestamp order. Empty when the
directory has not been listed or holds no filekey-named files.
"""
filekey_groups(node::Node) = node.children === nothing ? Node[] :
    [c for c in node.children
     if c.kind == :group && LegendDataManagement._can_convert_to(Timestamp, c.label)]

const RUN_DIR_EXPR = r"^r[0-9]{3}$"

"""
    run_dirs(node::Node)::Vector{Node}

The listed children of `node` that are directories named like a run (`r000`).
"""
run_dirs(node::Node) = node.children === nothing ? Node[] :
    [c for c in node.children if c.kind == :dir && occursin(RUN_DIR_EXPR, c.label)]

"""
    filekey_files(h::RemoteHost, dir::AbstractString)::Vector{String}

The absolute paths of the filekey tier files directly in `dir`, in name order.
"""
function filekey_files(h::RemoteHost, dir::AbstractString)
    files = String[]
    for entry in list_dir(h, dir)
        id = tier_file_id(entry.name)
        entry.kind == :file && id !== nothing && first(id) == :filekey &&
            push!(files, joinpath(dir, entry.name))
    end
    sort!(files)
end

"""
    period_level(dir::Node)::Bool

`true` when the listed directory `dir` has no filekey file of its own, so its
`detectors` row spans the run directories below it.
"""
period_level(dir::Node) = isempty(filekey_groups(dir))

"""
    ensure_detectors!(dir::Node)::Node

The `:detectors` child of the listed directory `dir`, inserted as its first child when
it is not there yet, so it stays above the runs and filekey rows. `dir` is a run
directory (it holds filekey files) or a period directory (it holds run directories).
The `remote_path` of the node does not exist on the host; it only identifies the node.
"""
function ensure_detectors!(dir::Node)
    dir.children === nothing && throw(ArgumentError(
        "$(dir.label) has not been listed yet; expand it before asking for detectors"))
    i = findfirst(c -> c.kind == :detectors, dir.children)
    i === nothing || return dir.children[i]
    isempty(filekey_groups(dir)) && isempty(run_dirs(dir)) && throw(ArgumentError(
        "$(dir.label) holds no filekey files and no run directories, so it has no detectors"))
    node = Node("detectors", joinpath(dir.remote_path, "detectors"), :detectors; parent = dir)
    pushfirst!(dir.children, node)
    node
end

"""
    detector_nodes(h::RemoteHost, helper::HelperConfig, dir::Node; jobs = 0)::Vector{Node}

Detached `:detector` rows for the listed directory `dir`. For a run directory, the
first filekey file is inspected and each detector is sized by its stored bytes in
that file. For a period directory, see [`period_detector_nodes`](@ref). A file
without a detector axis (`jlevt`, `jlskm`, `jlpmt`) gives an empty vector; whether a
tier has detectors is decided by looking, never by a list of tier names.
"""
function detector_nodes(h::RemoteHost, helper::HelperConfig, dir::Node; jobs::Integer = 0)
    period_level(dir) && return period_detector_nodes(h, helper, dir; jobs)
    file = only(first(filekey_groups(dir)).children)
    names, bytes = only(inspect_files(h, helper, [file.remote_path]; jobs))
    [Node(names[i], joinpath(dir.remote_path, "detectors", names[i]), :detector; size = bytes[i])
     for i in eachindex(names, bytes)]
end

"""
    period_detector_nodes(h, helper, period::Node; jobs = 0)::Vector{Node}

Detached `:detector` rows for the listed period directory `period`: the union, sorted
by name, of the detectors of the first filekey file of each of its run directories,
inspected in one helper call. A row's size is the sum over the runs that hold the
detector of its stored bytes in the run's first file times the run's number of
filekey files, and its `holders` name those runs. A run whose first file has no
detector axis contributes nothing. A period without a run directory that holds
filekey files is an error.
"""
function period_detector_nodes(h::RemoteHost, helper::HelperConfig, period::Node; jobs::Integer = 0)
    held = Tuple{Node,Vector{String}}[]
    for run in run_dirs(period)
        files = filekey_files(h, run.remote_path)
        isempty(files) || push!(held, (run, files))
    end
    isempty(held) && throw(ArgumentError(
        "$(period.label) has no run directory with filekey files to inspect"))
    inspected = inspect_files(h, helper, [first(files) for (_, files) in held]; jobs)
    rows = Dict{String,Node}()
    for ((run, files), (names, bytes, _)) in zip(held, inspected)
        for i in eachindex(names, bytes)
            row = get!(rows, names[i]) do
                Node(names[i], joinpath(period.remote_path, "detectors", names[i]), :detector; size = 0)
            end
            row.size += bytes[i] * length(files)
            push!(row.holders, run.remote_path => length(files))
        end
    end
    [rows[name] for name in sort!(collect(keys(rows)))]
end

"""
    attach_detectors!(node::Node, children::Vector{Node})::Node

Make `children` the rows of the `:detectors` node `node` and size it by their sum.
"""
function attach_detectors!(node::Node, children::Vector{Node})
    for child in children
        child.parent = node
    end
    node.children = children
    node.size = sum(c -> something(c.size, 0), children; init = 0)
    node
end

"""
    expand_detectors!(h::RemoteHost, helper::HelperConfig, node::Node; jobs = 0)::Node

List the detectors of the run that `node` belongs to, once. Returns `node`.
"""
function expand_detectors!(h::RemoteHost, helper::HelperConfig, node::Node; jobs::Integer = 0)
    node.kind == :detectors || throw(ArgumentError("not a detectors node: $(node.label)"))
    node.children === nothing || return node
    attach_detectors!(node, detector_nodes(h, helper, node.parent; jobs))
end

"""
    has_detectors(node::Node)::Bool

`false` for a `:detectors` node that was inspected and found no per-detector groups;
`true` for one that has detectors or has not been inspected yet.
"""
has_detectors(node::Node) = node.children === nothing || !isempty(node.children)
