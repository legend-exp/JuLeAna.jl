"""
    Progress(bytes, fraction, rate, eta)

One reading from `rsync --info=progress2`.
"""
struct Progress
    bytes::Int
    fraction::Float64
    rate::String
    eta::String
end

"""
    TransferResult

What an [`apply!`](@ref) did. `skipped` lists the link targets that were left
alone because real data already stood there. `warnings` holds rsync's and the
remote helper's standard error text, which is never discarded: GNU rsync can print
a warning (for example about a file that vanished mid-transfer) while still
exiting 0. It is `""` when nothing was printed.

`extracted_files` and `extracted_groups` count the reduced files pulled from the
staging directory and the HDF5 groups in them, `extracted_bytes` the bytes rsync
moved for them, and `conflicts` the relative paths that were not extracted because
a full local copy or a link stands there. `not_in_run` lists the
`(run directory, detector)` pairs a period entry named but the run does not hold.
"""
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

TransferResult(bytes, files, links, replaced_links, skipped, config, warnings) =
    TransferResult(bytes, files, links, replaced_links, skipped, config, warnings,
                   0, 0, 0, String[], Tuple{String,String}[])

"""
    check_rsync()::VersionNumber

The version of the `rsync` on `PATH`, or an error explaining how to get a usable
one. Apple's openrsync has neither `--info=progress2` nor a `--stats` this tool
can read, so it is rejected by name rather than being discovered mid-transfer.
"""
function check_rsync()
    out = read(pipeline(ignorestatus(`rsync --version`); stdin = devnull), String)
    line = String(first(eachsplit(out, '\n')))
    occursin("openrsync", line) && throw(ErrorException(
        "found Apple openrsync ($line), which has no --info=progress2 and no usable --stats. " *
        "Install GNU rsync with `brew install rsync` and put it ahead of /usr/bin in PATH."))
    m = match(r"rsync\s+version\s+([0-9]+(?:\.[0-9]+)+)", line)
    m === nothing && throw(ErrorException("cannot read an rsync version from: $line"))
    version = VersionNumber(m[1])
    version >= v"3.1" || throw(ErrorException(
        "rsync $version is too old; this tool needs 3.1 or newer. Install one with `brew install rsync`."))
    version
end

"""
    check_mount(p::Production)::String

The mount root, once it is known to be mounted: a readable directory whose
device differs from its parent's, or the filesystem root `/` itself. Link mode
points symlinks into a filesystem the user mounted; without it every link
would dangle from the moment it was created. A substring match against `mount`'s
output would accept an unmounted directory such as `/Volumes` whenever some
unrelated mounted path happens to contain it as a prefix, so the check instead
compares device numbers.
"""
function check_mount(p::Production)
    p.mount_root === nothing && throw(ArgumentError(
        "no mount root configured; pass --mount-root to use link mode"))
    isdir(p.mount_root) || throw(ArgumentError(
        "mount root $(p.mount_root) does not exist"))
    readdir(p.mount_root)  # throws on its own if the directory is not readable
    mounted = p.mount_root == "/" ||
              stat(p.mount_root).device != stat(dirname(p.mount_root)).device
    mounted || throw(ArgumentError(
        "mount root $(p.mount_root) is not a mount point; mount the remote filesystem there first"))
    p.mount_root
end

"""
    rsync_command(h::RemoteHost, source_root, local_root, files_from; dry_run::Bool)::Cmd

The one rsync invocation the tool makes, from `source_root` on `h` into `local_root`; the form that takes a `Production` uses its roots. `-r` is explicit because `--files-from`
switches off the recursion `-a` would imply, and without it a selected directory
arrives empty. `-l` copies a remote symlink (such as a `current` pointer) as a
symlink; without it rsync silently omits symlinks from the transfer. `--stats`
is on in both modes: it is the only place rsync reports how many files it sent.
"""
function rsync_command(h::RemoteHost, source_root::AbstractString, local_root::AbstractString,
                       files_from::AbstractString; dry_run::Bool)
    args = String["-r", "-l", "-t", "-p", "--partial-dir=.juleana-partial", "--stats",
                  "--files-from=$files_from"]
    push!(args, dry_run ? "--dry-run" : "--info=progress2")
    push!(args, rsync_source(h, source_root), rstrip(local_root, '/') * "/")
    # LC_ALL fixes the digit grouping in --stats, which parse_rsync_stats strips.
    addenv(`rsync $args`, "LC_ALL" => "C")
