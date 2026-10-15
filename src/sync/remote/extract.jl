# Remote helper of the sync tool: lists and extracts the detector groups of LEGEND
# HDF5 files, which store them either as top-level groups (`<detector>/<tier>`) or as
# the children of a single top-level tier group (`<tier>/<detector>`). It needs only
# HDF5 and ParallelProcessingTools; jobs are read from a TOML file and every result
# is one line of TOML on standard output.
#
#     julia --project=ENV extract.jl inspect JOBFILE [--jobs N]
#     julia --project=ENV extract.jl extract JOBFILE [--jobs N]

# The helper does no linear algebra. One BLAS thread per process keeps a master and its
# workers well below the per-user thread limits of login nodes; workers inherit the
# setting. It must precede the packages below, which load LinearAlgebra.
ENV["OPENBLAS_NUM_THREADS"] = "1"
using Distributed
using HDF5
using ParallelProcessingTools
using TOML

const SCRIPT = abspath(@__FILE__)

# Groups and datasets are summed through their stored size; any other object
# (a named datatype) holds no data.
storage_bytes(dset::HDF5.Dataset) = Int(HDF5.API.h5d_get_storage_size(dset))
storage_bytes(group::HDF5.Group) = sum(name -> storage_bytes(group[name]), keys(group); init = 0)
storage_bytes(::Any) = 0

# Mirror the DetectorId and ChannelId name patterns of LegendDataManagement (src/filekey.jl): the
# helper runs without that package.
const DETECTOR_ID = r"^(?:[BCPV][0-9]{5}[A-P]|S[0-9]{3}|PMT[0-9]{3}|PULS[0-9]{2}(?:ANA)?|AUX[0-9]{2}|DUMMY[0-9]{1,2}|BSLN[0-9]{2}|MUON[0-9]{2}|C00ANG[0-9]|C000RG[0-9])$"
const CHANNEL_ID = r"^ch(?:[0-9]{3}|(?:0[1-9]|[1-9][0-9])[0-9]{5})$"

# Where the detector groups of the open file `f` live: "" when at least one top-level
# group is a detector name (all top-level groups are then the detector rows, including
# auxiliary ones), the name of the tier group when the file has exactly one top-level
# group and at least one of its children is a detector name, and nothing when the file
# has no detector axis.
function detector_parent(f)
    tops = collect(String, keys(f))
    any(name -> occursin(DETECTOR_ID, name) || occursin(CHANNEL_ID, name), tops) && return ""
    if length(tops) == 1 && f[only(tops)] isa HDF5.Group
        any(name -> occursin(DETECTOR_ID, name) || occursin(CHANNEL_ID, name), keys(f[only(tops)])) && return only(tops)
    end
    nothing
end

# Detector names, their stored bytes and the enclosing group ("" for top-level
# detectors). A file without a detector axis reports no detectors. With `groups`
# (nothing sizes every group), only those groups are sized and the bytes are in the
# order of `groups`; a requested group the file lacks is an error.
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
        names, [storage_bytes(parent[name]) for name in sized], layout
    end
end

# The return type is concrete because `onworker` converts the remote result to
# the inferred return type.
# The destination is never the source. An existing destination that cannot be read
# as HDF5, or that is not a reduced file written by this tool, stops the job; it is
# never overwritten silently. The result also carries the id of the process that ran it.
# `groups` are detector names; for a file in the tier/detector layout they are copied
# below a `<tier>` group that carries the source group's attributes.
function extract_file(source::String, groups::Vector{String}, destination::String)::Tuple{Symbol,Int,Int}
    destination == source && error(source, ": destination ", destination, " is the source ", source)
    if isfile(destination)
        held = try
            h5open(destination, "r") do f
                haskey(attrs(f), "juleana_sync_groups") ? String.(attrs(f)["juleana_sync_groups"]) : nothing
            end
        catch err
            error(source, ": cannot read existing destination ", destination, ": ", sprint(showerror, err))
        end
        held === nothing && error(source, ": existing destination ", destination,
                                  " is not a reduced file written by this tool")
        held == groups && mtime(source) <= mtime(destination) &&
            return (:skipped, Int(filesize(destination)), myid())
    end
    mkpath(dirname(destination))
    # The final name only ever holds a complete file, so an interrupted run
    # leaves nothing the skip rule above could mistake for a finished file.
    partial = destination * ".partial"
    try
        h5open(source, "r") do src
            layout = detector_parent(src)
            layout === nothing && error("no detector axis, cannot extract ", join(groups, ", "))
            parent = layout == "" ? src : src[layout]
            h5open(partial, "w") do dst
                target = dst
                if layout != ""
                    # The reduced file keeps the tier group, with the attributes of the source's.
                    target = create_group(dst, layout)
                    for name in keys(attrs(parent))
                        attrs(target)[name] = attrs(parent)[name]
                    end
                end
                for group in groups
                    haskey(parent, group) || error("group $group not found in $source")
                    HDF5.copy_object(parent, group, target, group)
                end
                attrs(dst)["juleana_sync_groups"] = groups
                attrs(dst)["juleana_sync_source"] = source
            end
        end
        mv(partial, destination; force = true)
    catch err
        rm(partial; force = true)
        # The message leads with the source so a failure on a worker names its file.
        error(source, ": ", sprint(showerror, err))
    end
    (:extracted, Int(filesize(destination)), myid())
