# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

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
    Options(s::SyncSettings; from = nothing, dry_run = false, yes = false, cli = false)::Options

The options for valid settings. The first invalid field is an `ArgumentError` with its reason (named by
option with `cli`, by label otherwise). The helper settings come from the host's entry in the hosts
file; a staging directory in `s` replaces its staging directory. Paths become absolute because
[`check_mount`](@ref) compares a path's device with its parent's, which needs an absolute path.
"""
function Options(s::SyncSettings; from::Union{Nothing,AbstractString} = nothing, dry_run::Bool = false, yes::Bool = false,
                 cli::Bool = false)
    errors = settings_errors(s; cli)
    isempty(errors) || throw(ArgumentError(last(first(errors))))
    remote_root = isempty(s.remote_root) ? host_remote_root(s.hosts_file, s.host) : s.remote_root
    helper = isfile(s.hosts_file) ? host_helper_config(s.hosts_file, s.host) : HelperConfig()
    isempty(s.staging) || (helper = HelperConfig(helper.julia, helper.julia_project, s.staging))
    mount = isempty(s.mount_root) ? nothing : abspath(expanduser(s.mount_root))
    return Options(s.host, abspath(remote_root), abspath(expanduser(s.local_root)), mount, s.production, selection_path(s),
                   from === nothing ? nothing : String(from), dry_run, yes, parse(Int, s.jobs), helper)
end

"""
    SyncSettings(o::Options; hosts_file = default_hosts_file())

The settings that `o` came from. The default selection path of the production is not stored as an
explicit one.
"""
function SyncSettings(o::Options; hosts_file::AbstractString = default_hosts_file())
    explicit = isempty(o.production) || o.out != default_selection_path(o.host, o.production) ? o.out : ""
    return SyncSettings(; host = o.host, remote_root = o.remote_root, production = o.production, local_root = o.local_root,
                        mount_root = something(o.mount_root, ""), staging = something(o.helper.staging, ""), jobs = string(o.jobs),
                        selection = explicit, hosts_file)
end

"""
    parse_settings(args::AbstractVector{<:AbstractString}; hosts_file = default_hosts_file())

Parse the command line into `(; settings, from, dry_run, yes)`, where `settings` is a [`SyncSettings`](@ref)
whose empty fields keep their meaning (host default, no mount). The default Local root is
[`default_local_root`](@ref), empty without a `local_root` key in the user's `settings.yaml`.
"""
function parse_settings(args::AbstractVector{<:AbstractString}; hosts_file::AbstractString = default_hosts_file())
    parser = ArgParseSettings(prog = "juleana-sync",
                              description = "Mirror part of a remote LEGEND data production into a local " *
                                            "directory that LegendDataManagement can open unchanged.")
    @add_arg_table! parser begin
        "--host"
        help = "ssh alias of the machine holding the production"
        arg_type = String
        default = DEFAULT_HOST
        "--remote-root"
        help = "remote directory holding the productions (default: the host's entry in the hosts file of the configuration directory)"
        dest_name = "remote_root"
        arg_type = String
        default = ""
        "--local-root"
        help = "local directory mirroring the remote root (default: local_root in settings.yaml of the configuration directory)"
        dest_name = "local_root"
        arg_type = String
        default = default_local_root()
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
        help = "directory on the host where extracted files are staged (default: the host's entry in the hosts file, else \$TMPDIR/juleana-sync-\$USER)"
        arg_type = String
        default = ""
        "--production"
        help = "production to sync, as a path relative to the remote root (default: choose in the interface)"
        arg_type = String
        default = ""
        "--out"
        help = "where the interface saves the selection (a .yaml file; default: <configuration directory>/<production>.yaml)"
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
    parsed = parse_args(args, parser)

    from = isempty(parsed["from"]) ? nothing : parsed["from"]
    (from === nothing && (parsed["dry_run"] || parsed["yes"])) &&
        throw(ArgumentError("--dry-run and --yes only mean something together with --from"))
    settings = SyncSettings(; host = parsed["host"], remote_root = parsed["remote_root"], production = parsed["production"],
                            local_root = parsed["local_root"], mount_root = parsed["mount_root"], staging = parsed["staging"],
                            jobs = parsed["jobs"], selection = parsed["out"], hosts_file)
    return (; settings, from, dry_run = parsed["dry_run"], yes = parsed["yes"])
end

"""
    parse_options(args::AbstractVector{<:AbstractString}; hosts_file = default_hosts_file())::Options

Without `--remote-root`, the root of `--host` is read from `hosts_file`. The helper
settings come from the host's entry in `hosts_file`; `--staging` replaces its staging
directory and is a path on the host: absolute or starting with `~`. Invalid values are an
`ArgumentError` that names the option.
"""
function parse_options(args::AbstractVector{<:AbstractString}; hosts_file::AbstractString = default_hosts_file())
    (; settings, from, dry_run, yes) = parse_settings(args; hosts_file)
    return Options(settings; from, dry_run, yes, cli = true)
end

"""
    main(args::AbstractVector{<:AbstractString})::Int
    main(options::Options, host::RemoteHost = SSHHost(options.host))::Int

Entry point of the `juleana-sync` app and of `julia -m JuLeAna.Sync`; run the tool and return the
process exit code. Every failure is thrown; a nonzero return means the tool declined the request, not
that it hid an error. Without `--from` the screen opens with the fields filled from the arguments, whether or not
they are valid, and connects at once; with `--from` the arguments must be valid.
"""
function (@main)(args::AbstractVector{<:AbstractString})
    (; settings, from, dry_run, yes) = parse_settings(args)
    from === nothing && return run_tui(settings)
    return main(Options(settings; from, dry_run, yes, cli = true))
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
    selection = load_selection(options.from, production; host = options.host)

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
