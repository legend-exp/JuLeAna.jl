# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const HELPER_SCRIPT = joinpath(@__DIR__, "remote", "extract.jl")

const HELPER_PACKAGES = ["HDF5" => "0.17", "ParallelProcessingTools" => "0.4"]

const DEFAULT_REMOTE_JULIA = "~/.juliaup/bin/julia"
const DEFAULT_REMOTE_PROJECT = "~/.julia/environments/juleana-sync"

# Home directories are quota-limited on clusters, so staging defaults to the temporary directory.
const REMOTE_STAGING_SCRIPT = "printf %s \"\${TMPDIR:-/tmp}/juleana-sync-\$(id -un)\""

Base.@kwdef struct HelperConfig
    julia::Union{Nothing,String} = nothing
    julia_project::Union{Nothing,String} = nothing
    staging::Union{Nothing,String} = nothing
end

remote_julia(h::SSHHost, c::HelperConfig) = Cmd([expand_home(h, something(c.julia, DEFAULT_REMOTE_JULIA))])
remote_julia(::LocalHost, c::HelperConfig) = c.julia === nothing ? Base.julia_cmd() : Cmd([c.julia])

julia_project(h::SSHHost, c::HelperConfig) = expand_home(h, something(c.julia_project, DEFAULT_REMOTE_PROJECT))

function julia_project(::LocalHost, c::HelperConfig)
    c.julia_project === nothing || return c.julia_project
    active = Base.active_project()
    active === nothing && throw(ErrorException("the local helper runs in the active project, but there is no active project"))
    deps = get(TOML.parsefile(active), "deps", Dict{String,Any}())
    lacking = [name for name in first.(HELPER_PACKAGES) if !haskey(deps, name)]
    isempty(lacking) ||
        throw(ErrorException("the active project $(dirname(active)) lacks $(join(lacking, ", ")), which the local helper needs"))
    return dirname(active)
end

function staging_dir(h::SSHHost, c::HelperConfig)
    return c.staging === nothing ? String(strip(run_remote(h, `sh -c $REMOTE_STAGING_SCRIPT`))) : expand_home(h, c.staging)
end
staging_dir(::LocalHost, c::HelperConfig) = something(c.staging, joinpath(tempdir(), "juleana-sync-" * get(ENV, "USER", "user")))

struct EnvironmentStatus
    julia::String
    project::String
    present::Bool
    lacking::Vector{String}
end

environment_ready(s::EnvironmentStatus) = s.present && isempty(s.lacking)

function ensure_environment(h::RemoteHost, c::HelperConfig)
    version = String(strip(run_remote(h, `$(remote_julia(h, c)) --version`)))
    project = julia_project(h, c)
    toml = joinpath(project, "Project.toml")
    names = first.(HELPER_PACKAGES)
    remote_test(h, "-f", toml) || return EnvironmentStatus(version, project, false, names)
    deps = get(TOML.parse(read_file(h, toml)), "deps", Dict{String,Any}())
    return EnvironmentStatus(version, project, true, [name for name in names if !haskey(deps, name)])
end

function bootstrap_command(h::RemoteHost, c::HelperConfig)
    specs = join(("Pkg.PackageSpec(name = \"$name\", version = \"$version\")" for (name, version) in HELPER_PACKAGES), ", ")
    return `$(remote_julia(h, c)) --startup-file=no --project=$(julia_project(h, c)) -e $("import Pkg; Pkg.add([$specs])")`
end

function environment_problem(s::EnvironmentStatus, h::RemoteHost, c::HelperConfig)
    return "the helper environment $(s.project) " * (s.present ? "lacks $(join(s.lacking, ", "))" : "does not exist") *
           "; create it with: $(Base.shell_escape(bootstrap_command(h, c)))"
end

# An existing environment, and the active project that `LocalHost` uses, are never modified.
function bootstrap_environment!(h::RemoteHost, c::HelperConfig)
    h isa LocalHost && c.julia_project === nothing &&
        throw(ArgumentError("refusing to modify the active project $(dirname(Base.active_project())); name a helper environment with julia_project"))
    existing = ensure_environment(h, c)
    existing.present &&
        throw(ErrorException("the helper environment $(existing.project) already exists; refusing to modify it. Add the missing packages " *
                             "($(isempty(existing.lacking) ? "none" : join(existing.lacking, ", "))) yourself, or name another julia_project in hosts.yaml"))
    make_dir(h, julia_project(h, c))
    run_remote(h, bootstrap_command(h, c))
    status = ensure_environment(h, c)
    environment_ready(status) || throw(ErrorException(environment_problem(status, h, c)))
    return status
end

# The script and job file are pushed to staging first so the host runs the script of this checkout; the job file is kept
# after a failed run.
function run_helper(h::RemoteHost, c::HelperConfig, command::AbstractString, spec::AbstractDict; jobs::Integer = 0,
                    on_record = Returns(nothing),
                    warn = Returns(nothing))
    staging = staging_dir(h, c)
    script = push_file(h, HELPER_SCRIPT, staging)
    jobfile = mktempdir() do dir
        file = joinpath(dir, "$command.toml")
        open(io -> TOML.print(io, spec), file, "w")
        return push_file(h, file, joinpath(staging, "jobs"); checksum = true)
    end
    # LinearAlgebra is in the sysimage, so the BLAS thread count must be set before Julia starts.
    cmd = `env OPENBLAS_NUM_THREADS=1 $(remote_julia(h, c)) --startup-file=no --project=$(julia_project(h, c)) $script $command $jobfile`
    jobs > 0 && (cmd = `$cmd --jobs $jobs`)
    records = Dict{String,Any}[]
    function on_line(line)
        startswith(line, "r = {") || throw(ErrorException("unexpected output from the remote helper: $(repr(line))"))
        push!(records, Dict{String,Any}(TOML.parse(line)["r"]))
        return on_record(records[end])
    end
    warnings = last(stream_command(remote_command(h, cmd), on_line))
    isempty(warnings) || warn(warnings)
    remove_staged!(h, staging, [jobfile])
    return records
end

# With `groups`, only those are read; a missing group or a result that differs from the request is an error.
function inspect_files(h::RemoteHost, c::HelperConfig, files::AbstractVector{<:AbstractString};
                       groups::Union{Nothing,AbstractVector} = nothing,
                       jobs::Integer = 0, on_record = Returns(nothing))
    allunique(files) || throw(ArgumentError("files must be unique, they key the results"))
    wanted = something(groups, fill(nothing, length(files)))
    length(wanted) == length(files) || throw(DimensionMismatch("$(length(wanted)) group lists for $(length(files)) files"))
    job(f, g) = g === nothing ? Dict("file" => String(f)) : Dict("file" => String(f), "groups" => collect(String, g))
    records = run_helper(h, c, "inspect", Dict("job" => map(job, files, wanted)); jobs, on_record)
    found = Dict(r["file"] => (String.(r["groups"]), Int.(r["bytes"]), String(r["layout"])) for r in records)
    return map(files, wanted) do file, requested
        haskey(found, file) || throw(ErrorException("the remote helper reported nothing for $file"))
        names, bytes, _ = found[file]
        length(names) == length(bytes) ||
            throw(ErrorException("the remote helper sized $(length(bytes)) groups of $file for $(length(names)) names"))
        requested === nothing || names == requested ||
            throw(ErrorException("the remote helper sized $names for $file, not the requested $(collect(String, requested))"))
        return found[file]
    end
end