end

rsync_command(h::RemoteHost, p::Production, files_from::AbstractString; dry_run::Bool) =
    rsync_command(h, p.remote_root, p.local_root, files_from; dry_run)

# Run `command(list_file)` where `list_file` holds the relative paths `rels`.
function rsync_listed(command, rels::AbstractVector{<:AbstractString}, progress)
    mktempdir() do dir
        path = joinpath(dir, "files.txt")
        write(path, join(rels, "\n") * "\n")
        run_rsync(command(path), progress)
    end
end

const _progress_expr = r"([0-9,]+)\s+([0-9]+)%\s+(\S+)\s+([0-9]+:[0-9]{2}:[0-9]{2})"

"""
    parse_progress(chunk::AbstractString)::Union{Nothing,Progress}

One `--info=progress2` reading, or `nothing` for a line that is not one.
"""
function parse_progress(chunk::AbstractString)
    m = match(_progress_expr, chunk)
    m === nothing && return nothing
    Progress(parse(Int, replace(m[1], "," => "")), parse(Int, m[2]) / 100,
             String(m[3]), String(m[4]))
end

# Run rsync, feed every progress reading to `progress`, and return
# (stdout, stderr) so the --stats block can be parsed and any warning rsync
# printed can be reported. GNU rsync can exit 0 while still writing a warning
# to stderr (for example about a file that vanished mid-transfer), so stderr is
# read and returned rather than discarded on the success path. Progress
# readings are separated by carriage returns, not newlines. rsync reads no
# terminal input: its stdin is /dev/null, and the ssh transport it starts talks
# to rsync over its own pipe.
function run_rsync(cmd::Cmd, progress)
    errfile = tempname()
    transcript = IOBuffer()
    chunk = IOBuffer()
    proc = open(pipeline(ignorestatus(cmd); stdin = devnull, stderr = errfile), "r")
    while !eof(proc)
        c = read(proc, Char)
        if c == '\r' || c == '\n'
            text = String(take!(chunk))
            println(transcript, text)
            if progress !== nothing
                reading = parse_progress(text)
                reading === nothing || progress(reading)
            end
        else
            write(chunk, c)
        end
    end
    println(transcript, String(take!(chunk)))
    wait(proc)
    stderr_text = read(errfile, String)
    rm(errfile; force = true)
    success(proc) || throw(ErrorException(
        "rsync failed with exit code $(proc.exitcode): $cmd\n$stderr_text"))
    String(take!(transcript)), stderr_text
end

"""
    ExtractJob(source, destination, relative, groups)

One file to reduce: `source` is its absolute path on the host, `destination` the
absolute path of the reduced file in the staging tree, `relative` the path
relative to the remote root (which is also the path in the local mirror), and
`groups` the top-level HDF5 groups to keep.
"""
struct ExtractJob
    source::String
    destination::String
    relative::String
    groups::Vector{String}
end

"""
    staging_production_dir(staging::AbstractString, p::Production)::String

The directory of the staging tree that mirrors the remote root for `p`; rsync with
this directory as its source recreates the mirror layout.
"""
staging_production_dir(staging::AbstractString, p::Production) =
    joinpath(staging, replace(p.name, '/' => '-'))

