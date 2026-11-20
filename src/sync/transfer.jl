# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# `warnings` is the standard error of rsync and the helper, never discarded (GNU rsync can warn and still exit 0).
struct TransferResult
    bytes::Int
    files::Int
    links::Int
    replaced_links::Int
    skipped::Vector{String}
    config::String
    warnings::String
    extracted_files::Int
    extracted_groups::Int
    extracted_bytes::Int
    conflicts::Vector{String}
    not_in_run::Vector{Tuple{String,String}}
end

# Apple's openrsync has neither `--info=progress2` nor a readable `--stats`, so it is rejected by name.
function check_rsync()
    line = String(first(eachsplit(read(pipeline(ignorestatus(`rsync --version`); stdin = devnull), String), '\n')))
    occursin("openrsync", line) &&
        throw(ErrorException("found Apple openrsync ($line), which has no --info=progress2 and no usable --stats. " *
                             "Install GNU rsync with `brew install rsync` and put it ahead of /usr/bin in PATH."))
    m = match(r"rsync\s+version\s+([0-9]+(?:\.[0-9]+)+)", line)
    m === nothing && throw(ErrorException("cannot read an rsync version from: $line"))
    version = VersionNumber(m[1])
    version >= v"3.1" ||
        throw(ErrorException("rsync $version is too old; this tool needs 3.1 or newer. Install one with `brew install rsync`."))
    return version
end

# Compares devices: a substring match against `mount` would accept an unmounted `/Volumes` whenever an unrelated mounted path
# starts with it.
function check_mount(p::Production)
    p.mount_root === nothing && throw(ArgumentError("no mount root configured; pass --mount-root to use link mode"))
    isdir(p.mount_root) || throw(ArgumentError("mount root $(p.mount_root) does not exist"))
    readdir(p.mount_root)
    p.mount_root == "/" || stat(p.mount_root).device != stat(dirname(p.mount_root)).device ||
        throw(ArgumentError("mount root $(p.mount_root) is not a mount point; mount the remote filesystem there first"))
    return p.mount_root
end

# `-r` is explicit because `--files-from` switches off the recursion `-a` implies; `--stats` is the only report of how many
# files rsync sent.
function rsync_command(h::RemoteHost, source_root::AbstractString, local_root::AbstractString, files_from::AbstractString; dry_run::Bool)
    # With `--files-from`, rsync resolves the file list against the trailing slash of the source.
    source = (h isa SSHHost ? "$(h.alias):" : "") * rstrip(source_root, '/') * "/"
    args = String["-r", "-l", "-t", "-p", "--partial-dir=.juleana-partial", "--stats", "--files-from=$files_from",
                  (h isa SSHHost ? rsync_transport(h) : String[])..., dry_run ? "--dry-run" : "--info=progress2", source,
                  rstrip(local_root, '/') * "/"]
    return addenv(`rsync $args`, "LC_ALL" => "C")    # fixes the digit grouping that parse_rsync_stats strips
end

function rsync_listed(command, rels::AbstractVector{<:AbstractString}, progress)
    return mktempdir() do dir
        path = joinpath(dir, "files.txt")
        write(path, join(rels, "\n") * "\n")
        return run_rsync(command(path), progress)
    end
end

const _progress_expr = r"([0-9,]+)\s+([0-9]+)%\s+(\S+)\s+([0-9]+:[0-9]{2}:[0-9]{2})"

function parse_progress(chunk::AbstractString)
    m = match(_progress_expr, chunk)
    return m === nothing ? nothing :
           (; bytes = parse(Int, replace(m[1], "," => "")), fraction = parse(Int, m[2]) / 100, rate = m[3], eta = m[4])
end

# A failing `progress` stops rsync (SIGTERM, SIGKILL after 10 s).
function run_rsync(cmd::Cmd, progress)
    on_line(text) = (reading = parse_progress(text); reading === nothing || progress(reading))
    return stream_command(cmd, progress === nothing ? Returns(nothing) : on_line; cr = true)
end

struct ExtractJob
    source::String
    destination::String
    relative::String
    groups::Vector{String}
