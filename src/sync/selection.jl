"""
    ExtractEntry(dir, groups)

The detectors to take out of every filekey file below one directory: `dir` is a run
directory or a period directory relative to the remote root, `groups` the detector
names, sorted and without duplicates. A `dir` that is absolute or has a `..`
component, and an empty `groups`, are an `ArgumentError`: extraction writes below the
staging directory at `dir`, so it must stay below the remote root.
"""
struct ExtractEntry
    dir::String
    groups::Vector{String}
    function ExtractEntry(dir, groups)
        isabspath(dir) && throw(ArgumentError("dir must be relative, got $dir"))
        ".." in splitpath(dir) && throw(ArgumentError("dir must not contain .., got $dir"))
        isempty(groups) && throw(ArgumentError("no groups for dir $dir"))
        new(dir, sort!(unique(String.(groups))))
    end
end

Base.:(==)(a::ExtractEntry, b::ExtractEntry) = a.dir == b.dir && a.groups == b.groups
Base.hash(e::ExtractEntry, h::UInt) = hash(e.groups, hash(e.dir, h))

"""
    Selection

What the user chose, in a form that survives a restart: remote paths relative to
the remote root, split into the ones to copy and the ones to link, plus the
detectors to extract from runs or whole periods. Only the nodes carrying an explicit
mode are listed; the tree is reconstructed by expanding those paths again.
"""
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
end

Selection(host, production, remote_root, local_root, mount_root, copy, link, created) =
    Selection(host, production, remote_root, local_root, mount_root, copy, link, created,
              ExtractEntry[])

"""
    covering_extract(node::Node)::Union{Nothing,Node}

For a `:detector` row of a run directory, the row of the same detector below the
`detectors` node of a period directory above the run, when that row is marked for
extraction; `nothing` for every other node. Period-level rows are never covered.
"""
function covering_extract(node::Node)
    (node.kind == :detector && node.parent !== nothing) || return nothing
    run = node.parent.parent
    period_level(run) && return nothing
    dir = run.parent
    while dir !== nothing
        i = dir.children === nothing ? nothing : findfirst(c -> c.kind == :detectors, dir.children)
        if i !== nothing && dir.children[i].children !== nothing
            j = findfirst(c -> c.label == node.label && c.mode == :extract, dir.children[i].children)
            j === nothing || return dir.children[i].children[j]
        end
        dir = dir.parent
    end
    nothing
end

"""
    effective_mode(node::Node)::Symbol

The mode that applies to `node`: its own if it has one, otherwise the nearest
ancestor's, otherwise `:extract` for a run-level detector row covered by a
period-level mark (see [`covering_extract`](@ref)), otherwise `:none`.
"""
function effective_mode(node::Node)
    current = node
    while current !== nothing
        current.mode == :none || return current.mode
        current = current.parent
    end
    covering_extract(node) === nothing ? :none : :extract
end

"""
    set_mode!(node::Node, mode::Symbol)::Node

Choose `mode` for `node` and drop the explicit modes below it, so that the
subtree follows the new choice. The one survivor is a `:copy` under a `:link`:
that combination is how a few files are pulled out of an otherwise linked
directory.

A copy or link mark and an extract mark never cover the same run. Marking a
detector row `:extract` throws when its run or period directory, a directory above
it, or (for a period-level row) any listed run of the period that holds the detector is
copied or linked; runs that do not hold it are ignored.
Marking a production, section or directory `:copy` or `:link` throws when a marked
detector row is below it or when a marked period-level row lists it as a holder.
Single files and filekey groups can still be copied inside an extracted run.
"""
function set_mode!(node::Node, mode::Symbol)
    mode in (:none, :copy, :link, :extract) || throw(ArgumentError(
        "mode must be :none, :copy, :link or :extract, got :$mode"))
    mode == :extract && node.kind != :detector && throw(ArgumentError(
        "only detector rows can be extracted, not the :$(node.kind) row $(node.label)"))
    mode in (:copy, :link) && node.kind in (:detectors, :detector) && throw(ArgumentError(
        "detector rows have no path on the host; use :extract, not :$mode, on $(node.label)"))
    if mode == :extract
        dir = node.parent.parent
        # A period-level row concerns the period and only the runs that hold the detector.
        held = Set(first(h) for h in node.holders)
        scope = period_level(dir) ? vcat(dir, filter(r -> r.remote_path in held, run_dirs(dir))) : [dir]
        for scoped in scope
            effective_mode(scoped) in (:copy, :link) || continue
            owner = scoped
            while owner.mode == :none
                owner = owner.parent
            end
            throw(ArgumentError("cannot extract $(node.label) from $(dir.label): " *
                "$(scoped.label) is already transferred whole (:$(owner.mode) on $(owner.label))"))
        end
    elseif mode in (:copy, :link) && node.kind in (:production, :section, :dir)
        marked = extract_conflict(node)
        marked === nothing || throw(ArgumentError(
            "cannot mark $(node.label) :$mode: detector $(marked.label) of " *
            "$(marked.parent.parent.label) is marked for extraction; unmark the detector first"))
    end
    node.mode = mode
    clear_descendants!(node, mode)
    node
