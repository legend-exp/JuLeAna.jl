# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# The mirror sits beside the dataflow checkout, so a production's relative
# layout is the same here as on the remote.
const DEFAULT_LOCAL_ROOT = normpath(joinpath(@__DIR__, "..", "..", "..", "data"))
const DEFAULT_SELECTION_DIR = normpath(joinpath(@__DIR__, "..", "..", "config", "sync"))
const DEFAULT_HOSTS_FILE = joinpath(DEFAULT_SELECTION_DIR, "hosts.yaml")

"""
    host_remote_root(file::AbstractString, host::AbstractString)::String

The remote root that `file` (a YAML or JSON mapping of host aliases to
`{remote_root: ...}`) lists for `host`.
"""
function host_remote_root(file::AbstractString, host::AbstractString)
    hosts = readprops(file; subst_pathvar = false, subst_env = false)
    haskey(hosts, Symbol(host)) || throw(ArgumentError("host $host is not listed in $file; add it there or pass --remote-root"))
    return String(hosts[Symbol(host)].remote_root)
end

"""
    host_helper_config(file::AbstractString, host::AbstractString)::HelperConfig

The optional `julia`, `julia_project` and `staging` keys of `host`'s entry in the
hosts file `file`. A host without an entry, or an entry without those keys, selects
the defaults of [`HelperConfig`](@ref).
"""
function host_helper_config(file::AbstractString, host::AbstractString)
    hosts = readprops(file; subst_pathvar = false, subst_env = false)
    haskey(hosts, Symbol(host)) || return HelperConfig()
    entry = hosts[Symbol(host)]
    value(key) = haskey(entry, key) ? String(entry[key]) : nothing
    return HelperConfig(value(:julia), value(:julia_project), value(:staging))
end

"""
    default_selection_path(production::AbstractString)::String

Where the interface saves the selection for `production` unless told otherwise.
Directory separators in the production path become dashes.
"""
default_selection_path(production::AbstractString) = joinpath(DEFAULT_SELECTION_DIR, replace(production, '/' => '-') * ".yaml")

"""
    Options

The parsed command line. `mount_root` and `from` are `nothing` when the flag was
not given. `production` and `out` are empty when no production was named: the
interface then asks for one, and a headless run takes it from the selection file.
Every other field always has a value. `jobs` is the helper's worker count, 0
meaning its own default; `helper` says how to run the remote helper on the host.
"""
struct Options
    host::String
    remote_root::String
    local_root::String
    mount_root::Union{Nothing,String}
    production::String
    out::String
    from::Union{Nothing,String}
    dry_run::Bool
    yes::Bool
    jobs::Int
    helper::HelperConfig
end

function Options(host, remote_root, local_root, mount_root, production, out, from, dry_run, yes)
    return Options(host, remote_root, local_root, mount_root, production, out, from, dry_run, yes,
                   0, HelperConfig())
end

