# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const DEFAULT_HOST = "cslg4"

# The hosts file shipped with the package; it is only read.
const PACKAGED_HOSTS_FILE = normpath(joinpath(@__DIR__, "..", "..", "config", "sync", "hosts.yaml"))

"""
    config_dir()::String

The user's directory for hosts, settings and saved selections: `\$XDG_CONFIG_HOME/juleana/sync`, else
`~/.config/juleana/sync`. Nothing here is written except saved selections.
"""
config_dir() = joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "juleana", "sync")

"""
    default_selection_dir()::String

The directory that saved selections go to unless told otherwise: [`config_dir`](@ref).
"""
default_selection_dir() = config_dir()

"""
    default_hosts_file()::String

`hosts.yaml` of [`config_dir`](@ref) if it exists, else the file shipped with the package.
"""
function default_hosts_file()
    user = joinpath(config_dir(), "hosts.yaml")
    return isfile(user) ? user : PACKAGED_HOSTS_FILE
end

# Every configuration file is read here, so a malformed one is an error that names the file.
function read_config(file::AbstractString)
    try
        return readprops(file; subst_pathvar = false, subst_env = false)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("cannot read $file: " * sprint(showerror, err)))
    end
end

"""
    default_local_root()::String

The `local_root` key of `settings.yaml` in [`config_dir`](@ref), or `""` when there is no such key.
The tool never guesses a local root.
"""
function default_local_root()
    file = joinpath(config_dir(), "settings.yaml")
    isfile(file) || return ""
    settings = read_config(file)
    haskey(settings, :local_root) || return ""
    settings.local_root isa AbstractString || throw(ArgumentError("local_root in $file must be a path, got $(repr(settings.local_root))"))
    return String(settings.local_root)
end

"""
    host_remote_root(file::AbstractString, host::AbstractString)::String

The remote root that `file` (a YAML or JSON mapping of host aliases to
`{remote_root: ...}`) lists for `host`.
"""
function host_remote_root(file::AbstractString, host::AbstractString)
    hosts = read_config(file)
    haskey(hosts, Symbol(host)) || throw(ArgumentError("host $host is not listed in $file; add it there or pass --remote-root"))
    entry = hosts[Symbol(host)]
    entry isa PropDict && haskey(entry, :remote_root) && entry.remote_root isa AbstractString ||
        throw(ArgumentError("host $host in $file needs a remote_root path"))
    return String(entry.remote_root)
end

"""
    host_helper_config(file::AbstractString, host::AbstractString)::HelperConfig

The optional `julia`, `julia_project` and `staging` keys of `host`'s entry in the
hosts file `file`. A host without an entry, or an entry without those keys, selects
the defaults of [`HelperConfig`](@ref).
"""
function host_helper_config(file::AbstractString, host::AbstractString)
    hosts = read_config(file)
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
default_selection_path(production::AbstractString) = joinpath(default_selection_dir(), replace(production, '/' => '-') * ".yaml")

"""
    SyncSettings(; host, remote_root, production, local_root, mount_root, staging, jobs, selection, hosts_file)

The values of the settings panel and of the command line, all as text so that an invalid entry can be
held and shown with its reason. An empty `remote_root` stands for the host's entry in `hosts_file`, an
empty `staging` for the host default, an empty `mount_root` for no mount, an empty `selection` for
[`default_selection_path`](@ref) of the production. [`Options`](@ref) turns valid settings into the
values the rest of the tool uses. The constructor reads no file.
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

"""
    user_settings()::SyncSettings

`SyncSettings` with the Local root and the hosts file of the user's configuration directory.
"""
user_settings() = SyncSettings(; local_root = default_local_root(), hosts_file = default_hosts_file())

"The fields of [`SyncSettings`](@ref) that the user sets, in panel order."
const SETTINGS_FIELDS = (:host, :remote_root, :production, :local_root, :mount_root, :staging, :jobs, :selection)

"""
    hosts_choices(file)::Vector{String}

The host aliases listed in the hosts file `file`; none when the file does not exist.
"""
function hosts_choices(file::AbstractString)
    return isfile(file) ? sort!(String.(keys(read_config(file)))) : String[]
end

"""
    selection_path(s::SyncSettings)::String

The file the selection is saved to and loaded from: `s.selection`, else the default of the production,
else `""` while no production is named.
"""
function selection_path(s::SyncSettings)
    return !isempty(s.selection) ? s.selection : isempty(s.production) ? "" : default_selection_path(s.production)
end

"""
    field_error(s::SyncSettings, field::Symbol; check_paths = false, cli = false)::Union{Nothing,String}

Why the value of `field` is unusable, or `nothing`. The text names the field as the panel labels it;
with `cli` it names the command-line option instead (`--jobs must be an integer, got x`). With
`check_paths`, the local and mount roots must also be existing directories.
"""
function field_error(s::SyncSettings, field::Symbol; check_paths::Bool = false, cli::Bool = false)
    value = getfield(s, field)
    name(label, option) = cli ? option : label
    if field === :host
        return isempty(strip(value)) || occursin(r"\s", value) ?
               "$(name("Host", "--host")) must be an ssh alias without whitespace, got \"$value\"" : nothing
    elseif field === :remote_root
        isempty(value) || return nothing
        isfile(s.hosts_file) || return "$(name("Remote root", "--remote-root")) must be set: there is no hosts file $(s.hosts_file)"
        try
            host_remote_root(s.hosts_file, s.host)
        catch err
            err isa ArgumentError || rethrow()
            return cli ? err.msg : "Remote root: " * replace(err.msg, "pass --remote-root" => "set Remote root")
        end
        return nothing
    elseif field === :production
        return isempty(value) || !(isabspath(value) || ".." in splitpath(value)) ? nothing :
               "$(name("Production", "production name")) must be a relative path below the remote root, got \"$value\""
    elseif field === :local_root
        isempty(value) &&
            return cli ? "--local-root must be set: pass it or set local_root in $(joinpath(config_dir(), "settings.yaml"))" :
                   "Local root must be set"
        return check_paths && !isdir(expanduser(value)) ? "$(name("Local root", "--local-root")) $value is not an existing directory" :
               nothing
    elseif field === :mount_root
        return check_paths && !isempty(value) && !isdir(expanduser(value)) ?
               "$(name("Mount root", "--mount-root")) $value is not an existing directory" : nothing
    elseif field === :staging
        return isempty(value) || isabspath(value) || startswith(value, "~") ? nothing :
               "$(name("Staging", "--staging")) must be an absolute path or start with ~, got $value"
    elseif field === :jobs
        n = tryparse(Int, value)
        n === nothing && return cli ? "--jobs must be an integer, got $value" : "Jobs must be an integer >= 0, got $value"
        return n >= 0 ? nothing : cli ? "--jobs must not be negative, got $n" : "Jobs must be an integer >= 0, got $n"
    elseif field === :selection
        return isempty(value) || endswith(value, ".yaml") ? nothing : "$(name("Selection", "--out")) must end in .yaml, got $value"
    end
    return throw(ArgumentError("unknown setting $field"))
end

"""
    settings_errors(s::SyncSettings; check_paths = false, cli = false)::Vector{Pair{Symbol,String}}

The invalid fields of `s` with their reasons, in panel order.
"""
function settings_errors(s::SyncSettings; check_paths::Bool = false, cli::Bool = false)
    errors = Pair{Symbol,String}[]
    for field in SETTINGS_FIELDS
        message = field_error(s, field; check_paths, cli)
        message === nothing || push!(errors, field => message)
    end
    return errors
end
