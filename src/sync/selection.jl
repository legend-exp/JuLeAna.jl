# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

function relative_dir(dir)
    isabspath(dir) && throw(ArgumentError("dir must be relative, got $dir"))
    ".." in splitpath(dir) && throw(ArgumentError("dir must not contain .., got $dir"))
    return String(dir)
end

struct ExtractEntry
    dir::String
    groups::Vector{String}
    function ExtractEntry(dir, groups)
        relative_dir(dir)
        isempty(groups) && throw(ArgumentError("no groups for dir $dir"))
        return new(dir, sort!(unique(String.(groups))))
    end
end

struct DetectorEntry
    dir::String
    detectors::Vector{String}
    mode::Symbol
    function DetectorEntry(dir, detectors, mode)
        relative_dir(dir)
        isempty(detectors) && throw(ArgumentError("no detectors for dir $dir"))
        any(isempty, detectors) && throw(ArgumentError("empty detector name for dir $dir"))
        mode in (:copy, :link) || throw(ArgumentError("mode must be :copy or :link, got :$mode"))
        return new(dir, sort!(unique(String.(detectors))), Symbol(mode))
    end
end

struct Selection
    host::String
    production::String
    remote_root::String
    local_root::String
    mount_root::Union{Nothing,String}
    copy::Vector{String}
    link::Vector{String}
    created::DateTime
    extract::Vector{ExtractEntry}
    detector_files::Vector{DetectorEntry}
end

function Selection(host, production, remote_root, local_root, mount_root, copy, link, created, extract = ExtractEntry[])
    return Selection(host, production, remote_root, local_root, mount_root, copy, link, created, extract, DetectorEntry[])
end

function detectors_row(node::Node)
    i = node.children === nothing ? nothing : findfirst(c -> c.kind == :detectors, node.children)
    return i === nothing ? nothing : node.children[i]
end

function marked_rows(run::Node, marked)
    rows = Node[]
    dir = run.parent
    while dir !== nothing
        row = detectors_row(dir)
        row === nothing || row.children === nothing || append!(rows, filter(marked, row.children))
        dir = dir.parent
    end
    return rows
end

function covering_extract(node::Node)
    (node.kind == :detector && node.parent !== nothing) || return nothing
    run = node.parent.parent
    period_level(run) && return nothing
    return findfirst_row(marked_rows(run, c -> c.mode == :extract), node.label)
end

function covering_detector(node::Node)
    group = node.kind == :file && node.parent !== nothing ? node.parent : node
    group.kind == :group && group.parent !== nothing || return nothing
    rows = marked_rows(group.parent, c -> c.whole_files && c.mode in (:copy, :link))
    isempty(rows) && return nothing
    id = tier_file_id(basename(group.remote_path))
    (id === nothing || first(id) != :detector) && return nothing
    return findfirst_row(rows, last(id))
end

findfirst_row(rows, label) = (j = findfirst(c -> c.label == label, rows); j === nothing ? nothing : rows[j])

function effective_mode(node::Node)
    current = node
    while current !== nothing
        current.mode == :none || return current.mode
        current = current.parent
    end
    covering_extract(node) === nothing || return :extract
    row = covering_detector(node)
    return row === nothing ? :none : row.mode
end

