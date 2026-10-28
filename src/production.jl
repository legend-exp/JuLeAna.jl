# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const METADATA_URL = "git@github.com:legend-exp/legend-metadata"
const PRODUCTION_NAME = r"^[a-zA-Z0-9._-]+$"
const TIER_LABEL = r"^[a-zA-Z0-9_-]+$"
const BRANCH_NAME = r"^[a-zA-Z0-9._/][a-zA-Z0-9._/-]*$"
# folders of a new production below `generated/`
const GENERATED_DIRS = ("tier", "jllog", "jlplt", "jlreport", "jlpar", joinpath("jlpar", "rpars"), joinpath("jlpar", "ppars"))

# `git submodule foreach` scripts that check out `branch` in the metadata submodules: the
# `jldataprod` config and overrides submodules, and all others except those and the
# `simprod` config. `branch` matches `BRANCH_NAME`, so it is safe in the shell script.
jldataprod_checkout(branch) = """
    case "\$name" in
        jldataprod/config*|jldataprod/overrides*)
            git checkout '$branch' && git pull origin '$branch'
            ;;
    esac
    """
dataprod_checkout(branch) = """
    case "\$name" in
        jldataprod/config*|jldataprod/overrides*|simprod/config*)
            ;;
        *)
            git checkout '$branch' && git pull origin '$branch'
            ;;
    esac
    """

"""
    ProductionSpec(; name, parent, metadata_url = $(repr(METADATA_URL)), metadata_ref = nothing,
        jldataprod_branch = nothing, dataprod_branch = nothing, tier_paths = Pair{String,String}[], pars = String[],
        set_default = false, copy_software = true, shell = basename(get(ENV, "SHELL", "")),
        home = homedir())

What [`JuLeAna.create_production`](@ref) creates: the data production `name` in the folder
`parent` (an absolute path).

- `metadata_url`: the `legend-metadata` repository to clone.
- `metadata_ref`: branch or tag to check out in the metadata repository, with every
  submodule at the commit that ref records; `nothing` to keep the cloned default branch. The
  two branches below are checked out on top of it.
- `jldataprod_branch`: branch to check out in the `jldataprod/config*` and
  `jldataprod/overrides*` submodules of the metadata, `nothing` to keep the cloned ones.
- `dataprod_branch`: branch to check out in the metadata repository and all other
  submodules except `simprod/config*`, `nothing` to keep the cloned ones.
- `tier_paths`: `label => path` pairs of tiers kept in other folders, written to
  `config.yaml` as `tier/<label>`; each path must be an existing folder.
- `pars`: folders of parameters to copy into `generated/jlpar`; each path must contain a
  `/rpars` or `/ppars` component, and the part from there on is kept below `jlpar`.
- `set_default`: whether to set `LEGEND_DATA_CONFIG` to the new production in the startup
  file of the shell `shell` (`bash`: `.bashrc`, `zsh`: `.zshrc`) in `home`.
- `copy_software`: whether to copy the software of this process into the production (see
  [`JuLeAna.record_software`](@ref)).
"""
Base.@kwdef struct ProductionSpec
    name::String
    parent::String
    metadata_url::String = METADATA_URL
    metadata_ref::Union{Nothing,String} = nothing
    jldataprod_branch::Union{Nothing,String} = nothing
    dataprod_branch::Union{Nothing,String} = nothing
    tier_paths::Vector{Pair{String,String}} = Pair{String,String}[]
    pars::Vector{String} = String[]
    set_default::Bool = false
    copy_software::Bool = true
    shell::String = basename(get(ENV, "SHELL", ""))
    home::String = homedir()
end

# The startup file of `shell` in `home`, `nothing` for an unsupported shell.
function shell_rc_file(shell, home)
    return shell == "bash" ? joinpath(home, ".bashrc") : shell == "zsh" ? joinpath(home, ".zshrc") : nothing
end

