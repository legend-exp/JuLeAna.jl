# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# `roots` spells every path key of `config` below `remote_root`, because a path outside has no place in the mirror.
struct Production
    name::String
    remote_root::String
    local_root::String
    mount_root::Union{Nothing,String}
    config::PropDict
    roots::Vector{Pair{String,String}}
    overlays::Vector{String}
    config_file::String
    setup_config::Bool
end

normdir(x) = (s = rstrip(normpath(String(x)), '/'); isempty(s) ? "/" : s)

# Compares strings; symlinks are not resolved.
below(path::AbstractString, root::AbstractString) = path == root || startswith(path, rstrip(root, '/') * "/")

function overlay_files(h::RemoteHost, remote_root::AbstractString, name::AbstractString)
    root = normdir(remote_root)
    parts = splitpath(name)
    found = String[]
    for depth in 0:(length(parts) - 1)
        rel = join(parts[1:depth], "/")
        for entry in sort!(list_dir(h, normdir(joinpath(root, rel))); by = e -> e.name)
            entry.kind == :file && occursin(r"^config_[^/]+\.(json|ya?ml)$", entry.name) && push!(found, joinpath(rel, entry.name))
        end
    end
    return found
end

function Production(h::RemoteHost, name::AbstractString, remote_root::AbstractString, local_root::AbstractString;
                    mount_root::Union{Nothing,AbstractString} = nothing)
    root = normdir(remote_root)
    (isabspath(name) || ".." in splitpath(name)) &&
        throw(ArgumentError("production name must be a relative path below the remote root, got \"$name\""))
    name = rstrip(normpath(name), '/')
    dir = normdir(joinpath(root, name))
    dir != root && below(dir, root) ||
        throw(ArgumentError("production name must be a relative path below the remote root, got \"$name\""))
    entries = list_dir(h, dir)
    configs = [e.name for e in entries if e.kind == :file && e.name in PRODUCTION_CONFIGS]
    isempty(configs) && throw(ArgumentError("$dir holds neither config.json nor config.yaml, so it is not a production"))
    length(configs) == 1 ||
        throw(ArgumentError("$dir holds both config.json and config.yaml; keep the one LEGEND_DATA_CONFIG names and remove the other"))
    setup = any(e -> e.kind == :dir && e.name == "setup", entries) &&
            any(e -> e.kind == :dir && e.name == "config", list_dir(h, joinpath(dir, "setup")))
    files = [joinpath(name, only(configs)); overlay_files(h, root, name)]
    parts = [parse_production_config(read_file(h, joinpath(root, file)), dirname(joinpath(root, file)); extension = splitext(file)[2])
             for file in files]
    config = reduce(merge!, parts)
    return Production(String(name), root, normdir(local_root), mount_root === nothing ? nothing : normdir(mount_root), config,
                      production_roots(h, config, root), files[2:end], only(configs), setup)
end

# Environment variables are not expanded, because the config describes the host.
function parse_production_config(text::AbstractString, config_dir::AbstractString; extension::AbstractString = ".json")
    config = mktempdir() do dir
        path = joinpath(dir, extension == ".json" ? "config.json" : "config.yaml")    # the YAML reader returns nothing for `.yml`
        write(path, text)
        return readprops(path; subst_pathvar = false, subst_env = false, trim_null = false)
    end
    PropDicts.substitute_vars!(PropDicts._dict(config), Dict("_" => String(config_dir)); use_env = false, ignore_missing = false,
                               recursive = true)
    return config
end

# A key outside the remote root as written is compared again with symlinks resolved on the host, then spelled below the
# remote root; a key inside as written is kept, even where symlinks lead elsewhere.
function production_roots(h::RemoteHost, config::PropDict, remote_root::AbstractString)
    setups = config.setups
    length(setups) == 1 || throw(ArgumentError("a production config must contain exactly one setup, found $(length(setups)): " *
                                               join(string.(keys(setups)), ", ")))
    root = normdir(remote_root)
    paths = [String(key) => normdir(value) for (key, value) in PropDicts._dict(only(values(setups)).paths)]
    outside = [dir for (_, dir) in paths if !below(dir, root)]
    real = isempty(outside) ? Dict{String,String}() : Dict(zip([root; outside], real_paths(h, [root; outside])))
    roots = Pair{String,String}[]
    for (key, dir) in paths
        if !below(dir, root)
            below(real[dir], real[root]) ||
                throw(ArgumentError("path key $key resolves to $dir, which is outside the remote root $root, also with symlinks " *
                                    "resolved ($(real[dir]) is not below $(real[root])), and cannot be mirrored"))
            dir = normdir(joinpath(root, relpath(real[dir], real[root])))
        end
        push!(roots, key => dir)
    end
    return sort!(roots; by = first)
end

function relative(p::Production, remote_path::AbstractString)
    path, root = normdir(remote_path), normdir(p.remote_root)
    below(path, root) || throw(ArgumentError("$path is not inside the remote root $root"))
    return path == root ? "" : relpath(path, root)
end

to_local(p::Production, remote_path::AbstractString) = normdir(joinpath(p.local_root, relative(p, remote_path)))

# The mirrored config file stays byte-identical to the remote one so rsync never sees it as locally modified.
function write_local_config(p::Production)
    config = deepcopy(p.config)
    paths = PropDicts._dict(only(values(config.setups)).paths)
    for (key, dir) in p.roots
        paths[Symbol(key)] = to_local(p, dir)
    end
    path = joinpath(p.local_root, p.name, "config_local.yaml")
    mkpath(dirname(path))
    YAML.write_file(path, config)
    return path
end