# A whole-directory mark and a detector mark never cover the same run: a conflicting mark throws. A `:copy` under a `:link`
# survives.
function set_mode!(node::Node, mode::Symbol)
    mode in (:none, :copy, :link, :extract) || throw(ArgumentError("mode must be :none, :copy, :link or :extract, got :$mode"))
    kind = node.kind
    whole = kind == :detector && node.whole_files
    mode == :extract && kind != :detector && throw(ArgumentError("only detector rows can be extracted, not the :$kind row $(node.label)"))
    mode == :extract && whole &&
        throw(ArgumentError("cannot extract $(node.label): the files of $(node.parent.parent.label) hold one detector each; mark the row :copy or :link instead"))
    mode in (:copy, :link) && kind == :detectors && node.whole_files &&
        throw(ArgumentError("the $(node.label) row of $(node.parent.label) has no path on the host; mark one of the detector rows below it :$mode"))
    mode in (:copy, :link) && kind in (:detectors, :detector) && !node.whole_files &&
        throw(ArgumentError("detector rows have no path on the host; use :extract, not :$mode, on $(node.label)"))
    row = mode == :none ? nothing : covering_detector(node)
    row === nothing || throw(ArgumentError("cannot mark $(node.label) :$mode: its file is covered by the :$(row.mode) mark of detector " *
                                           "$(row.label) of $(row.parent.parent.label); unmark the period's detector first"))
    if mode == :extract || (whole && mode != :none)
        dir = node.parent.parent
        what = mode == :extract ? "extract $(node.label) from $(dir.label)" : "mark $(node.label) :$mode in $(dir.label)"
        held = Set(first(h) for h in node.holders)
        scope = period_level(dir) ? vcat(dir, filter(r -> r.remote_path in held, run_dirs(dir))) : [dir]
        for scoped in scope
            effective_mode(scoped) in (:copy, :link) || continue
            owner = scoped
            while owner.mode == :none
                owner = owner.parent
            end
            throw(ArgumentError("cannot $what: $(scoped.label) is already transferred whole (:$(owner.mode) on $(owner.label))"))
        end
        if whole
            for run in scope, file in something(run.children, Node[])
                file.kind == :group && file.label == node.label && file.mode != :none &&
                    throw(ArgumentError("cannot $what: file $(file.label) of $(run.label) is marked individually; unmark it first"))
            end
        end
    elseif mode in (:copy, :link) && kind in (:production, :section, :dir)
        marked = marked_conflict(node)
        marked === nothing ||
            throw(ArgumentError("cannot mark $(node.label) :$mode: detector $(marked.label) of $(marked.parent.parent.label) is marked " *
                                (marked.mode == :extract ? "for extraction" : ":$(marked.mode)") * "; unmark the detector first"))
    end
    node.mode = mode
    clear_descendants!(node, mode)
    return node
end

marked_detector(node::Node) = node.kind == :detector && (node.mode == :extract || (node.whole_files && node.mode in (:copy, :link)))

function subtree_marked(node::Node)
    marked_detector(node) && return node
    node.children === nothing && return nothing
    for child in node.children
        found = subtree_marked(child)
        found === nothing || return found
    end
    return nothing
end

function marked_conflict(node::Node)
    found = subtree_marked(node)
    found === nothing || return found
    ancestor = node.parent
    while ancestor !== nothing
        row = detectors_row(ancestor)
        if row !== nothing && row.children !== nothing
            for r in row.children
                marked_detector(r) && any(held -> first(held) == node.remote_path, r.holders) && return r
            end
        end
        ancestor = ancestor.parent
    end
    return nothing
end

function clear_descendants!(node::Node, mode::Symbol)
    node.children === nothing && return node
    for child in node.children
        (mode == :link && child.mode == :copy) || (child.mode = :none)
        clear_descendants!(child, mode)
    end
    return node
end

function exclude!(node::Node)
    if node.kind in (:detectors, :detector) && node.mode == :none && effective_mode(node) != :none
        covering = covering_extract(node)
        throw(ArgumentError(covering === nothing ? "cannot exclude detector row $(node.label); unmark the run instead" :
                            "cannot exclude detector row $(node.label): it is extracted for the whole period; unmark the period row $(covering.remote_path) instead"))
    end
    row = covering_detector(node)
    row === nothing || throw(ArgumentError("cannot exclude $(node.label): its file is covered by the :$(row.mode) mark of detector " *
                                           "$(row.label) of $(row.parent.parent.label); unmark the period's detector first"))
    effective_mode(node) == :none && return node
    node.mode == :none || return set_mode!(node, :none)
    ancestors = Node[]
    current = node
    while current.parent !== nothing
        current = current.parent
        pushfirst!(ancestors, current)
    end
    carry = :none
    for (i, level) in pairs(ancestors)
        level.mode == :none || (carry = level.mode; level.mode = :none)
        carry == :none && continue
        on_path = i < lastindex(ancestors) ? ancestors[i + 1] : node
        for sibling in level.children
            sibling === on_path || sibling.kind == :detectors || set_mode!(sibling, carry)
        end
    end
    return node