"""
    JuLeAna.check_production(spec::ProductionSpec)

Return the folder of the production `spec` describes, after checking `spec` without
changing anything: the name contains only letters, digits, `.`, `_` and `-`, the parent is
an absolute path, the production folder does not exist, the branch names contain only
letters, digits, `.`, `_`, `/` and `-` and do not start with `-` (also the `metadata_ref`), every tier label is unique and
contains only letters, digits, `_` and `-`, every tier path and parameter folder exists,
every parameter folder has a `/rpars` or `/ppars` component, and with `set_default` the
shell is `bash` or `zsh`. Throws an `ArgumentError` that names the first problem.
"""
function check_production(spec::ProductionSpec)
    occursin(PRODUCTION_NAME, spec.name) ||
        throw(ArgumentError("the production name $(repr(spec.name)) may contain only letters, digits, '.', '_' and '-'"))
    isabspath(spec.parent) || throw(ArgumentError("the production folder must be an absolute path, got $(repr(spec.parent))"))
    path = joinpath(spec.parent, spec.name)
    ispath(path) && throw(ArgumentError("$path exists; remove it or choose another name"))
    for branch in (spec.metadata_ref, spec.jldataprod_branch, spec.dataprod_branch)
        isnothing(branch) ||
            occursin(BRANCH_NAME, branch) ||
            throw(ArgumentError("the branch name $(repr(branch)) may contain only letters, digits, '.', '_', '/' and '-' and may not start with '-'"))
    end
    labels = first.(spec.tier_paths)
    allunique(labels) || throw(ArgumentError("tier labels must be unique, got $(join(labels, ", "))"))
    for (label, tier) in spec.tier_paths
        occursin(TIER_LABEL, label) || throw(ArgumentError("the tier label $(repr(label)) may contain only letters, digits, '_' and '-'"))
        isdir(tier) || throw(ArgumentError("the path $tier of tier $label is not a folder"))
    end
    for pars in spec.pars
        isdir(pars) || throw(ArgumentError("the parameter folder $pars does not exist"))
        isnothing(pars_subpath(pars)) && throw(ArgumentError("the parameter folder $pars has no /rpars or /ppars component"))
    end
    spec.set_default &&
        isnothing(shell_rc_file(spec.shell, spec.home)) &&
        throw(ArgumentError("cannot set the default production for the shell $(repr(spec.shell)); set LEGEND_DATA_CONFIG by hand"))
    return path
end

# The part of the parameter folder `pars` from its `/rpars` or `/ppars` component on.
function pars_subpath(pars)
    m = match(r"(/(?:rpars|ppars)(?:/.*)?)$", rstrip(pars, '/'))
    return isnothing(m) ? nothing : String(m[1])
end

# Run `cmd` and pass every line of its standard and error output to `log`; throw if it fails.
function run_logged(cmd::Cmd, log)
    out = Pipe()
    process = run(pipeline(cmd; stdout = out, stderr = out); wait = false)
    close(out.in)
    for line in eachline(out)
        log(line)
    end
    wait(process)
    success(process) || throw(ErrorException("command failed with exit code $(process.exitcode): $cmd"))
    return nothing
end

"""
    JuLeAna.data_config_text(tier_paths, parent)

Return the text of the `config.yaml` of a new production: the paths of the `l200` setup
relative to the folder of the file (`\$_`), and after the `tier` path one `tier/<label>`
entry per pair of `tier_paths`. A path below `parent`, the folder that holds the
production, is written relative to it as `\$_/..`. The paths are single-quoted YAML strings.
"""
function data_config_text(tier_paths, parent)
    quoted(path) = "'" * replace(path, "'" => "''") * "'"
    prefix = rstrip(parent, '/') * "/"
    tiers = join(("      tier/$label: $(quoted(startswith(path, prefix) ?
                                             "\$_/../" * path[(length(prefix) + 1):end] : path))\n" for (label, path) in tier_paths))
    return """
        setups:
          l200:
            paths:
              metadata: '\$_/legend-metadata/'

              tier: '\$_/generated/tier/'
        $(tiers)      tier/jllog: '\$_/generated/jllog/'
              tier/jlrep: '\$_/generated/jlreport/'
              tier/jlplt: '\$_/generated/jlplt/'

              par: '\$_/generated/jlpar/'
        """
end