"""
    plan_extraction(h, p, sel, staging; helper = HelperConfig(), jobs = 0)

The extraction jobs for `sel` and the `(run directory, detector)` pairs left out,
both ordered. An entry whose directory holds filekey files is a run entry and is
taken as it is. Any other entry is a period entry: it expands to its run
directories that hold filekey files (a run directory without any is recorded as
holding none of the requested detectors), the first filekey file of each is inspected
(one helper call for all period entries), a requested detector that file lacks is
recorded and left out of that run's job, and a run that holds none of the requested
detectors gets no job. Entries are merged per run by union of their detectors, and
there is one job per filekey file in name order. A file that `sel.copy` already
covers, as itself or through a directory above it, is copied whole and left out.
"""
function plan_extraction(h::RemoteHost, p::Production, sel::Selection, staging::AbstractString;
                         helper::HelperConfig = HelperConfig(), jobs::Integer = 0)
    covered(rel) = any(c -> rel == c || startswith(rel, c * "/"), sel.copy)
    stage = staging_production_dir(staging, p)
    files_of = Dict{String,Vector{String}}()      # run directory (relative) => its filekey files
    wanted = Dict{String,Set{String}}()           # run directory (relative) => detectors to take
    periods = Tuple{ExtractEntry,Vector{String},Vector{String}}[]   # entry, runs with files, runs without
    for entry in sel.extract
        dir = joinpath(p.remote_root, entry.dir)
        files = filekey_files(h, dir)
        if !isempty(files)
            files_of[entry.dir] = files
            union!(get!(Set{String}, wanted, entry.dir), entry.groups)
            continue
        end
        runs = String[]
        empty_runs = String[]
        for e in sort!(list_dir(h, dir); by = e -> e.name)
            (e.kind == :dir && occursin(RUN_DIR_EXPR, e.name)) || continue
            run_files = filekey_files(h, joinpath(dir, e.name))
            if isempty(run_files)
                push!(empty_runs, joinpath(entry.dir, e.name))
                continue
            end
            files_of[joinpath(entry.dir, e.name)] = run_files
            push!(runs, joinpath(entry.dir, e.name))
        end
        isempty(runs) && throw(ErrorException(
            "extract entry $(entry.dir) holds no filekey files and no run directory with filekey files"))
        push!(periods, (entry, runs, empty_runs))
    end
    firsts = unique([first(files_of[run]) for (_, runs, _) in periods for run in runs])
    inspected = isempty(firsts) ? Tuple{Vector{String},Vector{Int},String}[] :
                inspect_files(h, helper, firsts; jobs)
    present_in = Dict(file => first(found) for (file, found) in zip(firsts, inspected))
    for (entry, runs, _) in periods
        all(run -> isempty(present_in[first(files_of[run])]), runs) && throw(ArgumentError(
            "extract entry $(entry.dir): the tier has no per-detector groups"))
    end
    not_in_run = Tuple{String,String}[]
    for (entry, _, empty_runs) in periods, run in empty_runs, group in entry.groups
        push!(not_in_run, (run, group))
    end
    for (entry, runs, _) in periods, run in runs
        present = present_in[first(files_of[run])]
        for group in entry.groups
            if group in present
                push!(get!(Set{String}, wanted, run), group)
            else
                push!(not_in_run, (run, group))
            end
        end
    end
    plan = ExtractJob[]
    for run in sort!(collect(keys(wanted)))
        groups = sort!(collect(wanted[run]))
        for file in files_of[run]
            rel = joinpath(run, basename(file))
            destination = joinpath(stage, rel)
            startswith(destination, stage * "/") || throw(ErrorException(
                "extraction destination $destination is not below the staging directory $stage"))
            covered(rel) || push!(plan, ExtractJob(file, destination, rel, groups))
        end
    end
    plan, sort!(unique!(not_in_run))
end

"""
    plan_bytes(h::RemoteHost, helper::HelperConfig, plan::Vector{ExtractJob}; jobs = 0)::Int

The summed stored size of the groups the jobs of `plan` take, from inspecting
every source file with the remote helper. A group that is not in its file is an
error.
"""
function plan_bytes(h::RemoteHost, helper::HelperConfig, plan::Vector{ExtractJob}; jobs::Integer = 0)
    isempty(plan) && return 0
    plan_group_bytes(plan, inspect_files(h, helper, [j.source for j in plan]; jobs))
