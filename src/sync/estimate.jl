# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# `extract_exact` is `false` when the extract size comes from the first file of each run only.
struct Estimate
    bytes::Int
    files::Int
    links::Int
    complete::Bool
    extract_bytes::Int
    extract_files::Int
    extract_exact::Bool
    not_in_run::Vector{Tuple{String,String}}
end

function Estimate(bytes, files, links, complete, extract_bytes = 0, extract_files = 0, extract_exact = true)
    return Estimate(bytes, files, links, complete, extract_bytes, extract_files, extract_exact, Tuple{String,String}[])
end

function format_bytes(n::Integer)
    n < 1024 && return "$n B"
    value = Float64(n)
    for unit in ("K", "M", "G", "T")
        value /= 1024
        value < 1024 && return string(round(value; digits = 1), " ", unit)
    end
    return string(round(value / 1024; digits = 1), " P")
end

# Approximate, as `extract_exact` records; `apply!` with `dry_run` is exact. A run-level count wins where run and period rows
# both name a run.
function running_estimate(root::Node)
    bytes = files = links = extract_bytes = 0
    complete = true
    sized(node) = node.size === nothing ? (complete = false; 0) : node.size
    run_counts = Dict{Node,Int}()
    period_counts = Dict{String,Int}()
    pending = Node[root]
    while !isempty(pending)
        node = pop!(pending)
        if node.kind == :detector && node.mode == :extract
            covering_extract(node) === nothing || continue
            dir = node.parent.parent
            if period_level(dir)
                extract_bytes += sized(node)
                merge!(period_counts, Dict(node.holders))
            else
                extract_bytes += sized(node) * get!(() -> count(g -> effective_mode(g) != :copy, filekey_groups(dir)), run_counts, dir)
            end
            continue
        end
        if node.kind == :detector && node.whole_files && node.mode != :none
            node.mode == :copy ? (bytes += sized(node); files += length(node.holders)) : (links += length(node.holders))
            continue
        end
        mode = effective_mode(node)
        node.kind == :group && mode != :none && covering_detector(node) !== nothing && continue
        parent_mode = node.parent === nothing ? :none : effective_mode(node.parent)
        if mode == :copy && parent_mode != :copy
            bytes += sized(node)
            node.kind in (:file, :group) && (files += 1)
            continue
        end
        mode == :link && parent_mode != :link && (links += 1)
        node.children === nothing || append!(pending, node.children)
    end
    for (run, n) in run_counts
        period_counts[run.remote_path] = n
    end
    extract_files = sum(values(period_counts); init = 0)
    return Estimate(bytes, files, links, complete, extract_bytes, extract_files, extract_files == 0)
end

format_not_in_run(pairs) = join(("$detector in $run" for (run, detector) in pairs), ", ")

function format_estimate(e::Estimate)
    return string("selected: ", format_bytes(e.bytes), e.complete ? "" : "?", " copy (", e.files, " files), ", e.links, " links",
                  e.extract_files == 0 ? "" :
                  string(", ", e.extract_exact ? "" : "~", format_bytes(e.extract_bytes), " extract (", e.extract_files, " files)"),
                  isempty(e.not_in_run) ? "" : string(", ", length(e.not_in_run), " not in run"))
end

# Must run with `LC_ALL=C` so the digit grouping is a comma.
function parse_rsync_stats(out::AbstractString, links::Integer)
    bytes = match(r"^Total transferred file size:\s+([0-9,]+)"m, out)
    files = match(r"^Number of regular files transferred:\s+([0-9,]+)"m, out)
    (bytes === nothing || files === nothing) &&
        throw(ErrorException("rsync --stats printed no transfer totals; GNU rsync >= 3.1 is required. Output was:\n$out"))
    return Estimate(parse(Int, replace(bytes[1], "," => "")), parse(Int, replace(files[1], "," => "")), Int(links), true)
end
