# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Remote helper of the sync tool: lists and extracts the detector groups of LEGEND HDF5 files. It needs only HDF5 and
# ParallelProcessingTools; jobs come from a TOML file and every result is one line of TOML on standard output.
#
#     julia --project=ENV extract.jl inspect JOBFILE [--jobs N]
#     julia --project=ENV extract.jl extract JOBFILE [--jobs N]

# One BLAS thread per process keeps a master and its workers below per-user thread limits; it must precede the packages that
# load LinearAlgebra.
ENV["OPENBLAS_NUM_THREADS"] = "1"
using Distributed
using HDF5
using ParallelProcessingTools
using TOML

const SCRIPT = abspath(@__FILE__)

storage_bytes(dset::HDF5.Dataset) = Int(HDF5.API.h5d_get_storage_size(dset))
storage_bytes(group::HDF5.Group) = sum(name -> storage_bytes(group[name]), keys(group); init = 0)
storage_bytes(::Any) = 0

# Name patterns of LegendDataManagement (src/filekey.jl); the helper runs without that package.
const DETECTOR_ID = r"^(?:[BCPV][0-9]{5}[A-P]|S[0-9]{3}|PMT[0-9]{3}|PULS[0-9]{2}(?:ANA)?|AUX[0-9]{2}|DUMMY[0-9]{1,2}|BSLN[0-9]{2}|MUON[0-9]{2}|C00ANG[0-9]|C000RG[0-9])$"
const CHANNEL_ID = r"^ch(?:[0-9]{3}|(?:0[1-9]|[1-9][0-9])[0-9]{5})$"

is_detector(name) = occursin(DETECTOR_ID, name) || occursin(CHANNEL_ID, name)

# "" when top-level groups are detector names, else the tier group's name, `nothing` without a detector axis.
function detector_parent(f)
    tops = collect(String, keys(f))
    any(is_detector, tops) && return ""
    length(tops) == 1 && f[only(tops)] isa HDF5.Group && any(is_detector, keys(f[only(tops)])) && return only(tops)
    return nothing
end

# The return type is concrete because `onworker` converts the remote result to the inferred type.
function inspect_file(path::String, groups::Union{Nothing,Vector{String}})::Tuple{Vector{String},Vector{Int},String}
    h5open(path, "r") do f
        layout = detector_parent(f)
        if layout === nothing
            isempty(something(groups, String[])) || error("group $(first(groups)) not found in $path")
            return (String[], Int[], "")
        end
        parent = layout == "" ? f : f[layout]
        names = collect(String, keys(parent))
        sized = something(groups, names)
        for group in sized
            haskey(parent, group) || error("group $group not found in $path")
        end
        return sized, [storage_bytes(parent[name]) for name in sized], layout
    end
end

# An existing destination that is not a readable reduced file written by this tool stops the job instead of being
# overwritten.
function extract_file(source::String, groups::Vector{String}, destination::String)::Tuple{Symbol,Int,Int}
    destination == source && error(source, ": destination ", destination, " is the source ", source)
    if isfile(destination)
        held = try
            h5open(destination, "r") do f
                return haskey(attrs(f), "juleana_sync_groups") ? String.(attrs(f)["juleana_sync_groups"]) : nothing
            end
        catch err
            error(source, ": cannot read existing destination ", destination, ": ", sprint(showerror, err))
        end
        held === nothing && error(source, ": existing destination ", destination, " is not a reduced file written by this tool")
        held == groups && mtime(source) <= mtime(destination) && return (:skipped, Int(filesize(destination)), myid())
    end
    mkpath(dirname(destination))
    partial = destination * ".partial"
    try
        h5open(source, "r") do src
            layout = detector_parent(src)
            layout === nothing && error("no detector axis, cannot extract ", join(groups, ", "))
            parent = layout == "" ? src : src[layout]
            h5open(partial, "w") do dst
                target = dst
                if layout != ""
                    target = create_group(dst, layout)
                    foreach(name -> attrs(target)[name] = attrs(parent)[name], keys(attrs(parent)))
                end
                for group in groups
                    haskey(parent, group) || error("group $group not found in $source")
                    HDF5.copy_object(parent, group, target, group)
                end
                attrs(dst)["juleana_sync_groups"] = groups
                return attrs(dst)["juleana_sync_source"] = source
            end
        end
        mv(partial, destination; force = true)
    catch err
        rm(partial; force = true)
        error(source, ": ", sprint(showerror, err))
    end
    return (:extracted, Int(filesize(destination)), myid())