end

"""
    plan_group_bytes(plan::Vector{ExtractJob}, inspected)::Int

The summed stored size of the groups each job of `plan` takes, given the
`inspect_files` result for the same files in the same order. A result of a different
length, or a group that is not in its file, is an error.
"""
function plan_group_bytes(plan::Vector{ExtractJob}, inspected)
    length(inspected) == length(plan) || throw(ErrorException(
        "inspected $(length(inspected)) files for a plan of $(length(plan)) jobs"))
    total = 0
    for i in eachindex(plan, inspected)
        job = plan[i]
        names, bytes = inspected[i]
        for group in job.groups
            k = findfirst(==(group), names)
            k === nothing && throw(ErrorException("group $group is not in $(job.source)"))
            total += bytes[k]
        end
    end
    total
end

"""
    prepare_extraction(h, p, sel, helper; jobs = 0)

The staging directory, the extraction plan for `sel` and the pairs left out of it
(see [`plan_extraction`](@ref)), once the helper environment on `h` is known to be
ready.
"""
function prepare_extraction(h::RemoteHost, p::Production, sel::Selection, helper::HelperConfig;
                            jobs::Integer = 0)
    status = ensure_environment(h, helper)
    environment_ready(status) || throw(ErrorException(environment_problem(status, h, helper)))
    staging = staging_dir(h, helper)
    plan, not_in_run = plan_extraction(h, p, sel, staging; helper, jobs)
    staging, plan, not_in_run
end

"""
    ExtractProgress(done, total, bytes)

Reduced files finished, of `total`, and the bytes written to the staging directory
so far.
"""
struct ExtractProgress
    done::Int
    total::Int
    bytes::Int
end

# Reduced files carry HDF5 metadata beyond the stored dataset sizes.
const STAGING_MARGIN = 1.05

"""
    check_staging_space(staging, free, needed)::Nothing

Throw when `needed` bytes of reduced files, with [`STAGING_MARGIN`](@ref), do not
fit into `free` bytes.
"""
function check_staging_space(staging::AbstractString, free::Integer, needed::Integer)
    ceil(Int, STAGING_MARGIN * needed) <= free && return nothing
    throw(ErrorException(
        "staging directory $staging has $(format_bytes(free)) free but the extraction needs about " *
        "$(format_bytes(needed)); set \"staging\" for this host in config/sync/hosts.json or pass --staging"))
end

"""
    reduced_groups(path::AbstractString)::Union{Nothing,Vector{String}}

The groups a reduced file holds, from its `juleana_sync_groups` root attribute, or
`nothing` for an HDF5 file that has none, which is a full copy.
"""
function reduced_groups(path::AbstractString)
    try
        HDF5.h5open(path, "r") do f
            a = HDF5.attrs(f)
            haskey(a, "juleana_sync_groups") ? String.(a["juleana_sync_groups"]) : nothing
        end
    catch err
        err isa InterruptException && rethrow()
        throw(ErrorException("cannot read $path as HDF5 ($(sprint(showerror, err))); " *
                             "remove the file before retrying"))
    end
end

"""
    reconcile_local(p::Production, plan::Vector{ExtractJob})::Tuple{Vector{ExtractJob},Vector{String}}

Split `plan` into the jobs that may run and the relative paths that conflict with
what is in the mirror. Nothing at the path: the job runs. A reduced file from an
earlier extraction: the job runs with the union of both group lists, so a later
extraction never loses groups. A full copy, or a symlink at the path or at any
directory above it: a conflict, because a reduced file must never replace more
data and rsync would write through the link.
"""
function reconcile_local(p::Production, plan::Vector{ExtractJob})
    runnable = ExtractJob[]
    conflicts = String[]
    for job in plan
        path = to_local(p, job.source)
        walk = p.local_root
        linked = false
        for part in splitpath(job.relative)
            walk = joinpath(walk, part)
            linked |= islink(walk)
        end
        if !linked && !ispath(path)
            push!(runnable, job)
            continue
        end
        held = linked ? nothing : reduced_groups(path)
        if held === nothing
            push!(conflicts, job.relative)
        else
            push!(runnable, ExtractJob(job.source, job.destination, job.relative,
                                       sort!(union(job.groups, held))))
        end
    end
    runnable, conflicts