"""
    JuLeAna.create_production(spec::ProductionSpec; log = line -> @info(line))

Create the data production `spec` describes and return the path of its data config file
`config.yaml`, which `LEGEND_DATA_CONFIG` names to use it. Checks `spec` first with
[`JuLeAna.check_production`](@ref), then

1. creates the production folder and clones the metadata with its submodules into
   `legend-metadata`; with `metadata_ref` it checks out that branch or tag and updates all
   submodules to the commits it records, then it checks out the other branches of `spec`,
2. creates the folders `generated/{tier,jllog,jlplt,jlreport,jlpar/rpars,jlpar/ppars}`,
3. writes `config.yaml` (see [`JuLeAna.data_config_text`](@ref)),
4. copies the parameter folders into `generated/jlpar`,
5. copies the software of this process into a subfolder of `setup/software` (see
   [`JuLeAna.record_software`](@ref)),
6. sets `LEGEND_DATA_CONFIG` in the shell startup file: replaces the lines that export it,
   or appends one.

`log` gets a line for every step and the output of `git`. A failing step throws and
leaves what was created so far.
"""
function create_production(spec::ProductionSpec; log = line -> @info(line))
    path = check_production(spec)
    mkpath(path)
    log("Created $path")
    metadata = joinpath(path, "legend-metadata")
    log("Cloning $(spec.metadata_url) into $metadata")
    run_logged(`git clone --recursive $(spec.metadata_url) $metadata`, log)
    run_logged(`git -C $metadata submodule init`, log)
    run_logged(`git -C $metadata submodule update`, log)
    if !isnothing(spec.metadata_ref)
        # A fresh clone is at the remote tip of every branch, so no pull is needed. `checkout`
        # creates a local branch from `origin/<ref>` and detaches HEAD at a tag.
        log("Checking out $(spec.metadata_ref) in the metadata")
        run_logged(`git -C $metadata -c advice.detachedHead=false checkout $(spec.metadata_ref)`, log)
        log("Updating the submodules to the commits of $(spec.metadata_ref)")
        run_logged(`git -C $metadata submodule update --init --recursive`, log)
    end
    if !isnothing(spec.jldataprod_branch)
        log("Checking out $(spec.jldataprod_branch) in the jldataprod config and overrides submodules")
        run_logged(`git -C $metadata -c advice.detachedHead=false submodule foreach --recursive $(jldataprod_checkout(spec.jldataprod_branch))`,
                   log)
    end
    if !isnothing(spec.dataprod_branch)
        log("Checking out $(spec.dataprod_branch) in the metadata and its other submodules")
        run_logged(`git -C $metadata checkout $(spec.dataprod_branch)`, log)
        run_logged(`git -C $metadata pull origin $(spec.dataprod_branch)`, log)
        run_logged(`git -C $metadata -c advice.detachedHead=false submodule foreach --recursive $(dataprod_checkout(spec.dataprod_branch))`,
                   log)
    end
    foreach(d -> mkpath(joinpath(path, "generated", d)), GENERATED_DIRS)
    log("Created the folders in $(joinpath(path, "generated"))")
    config = joinpath(path, "config.yaml")
    write(config, data_config_text(spec.tier_paths, spec.parent))
    log("Wrote $config")
    for pars in spec.pars
        dest = mkpath(joinpath(path, "generated", "jlpar", lstrip(pars_subpath(pars), '/')))
        for entry in readdir(pars)
            cp(joinpath(pars, entry), joinpath(dest, entry))
        end
        log("Copied $pars to $dest")
    end
    if spec.copy_software
        record_software(path; log)
    end
    if spec.set_default
        rc = shell_rc_file(spec.shell, spec.home)
        line = "export LEGEND_DATA_CONFIG=$(with_production_config(config))"
        lines = isfile(rc) ? readlines(rc) : String[]
        exports = findall(startswith("export LEGEND_DATA_CONFIG="), lines)
        isempty(exports) ? push!(lines, line) : (lines[exports] .= line)
        write(rc, join(lines, "\n") * "\n")
        log((isempty(exports) ? "Added" : "Updated") * " LEGEND_DATA_CONFIG in $rc")
    end
    return config
end

# Folders of a package folder that is not a git checkout that are not copied.
const SNAPSHOT_SKIP = (".git", joinpath("docs", "build"))