end

# The first detector row in the listed subtree of `node` that is marked for extraction.
function subtree_extract(node::Node)
    node.kind == :detector && node.mode == :extract && return node
    node.children === nothing && return nothing
    for child in node.children
        found = subtree_extract(child)
        found === nothing || return found
    end
    nothing
end

# A marked detector row that covers part of `node`: one in its subtree, or a marked
# period-level row above it that lists the path of `node` among its holders.
function extract_conflict(node::Node)
    found = subtree_extract(node)
    found === nothing || return found
    ancestor = node.parent
    while ancestor !== nothing
        i = ancestor.children === nothing ? nothing : findfirst(c -> c.kind == :detectors, ancestor.children)
        if i !== nothing && ancestor.children[i].children !== nothing
            for row in ancestor.children[i].children
                row.mode == :extract && any(held -> first(held) == node.remote_path, row.holders) &&
                    return row
            end
        end
        ancestor = ancestor.parent
    end
    nothing
end

function clear_descendants!(node::Node, mode::Symbol)
    node.children === nothing && return node
    for child in node.children
        (mode == :link && child.mode == :copy) || (child.mode = :none)
        clear_descendants!(child, mode)
    end
    node
end

"""
    exclude!(node::Node)::Node

Take `node` out of the selection it inherits. Walking down from the root, the
nearest explicit mode seen so far is handed to the siblings of whichever child
stays on the path to `node`, updating to a level's own mode whenever one is
carried there; every node on the path, `node` included, ends up with no mode of
its own. A node that carries its own mode simply loses it, along with the
explicit modes below it.
"""
function exclude!(node::Node)
    # Detector rows without an own mode inherit the mode of their run or period, which cannot be split per detector.
    if node.kind in (:detectors, :detector) && node.mode == :none && effective_mode(node) != :none
        covering = covering_extract(node)
        throw(ArgumentError(covering === nothing ?
            "cannot exclude detector row $(node.label); unmark the run instead" :
            "cannot exclude detector row $(node.label): it is extracted for the whole period; " *
            "unmark the period row $(covering.remote_path) instead"))
    end
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
    node
end

"""
    first_n_filekeys!(node::Node, n::Integer)::Int

Mark the first `n` filekeys of a listed run directory for copying, in timestamp
order, and return how many were marked.
"""
function first_n_filekeys!(node::Node, n::Integer)
    node.children === nothing && throw(ArgumentError(
        "$(node.label) has not been listed yet; expand it before selecting filekeys"))
    groups = filekey_groups(node)
    isempty(groups) && throw(ArgumentError("$(node.label) contains no filekey groups"))
    count = 0
    for group in groups
        count >= n && break
        set_mode!(group, :copy)
        count += 1
    end
    count
end

"""
    find_node!(h::RemoteHost, p::Production, root::Node, rel::AbstractString)::Node

The node at `rel` (a path relative to the remote root), listing every directory
from `root` down to it, inclusive. Descends into whichever child covers the
longest prefix of `rel`, because a `:section` node stands for a whole configured
directory rather than one path component.
"""
function find_node!(h::RemoteHost, p::Production, root::Node, rel::AbstractString)
    isempty(rel) && return root
    node = root
    while relative(p, node.remote_path) != rel
        node.children === nothing && expand!(h, p, node)
        best = nothing
        best_len = -1
        for child in node.children
            child_rel = relative(p, child.remote_path)
            (child_rel == rel || startswith(rel, child_rel * "/")) || continue
            if length(child_rel) > best_len
                best = child
                best_len = length(child_rel)
            end
        end
        best === nothing && throw(ArgumentError(
            "$rel is not in the production tree below $(node.label)"))
        node = best
    end
    node.children === nothing && node.kind in (:section, :dir) && expand!(h, p, node)
    node
end

function collect_modes!(node::Node, p::Production, copies::Vector{String},
                        links::Vector{String}, extracts::Dict{String,Vector{String}})
    node.mode == :copy && push!(copies, relative(p, node.remote_path))
    node.mode == :link && push!(links, relative(p, node.remote_path))
    # A detector row hangs below the `detectors` node of its run or period directory, so that directory is two levels up.
    node.mode == :extract && push!(get!(extracts, relative(p, node.parent.parent.remote_path), String[]),
                                   node.label)
    node.children === nothing && return nothing
    for child in node.children
        collect_modes!(child, p, copies, links, extracts)
    end
    nothing
end

"""
    mandatory_copies(p::Production)::Vector{String}

The paths, relative to the remote root, that every mirror of `p` copies: the
production's own config.json, the overlays applied to it and its metadata checkout.
Without them the mirror cannot be opened.
"""
function mandatory_copies(p::Production)
    mandatory = [relative(p, joinpath(p.remote_root, p.name, "config.json")); p.overlays]
    i = findfirst(kv -> first(kv) == "metadata", p.roots)
    i === nothing && throw(ArgumentError(
        "production $(p.name) has no \"metadata\" path key; legend-metadata cannot be mirrored"))
    push!(mandatory, relative(p, last(p.roots[i])))