end

"""
    rsync_dry_run(h::RemoteHost, p::Production, sel::Selection)::Estimate

What the transfer would actually move, given what is already in the mirror.
"""
function rsync_dry_run(h::RemoteHost, p::Production, sel::Selection)
    out, _ = rsync_listed(path -> rsync_command(h, p, path; dry_run = true), sel.copy, nothing)
    parse_rsync_stats(out, length(sel.link))
end

"""
    remove_stale_links!(p::Production, sel::Selection)::Int

Remove symlinks standing where copies are about to land, and return how many.
Only symlinks are removed: a regular file or a directory at the same path is
data, and the tool never deletes data.
"""
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
    removed
end

function link_path!(h::RemoteHost, p::Production, rel::AbstractString,
                    copies::Set{String}, skipped::Vector{String})
    # A path that is itself copied belongs to rsync: it gets no link, and
    # descending into it would treat a regular file as a directory.
    rel in copies && return 0
    remote = joinpath(p.remote_root, rel)
    target = to_local(p, remote)
    if !any(c -> c == rel || startswith(c, rel * "/"), copies)
        # A link the tool put here before may be replaced; anything else stays.
        if islink(target)
            rm(target)
        elseif ispath(target)
            push!(skipped, rel)
            return 0
        end
        mkpath(dirname(target))
        symlink(to_mount(p, remote), target)
        return 1
    end
    # Something below is copied, so this level has to be a real directory and the
    # link decision moves down to the children.
    mkpath(target)
    created = 0
    for entry in list_dir(h, remote)
        created += link_path!(h, p, joinpath(rel, entry.name), copies, skipped)
    end
    created
end

"""
    create_links!(h::RemoteHost, p::Production, sel::Selection)

Create the symlinks `sel` asks for, returning how many were made and which
targets were left alone because real data already stood there.
"""
function create_links!(h::RemoteHost, p::Production, sel::Selection)
    copies = Set(sel.copy)
    skipped = String[]
    created = 0
    for rel in sel.link
        created += link_path!(h, p, rel, copies, skipped)
    end
    created, skipped
end

