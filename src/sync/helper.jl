# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const HELPER_SCRIPT = joinpath(@__DIR__, "remote", "extract.jl")

# Versions the helper is written against; the remote environment is created with
# these bounds.
const HELPER_PACKAGES = ["HDF5" => "0.17", "ParallelProcessingTools" => "0.4"]

const DEFAULT_REMOTE_JULIA = "~/.juliaup/bin/julia"
const DEFAULT_REMOTE_PROJECT = "~/.julia/environments/juleana-sync"

# Run by `sh -c` on the remote: the home directory is quota-limited on the
# clusters, so staging defaults to the temporary directory.
const REMOTE_STAGING_SCRIPT = "printf %s \"\${TMPDIR:-/tmp}/juleana-sync-\$(id -un)\""

"""
    HelperConfig(; julia = nothing, julia_project = nothing, staging = nothing)

How to run the remote helper on one host: the Julia executable, the environment
that holds HDF5 and ParallelProcessingTools, and the staging directory. `nothing`
selects the default ([`DEFAULT_REMOTE_JULIA`](@ref), [`DEFAULT_REMOTE_PROJECT`](@ref)
and `\${TMPDIR:-/tmp}/juleana-sync-<user>`). A leading `~` is expanded on the host.
"""
struct HelperConfig
    julia::Union{Nothing,String}
    julia_project::Union{Nothing,String}
    staging::Union{Nothing,String}
end

HelperConfig(; julia = nothing, julia_project = nothing, staging = nothing) =
    HelperConfig(julia, julia_project, staging)

"""
    remote_julia(h::RemoteHost, c::HelperConfig)::Cmd

The Julia executable to run the helper with. `LocalHost` uses the running Julia.
"""
remote_julia(h::SSHHost, c::HelperConfig) =
    Cmd([expand_home(h, something(c.julia, DEFAULT_REMOTE_JULIA))])
remote_julia(::LocalHost, c::HelperConfig) =
    c.julia === nothing ? Base.julia_cmd() : Cmd([c.julia])

"""
    julia_project(h::RemoteHost, c::HelperConfig)::String

The environment the helper runs in. `LocalHost` uses the active project, which must hold HDF5 and
ParallelProcessingTools; the package's test environment does.
"""
julia_project(h::SSHHost, c::HelperConfig) =
    expand_home(h, something(c.julia_project, DEFAULT_REMOTE_PROJECT))
function julia_project(::LocalHost, c::HelperConfig)
    c.julia_project === nothing || return c.julia_project
    active = Base.active_project()
    active === nothing && throw(ErrorException("the local helper runs in the active project, but there is no active project"))
    deps = get(TOML.parsefile(active), "deps", Dict{String,Any}())
    lacking = [name for name in first.(HELPER_PACKAGES) if !haskey(deps, name)]
    isempty(lacking) || throw(ErrorException("the active project $(dirname(active)) lacks $(join(lacking, ", ")), which the local helper needs"))
    return dirname(active)
end

"""
    staging_dir(h::RemoteHost, c::HelperConfig)::String

The directory the helper writes reduced files to and the tool pulls them from.
"""
staging_dir(h::SSHHost, c::HelperConfig) = c.staging === nothing ?
    String(strip(run_remote(h, `sh -c $REMOTE_STAGING_SCRIPT`))) : expand_home(h, c.staging)
staging_dir(::LocalHost, c::HelperConfig) =
    something(c.staging, joinpath(tempdir(), "juleana-sync-" * get(ENV, "USER", "user")))

"""
    EnvironmentStatus(julia, project, present, lacking)

What is on the host: the Julia version string, the environment path, whether the
environment has a `Project.toml`, and which of [`HELPER_PACKAGES`](@ref) its
`[deps]` lacks. The packages being installed and precompiled is not checked here;
the helper's own error says so when they are not.
"""
struct EnvironmentStatus
    julia::String
    project::String
    present::Bool
    lacking::Vector{String}
