# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# `children === nothing` means not listed yet. A `whole_files` `:detectors` row stands for per-detector files and can be
# copied or linked; every other one stands for HDF5 groups inside filekey files and can only be extracted.
Base.@kwdef mutable struct Node
    label::String
    remote_path::String
    kind::Symbol
    size::Union{Nothing,Int} = nothing
    children::Union{Nothing,Vector{Node}} = nothing
    mode::Symbol = :none
    parent::Union{Nothing,Node} = nothing
    local_state::Symbol = :missing
    holders::Vector{Pair{String,Int}} = Pair{String,Int}[]
    whole_files::Bool = false
end

Node(label, remote_path, kind::Symbol; kwargs...) = Node(; label, remote_path, kind, kwargs...)

function attach!(node::Node, children::Vector{Node})
    foreach(child -> child.parent = node, children)
    node.children = children
    return node
end

const _tier_file_expr = r"^[a-z][a-z0-9]*-p[0-9]{2}-r[0-9]{3}-[a-z]+-(.+)-tier_[a-z0-9]+\.[a-z0-9]+$"
const RUN_DIR_EXPR = r"^r[0-9]{3}$"

# READMEs and scratch files legitimately sit in a run directory.
function tier_file_id(name::AbstractString)
    m = match(_tier_file_expr, name)
    m === nothing && return nothing
    id = String(m[1])
    LegendDataManagement._can_convert_to(Timestamp, id) && return (:filekey, id)
    LegendDataManagement._can_convert_to(DetectorId, id) && return (:detector, id)
    return nothing
end

function group_children(entries::AbstractVector{DirEntry}, dir::AbstractString)
    rows = Dict(k => Node[] for k in (:dir, :filekey, :detector, :plain))
    for entry in entries
        path = joinpath(dir, entry.name)
        if entry.kind == :dir
            push!(rows[:dir], Node(entry.name, path, :dir))
            continue
        end
        file = Node(entry.name, path, :file; size = entry.size)
        id = tier_file_id(entry.name)
        if id === nothing
            push!(rows[:plain], file)
        else
            group = Node(id[2], path, :group; size = entry.size, children = [file])
            file.parent = group
            push!(rows[id[1]], group)
        end
    end
    foreach(k -> sort!(rows[k]; by = n -> n.label), (:dir, :detector, :plain))
    sort!(rows[:filekey]; by = n -> Timestamp(n.label).unixtime)
    return vcat(rows[:dir], rows[:filekey], rows[:detector], rows[:plain])
end

function production_tree(h::RemoteHost, p::Production)
    dir = joinpath(p.remote_root, p.name)
    entries = list_dir(h, dir)
    i = findfirst(e -> e.kind == :file && e.name == p.config_file, entries)
    i === nothing && throw(ArgumentError("no $(p.config_file) in $dir"))
    root = Node("Production: $(p.name)", dir, :production)
    children = Node[Node(p.config_file, joinpath(dir, p.config_file), :file; size = entries[i].size)]
    append!(children, [Node(key, path, :section) for (key, path) in p.roots])
    any(e -> e.kind == :dir && e.name == "setup", entries) && push!(children, Node("setup", joinpath(dir, "setup"), :section))
    attach!(root, children).local_state = node_local_state(p, root)
    return root
end

function expand!(h::RemoteHost, p::Production, node::Node; detectors::Bool = false, sizes::Bool = true)
    node.children === nothing || return node
    node.kind in (:section, :dir) || throw(ArgumentError("a :$(node.kind) node cannot be expanded: $(node.label)"))
    entries = list_dir(h, node.remote_path)
    check_tier_kinds(node.remote_path, entries)
    children = group_children(entries, node.remote_path)
    dirs = [c for c in children if c.kind == :dir]
    if sizes && !isempty(dirs)
        for (dir, bytes) in zip(dirs, dir_sizes(h, [c.remote_path for c in dirs]))
            dir.size = bytes
        end
    end
    attach!(node, children)
    if detectors
        if !isempty(filekey_groups(node))
            ensure_detectors!(node)
        else
            for run in run_dirs(node)
                entries = list_dir(h, run.remote_path)
                check_tier_kinds(run.remote_path, entries)
                i = findfirst(!isnothing, tier_kind.(entries))
                i === nothing && continue
                ensure_detectors!(node; whole_files = tier_kind(entries[i]) == :detector)
                break
            end
        end
    end
    node.local_state = node_local_state(p, node)
    return node
end

function tier_kind(e::DirEntry)
    id = e.kind == :file ? tier_file_id(e.name) : nothing
    return id === nothing ? nothing : first(id)
end

# A directory holds either filekey files or per-detector files: a mix would be grouped by one kind and the other go unseen.
function check_tier_kinds(dir::AbstractString, entries)
    a = findfirst(e -> tier_kind(e) == :filekey, entries)
    b = findfirst(e -> tier_kind(e) == :detector, entries)
    (a === nothing || b === nothing) && return nothing
    return throw(ArgumentError("$dir holds filekey files and per-detector files, for example $(entries[a].name) and $(entries[b].name)"))
end

function tier_entries(h::RemoteHost, dir::AbstractString, kind::Symbol)
    entries = list_dir(h, dir)
    check_tier_kinds(dir, entries)
    return filter(e -> tier_kind(e) == kind, entries)
end

function run_names(h::RemoteHost, dir::AbstractString)
    return sort!([e.name for e in list_dir(h, dir) if e.kind == :dir && occursin(RUN_DIR_EXPR, e.name)])