"""
    apply!(h, p, sel; dry_run = false, progress = nothing,
           helper = HelperConfig(), jobs = 0, extract_progress = nothing)

Bring the mirror in line with `sel`. With `dry_run` it only asks rsync what would
move, inspects the files to extract with the remote helper, and returns an
[`Estimate`](@ref); otherwise it transfers, creates the links and writes
`config_local.json`, and returns a [`TransferResult`](@ref).

`progress` is called with a [`Progress`](@ref) for each reading rsync prints.
Extract entries are reduced on the host by the remote helper (`helper` says how to
run it, `jobs` how many workers it may use) into a staging directory, pulled with
rsync, and removed from the staging directory again; `extract_progress` is called
with an [`ExtractProgress`](@ref) after each reduced file. A failure once the
helper has started keeps the staged files for a resumed run and says where they are.
"""
function apply!(h::RemoteHost, p::Production, sel::Selection;
                dry_run::Bool = false, progress = nothing,
                helper::HelperConfig = HelperConfig(), jobs::Integer = 0,
                extract_progress = nothing)
    check_rsync()
    isdir(p.local_root) || error("local root $(p.local_root) does not exist")
    # Find out now, not halfway through a transfer, whether the mirror is writable.
    probe, io = mktemp(p.local_root)
    close(io)
    rm(probe)
    isempty(sel.link) || check_mount(p)
    staging, plan, not_in_run = isempty(sel.extract) ?
        ("", ExtractJob[], Tuple{String,String}[]) : prepare_extraction(h, p, sel, helper; jobs)
    if dry_run
        estimate = rsync_dry_run(h, p, sel)
        isempty(sel.extract) && return estimate
        return Estimate(estimate.bytes, estimate.files, estimate.links, true,
                        plan_bytes(h, helper, plan; jobs), length(plan), true, not_in_run)
    end

    plan, conflicts = reconcile_local(p, plan)
    isempty(plan) || check_staging_space(staging, free_bytes(h, make_dir(h, staging)),
                                         plan_bytes(h, helper, plan; jobs))
    warnings = String[]
    pulled = Estimate(0, 0, 0, true)
    replaced = 0
    in_mirror = false
    result = nothing
    try
        if !isempty(plan)
            spec = Dict("job" => [Dict("source" => j.source, "groups" => j.groups,
                                       "destination" => j.destination) for j in plan])
            done = 0
            staged_bytes = 0
            run_helper(h, helper, "extract", spec; jobs, warn = text -> push!(warnings, text),
                       on_record = function (record)
                           record["event"] == "file" || return
                           done += 1
                           staged_bytes += record["bytes"]
                           extract_progress === nothing ||
                               extract_progress(ExtractProgress(done, length(plan), staged_bytes))
                       end)
        end
        replaced = remove_stale_links!(p, sel)
        out, copy_warnings = rsync_listed(path -> rsync_command(h, p, path; dry_run = false),
                                          sel.copy, progress)
        push!(warnings, copy_warnings)
        if !isempty(plan)
            # The helper phase can be long; the mirror may have changed since the plan was checked.
            again, changed = reconcile_local(p, plan)
            isempty(changed) || error("the local mirror changed during the extraction; ",
                                      "full copy or symlink now at: ", join(changed, ", "))
            pull_out, pull_warnings = rsync_listed(
                path -> rsync_command(h, staging_production_dir(staging, p), p.local_root, path;
                                      dry_run = false),
                [j.relative for j in again], progress)
            pulled = parse_rsync_stats(pull_out, 0)
            push!(warnings, pull_warnings)
        end
        in_mirror = true
        moved = parse_rsync_stats(out, length(sel.link))
        created, skipped = create_links!(h, p, sel)
        config = write_local_config(p)
        isempty(plan) || remove_staged!(h, staging, [j.destination for j in plan])
        result = TransferResult(moved.bytes, moved.files, created, replaced, skipped,
                                config, join(filter(!isempty, warnings), "\n"),
                                length(plan), sum(j -> length(j.groups), plan; init = 0),
                                pulled.bytes, conflicts, not_in_run)
    catch err
        (isempty(plan) || err isa InterruptException) && rethrow()
        throw(ErrorException(sprint(showerror, err) * (in_mirror ?
            "\nthe reduced files are already in the local mirror; the staged copies were kept in $staging" :
            "\nreduced files already staged were kept in $staging; running the same selection again resumes from them")))
    end
    result
end

"""
    summary_text(r::TransferResult)::String

The lines the tool prints after an apply.
"""
function summary_text(r::TransferResult)
    lines = ["transferred $(format_bytes(r.bytes)) in $(r.files) files",
             "created $(r.links) links, replaced $(r.replaced_links) stale ones"]
    isempty(r.skipped) ||
        push!(lines, "kept existing data at $(length(r.skipped)) link targets: " *
                     join(r.skipped, ", "))
    r.extracted_files == 0 ||
        push!(lines, "extracted $(r.extracted_files) files, $(r.extracted_groups) groups " *
                     "($(format_bytes(r.extracted_bytes)) transferred)")
    isempty(r.conflicts) ||
        push!(lines, "kept $(length(r.conflicts)) existing files instead of extracting (full copies or symlinks): " *
                     join(r.conflicts, ", "))
    isempty(r.not_in_run) ||
        push!(lines, "not in run, left out of the extraction: " *
                     format_not_in_run(r.not_in_run))
    isempty(r.warnings) || push!(lines, "rsync warnings:\n$(r.warnings)")
    push!(lines, "export LEGEND_DATA_CONFIG=$(r.config)")
    join(lines, "\n")
end