end

toml_value(x) = chopprefix(strip(sprint(TOML.print, Dict("v" => x))), "v = ")

function emit(; fields...)
    println("r = {", join(("$k = $(toml_value(v))" for (k, v) in fields), ", "), "}")
    return flush(stdout)
end

default_workers(nitems) = nitems < 4 ? 1 : min(8, nitems, Sys.CPU_THREADS ÷ 2)

function start_workers(n::Integer)
    ppt_worker_pool!(FlexWorkerPool(withmyid = false, label = "juleana-sync"))
    # The workers include this file for its functions; the sentinel keeps the entry point from running there.
    @always_everywhere begin
        const LOADED_AS_LIBRARY = true
        include($SCRIPT)
    end
    runworkers(OnLocalhost(n = n))
    return timedwait(() -> nprocs() > n, 300.0) == :ok || error("only $(nprocs() - 1) of $n workers started within 300 s")
end

# At most `n` files are in flight; once one fails, no consumer takes another.
function run_items(done, f, items::Vector, n::Integer)
    if n <= 1
        foreach(item -> done(item, f(item...)), items)
        return nothing
    end
    try
        start_workers(n)
        queue = Channel{eltype(items)}(length(items))
        foreach(item -> put!(queue, item), items)
        close(queue)
        failed = Threads.Atomic{Bool}(false)
        consumers = [Threads.@spawn(for item in queue
                                        failed[] && break
                                        try
                                            done(item, onworker(f, item...))
                                        catch
                                            failed[] = true
                                            rethrow()
                                        end
                                    end) for _ in 1:n]
        errors = Exception[]
        for task in consumers
            try
                wait(task)
            catch err
                push!(errors, err isa TaskFailedException ? err.task.exception : err)
            end
        end
        isempty(errors) || throw(first(errors))
    finally
        stopworkers()
    end
    return nothing
end

function main(args)
    valid = length(args) in (2, 4) && args[1] in ("inspect", "extract") &&
            (length(args) == 2 || (args[3] == "--jobs" && something(tryparse(Int, args[4]), 0) >= 1))
    valid || (println(stderr, "usage: extract.jl (inspect|extract) JOBFILE [--jobs N]"); return 2)
    command, jobfile = args[1], args[2]
    jobs = length(args) == 4 ? parse(Int, args[4]) : 0
    workers_for(list) = jobs > 0 ? min(jobs, length(list)) : default_workers(length(list))
    try
        spec = TOML.parsefile(jobfile)
        if command == "inspect"
            list = [(String(j["file"]), haskey(j, "groups") ? String.(j["groups"]) : nothing) for j in spec["job"]]
            run_items(inspect_file, list, workers_for(list)) do (file, requested), (names, sizes, layout)
                return emit(; event = "inspect", file, groups = names, bytes = sizes, layout)
            end
        else
            list = [(String(j["source"]), String.(j["groups"]), String(j["destination"])) for j in spec["job"]]
            n = workers_for(list)
            io_lock = ReentrantLock()
            counts = Dict(:extracted => 0, :skipped => 0)
            run_items(extract_file, list, n) do item, (status, bytes, worker)
                Base.@lock io_lock begin
                    counts[status] += 1
                    emit(event = "file", source = item[1], destination = item[3], status = String(status), groups = length(item[2]),
                         bytes = bytes, worker = worker)
                end
            end
            emit(event = "summary", files = length(list), extracted = counts[:extracted], skipped = counts[:skipped],
                 groups = sum(j -> length(j[2]), list; init = 0), workers = n <= 1 ? 0 : n)
        end
    catch err
        println(stderr, "extract.jl: ", sprint(showerror, err))
        return 1
    end
    return 0
end

!@isdefined(LOADED_AS_LIBRARY) && abspath(PROGRAM_FILE) == SCRIPT && exit(main(ARGS))