# Copy the package `src` to `dest` without its manifests: for a git checkout the files git
# tracks (as they are now) and the untracked files it does not ignore, else every file
# outside `SNAPSHOT_SKIP`.
function copy_package_tree(src, dest)
    files = String[]
    if isnothing(git_state(src))
        for (root, dirs, fs) in walkdir(src)
            # pruning `dirs` keeps `walkdir` out of the skipped folders
            filter!(d -> !(normpath(joinpath(relpath(root, src), d)) in SNAPSHOT_SKIP), dirs)
            append!(files, relpath.(joinpath.(root, fs), src))
        end
    else
        listed = split(read(`git -C $src ls-files -z --cached --others --exclude-standard`, String), '\0'; keepempty = false)
        append!(files, filter(f -> isfile(joinpath(src, f)), listed))
    end
    for f in files
        dirname(f) == "" && startswith(f, "Manifest") && endswith(f, ".toml") && continue
        mkpath(dirname(joinpath(dest, f)))
        cp(joinpath(src, f), joinpath(dest, f); follow_symlinks = true)
    end
    return dest
end

# `(; commit, modified)` of the git checkout `dir`, or `nothing` if it is not one.
function git_state(dir)
    isdir(joinpath(dir, ".git")) || isfile(joinpath(dir, ".git")) || return nothing
    commit = strip(read(`git -C $dir rev-parse HEAD`, String))
    modified = !isempty(strip(read(`git -C $dir status --porcelain`, String)))
    return (; commit, modified)
end

"""
    JuLeAna.running_manifest()

Return the path of the manifest of the environment this process loaded JuLeAna from: the
first environment of `Base.load_path()` whose manifest has a `JuLeAna` entry. Throws an
`ErrorException` if there is none.
"""
function running_manifest()
    for project in Base.load_path()
        isfile(project) || continue
        dir = dirname(project)
        for name in ("Manifest-v$(VERSION.major).$(VERSION.minor).toml", "Manifest.toml")
            manifest = joinpath(dir, name)
            isfile(manifest) && haskey(get(TOML.parsefile(manifest), "deps", Dict()), "JuLeAna") && return manifest
        end
    end
    return throw(ErrorException("running_manifest: no environment of the load path has JuLeAna in its manifest"))
end

