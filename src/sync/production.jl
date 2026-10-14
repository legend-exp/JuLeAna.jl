"""
    Production(h::RemoteHost, name, remote_root, local_root; mount_root = nothing)

A production of `remote_root` on `h`, together with the local directory that
mirrors it. `name` is the production's path relative to `remote_root` and may
have several components (`temp/jl-dev`); it must stay below the root.

The production's `config.json` is read first, then every overlay returned by
[`overlay_files`](@ref), root first. `\$_` expands to the directory of the file it
appears in, and the files are deep-merged so that a later file wins: an overlay
overrides the production, and a deeper overlay overrides a shallower one. Every
path of the merged `config` must lie inside `remote_root`, because a path outside
it has no place in the mirror. `overlays` lists the overlay files applied, relative
to `remote_root`.
"""
struct Production
    name::String
    remote_root::String
    local_root::String
    mount_root::Union{Nothing,String}
    config::PropDict
    roots::Vector{Pair{String,String}}
    overlays::Vector{String}
end

# A directory path without a trailing separator; the filesystem root normalizes
# to "/" rather than the empty string that stripping it would otherwise produce.
normdir(x) = (s = rstrip(normpath(String(x)), '/'); isempty(s) ? "/" : s)

"""
    overlay_files(h::RemoteHost, remote_root, name)::Vector{String}

The site overlay configs that apply to production `name`: the files called
`config_<site>.json`, `.yaml` or `.yml` in each directory from `remote_root` down
to the parent of the production, root first and sorted by name within a
directory. The production directory itself is not searched. Paths are relative to
`remote_root`.
"""
function overlay_files(h::RemoteHost, remote_root::AbstractString, name::AbstractString)
    root = normdir(remote_root)
    parts = splitpath(name)
    found = String[]
    for depth in 0:length(parts) - 1
        rel = join(parts[1:depth], "/")
        for entry in sort!(list_dir(h, normdir(joinpath(root, rel))); by = e -> e.name)
            entry.kind == :file && occursin(r"^config_[^/]+\.(json|ya?ml)$", entry.name) &&
                push!(found, joinpath(rel, entry.name))
        end
    end
    found
end

function Production(h::RemoteHost, name::AbstractString,
                    remote_root::AbstractString, local_root::AbstractString;
                    mount_root::Union{Nothing,AbstractString} = nothing)
    root = normdir(remote_root)
    (isabspath(name) || ".." in splitpath(name)) && throw(ArgumentError(
        "production name must be a relative path below the remote root, got \"$name\""))
    name = rstrip(normpath(name), '/')
    dir = normdir(joinpath(root, name))
    startswith(dir, root * "/") || throw(ArgumentError(
        "production name must be a relative path below the remote root, got \"$name\""))
    files = [joinpath(name, "config.json"); overlay_files(h, root, name)]
    config = nothing
    for file in files
        path = joinpath(root, file)
        part = parse_production_config(read_file(h, path), dirname(path);
                                       extension = splitext(file)[2])
        config === nothing ? (config = part) : merge!(config, part)
    end
    mount = mount_root === nothing ? nothing : normdir(mount_root)
    Production(String(name), root, normdir(local_root), mount, config,
               production_roots(config, root), files[2:end])
end

"""
    parse_production_config(text::AbstractString, config_dir::AbstractString; extension = ".json")::PropDict

Parse a config file that was read as text, expanding `\$_` to `config_dir`.
`extension` selects the format (`.json`, `.yaml` or `.yml`). Environment variables
are not expanded: the config describes the remote machine, so a variable resolved
against this one would be a different path. Any variable other than `_` is an
error.
"""
function parse_production_config(text::AbstractString, config_dir::AbstractString;
                                 extension::AbstractString = ".json")
    config = mktempdir() do dir
        # The YAML reader returns nothing for a `.yml` file; `.yaml` reads the same format.
        path = joinpath(dir, extension == ".json" ? "config.json" : "config.yaml")
        write(path, text)
        readprops(path; subst_pathvar = false, subst_env = false, trim_null = false)
    end
    PropDicts.substitute_vars!(PropDicts._dict(config),
                               Dict("_" => String(config_dir));
                               use_env = false, ignore_missing = false, recursive = true)
    config
end

"""
    production_roots(config::PropDict, remote_root::AbstractString)

The configured path keys and their absolute remote directories, sorted by key.
"""
function production_roots(config::PropDict, remote_root::AbstractString)
    setups = config.setups
    length(setups) == 1 || throw(ArgumentError(
        "a production config must contain exactly one setup, found $(length(setups)): " *
        join(string.(keys(setups)), ", ")))
    root = normdir(remote_root)
    roots = Pair{String,String}[]
    for (key, value) in PropDicts._dict(only(values(setups)).paths)
        dir = normdir(value)
        dir == root || startswith(dir, root * "/") || throw(ArgumentError(
            "path key $key resolves to $dir, which is outside the remote root $root and cannot be mirrored"))
        push!(roots, String(key) => dir)
    end
    sort!(roots; by = first)
end

"""
    relative(p::Production, remote_path)::String

`remote_path` expressed relative to the remote root, the form rsync's
`--files-from` list consumes. The remote root itself maps to `""`.
"""
function relative(p::Production, remote_path::AbstractString)
    path = normdir(remote_path)
    root = normdir(p.remote_root)
    path == root && return ""
    startswith(path, root * "/") || throw(ArgumentError(
        "$path is not inside the remote root $root"))
    relpath(path, root)
end

"""
    to_local(p::Production, remote_path)::String

Where `remote_path` lives in the local mirror.
"""
to_local(p::Production, remote_path::AbstractString) =
    normdir(joinpath(p.local_root, relative(p, remote_path)))

"""
    to_mount(p::Production, remote_path)::String

Where `remote_path` appears under the mounted remote filesystem. Link mode needs
a mount root; without one there is nothing for a symlink to point at.
"""
function to_mount(p::Production, remote_path::AbstractString)
    p.mount_root === nothing && throw(ArgumentError(
        "no mount root configured; pass --mount-root to use link mode"))
    normdir(joinpath(p.mount_root, relative(p, remote_path)))
end

"""
    local_config(p::Production)::PropDict

The production's merged config with every path pointing into the mirror. Every
path lies inside `remote_root` (see [`production_roots`](@ref)), including a value
that is the remote root itself, and is mapped through [`to_local`](@ref).
"""
function local_config(p::Production)
    config = deepcopy(p.config)
    paths = PropDicts._dict(only(values(config.setups)).paths)
    for (key, value) in collect(paths)
        paths[key] = to_local(p, value)
    end
    config
end

"""
    write_local_config(p::Production)::String

Write `config_local.yaml` next to the mirrored `config.json` and return its path.
The mirrored `config.json` stays byte-identical to the remote one, so rsync never
sees it as locally modified.
"""
function write_local_config(p::Production)
    path = joinpath(p.local_root, p.name, "config_local.yaml")
    mkpath(dirname(path))
    YAML.write_file(path, local_config(p))
    path
end