end

staging_production_dir(staging::AbstractString, p::Production) = joinpath(staging, replace(p.name, '/' => '-'))

covered(rel, paths) = any(c -> rel == c || startswith(rel, c * "/"), paths)

# A file that `sel.copy` covers is copied whole and left out; the first file of each run decides which detectors it holds.
function plan_extraction(h::RemoteHost, p::Production, sel::Selection, staging::AbstractString; helper::HelperConfig = HelperConfig(),
                         jobs::Integer = 0, steps::Steps = NO_STEPS)
    steps("planning extraction")
    stage = staging_production_dir(staging, p)
    files_of = Dict{String,Vector{String}}()
    wanted = Dict{String,Set{String}}()
    periods = Tuple{ExtractEntry,Vector{String},Vector{String}}[]
    for entry in sel.extract
        dir = joinpath(p.remote_root, entry.dir)
        files = filekey_files(h, dir)
        if !isempty(files)
            files_of[entry.dir] = files
            union!(get!(Set{String}, wanted, entry.dir), entry.groups)
            continue
        end
        runs = [(joinpath(entry.dir, name), filekey_files(h, joinpath(dir, name))) for name in run_names(h, dir)]
        merge!(files_of, Dict(run => files for (run, files) in runs if !isempty(files)))
        with_files = [run for (run, files) in runs if !isempty(files)]
        isempty(with_files) &&
            throw(ErrorException("extract entry $(entry.dir) holds no filekey files and no run directory with filekey files"))
        push!(periods, (entry, with_files, [run for (run, files) in runs if isempty(files)]))
    end
    firsts = unique([first(files_of[run]) for (_, runs, _) in periods for run in runs])
    seen = 0
    inspected = isempty(firsts) ? Tuple{Vector{String},Vector{Int},String}[] :
                inspect_files(h, helper, firsts; jobs,
                              on_record = _ -> steps("planning extraction"; done = (seen += 1), total = length(firsts)))
    present_in = Dict(file => first(found) for (file, found) in zip(firsts, inspected))
    not_in_run = Tuple{String,String}[]
    for (entry, runs, empty_runs) in periods
        all(run -> isempty(present_in[first(files_of[run])]), runs) &&
            throw(ArgumentError("extract entry $(entry.dir): the tier has no per-detector groups"))
        append!(not_in_run, (run, group) for run in empty_runs for group in entry.groups)
        for run in runs, group in entry.groups
            group in present_in[first(files_of[run])] ? push!(get!(Set{String}, wanted, run), group) : push!(not_in_run, (run, group))
        end
    end
    plan = ExtractJob[]
    for run in sort!(collect(keys(wanted))), file in files_of[run]
        rel = joinpath(run, basename(file))
        destination = joinpath(stage, rel)
        startswith(destination, stage * "/") ||
            throw(ErrorException("extraction destination $destination is not below the staging directory $stage"))
        covered(rel, sel.copy) || push!(plan, ExtractJob(file, destination, rel, sort!(collect(wanted[run]))))
    end
    return plan, sort!(unique!(not_in_run))
end

function plan_bytes(h::RemoteHost, helper::HelperConfig, plan::Vector{ExtractJob}; jobs::Integer = 0, steps::Steps = NO_STEPS)
    steps("sizing extract groups"; total = length(plan))
    isempty(plan) && return 0
    seen = 0
    inspected = inspect_files(h, helper, [j.source for j in plan]; groups = [j.groups for j in plan], jobs,
                              on_record = _ -> steps("sizing extract groups"; done = (seen += 1), total = length(plan)))
    return sum(sum(bytes; init = 0) for (_, bytes) in inspected; init = 0)
end

# `nothing` for an HDF5 file without the attribute: a full copy.
function reduced_groups(path::AbstractString)
    try
        HDF5.h5open(path, "r") do f
            a = HDF5.attrs(f)
            return haskey(a, "juleana_sync_groups") ? String.(a["juleana_sync_groups"]) : nothing
        end
    catch err
        err isa InterruptException && rethrow()
        throw(ErrorException("cannot read $path as HDF5 ($(sprint(showerror, err))); remove the file before retrying"))
    end