"""
    JuLeAna.snapshot_software(dest::AbstractString; manifest = JuLeAna.running_manifest(),
        source = pkgdir(JuLeAna), log = line -> @info(line))

Copy the software of this process to the folder `dest`, so that it can be installed again
with `Pkg.Apps.develop(path = "<dest>/JuLeAna.jl")`:

- the package `source` of JuLeAna to `dest/JuLeAna.jl`: for a git checkout the files git
  tracks, with their uncommitted changes, and the untracked files it does not ignore, else
  every file except `.git` and `docs/build`; its own manifests are not copied;
- every other package that `manifest` takes from a path (developed packages) to
  `dest/<name>`, likewise;
- `manifest` to `dest/JuLeAna.jl/Manifest.toml`, with the JuLeAna entry taken from `.`
  and the copied packages from `../<name>`, so that every package keeps its version;
- each copied package folder is a git repository with one commit of all its files,
  including `Manifest.toml`, so that `Pkg.add(path = ...)` accepts it. The commit has a
  fixed author and does not depend on the git configuration of the user;
- `dest/SNAPSHOT.toml`: the date, user, host and Julia version, for each package its
  `source`, its `commit` and whether it was `modified` (for a git checkout) and the `tree`
  of the commit of the copy, and a `fingerprint` of the Julia version and the trees. Equal
  software has equal fingerprints;
- `dest/PROVENANCE.md`: the same for reading, and the steps to run the copy.

Returns `dest`. Throws if `dest` exists.
"""
function snapshot_software(dest::AbstractString; manifest = running_manifest(), source = pkgdir(JuLeAna), log = line -> @info(line))
    ispath(dest) && throw(ArgumentError("snapshot_software: $dest exists"))
    data = TOML.parsefile(manifest)
    deps = data["deps"]
    copies = Pair{String,String}["JuLeAna" => source]
    for (name, entries) in deps, entry in entries

        name != "JuLeAna" && haskey(entry, "path") || continue
        path = entry["path"]
        push!(copies, name => (isabspath(path) ? path : normpath(joinpath(dirname(manifest), path))))
    end
    created = Dates.format(now(UTC), HISTORY_TIME_FORMAT)
    user, host = get(ENV, "USER", "unknown"), gethostname()
    lines = ["# Software of this production", "", "Copied $created UTC by $user@$host with Julia $VERSION.", "",
             "| Package | Source | Commit | Uncommitted changes |", "|---|---|---|---|"]
    states = Dict{String,Any}()
    for (name, path) in copies
        target = joinpath(dest, name == "JuLeAna" ? "JuLeAna.jl" : name)
        copy_package_tree(path, target)
        state = git_state(path)
        states[name] = state
        push!(lines,
              "| $name | $path | $(isnothing(state) ? "–" : state.commit) | $(isnothing(state) ? "–" : state.modified ? "yes" : "no") |")
        log("Copied $name from $path to $target")
    end
    for (name, entries) in deps, entry in entries

        if name == "JuLeAna"
            foreach(k -> delete!(entry, k), ("git-tree-sha1", "repo-url", "repo-rev", "repo-subdir"))
            entry["path"] = "."
        elseif haskey(entry, "path")
            entry["path"] = "../$name"
        end
    end
    open(io -> TOML.print(io, data; sorted = true), joinpath(dest, "JuLeAna.jl", "Manifest.toml"), "w")
    packages = Dict{String,Any}()
    for (name, path) in copies
        target = joinpath(dest, name == "JuLeAna" ? "JuLeAna.jl" : name)
        state = states[name]
        message = "Snapshot of $path" *
                  (isnothing(state) ? " (not a git checkout)" : " at $(state.commit)" * (state.modified ? " with uncommitted changes" : ""))
        # `Manifest.toml` is ignored by the `.gitignore` of a package
        run_logged(`git -C $target init -q -b main`, log)
        run_logged(`git -C $target add -A --force`, log)
        # No automatic maintenance: git runs it in a detached process that writes into `.git` while
        # `record_software` may already be removing the snapshot.
        run_logged(`git -C $target -c user.name=JuLeAna -c user.email=juleana@localhost -c commit.gpgsign=false -c maintenance.auto=false -c gc.auto=0 commit -q -m $message`,
                   log)
        tree = strip(read(`git -C $target rev-parse $("HEAD^{tree}")`, String))
        packages[name] = Dict{String,Any}("source" => path, "tree" => tree)
        isnothing(state) || merge!(packages[name], Dict{String,Any}("commit" => state.commit, "modified" => state.modified))
    end
    trees = join(("$name=$(packages[name]["tree"])\n" for name in sort!(collect(keys(packages)))))
    fingerprint = strip(read(pipeline(`git hash-object --stdin`; stdin = IOBuffer("julia=$VERSION\n" * trees)), String))
    open(joinpath(dest, "SNAPSHOT.toml"), "w") do io
        return TOML.print(io,
                          Dict{String,Any}("created" => created, "user" => user, "host" => host, "julia" => string(VERSION),
                                           "fingerprint" => fingerprint, "packages" => packages); sorted = true)
    end
    append!(lines,
            ["", "## Reproducing", "", "In this folder, install the packages from the manifest and run JuLeAna from the copy:", "", "```",
             "cd <this folder>/JuLeAna.jl", "julia --project=. -e 'using Pkg; Pkg.instantiate()'",
             "export LEGEND_DATA_CONFIG=<data config of the production>", "julia --project=. -m JuLeAna --no-tui ...", "```", "",
             "Every package folder is a git repository with one commit. `Pkg.develop(path = \"<this folder>/JuLeAna.jl\")` " *
             "and `Pkg.add(path = \"<this folder>/JuLeAna.jl\")` install the copy as well; `add` installs the committed tree. " *
             "`Pkg.Apps.develop(path = \"<this folder>/JuLeAna.jl\")` replaces the globally installed `juleana` app.", "",
             "`SNAPSHOT.toml` holds the same information in machine-readable form."])
    write(joinpath(dest, "PROVENANCE.md"), join(lines, "\n") * "\n")
    log("Wrote $(joinpath(dest, "PROVENANCE.md"))")
    return dest
end