end

function detector_files(h::RemoteHost, run::AbstractString, label::AbstractString = run)
    files = Dict{String,DirEntry}()
    for e in tier_entries(h, run, :detector)
        name = last(tier_file_id(e.name))
        haskey(files, name) && throw(ArgumentError("$label holds two files for detector $name: $(files[name].name) and $(e.name)"))
        files[name] = e
    end
    return files
end

function node_local_state(p::Production, node::Node)
    path = to_local(p, node.remote_path)
    islink(path) && return :linked
    isfile(path) && return :present
    isdir(path) || return :missing
    node.children === nothing && return isempty(readdir(path)) ? :missing : :present
    states = [node_local_state(p, c) for c in node.children if c.kind ∉ (:detectors, :detector)]
    all(==(:missing), states) && return :missing
    return all(s -> s in (:present, :linked), states) ? :present : :partial
end

function filekey_groups(node::Node)
    return node.children === nothing ? Node[] :
           [c for c in node.children if c.kind == :group && LegendDataManagement._can_convert_to(Timestamp, c.label)]
end

run_dirs(node::Node) = node.children === nothing ? Node[] : [c for c in node.children if c.kind == :dir && occursin(RUN_DIR_EXPR, c.label)]

filekey_files(h::RemoteHost, dir::AbstractString) = sort!([joinpath(dir, e.name) for e in tier_entries(h, dir, :filekey)])

period_level(dir::Node) = isempty(filekey_groups(dir))

# Its `remote_path` does not exist on the host.
function ensure_detectors!(dir::Node; whole_files::Bool = false)
    dir.children === nothing && throw(ArgumentError("$(dir.label) has not been listed yet; expand it before asking for detectors"))
    i = findfirst(c -> c.kind == :detectors, dir.children)
    i === nothing || return dir.children[i]
    isempty(filekey_groups(dir)) && isempty(run_dirs(dir)) &&
        throw(ArgumentError("$(dir.label) holds no filekey files and no run directories, so it has no detectors"))
    node = Node("detectors", joinpath(dir.remote_path, "detectors"), :detectors; parent = dir, whole_files)
    pushfirst!(dir.children, node)
    return node
end

# A file without a detector axis (`jlevt`, `jlskm`, `jlpmt`) gives no rows.
function detector_nodes(h::RemoteHost, helper::HelperConfig, dir::Node; jobs::Integer = 0, steps::Steps = NO_STEPS)
    if period_level(dir)
        i = dir.children === nothing ? nothing : findfirst(c -> c.kind == :detectors, dir.children)
        return i !== nothing && dir.children[i].whole_files ? period_file_nodes(h, dir; steps) :
               period_detector_nodes(h, helper, dir; jobs, steps)
    end
    steps("reading first file")
    names, bytes = only(inspect_files(h, helper, [only(first(filekey_groups(dir)).children).remote_path]; jobs))
    return [Node(names[i], joinpath(dir.remote_path, "detectors", names[i]), :detector; size = bytes[i]) for i in eachindex(names, bytes)]
end

function period_detector_nodes(h::RemoteHost, helper::HelperConfig, period::Node; jobs::Integer = 0, steps::Steps = NO_STEPS)
    held = [(run, files) for run in run_dirs(period) for files in (filekey_files(h, run.remote_path),) if !isempty(files)]
    isempty(held) && throw(ArgumentError("$(period.label) has no run directory with filekey files to inspect"))
    seen = 0
    steps("reading first files"; total = length(held))
    inspected = inspect_files(h, helper, [first(files) for (_, files) in held]; jobs,
                              on_record = _ -> steps("reading first files"; done = (seen += 1), total = length(held)))
    rows = Dict{String,Node}()
    for ((run, files), (names, bytes, _)) in zip(held, inspected), i in eachindex(names, bytes)
        row = get!(() -> Node(names[i], joinpath(period.remote_path, "detectors", names[i]), :detector; size = 0), rows, names[i])
        row.size += bytes[i] * length(files)
        push!(row.holders, run.remote_path => length(files))
    end
    return [rows[name] for name in sort!(collect(keys(rows)))]
end

function period_file_nodes(h::RemoteHost, period::Node; steps::Steps = NO_STEPS)
    rows = Dict{String,Node}()
    runs = run_dirs(period)
    steps("listing runs"; total = length(runs))
    for (i, run) in pairs(runs)
        for (name, entry) in detector_files(h, run.remote_path, run.label)
            row = get!(() -> Node(name, joinpath(period.remote_path, "detectors", name), :detector; size = 0, whole_files = true), rows,
                       name)
            row.size += entry.size
            push!(row.holders, run.remote_path => 1)
        end
        steps("listing runs"; done = i, total = length(runs))
    end
    isempty(rows) && throw(ArgumentError("$(period.label) holds no per-detector files in any of its run directories"))
    return [rows[name] for name in sort!(collect(keys(rows)))]
end

function expand_detectors!(h::RemoteHost, helper::HelperConfig, node::Node; jobs::Integer = 0, steps::Steps = NO_STEPS)
    node.kind == :detectors || throw(ArgumentError("not a detectors node: $(node.label)"))
    node.children === nothing || return node
    return attach_detectors!(node, detector_nodes(h, helper, node.parent; jobs, steps))
end

function attach_detectors!(node::Node, children::Vector{Node})
    attach!(node, children).size = sum(c -> something(c.size, 0), children; init = 0)
    return node
end