end

# A reduced file runs with the union of both group lists; a full copy, or a symlink at or above the path, is a conflict,
# because a reduced file must never replace more data and rsync would write through the link.
function reconcile_local(p::Production, plan::Vector{ExtractJob})
    runnable, conflicts = ExtractJob[], String[]
    for job in plan
        path = to_local(p, job.source)
        walk = p.local_root
        linked = false
        for part in splitpath(job.relative)
            walk = joinpath(walk, part)
            linked |= islink(walk)
        end
        held = linked || !ispath(path) ? nothing : reduced_groups(path)
        if !linked && !ispath(path)
            push!(runnable, job)
        elseif held === nothing
            push!(conflicts, job.relative)
        else
            push!(runnable, ExtractJob(job.source, job.destination, job.relative, sort!(union(job.groups, held))))
        end
    end
    return runnable, conflicts
end

function plan_detector_files(h::RemoteHost, p::Production, sel::Selection; steps::Steps = NO_STEPS)
    modes = Dict{Tuple{String,String},Symbol}()
    for entry in sel.detector_files, name in entry.detectors
        get!(modes, (entry.dir, name), entry.mode) == entry.mode ||
            throw(ArgumentError("detector $name of $(entry.dir) is in a copy and a link entry"))
    end
    copies, links = String[], String[]
    not_in_run = Tuple{String,String}[]
    runs_of = [run_names(h, joinpath(p.remote_root, entry.dir)) for entry in sel.detector_files]
    total = sum(length, runs_of; init = 0)
    done = 0
    isempty(sel.detector_files) || steps("listing detector files"; total)
    for (entry, runs) in zip(sel.detector_files, runs_of)
        found = 0
        for run in runs
            files = detector_files(h, joinpath(p.remote_root, entry.dir, run), joinpath(entry.dir, run))
            found += length(files)
            for name in entry.detectors
                haskey(files, name) || (push!(not_in_run, (joinpath(entry.dir, run), name)); continue)
                rel = joinpath(entry.dir, run, files[name].name)
                covered(rel, sel.copy) || (entry.mode == :copy ? push!(copies, rel) : covered(rel, sel.link) || push!(links, rel))
            end
            steps("listing detector files"; done = (done += 1), total)
        end
        found == 0 && throw(ArgumentError("detector file entry $(entry.dir): no run directory holds per-detector files"))
    end
    return sort!(unique!(copies)), sort!(unique!(links)), sort!(unique!(not_in_run))
end

# Only symlinks go: a regular file or a directory there is data, which the tool never deletes.
function remove_stale_links!(p::Production, sel::Selection)
    removed = 0
    for rel in sel.copy
        path = p.local_root
        for part in splitpath(rel)
            path = joinpath(path, part)
            if islink(path)
                rm(path)
                removed += 1
                break
            end
        end
    end
    return removed
end

# Real data at the target is kept and recorded in `skipped`; a link the tool made before may be replaced.
function link_path!(h::RemoteHost, p::Production, rel::AbstractString, copies::Set{String}, skipped::Vector{String})
    rel in copies && return 0
    remote = joinpath(p.remote_root, rel)
    target = to_local(p, remote)
    if !any(c -> startswith(c, rel * "/"), copies)
        if islink(target)
            rm(target)
        elseif ispath(target)
            push!(skipped, rel)
            return 0
        end
        mkpath(dirname(target))
        symlink(normdir(joinpath(p.mount_root, rel)), target)
        return 1
    end
    mkpath(target)
    return sum(entry -> link_path!(h, p, joinpath(rel, entry.name), copies, skipped), list_dir(h, remote); init = 0)
end