"""
    JuLeAna.record_software(root::AbstractString; manifest = JuLeAna.running_manifest(),
        source = pkgdir(JuLeAna), log = line -> @info(line))

Make sure the folder `root/setup/software` holds a snapshot of the software of this process
and return the name of its subfolder. Takes a new snapshot with
[`JuLeAna.snapshot_software`](@ref) and compares its `fingerprint` with that of every
subfolder that has a `SNAPSHOT.toml`; other subfolders are ignored. For equal software it
removes the new snapshot and returns the existing subfolder. Otherwise the new snapshot
becomes the subfolder `<yyyy-mm-ddTHHMMSSZ>-<short JuLeAna commit>`, with `-modified`
appended if JuLeAna had uncommitted changes, and `nogit` instead of the commit if it is not
a git checkout. Throws if a step fails.
"""
function record_software(root::AbstractString; manifest = running_manifest(), source = pkgdir(JuLeAna), log = line -> @info(line))
    software = mkpath(joinpath(root, "setup", "software"))
    fresh = joinpath(software, ".new-" * string(uuid4()))
    try
        snapshot_software(fresh; manifest, source, log)
    catch
        rm(fresh; recursive = true, force = true)
        rethrow()
    end
    snapshot = TOML.parsefile(joinpath(fresh, "SNAPSHOT.toml"))
    for sub in readdir(software)
        startswith(sub, ".new-") && continue
        file = joinpath(software, sub, "SNAPSHOT.toml")
        isfile(file) && TOML.parsefile(file)["fingerprint"] == snapshot["fingerprint"] || continue
        rm(fresh; recursive = true)
        log("The software is already recorded in $(joinpath(software, sub))")
        return sub
    end
    juleana = snapshot["packages"]["JuLeAna"]
    name = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHHMMSS") *
           "Z-" *
           (haskey(juleana, "commit") ? first(juleana["commit"], 7) : "nogit") *
           (get(juleana, "modified", false) ? "-modified" : "")
    mv(fresh, joinpath(software, name))
    log("Recorded the software in $(joinpath(software, name))")
    return name
end

"""
    JuLeAna.software_version(snapshot = nothing)

Return a one-line description of the software of this process for the processing
history: the JuLeAna version, and for a git checkout its short commit and `modified` if it
has uncommitted changes, the Julia version, and with `snapshot`, the name of a subfolder of
`setup/software` (see [`JuLeAna.record_software`](@ref)), `snapshot setup/software/<snapshot>`.
"""
function software_version(snapshot = nothing)
    state = git_state(pkgdir(JuLeAna))
    checkout = isnothing(state) ? "" : " (" * first(state.commit, 7) * (state.modified ? ", modified" : "") * ")"
    return "JuLeAna $(pkgversion(JuLeAna))$checkout, Julia $VERSION" * (isnothing(snapshot) ? "" : ", snapshot setup/software/$snapshot")
end

# Untracked files of the metadata up to this size are copied into its record; larger ones
# are recorded by their hash only.
const METADATA_COPY_LIMIT = 1_000_000

# Output of git in the checkout `dir`. Optional locks are off, so that reading the state of a
# checkout does not refresh its index.
git_read(dir, args...) = read(`git --no-optional-locks -C $dir $args`, String)

# Hash git gives the contents of the file `path` or of `io` as a blob; nothing is written.
function git_hash(path::AbstractString)
    return String(strip(read(`git hash-object --no-filters -- $path`, String)))
end
function git_hash(io::IO)
    return String(strip(read(pipeline(`git hash-object --stdin`; stdin = io), String)))
end

# Path of the file of the repository `repo` (`"."` for the metadata itself) in a folder of a
# metadata record.
record_subpath(repo) = repo == "." ? "root" : repo