"""
    parse_options(args::AbstractVector{<:AbstractString}; hosts_file = DEFAULT_HOSTS_FILE)::Options

Without `--remote-root`, the root of `--host` is read from `hosts_file`. The helper
settings come from the host's entry in `hosts_file`; `--staging` replaces its staging
directory and is a path on the host: absolute or starting with `~`.
"""
function parse_options(args::AbstractVector{<:AbstractString}; hosts_file::AbstractString = DEFAULT_HOSTS_FILE)
    settings = ArgParseSettings(prog = "juleana-sync",
                                description = "Mirror part of a remote LEGEND data production into a local " *
                                              "directory that LegendDataManagement can open unchanged.")
    @add_arg_table! settings begin
        "--host"
        help = "ssh alias of the machine holding the production"
        arg_type = String
        default = "cslg4"
        "--remote-root"
        help = "remote directory holding the productions (default: the host's entry in config/sync/hosts.yaml)"
        dest_name = "remote_root"
        arg_type = String
        default = ""
        "--local-root"
        help = "local directory mirroring the remote root"
        dest_name = "local_root"
        arg_type = String
        default = DEFAULT_LOCAL_ROOT
        "--mount-root"
        help = "where the remote root is mounted; enables link mode"
        dest_name = "mount_root"
        arg_type = String
        default = ""
        "--jobs"
        help = "at most this many worker processes for the remote extraction helper, capped by the file count (2 or more uses workers for two or more files; a single file runs in-process; default: the helper decides)"
        arg_type = String
        default = "0"
        "--staging"
        help = "directory on the host where extracted files are staged (default: the host's entry in config/sync/hosts.yaml, else \$TMPDIR/juleana-sync-\$USER)"
        arg_type = String
        default = ""
        "--production"
        help = "production to sync, as a path relative to the remote root (default: choose in the interface)"
        arg_type = String
        default = ""
        "--out"
        help = "where the interface saves the selection (a .yaml file)"
        arg_type = String
        default = ""
        "--from"
        help = "apply a saved selection without starting the interface"
        arg_type = String
        default = ""
        "--dry-run"
        help = "with --from: ask rsync what would move and print it"
        dest_name = "dry_run"
        action = :store_true
        "--yes"
        help = "with --from: transfer without asking"
        action = :store_true
    end
    parsed = parse_args(args, settings)

    from = isempty(parsed["from"]) ? nothing : parsed["from"]
    (from === nothing && (parsed["dry_run"] || parsed["yes"])) &&
        throw(ArgumentError("--dry-run and --yes only mean something together with --from"))
    mount = isempty(parsed["mount_root"]) ? nothing : abspath(parsed["mount_root"])
    out = !isempty(parsed["out"]) ? parsed["out"] :
          isempty(parsed["production"]) ? "" : default_selection_path(parsed["production"])
    isempty(out) || endswith(out, ".yaml") || throw(ArgumentError("--out must end in .yaml, got $out"))
    remote_root = isempty(parsed["remote_root"]) ?
                  host_remote_root(hosts_file, parsed["host"]) : parsed["remote_root"]

    jobs = tryparse(Int, parsed["jobs"])
    jobs === nothing && throw(ArgumentError("--jobs must be an integer, got $(parsed["jobs"])"))
    jobs >= 0 || throw(ArgumentError("--jobs must not be negative, got $jobs"))
    helper = isfile(hosts_file) ? host_helper_config(hosts_file, parsed["host"]) : HelperConfig()
    staging = parsed["staging"]
    isempty(staging) || isabspath(staging) || startswith(staging, "~") ||
        throw(ArgumentError("--staging must be an absolute path or start with ~, got $staging"))
    isempty(staging) || (helper = HelperConfig(helper.julia, helper.julia_project, staging))

    # check_mount compares a path's device with its parent's, which only works
    # for an absolute path; --remote-root feeds path arithmetic that assumes
    # the same.
    return Options(parsed["host"], abspath(remote_root), abspath(parsed["local_root"]),
                   mount, parsed["production"], out, from, parsed["dry_run"], parsed["yes"],
                   jobs, helper)
end

"""
    main(args::AbstractVector{<:AbstractString})::Int
    main(options::Options, host::RemoteHost = SSHHost(options.host))::Int

Entry point of the `juleana-sync` app and of `julia -m JuLeAna.Sync`; run the tool and return the
process exit code. Every failure is thrown; a nonzero return means the tool declined the request, not
that it hid an error.
"""
function (@main)(args::AbstractVector{<:AbstractString})
    return main(parse_options(args))
end

function main(options::Options, host::RemoteHost = SSHHost(options.host))
    return options.from === nothing ? run_tui(options, host) : run_headless(options, host)
end

"""
    run_headless(options::Options, host::RemoteHost)::Int

Apply a saved selection without starting the interface. The production is the one
named by `--production`, or else the one the selection records. The estimate is always
shown first; `--yes` skips the question that follows it, `--dry-run` stops there.
Returns 1 when the user answers no. Extract entries need the remote helper environment;
an environment that is missing is an error that names the command that creates it,
because there is no one to ask.
"""
function run_headless(options::Options, host::RemoteHost)
    name = isempty(options.production) ?
           String(readprops(options.from; subst_pathvar = false, subst_env = false).production) :
           options.production
    production = Production(host, name, options.remote_root,
                            options.local_root; mount_root = options.mount_root)
    selection = load_selection(options.from, production)

    printer = StepPrinter()
    (; estimate, staging, free) = with_failed_step(printer) do
        return estimate_selection(host, production, selection; helper = options.helper, jobs = options.jobs, report = printer)
    end
    println()
    println(format_estimate(estimate))
    isempty(estimate.not_in_run) || println("not in run: ", format_not_in_run(estimate.not_in_run))
    staging === nothing || println("staging ", staging, ": ", format_bytes(free), " free")
    options.dry_run && return 0

    if !options.yes
        print("transfer? [y/N] ")
        startswith(lowercase(readline()), "y") || return 1
    end

    printer = StepPrinter()
    result = with_failed_step(printer) do
        return apply!(host, production, selection; helper = options.helper, jobs = options.jobs, report = printer)
    end
    println()
    println(summary_text(result))
    return 0
end