end

function Selection(p::Production, host::AbstractString, root::Node)
    copies = String[]
    links = String[]
    extracts = Dict{String,Vector{String}}()
    collect_modes!(root, p, copies, links, extracts)
    for path in mandatory_copies(p)
        path in copies || push!(copies, path)
    end
    entries = [ExtractEntry(run, sort!(groups)) for (run, groups) in sort!(collect(extracts); by = first)]
    Selection(host, p.name, p.remote_root, p.local_root, p.mount_root,
              sort!(copies), sort!(links), now(), entries)
end

"""
    selection_propdict(sel::Selection)::PropDict

The serialized form. A missing mount root is written as `""`: `readprops` trims
nulls, so a null would come back as an absent key. The extract entries are
written as objects; a file without the key reads as no entries.
"""
selection_propdict(sel::Selection) = PropDict(
    :host => sel.host,
    :production => sel.production,
    :remote_root => sel.remote_root,
    :local_root => sel.local_root,
    :mount_root => sel.mount_root === nothing ? "" : sel.mount_root,
    :copy => sel.copy,
    :link => sel.link,
    :extract => [PropDict(:dir => e.dir, :groups => e.groups) for e in sel.extract],
    :created => string(sel.created),
)

function Selection(props::PropDict)
    mount = String(props.mount_root)
    # readprops returns array elements as plain dictionaries with string keys;
    # `run_dir` is accepted as an alias for `dir`.
    extract = haskey(props, :extract) ?
              [ExtractEntry(String(haskey(e, "dir") ? e["dir"] : get(e, "run_dir") do
                                      throw(ArgumentError("extract entry without a \"dir\" key: $e"))
                                  end), String.(e["groups"])) for e in props.extract] :
              ExtractEntry[]
    Selection(String(props.host), String(props.production),
              String(props.remote_root), String(props.local_root),
              isempty(mount) ? nothing : mount,
              String.(props.copy), String.(props.link),
              DateTime(String(props.created)), extract)
end

"""
    save_selection(path::AbstractString, sel::Selection)::String

Write `sel` as YAML and return `path`, which must end in `.yaml`: `readprops`
picks the format from the extension.
"""
function save_selection(path::AbstractString, sel::Selection)
    endswith(path, ".yaml") || throw(ArgumentError("a selection file must end in .yaml, got $path"))
    mkpath(dirname(path))
    YAML.write_file(path, selection_propdict(sel))
    path
end

"""
    load_selection(path::AbstractString, p::Production)::Selection

Read a saved selection and check it belongs to `p`. Variable substitution is off:
a selection holds literal paths, and expanding a `\$` in one would silently point
the transfer somewhere else. The returned selection's copy list is the union of the
file's and `mandatory_copies(p)`, so a hand-written file still yields an openable mirror.
"""
function load_selection(path::AbstractString, p::Production)
    sel = Selection(readprops(path; subst_pathvar = false, subst_env = false))
    sel.production == p.name || throw(ArgumentError(
        "selection $path is for production $(sel.production), not $(p.name)"))
    rstrip(normpath(sel.remote_root), '/') == p.remote_root || throw(ArgumentError(
        "selection $path has remote root $(sel.remote_root), not $(p.remote_root)"))
    Selection(sel.host, sel.production, sel.remote_root, sel.local_root, sel.mount_root,
              sort!(union(sel.copy, mandatory_copies(p))), sel.link, sel.created, sel.extract)
end

"""
    apply_selection!(h::RemoteHost, p::Production, root::Node, sel::Selection;
                     helper = HelperConfig(), jobs = 0)::Node

Expand `root` along every path in `sel` and set the modes it records, including
the detectors of every extract entry (which are listed with the remote helper). The
overlay configs of `p` are copied with the production but are not nodes of its tree,
so they are skipped. A recorded detector that is not in the first file of its run, or
in no run of its period, is an error.
"""
function apply_selection!(h::RemoteHost, p::Production, root::Node, sel::Selection;
                          helper::HelperConfig = HelperConfig(), jobs::Integer = 0)
    for rel in sel.link
        set_mode!(find_node!(h, p, root, rel), :link)
    end
    for rel in sel.copy
        rel in p.overlays && continue
        set_mode!(find_node!(h, p, root, rel), :copy)
    end
    for entry in sel.extract
        dir = find_node!(h, p, root, entry.dir)
        detectors = expand_detectors!(h, helper, ensure_detectors!(dir); jobs)
        for group in entry.groups
            i = findfirst(c -> c.label == group, detectors.children)
            i === nothing && throw(ArgumentError(
                "detector group $group of $(entry.dir) is not in " *
                (period_level(dir) ? "any run of the period" : "the first file of the run")))
            set_mode!(detectors.children[i], :extract)
        end
    end
    root
end
