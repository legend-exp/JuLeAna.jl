# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    Options

The parsed command line. `mount_root` and `from` are `nothing` when not given; `production` and `out` are empty when no
production was named (the interface then asks for one, and a headless run takes it from the selection file). `jobs` is the
helper's worker count (0 for its own default) and `helper` says how to run the remote helper on the host.
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

function Options(host, remote_root, local_root, mount_root, production, out, from, dry_run, yes, jobs = 0)
    return Options(host, remote_root, local_root, mount_root, production, out, from, dry_run, yes, jobs, HelperConfig())
end

# Paths become absolute because `check_mount` compares a path's device with its parent's.
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

function SyncSettings(o::Options; hosts_file::AbstractString = default_hosts_file())
    explicit = isempty(o.production) || o.out != default_selection_path(o.host, o.production) ? o.out : ""
    return SyncSettings(; host = o.host, remote_root = o.remote_root, production = o.production, local_root = o.local_root,
                        mount_root = something(o.mount_root, ""), staging = something(o.helper.staging, ""), jobs = string(o.jobs),
                        selection = explicit, hosts_file)
end

function parse_settings(args::AbstractVector{<:AbstractString}; hosts_file::AbstractString = default_hosts_file())
    parser = ArgParseSettings(prog = "juleana-sync",
                              description = "Mirror part of a remote LEGEND data production into a local directory that LegendDataManagement can open unchanged.")
    for (flag, help, default) in (("--host", "ssh alias of the machine holding the production", DEFAULT_HOST),
                                  ("--remote-root",
                                   "remote directory holding the productions (default: the host's entry in the hosts file of the configuration directory)", ""),
                                  ("--local-root", "local directory mirroring the remote root (default: local_root in settings.yaml of the configuration directory)",
                                   default_local_root()),
                                  ("--mount-root", "where the remote root is mounted; enables link mode", ""),
                                  ("--jobs",
                                   "at most this many worker processes for the remote extraction helper, capped by the file count (2 or more uses workers for two or more files; a single file runs in-process; default: the helper decides)",
                                   "0"),
                                  ("--staging",
                                   "directory on the host where extracted files are staged (default: the host's entry in the hosts file, else \$TMPDIR/juleana-sync-\$USER)",
                                   ""),
                                  ("--production", "production to sync, as a path relative to the remote root (default: choose in the interface)", ""),
                                  ("--out", "where the interface saves the selection (a .yaml file; default: <configuration directory>/<host>/<production>.yaml)", ""),
                                  ("--from", "apply a saved selection without starting the interface", ""))
        add_arg_table!(parser, flag,
                       Dict(:help => help, :arg_type => String, :default => default, :dest_name => replace(flag[3:end], '-' => '_')))
    end
    add_arg_table!(parser, "--dry-run",
                   Dict(:help => "with --from: ask rsync what would move and print it", :dest_name => "dry_run", :action => :store_true),
                   "--yes", Dict(:help => "with --from: transfer without asking", :action => :store_true))
    parsed = parse_args(args, parser)
    from = isempty(parsed["from"]) ? nothing : parsed["from"]
    from === nothing && (parsed["dry_run"] || parsed["yes"]) &&
        throw(ArgumentError("--dry-run and --yes only mean something together with --from"))
    settings = SyncSettings(; (field => parsed[field === :selection ? "out" : String(field)] for field in SETTINGS_FIELDS)..., hosts_file)
    return (; settings, from, dry_run = parsed["dry_run"], yes = parsed["yes"])
end

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

Apply the saved selection `options.from` without the interface, for the production named by `--production` or else the one the
selection records. The estimate is always shown first; `--yes` skips the question after it, `--dry-run` stops there. Returns 1
when the user answers no. Extract entries need the helper environment; a missing one is an error naming the command that
creates it.
"""
function run_headless(options::Options, host::RemoteHost)
    name = isempty(options.production) ? String(readprops(options.from; subst_pathvar = false, subst_env = false).production) :
           options.production
    production = Production(host, name, options.remote_root, options.local_root; mount_root = options.mount_root)
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