"""
    apply!(h, p, sel; dry_run = false, helper = HelperConfig(), jobs = 0, report = nothing,
           steps = Steps(apply_steps(sel; dry_run), report))

Bring the mirror in line with `sel`. With `dry_run` it only asks rsync what would move, inspects the files to extract with
the remote helper and returns an `Estimate`; otherwise it transfers, creates the links, writes `config_local.yaml` and
returns a `TransferResult`. Extract entries are reduced on the host by the helper into a staging directory, pulled with
rsync and removed from staging again; a failure once the helper has started keeps the staged files for a resumed run.
`report` receives a `StepProgress` per reading of each step.
"""
function apply!(h::RemoteHost, p::Production, sel::Selection; dry_run::Bool = false, helper::HelperConfig = HelperConfig(),
                jobs::Integer = 0, report = nothing, steps::Steps = Steps(apply_steps(sel; dry_run), report))
    check_rsync()
    isdir(p.local_root) || error("local root $(p.local_root) does not exist")
    mktemp((_, _) -> nothing, p.local_root)
    detector_copies, detector_links, detector_absent = plan_detector_files(h, p, sel; steps)
    resolved = Selection(sel.host, sel.production, sel.remote_root, sel.local_root, sel.mount_root, sort!(union(sel.copy, detector_copies)),
                         sort!(union(sel.link, detector_links)), sel.created, sel.extract, sel.detector_files)
    isempty(resolved.link) || check_mount(p)
    staging, plan, extract_absent = "", ExtractJob[], Tuple{String,String}[]
    if !isempty(sel.extract)
        status = ensure_environment(h, helper)
        environment_ready(status) || throw(ErrorException(environment_problem(status, h, helper)))
        staging = staging_dir(h, helper)
        plan, extract_absent = plan_extraction(h, p, sel, staging; helper, jobs, steps)
    end
    not_in_run = sort!(unique!(vcat(extract_absent, detector_absent)))
    if dry_run
        extract_bytes = isempty(sel.extract) ? 0 : plan_bytes(h, helper, plan; jobs, steps)
        steps("checking files to copy")
        out, _ = rsync_listed(path -> rsync_command(h, p.remote_root, p.local_root, path; dry_run = true), resolved.copy, nothing)
        estimate = parse_rsync_stats(out, length(resolved.link))
        return Estimate(estimate.bytes, estimate.files, estimate.links, true, extract_bytes, length(plan), true, not_in_run)
    end

    plan, conflicts = reconcile_local(p, plan)
    if !isempty(plan)
        free, needed = free_bytes(h, make_dir(h, staging)), 1.05 * plan_bytes(h, helper, plan; jobs, steps)
        needed <= free ||
            throw(ErrorException("staging directory $staging has $(format_bytes(free)) free but the extraction needs about " *
                                 "$(format_bytes(ceil(Int, needed))); set \"staging\" for this host in " *
                                 "$(joinpath(config_dir(), "hosts.yaml")) or pass --staging"))
    end
    rsync_reading(name) = r -> steps(name; done = round(Int, 100 * r.fraction), total = 100, bytes = r.bytes,
                                     detail = "$(r.rate)  ETA $(r.eta)")
    warnings = String[]
    pulled = Estimate(0, 0, 0, true)
    replaced = 0
    in_mirror = false
    try
        if !isempty(plan)
            spec = Dict("job" => [Dict("source" => j.source, "groups" => j.groups, "destination" => j.destination) for j in plan])
            done = staged_bytes = 0
            steps("extracting on the host"; total = length(plan))
            run_helper(h, helper, "extract", spec; jobs, warn = text -> push!(warnings, text),
                       on_record = function (record)
                           record["event"] == "file" || return
                           done += 1
                           staged_bytes += record["bytes"]
                           return steps("extracting on the host"; done, total = length(plan), bytes = staged_bytes)
                       end)
        end
        replaced = remove_stale_links!(p, resolved)
        steps("copying"; total = 100)
        out, copy_warnings = rsync_listed(path -> rsync_command(h, p.remote_root, p.local_root, path; dry_run = false), resolved.copy,
                                          rsync_reading("copying"))
        push!(warnings, copy_warnings)
        if !isempty(plan)
            # The mirror may have changed since the plan was checked.
            again, changed = reconcile_local(p, plan)
            isempty(changed) || error("the local mirror changed during the extraction; full copy or symlink now at: ", join(changed, ", "))
            steps("pulling extracted files"; total = 100)
            pull_out, pull_warnings = rsync_listed(path -> rsync_command(h, staging_production_dir(staging, p), p.local_root, path;
                                                                         dry_run = false),
                                                   [j.relative for j in again], rsync_reading("pulling extracted files"))
            pulled = parse_rsync_stats(pull_out, 0)
            push!(warnings, pull_warnings)
        end
        in_mirror = true
        moved = parse_rsync_stats(out, length(resolved.link))
        steps("creating links")
        skipped, copies = String[], Set(resolved.copy)
        created = sum(rel -> link_path!(h, p, rel, copies, skipped), resolved.link; init = 0)
        config = write_local_config(p)
        isempty(plan) || (steps("cleaning up staging"); remove_staged!(h, staging, [j.destination for j in plan]))
        return TransferResult(moved.bytes, moved.files, created, replaced, skipped, config, join(filter(!isempty, warnings), "\n"),
                              length(plan),
                              sum(j -> length(j.groups), plan; init = 0), pulled.bytes, conflicts, not_in_run)
    catch err
        (isempty(plan) || err isa InterruptException || err isa SyncStopped) && rethrow()
        throw(ErrorException(sprint(showerror, err) *
                             (in_mirror ? "\nthe reduced files are already in the local mirror; the staged copies were kept in $staging" :
                              "\nreduced files already staged were kept in $staging; running the same selection again resumes from them")))
    end