end

# TOML's own encoder formats the values, so strings are escaped correctly.
toml_value(x) = chopprefix(strip(sprint(TOML.print, Dict("v" => x))), "v = ")

function emit(; fields...)
    println("r = {", join(("$k = $(toml_value(v))" for (k, v) in fields), ", "), "}")
    flush(stdout)
end

default_workers(nitems) = nitems < 4 ? 1 : min(8, nitems, Sys.CPU_THREADS ÷ 2)

function start_workers(n::Integer)
    ppt_worker_pool!(FlexWorkerPool(withmyid = false, label = "juleana-sync"))
    # The workers include this file to get its functions. The sentinel keeps the
    # entry point at the bottom from running there (and again in this process).
    @always_everywhere begin
        const LOADED_AS_LIBRARY = true
        include($SCRIPT)
    end
    runworkers(OnLocalhost(n = n))
    timedwait(() -> nprocs() > n, 300.0) == :ok ||
        error("only $(nprocs() - 1) of $n workers started within 300 s")
end

# Call `done(item, f(item...))` for every item, in the main process for `n <= 1`
# and on `n` workers otherwise. `n` consumer tasks take items from a channel, so
# at most `n` files are in flight; once one fails, no consumer takes another item.
# Files already written stay for a resumed run.
function run_items(done, f, items::Vector, n::Integer)
    if n <= 1
        for item in items
            done(item, f(item...))
        end
        return nothing
    end
    try
        start_workers(n)
        queue = Channel{eltype(items)}(length(items))
        foreach(item -> put!(queue, item), items)
        close(queue)
        failed = Threads.Atomic{Bool}(false)
        consumers = [Threads.@spawn(begin
                         for item in queue
                             failed[] && break
                             try
                                 done(item, onworker(f, item...))
                             catch
                                 failed[] = true
                                 rethrow()
                             end
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
    nothing
end

function main(args)
    usage = "usage: extract.jl (inspect|extract) JOBFILE [--jobs N]"
    valid = length(args) in (2, 4) && args[1] in ("inspect", "extract") &&
            (length(args) == 2 ||
             (args[3] == "--jobs" && something(tryparse(Int, args[4]), 0) >= 1))
    valid || (println(stderr, usage); return 2)
    command, jobfile = args[1], args[2]
    jobs = length(args) == 4 ? parse(Int, args[4]) : 0
    try
        spec = TOML.parsefile(jobfile)
        if command == "inspect"
            # `files` lists files whose groups are all sized; each `job` entry names a
            # file and, optionally, the only groups to size.
            list = Tuple{String,Union{Nothing,Vector{String}}}[(String(f), nothing) for f in get(spec, "files", [])]
            for j in get(spec, "job", [])
                push!(list, (String(j["file"]), haskey(j, "groups") ? String.(j["groups"]) : nothing))
            end
            n = jobs > 0 ? min(jobs, length(list)) : default_workers(length(list))
            run_items(inspect_file, list, n) do item, (names, sizes, layout)
                if item[2] === nothing
                    emit(event = "inspect", file = item[1], groups = names, bytes = sizes, layout = layout)
                else
                    emit(event = "inspect", file = item[1], groups = names, sized = item[2],
                         bytes = sizes, layout = layout)
                end
            end
        else
            list = [(String(j["source"]), String.(j["groups"]), String(j["destination"]))
                    for j in spec["job"]]
            n = jobs > 0 ? min(jobs, length(list)) : default_workers(length(list))
            io_lock = ReentrantLock()
            counts = Dict(:extracted => 0, :skipped => 0)
            run_items(extract_file, list, n) do item, (status, bytes, worker)
                Base.@lock io_lock begin
                    counts[status] += 1
                    emit(event = "file", source = item[1], destination = item[3],
                         status = String(status), groups = length(item[2]), bytes = bytes,
                         worker = worker)
                end
            end
            emit(event = "summary", files = length(list), extracted = counts[:extracted],
                 skipped = counts[:skipped], groups = sum(j -> length(j[2]), list; init = 0),
                 workers = n <= 1 ? 0 : n)
        end
    catch err
        println(stderr, "extract.jl: ", sprint(showerror, err))
        return 1
    end
    0
end

!@isdefined(LOADED_AS_LIBRARY) && abspath(PROGRAM_FILE) == SCRIPT && exit(main(ARGS))