end

environment_ready(s::EnvironmentStatus) = s.present && isempty(s.lacking)

"""
    ensure_environment(h::RemoteHost, c::HelperConfig)::EnvironmentStatus

Check that Julia runs on `h` and report the state of the helper environment. A
missing executable is an error carrying the remote standard error.
"""
function ensure_environment(h::RemoteHost, c::HelperConfig)
    julia = remote_julia(h, c)
    version = String(strip(run_remote(h, `$julia --version`)))
    project = julia_project(h, c)
    toml = joinpath(project, "Project.toml")
    names = first.(HELPER_PACKAGES)
    file_exists(h, toml) || return EnvironmentStatus(version, project, false, names)
    deps = get(TOML.parse(read_file(h, toml)), "deps", Dict{String,Any}())
    EnvironmentStatus(version, project, true, [name for name in names if !haskey(deps, name)])
end

"""
    bootstrap_command(h::RemoteHost, c::HelperConfig)::Cmd

The command that adds the helper's packages to its environment, creating the
environment when it does not exist. The interface shows it before running it.
"""
function bootstrap_command(h::RemoteHost, c::HelperConfig)
    specs = join(("Pkg.PackageSpec(name = \"$name\", version = \"$version\")"
                  for (name, version) in HELPER_PACKAGES), ", ")
    code = "import Pkg; Pkg.add([$specs])"
    `$(remote_julia(h, c)) --startup-file=no --project=$(julia_project(h, c)) -e $code`
end

"""
    environment_problem(s::EnvironmentStatus, h::RemoteHost, c::HelperConfig)::String

The error text for an environment that is not ready, ending with the command that
creates it.
"""
environment_problem(s::EnvironmentStatus, h::RemoteHost, c::HelperConfig) =
    "the helper environment $(s.project) " *
    (s.present ? "lacks $(join(s.lacking, ", "))" : "does not exist") *
    "; create it with: $(Base.shell_escape(bootstrap_command(h, c)))"

"""
    bootstrap_environment!(h::RemoteHost, c::HelperConfig)::EnvironmentStatus

Run [`bootstrap_command`](@ref) and return the resulting status, which must be
ready. Only an environment that does not exist yet is created: an existing one is
never modified, and neither is the active project that `LocalHost` uses by default.
"""
function bootstrap_environment!(h::RemoteHost, c::HelperConfig)
    h isa LocalHost && c.julia_project === nothing && throw(ArgumentError(
        "refusing to modify the active project $(dirname(Base.active_project())); name a helper environment with julia_project"))
    existing = ensure_environment(h, c)
    existing.present && throw(ErrorException(
        "the helper environment $(existing.project) already exists; refusing to modify it. " *
        "Add the missing packages ($(isempty(existing.lacking) ? "none" : join(existing.lacking, ", "))) yourself, or name another julia_project in hosts.yaml"))
    make_dir(h, julia_project(h, c))
    run_remote(h, bootstrap_command(h, c))
    status = ensure_environment(h, c)
    environment_ready(status) || throw(ErrorException(environment_problem(status, h, c)))
    status
end

"""
    parse_record(line::AbstractString)::Dict{String,Any}

One output line of the helper: a TOML document `r = {...}`. Any other line is an
error, so stray output is never mistaken for a result. Keys are passed through
as they are.
"""
function parse_record(line::AbstractString)
    startswith(line, "r = {") || throw(ErrorException(
        "unexpected output from the remote helper: $(repr(line))"))
    Dict{String,Any}(TOML.parse(line)["r"])
end