end

function apply_steps(sel::Selection; dry_run::Bool)
    extract = !isempty(sel.extract)
    return String[isempty(sel.detector_files) ? String[] : ["listing detector files"];
                  extract ? ["planning extraction", "sizing extract groups"] : String[];
                  dry_run ? ["checking files to copy"] :
                  [extract ? ["extracting on the host"] : String[]; "copying"; extract ? ["pulling extracted files"] : String[];
                   "creating links";
                   extract ? ["cleaning up staging"] : String[]]]
end

"""
    estimate_selection(h, p, sel; helper = HelperConfig(), jobs = 0, report = nothing)

The dry run of [`apply!`](@ref) and, when `sel` has extract entries, the free space of the staging directory. Returns
`(; estimate, staging, free)`; the last two are `nothing` without extract entries.
"""
function estimate_selection(h::RemoteHost, p::Production, sel::Selection; helper::HelperConfig = HelperConfig(), jobs::Integer = 0,
                            report = nothing)
    extract = !isempty(sel.extract)
    steps = Steps(vcat(apply_steps(sel; dry_run = true), extract ? ["staging free space"] : String[]), report)
    estimate = apply!(h, p, sel; dry_run = true, helper, jobs, steps)
    extract || return (; estimate, staging = nothing, free = nothing)
    steps("staging free space")
    staging = staging_dir(h, helper)
    existing = staging
    while !remote_test(h, "-d", existing)
        existing = dirname(existing)
    end
    return (; estimate, staging, free = free_bytes(h, existing))
end

function summary_text(r::TransferResult)
    lines = ["transferred $(format_bytes(r.bytes)) in $(r.files) files",
             "created $(r.links) links, replaced $(r.replaced_links) stale ones"]
    isempty(r.skipped) || push!(lines, "kept existing data at $(length(r.skipped)) link targets: " * join(r.skipped, ", "))
    r.extracted_files == 0 ||
        push!(lines, "extracted $(r.extracted_files) files, $(r.extracted_groups) groups ($(format_bytes(r.extracted_bytes)) transferred)")
    isempty(r.conflicts) ||
        push!(lines,
              "kept $(length(r.conflicts)) existing files instead of extracting (full copies or symlinks): " * join(r.conflicts, ", "))
    isempty(r.not_in_run) || push!(lines, "not in run, left out: " * format_not_in_run(r.not_in_run))
    isempty(r.warnings) || push!(lines, "rsync warnings:\n$(r.warnings)")
    push!(lines, "export LEGEND_DATA_CONFIG=$(r.config)")
    return join(lines, "\n")
end
