# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const DEFAULT_HOST = "cslg4"

const PACKAGED_HOSTS_FILE = normpath(joinpath(@__DIR__, "..", "..", "config", "sync", "hosts.yaml"))

config_dir() = joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "juleana", "sync")

function default_hosts_file()
    user = joinpath(config_dir(), "hosts.yaml")
    return isfile(user) ? user : PACKAGED_HOSTS_FILE
end

const CONFIG_FILE_ERRORS = Union{YAML.ScannerError,YAML.ParserError,YAML.ComposerError,YAML.ConstructorError,SystemError,ArgumentError}

function read_config(file::AbstractString)
    try
        return readprops(file; subst_pathvar = false, subst_env = false)
    catch err
        err isa CONFIG_FILE_ERRORS || rethrow()
        throw(ArgumentError("cannot read $file: " * sprint(showerror, err)))
    end
end

# The tool never guesses a local root.
function default_local_root()
    file = joinpath(config_dir(), "settings.yaml")
    isfile(file) || return ""
    settings = read_config(file)
    haskey(settings, :local_root) || return ""
    settings.local_root isa AbstractString || throw(ArgumentError("local_root in $file must be a path, got $(repr(settings.local_root))"))
    return String(settings.local_root)
end

function host_remote_root(file::AbstractString, host::AbstractString)
    entry = get(read_config(file), Symbol(host), nothing)
    entry isa PropDict && haskey(entry, :remote_root) && entry.remote_root isa AbstractString ||
        throw(ArgumentError("host $host in $file needs a remote_root path; add it there or pass --remote-root"))
    return String(entry.remote_root)
end

function host_helper_config(file::AbstractString, host::AbstractString)
    entry = get(read_config(file), Symbol(host), PropDict())
    return HelperConfig((haskey(entry, key) ? String(entry[key]) : nothing for key in (:julia, :julia_project, :staging))...)
end

function default_selection_path(host::AbstractString, production::AbstractString)
    return joinpath(config_dir(), host, replace(production, '/' => '-') * ".yaml")
end

"""
    SyncSettings(; host, remote_root, production, local_root, mount_root, staging, jobs, selection, hosts_file)

The values of the settings panel and of the command line, all text so that an invalid entry can be held and shown with its
reason. An empty `remote_root` stands for the host's entry in `hosts_file`, an empty `staging` for the host default, an empty
`mount_root` for no mount and an empty `selection` for the default selection path of the host and production.
[`Options`](@ref) turns valid settings into the values the rest of the tool uses. The constructor reads no file.
"""
Base.@kwdef mutable struct SyncSettings
    host::String = DEFAULT_HOST
    remote_root::String = ""
    production::String = ""
    local_root::String = ""
    mount_root::String = ""
    staging::String = ""
    jobs::String = "0"
    selection::String = ""
    hosts_file::String = PACKAGED_HOSTS_FILE
end

Base.copy(s::SyncSettings) = SyncSettings(; (name => getfield(s, name) for name in fieldnames(SyncSettings))...)

user_settings() = SyncSettings(; local_root = default_local_root(), hosts_file = default_hosts_file())

const SETTINGS_FIELDS = (:host, :remote_root, :production, :local_root, :mount_root, :staging, :jobs, :selection)
const FIELD_LABELS = (host = "Host", remote_root = "Remote root", production = "Production", local_root = "Local root",
                      mount_root = "Mount root",
                      staging = "Staging", jobs = "Jobs", selection = "Selection")
const CLI_NAMES = (host = "--host", remote_root = "--remote-root", production = "production name", local_root = "--local-root",
                   mount_root = "--mount-root", staging = "--staging", jobs = "--jobs", selection = "--out")

hosts_choices(file::AbstractString) = isfile(file) ? sort!(String.(keys(read_config(file)))) : String[]

host_remote_roots(file::AbstractString) = [host_remote_root(file, host) for host in hosts_choices(file)]

function preselect_production(folder::AbstractString, roots::AbstractVector{<:AbstractString})
    folder = normdir(folder)
    for root in roots
        prefix = endswith(root, "/") ? normdir(root) : normdir(root) * "/"
        startswith(folder, prefix) && length(folder) > length(prefix) && return String(folder[(length(prefix) + 1):end])
    end
    return nothing
end

function selection_path(s::SyncSettings)
    return !isempty(s.selection) ? s.selection : isempty(s.production) ? "" : default_selection_path(s.host, s.production)
end

function field_error(s::SyncSettings, field::Symbol; check_paths::Bool = false, cli::Bool = false)
    value = getfield(s, field)
    name = cli ? CLI_NAMES[field] : FIELD_LABELS[field]
    reason = if field === :host
        isempty(strip(value)) || occursin(r"\s", value) ? "an ssh alias without whitespace" : nothing
    elseif field === :remote_root
        if isempty(value)
            isfile(s.hosts_file) || return "$name must be set: there is no hosts file $(s.hosts_file)"
            try
                host_remote_root(s.hosts_file, s.host)
            catch err
                err isa ArgumentError || rethrow()
                return "$name must be set: $(err.msg)"
            end
        end
        nothing
    elseif field === :production
        isabspath(value) || ".." in splitpath(value) ? "a relative path below the remote root" : nothing
    elseif field === :local_root
        isempty(value) ? "set (local_root in settings.yaml of the configuration directory)" :
        check_paths && !isdir(expanduser(value)) ? "an existing directory" : nothing
    elseif field === :mount_root
        check_paths && !isempty(value) && !isdir(expanduser(value)) ? "an existing directory" : nothing
    elseif field === :staging
        isempty(value) || isabspath(value) || startswith(value, "~") ? nothing : "an absolute path or start with ~"
    elseif field === :jobs
        n = tryparse(Int, value)
        n === nothing || n < 0 ? "an integer >= 0" : nothing
    elseif field === :selection
        isempty(value) || endswith(value, ".yaml") ? nothing : "a path ending in .yaml"
    else
        throw(ArgumentError("unknown setting $field"))
    end
    return reason === nothing ? nothing : string(name, " must be ", reason, isempty(value) ? "" : ", got $value")
end

function settings_errors(s::SyncSettings; check_paths::Bool = false, cli::Bool = false)
    errors = [field => field_error(s, field; check_paths, cli) for field in SETTINGS_FIELDS]
    return filter!(e -> last(e) !== nothing, errors)
end