# The state of the metadata checkout `metadata` and its submodules: for each repository
# (`"."` and the submodule paths) its `commit`, `branch`, `remote`, `diff` against the commit
# (without submodule changes) and untracked files, and for a submodule whether it is `moved`
# from the commit its superproject records; an uninitialized submodule has only that
# recorded `commit`.
function metadata_state(metadata)
    isdir(joinpath(metadata, ".git")) ||
        isfile(joinpath(metadata, ".git")) ||
        throw(ArgumentError("record_metadata: the metadata $metadata is not a git checkout"))
    repos = Dict{String,Any}("." => Dict{String,Any}())
    status = git_read(metadata, "submodule", "status", "--recursive")
    for line in eachline(IOBuffer(status))
        m = match(r"^([ +\-U])([0-9a-f]+) (\S+)", line)
        isnothing(m) && throw(ErrorException("record_metadata: unexpected `git submodule status` line $(repr(line))"))
        repos[String(m[3])] = m[1] == "-" ? Dict{String,Any}("commit" => String(m[2]), "initialized" => false) :
                              Dict{String,Any}("moved" => m[1] != " ")
    end
    for (repo, state) in repos
        get(state, "initialized", true) || continue
        dir = joinpath(metadata, repo)
        state["commit"] = String(strip(git_read(dir, "rev-parse", "HEAD")))
        branch = String(strip(git_read(dir, "rev-parse", "--abbrev-ref", "HEAD")))
        branch == "HEAD" || (state["branch"] = branch)
        remote = String(strip(read(ignorestatus(`git -C $dir config --get remote.origin.url`), String)))
        isempty(remote) || (state["remote"] = remote)
        state["diff"] = git_read(dir, "diff", "--binary", "--ignore-submodules=all", "HEAD")
        state["untracked"] = [Dict{String,Any}("path" => String(f), "hash" => git_hash(joinpath(dir, f)),
                                               "size" => filesize(joinpath(dir, f)))
                              for f in split(git_read(dir, "ls-files", "-z", "--others", "--exclude-standard"), '\0'; keepempty = false)]
    end
    return repos
end

"""
    JuLeAna.record_metadata(root::AbstractString, metadata::AbstractString;
        configs = String[], log = line -> @info(line))

Make sure the folder `root/setup/metadata` holds a record of the metadata checkout
`metadata` and its submodules as they are now, together with the config files `configs`,
and return the name of its subfolder. Reads the metadata with git only and does not change
it. Throws an `ArgumentError` if `metadata` is not a git checkout.

A record holds:

- `METADATA.toml`: the date, user and host; for every repository (`"."` for `metadata`,
  else the path of the submodule) its `commit`, `branch` (unless detached), `remote`,
  whether it is `modified`, for a submodule whether it is `moved` from the commit its
  superproject records, its `patch` and its untracked files with their `path`, `hash`,
  `size` and whether they were `copied`; for every config file its `source`, `file` and
  `hash`; and a `fingerprint` of all of it. Equal metadata and configs have equal
  fingerprints;
- `patches/`: for every repository with uncommitted changes the `git diff --binary` of its
  files against its commit;
- `untracked/`: the untracked files that git does not ignore, up to
  $(METADATA_COPY_LIMIT ÷ 1_000_000) MB each;
- `config/`: copies of `configs`;
- `PROVENANCE.md`: the same for reading, and the steps to restore the metadata.

For a fingerprint that a subfolder already has, nothing is written and that subfolder is
returned. Otherwise the record becomes the subfolder `<yyyy-mm-ddTHHMMSSZ>-<short commit of
metadata>`, with `-modified` appended if a repository has uncommitted changes or untracked
files, or a submodule is not at the commit its superproject records.
"""
function record_metadata(root::AbstractString, metadata::AbstractString; configs = String[], log = line -> @info(line))
    repos = metadata_state(metadata)
    for s in values(repos)
        s["modified"] = get(s, "moved", false) || !isempty(get(s, "diff", "")) || !isempty(get(s, "untracked", []))
    end
    config_entries = [Dict{String,Any}("source" => abspath(c), "file" => "$i-$(basename(c))", "hash" => git_hash(c))
                      for (i, c) in pairs(configs)]
    io = IOBuffer()
    for repo in sort!(collect(keys(repos)))
        s = repos[repo]
        println(io, "repo=", repo, " commit=", s["commit"], " diff=", git_hash(IOBuffer(get(s, "diff", ""))))
        for u in get(s, "untracked", [])
            println(io, "untracked=", repo, "/", u["path"], " ", u["hash"])
        end
    end
    for c in config_entries
        println(io, "config=", c["file"], " ", c["hash"])
    end
    fingerprint = git_hash(seekstart(io))
    records = mkpath(joinpath(root, "setup", "metadata"))
    for sub in readdir(records)
        file = joinpath(records, sub, "METADATA.toml")
        isfile(file) && TOML.parsefile(file)["fingerprint"] == fingerprint || continue
        log("The metadata is already recorded in $(joinpath(records, sub))")
        return sub
    end
    fresh = joinpath(records, ".new-" * string(uuid4()))
    created = Dates.format(now(UTC), HISTORY_TIME_FORMAT)
    user, host = get(ENV, "USER", "unknown"), gethostname()
    entries = Dict{String,Any}()
    try
        for (repo, s) in repos
            entry = Dict{String,Any}(k => s[k] for k in ("commit", "branch", "remote", "initialized", "moved", "modified") if haskey(s, k))
            if get(s, "initialized", true)
                if !isempty(s["diff"])
                    entry["patch"] = "patches/$(record_subpath(repo)).patch"
                    patch = joinpath(fresh, entry["patch"])
                    mkpath(dirname(patch))
                    write(patch, s["diff"])
                end
                for u in s["untracked"]
                    u["copied"] = u["size"] <= METADATA_COPY_LIMIT
                    u["copied"] || continue
                    dest = joinpath(fresh, "untracked", record_subpath(repo), u["path"])
                    mkpath(dirname(dest))
                    cp(joinpath(metadata, repo, u["path"]), dest)
                end
                entry["untracked"] = s["untracked"]
            end
            entries[repo] = entry
        end
        for (c, entry) in zip(configs, config_entries)
            cp(c, joinpath(mkpath(joinpath(fresh, "config")), entry["file"]))
        end
        open(joinpath(fresh, "METADATA.toml"), "w") do io
            return TOML.print(io,
                              Dict{String,Any}("created" => created, "user" => user, "host" => host, "metadata" => abspath(metadata),
                                               "fingerprint" => fingerprint, "repos" => entries, "configs" => config_entries);
                              sorted = true)
        end
        write(joinpath(fresh, "PROVENANCE.md"), metadata_provenance(metadata, entries, config_entries, created, user, host))
    catch
        rm(fresh; recursive = true, force = true)
        rethrow()
    end
    name = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHHMMSS") *
           "Z-" *
           first(repos["."]["commit"], 7) *
           (any(s -> get(s, "modified", false), values(repos)) ? "-modified" : "")
    mv(fresh, joinpath(records, name))
    log("Recorded the metadata in $(joinpath(records, name))")
    return name