end

function first_n_filekeys!(node::Node, n::Integer)
    node.children === nothing && throw(ArgumentError("$(node.label) has not been listed yet; expand it before selecting filekeys"))
    groups = filekey_groups(node)
    isempty(groups) && throw(ArgumentError("$(node.label) contains no filekey groups"))
    foreach(group -> set_mode!(group, :copy), first(groups, n))
    return min(n, length(groups))
end

# A `:section` stands for a whole configured directory, so it descends into the child covering the longest prefix of `rel`.
function find_node!(h::RemoteHost, p::Production, root::Node, rel::AbstractString)
    isempty(rel) && return root
    node = root
    while relative(p, node.remote_path) != rel
        node.children === nothing && expand!(h, p, node)
        rels = [relative(p, child.remote_path) for child in node.children]
        covering = [i for i in eachindex(rels) if rels[i] == rel || startswith(rel, rels[i] * "/")]
        isempty(covering) && throw(ArgumentError("$rel is not in the production tree below $(node.label)"))
        node = node.children[covering[argmax(length.(rels[covering]))]]
    end
    node.children === nothing && node.kind in (:section, :dir) && expand!(h, p, node)
    return node
end

function collect_modes!(node::Node, p::Production, copies, links, extracts, files)
    if node.kind == :detector && node.whole_files
        node.mode == :none || push!(get!(files, (relative(p, node.parent.parent.remote_path), node.mode), String[]), node.label)
        return nothing
    end
    node.mode == :copy && push!(copies, relative(p, node.remote_path))
    node.mode == :link && push!(links, relative(p, node.remote_path))
    node.mode == :extract && push!(get!(extracts, relative(p, node.parent.parent.remote_path), String[]), node.label)
    node.children === nothing || foreach(child -> collect_modes!(child, p, copies, links, extracts, files), node.children)
    return nothing
end

function mandatory_copies(p::Production)
    production = joinpath(p.remote_root, p.name)
    mandatory = [relative(p, joinpath(production, p.config_file)); p.overlays]
    p.setup_config && push!(mandatory, relative(p, joinpath(production, "setup", "config")))
    i = findfirst(kv -> first(kv) == "metadata", p.roots)
    i === nothing && throw(ArgumentError("production $(p.name) has no \"metadata\" path key; legend-metadata cannot be mirrored"))
    return push!(mandatory, relative(p, last(p.roots[i])))
end

function Selection(p::Production, host::AbstractString, root::Node)
    copies, links = String[], String[]
    extracts = Dict{String,Vector{String}}()
    files = Dict{Tuple{String,Symbol},Vector{String}}()
    collect_modes!(root, p, copies, links, extracts, files)
    union!(copies, mandatory_copies(p))
    return Selection(host, p.name, p.remote_root, p.local_root, p.mount_root, sort!(copies), sort!(links), now(),
                     [ExtractEntry(run, groups) for (run, groups) in sort!(collect(extracts); by = first)],
                     [DetectorEntry(dir, detectors, mode) for ((dir, mode), detectors) in sort!(collect(files); by = first)])
end

function Selection(props::PropDict)
    mount = String(props.mount_root)
    # readprops returns array elements as plain dictionaries with string keys.
    extract = haskey(props, :extract) ?
              [ExtractEntry(haskey(e, "dir") ? e["dir"] : e["run_dir"], String.(e["groups"])) for e in props.extract] : ExtractEntry[]
    detector_files = haskey(props, :detector_files) ?
                     [DetectorEntry(e["dir"], String.(e["detectors"]), Symbol(e["mode"])) for e in props.detector_files] : DetectorEntry[]
    return Selection(String(props.host), String(props.production), String(props.remote_root), String(props.local_root),
                     isempty(mount) ? nothing : mount, String.(props.copy), String.(props.link), DateTime(String(props.created)), extract,
                     detector_files)