"""
    helper_command(h, c, script, command, jobfile, jobs)::Cmd

The command that runs the staged helper `script` on `h`. LinearAlgebra is part of the
sysimage, so the BLAS thread count must be in the process environment before Julia
starts; the script sets it again for the workers.
"""
function helper_command(h::RemoteHost, c::HelperConfig, script, command, jobfile, jobs)
    cmd = `env OPENBLAS_NUM_THREADS=1 $(remote_julia(h, c)) --startup-file=no --project=$(julia_project(h, c)) $script $command $jobfile`
    jobs > 0 ? `$cmd --jobs $jobs` : cmd
end

"""
    run_helper(h, c, command, spec; jobs = 0, on_record = Returns(nothing),
               warn = Returns(nothing))::Vector{Dict{String,Any}}

Run `command` (`"inspect"` or `"extract"`) of the remote helper with the job
description `spec`, a TOML-serializable dictionary. The script and the job file
are pushed to the staging directory first, so the host always runs the script that
matches this checkout. `on_record` is called with each output record as it
arrives; all records are returned. Standard error of a successful run, which the
helper uses for warnings, is passed to `warn` and never discarded. `jobs` is the
helper's `--jobs` (0 lets it decide). The job file is removed after a successful
run and kept after a failed one.
"""
function run_helper(h::RemoteHost, c::HelperConfig, command::AbstractString,
                    spec::AbstractDict; jobs::Integer = 0, on_record = Returns(nothing),
                    warn = Returns(nothing))
    staging = staging_dir(h, c)
    script = push_file(h, HELPER_SCRIPT, staging)
    jobfile = mktempdir() do dir
        file = joinpath(dir, "$command.toml")
        open(io -> TOML.print(io, spec), file, "w")
        push_file(h, file, joinpath(staging, "jobs"); checksum = true)
    end
    cmd = helper_command(h, c, script, command, jobfile, jobs)
    records = Dict{String,Any}[]
    warnings = stream_remote(h, cmd, function (line)
        record = parse_record(line)
        push!(records, record)
        on_record(record)
    end)
    isempty(warnings) || warn(warnings)
    remove_staged!(h, staging, [jobfile])
    records
end

"""
    inspect_files(h, c, files; groups = nothing, jobs = 0)::Vector{Tuple{Vector{String},Vector{Int},String}}

For each file in `files`, in order: the detector names, the stored size in bytes, and
the layout. The layout is the name of the tier group that holds the detectors
(`jlpks` in `jlpks/B00000C`) or `""` when the detectors are top-level groups. A file
without a detector axis has no names.

Without `groups`, the sizes are those of all names. `groups` holds one vector of
group names per file, and `files` must then be unique. The result for such a file
carries the sized group names in place of all names, and its sizes are in their
order; only those groups are read. A group a file lacks, or a record whose sized
names differ from the request, is an error.
"""
function inspect_files(h::RemoteHost, c::HelperConfig, files::AbstractVector{<:AbstractString};
                       groups::Union{Nothing,AbstractVector} = nothing, jobs::Integer = 0)
    if groups !== nothing
        length(groups) == length(files) || throw(DimensionMismatch(
            "$(length(groups)) group lists for $(length(files)) files"))
        seen = Set{String}()
        for file in files
            file in seen && throw(ArgumentError("file $file is listed more than once with group lists"))
            push!(seen, file)
        end
    end
    spec = groups === nothing ? Dict("files" => collect(String, files)) :
           Dict("job" => [Dict("file" => String(f), "groups" => collect(String, g))
                          for (f, g) in zip(files, groups)])
    records = run_helper(h, c, "inspect", spec; jobs)
    found = Dict(r["file"] => (String.(get(r, "sized", r["groups"])), Int.(r["bytes"]), String(r["layout"]))
                 for r in records)
    map(files, groups === nothing ? fill(nothing, length(files)) : groups) do file, requested
        haskey(found, file) || throw(ErrorException("the remote helper reported nothing for $file"))
        requested === nothing || found[file][1] == requested || throw(ErrorException(
            "the remote helper sized $(found[file][1]) for $file, not the requested $(collect(String, requested))"))
        found[file]
    end
end