end

# Text of the `PROVENANCE.md` of a metadata record.
function metadata_provenance(metadata, entries, configs, created, user, host)
    lines = ["# Metadata of this production", "", "Recorded $created UTC by $user@$host from `$(abspath(metadata))`.", "",
             "| Repository | Commit | Branch | Uncommitted changes |", "|---|---|---|---|"]
    repos = sort!(collect(keys(entries)))
    for repo in repos
        e = entries[repo]
        changes = !get(e, "initialized", true) ? "not checked out" : e["modified"] ? "yes" : "no"
        push!(lines, "| $repo | $(e["commit"]) | $(get(e, "branch", "–")) | $changes |")
    end
    large = [(repo, u) for repo in repos for u in get(entries[repo], "untracked", []) if !u["copied"]]
    if !isempty(large)
        append!(lines, ["", "Untracked files larger than $(METADATA_COPY_LIMIT ÷ 1_000_000) MB, recorded by their git hash only:", ""])
        append!(lines, ["- `$repo/$(u["path"])` ($(u["size"]) bytes, $(u["hash"]))" for (repo, u) in large])
    end
    if !isempty(configs)
        append!(lines, ["", "Config files, copied to `config/`:", ""])
        append!(lines, ["- `$(c["source"])` as `$(c["file"])`" for c in configs])
    end
    root = entries["."]
    append!(lines,
            ["", "## Restoring", "",
             "Clone the metadata, check out the recorded commits and apply the uncommitted changes " * "(`<record>` is this folder):", "",
             "```", "git clone $(get(root, "remote", "<remote>")) legend-metadata", "cd legend-metadata", "git checkout $(root["commit"])",
             "git submodule update --init --recursive"])
    for repo in repos
        get(entries[repo], "moved", false) && push!(lines, "git -C $repo checkout $(entries[repo]["commit"])")
    end
    for repo in repos
        e = entries[repo]
        haskey(e, "patch") && push!(lines, "git -C $repo apply <record>/$(e["patch"])")
        any(u -> u["copied"], get(e, "untracked", [])) && push!(lines, "cp -R <record>/untracked/$(record_subpath(repo))/. $repo/")
    end
    append!(lines, ["```", "", "`METADATA.toml` holds the same information in machine-readable form."])
    return join(lines, "\n") * "\n"
end