end

# The path must end in `.yaml` because `readprops` picks the format from the extension; a missing mount root is written as
# `""` because it trims nulls.
function save_selection(path::AbstractString, sel::Selection)
    endswith(path, ".yaml") || throw(ArgumentError("a selection file must end in .yaml, got $path"))
    mkpath(dirname(path))
    YAML.write_file(path,
                    PropDict(:host => sel.host, :production => sel.production, :remote_root => sel.remote_root,
                             :local_root => sel.local_root,
                             :mount_root => something(sel.mount_root, ""), :copy => sel.copy, :link => sel.link,
                             :extract => [PropDict(:dir => e.dir, :groups => e.groups) for e in sel.extract],
                             :detector_files => [PropDict(:dir => e.dir, :detectors => e.detectors, :mode => String(e.mode))
                                                 for e in sel.detector_files], :created => string(sel.created)))
    return path
end

# Variable substitution is off: a `$` in a literal path would silently point the transfer elsewhere.
function load_selection(path::AbstractString, p::Production; host::Union{Nothing,AbstractString} = nothing)
    sel = Selection(readprops(path; subst_pathvar = false, subst_env = false))
    host === nothing || sel.host == host ||
        throw(ArgumentError("selection $path was saved for host $(sel.host), but the current host is $host"))
    sel.production == p.name || throw(ArgumentError("selection $path is for production $(sel.production), not $(p.name)"))
    rstrip(normpath(sel.remote_root), '/') == p.remote_root ||
        throw(ArgumentError("selection $path has remote root $(sel.remote_root), not $(p.remote_root)"))
    return Selection(sel.host, sel.production, sel.remote_root, sel.local_root, sel.mount_root, sort!(union(sel.copy, mandatory_copies(p))),
                     sel.link, sel.created, sel.extract, sel.detector_files)
end

function apply_selection!(h::RemoteHost, p::Production, root::Node, sel::Selection;
                          helper::HelperConfig = HelperConfig(), jobs::Integer = 0, steps::Steps = NO_STEPS)
    total = length(sel.link) + length(sel.copy) + length(sel.extract) + length(sel.detector_files)
    done = 0
    tick() = steps("listing directories"; done = (done += 1), total)
    steps("listing directories"; total)
    for rel in sel.link
        set_mode!(find_node!(h, p, root, rel), :link)
        tick()
    end
    for rel in sel.copy
        rel in p.overlays || set_mode!(find_node!(h, p, root, rel), :copy)
        tick()
    end
    for entry in sel.extract
        dir = find_node!(h, p, root, entry.dir)
        rows = expand_detectors!(h, helper, ensure_detectors!(dir); jobs)
        for group in entry.groups
            row = findfirst_row(rows.children, group)
            row === nothing && throw(ArgumentError("detector group $group of $(entry.dir) is not in " *
                                                   (period_level(dir) ? "any run of the period" : "the first file of the run")))
            set_mode!(row, :extract)
        end
        tick()
    end
    for entry in sel.detector_files
        rows = expand_detectors!(h, helper, ensure_detectors!(find_node!(h, p, root, entry.dir); whole_files = true))
        for name in entry.detectors
            row = findfirst_row(rows.children, name)
            row === nothing && throw(ArgumentError("detector $name of $(entry.dir): no run of the period holds a file for it"))
            row.mode in (:none, entry.mode) ||
                throw(ArgumentError("detector $name of $(entry.dir) is marked both :$(row.mode) and :$(entry.mode)"))
            set_mode!(row, entry.mode)
        end
        tick()
    end
    return root
end
