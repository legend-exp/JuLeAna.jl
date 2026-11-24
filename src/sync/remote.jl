# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

abstract type RemoteHost end

struct SSHHost <: RemoteHost
    alias::String
    control_path::Union{Nothing,String}
end

function SSHHost(alias::AbstractString)
    proc, out, err = run_capture(`ssh -G $alias`)
    success(proc) || throw(ErrorException("ssh -G $alias failed with exit code $(proc.exitcode)\n$err"))
    m = match(r"^controlmaster[ \t]+(\S+)"mi, out)
    m !== nothing && lowercase(m.captures[1]) ∉ ("no", "false") && return SSHHost(alias, nothing)
    sshdir = joinpath(homedir(), ".ssh")
    isdir(sshdir) || throw(ArgumentError("SSH control directory does not exist: $sshdir"))
    return SSHHost(alias, joinpath(sshdir, "juleana-sync-%C"))
end

function run_capture(cmd::Cmd)
    out, err = IOBuffer(), IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdin = devnull, stdout = out, stderr = err))
    return proc, String(take!(out)), String(take!(err))
end

# `list_dir` and `dir_sizes` use Julia filesystem calls, because BSD `find` and `du` lack `-printf` and `-sb`.
struct LocalHost <: RemoteHost end

struct DirEntry
    name::String
    kind::Symbol
    size::Union{Nothing,Int}
end

# A dropped connection fails after about a minute instead of hanging.
function ssh_options(h::SSHHost)
    liveness = ["-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
    return h.control_path === nothing ? liveness :
           [liveness; "-o"; "ControlMaster=auto"; "-o"; "ControlPath=$(h.control_path)"; "-o"; "ControlPersist=60s"]
end

# The transport keeps its stdin, which is rsync's channel to the remote side, so it gets no `-n`.
function rsync_transport(h::SSHHost)
    words = ["ssh", "-o", "BatchMode=yes", ssh_options(h)...]
    any(w -> any(isspace, w), words) &&
        throw(ArgumentError("an ssh option contains whitespace, which rsync -e cannot carry: $(join(words, ' '))"))
    return ["-e", join(words, ' ')]
end

# ssh hands its command to the remote shell as one string, so every argument is quoted; `-n` and BatchMode keep ssh off the
# raw-mode terminal.
function remote_command(h::SSHHost, cmd::Cmd)
    return `ssh -n -o BatchMode=yes $(ssh_options(h)) $(h.alias) $(Base.shell_escape_posixly(cmd))`
end
remote_command(::LocalHost, cmd::Cmd) = cmd

function run_remote(h::RemoteHost, cmd::Cmd)
    full = remote_command(h, cmd)
    proc, out, err = run_capture(full)
    success(proc) && return out
    h isa SSHHost && proc.exitcode == 255 &&
        throw(ErrorException("ssh could not reach $(h.alias). ssh runs without a password prompt, so a host that needs one or a " *
                             "shared connection (ControlMaster) has to be opened first with `ssh $(h.alias)`.\n$err"))
    return throw(ErrorException("remote command failed with exit code $(proc.exitcode): $full\n$err"))
end

function parse_dir_listing(text::AbstractString)
    entries = DirEntry[]
    for line in eachsplit(chomp(text), '\n')
        isempty(line) && continue
        fields = split(line, '\t')
        length(fields) == 3 ||
            throw(ArgumentError("cannot parse directory listing line (expected type, size and name separated by tabs): $(repr(line))"))
        type_char, size_str, name = fields
        kind = type_char == "f" ? :file : type_char == "d" ? :dir : type_char == "l" ? :link : :other
        push!(entries, DirEntry(String(name), kind, kind == :file ? parse(Int, size_str) : nothing))
    end
    return entries
end

# Never descends: the tool must not walk a shared filesystem recursively.
list_dir(h::SSHHost, dir::AbstractString) = parse_dir_listing(run_remote(h, `find $dir -mindepth 1 -maxdepth 1 -printf '%y\t%s\t%f\n'`))

function list_dir(::LocalHost, dir::AbstractString)
    isdir(dir) || throw(ArgumentError("not a directory: $dir"))
    return map(readdir(dir)) do name
        st = lstat(joinpath(dir, name))
        kind = islink(st) ? :link : isfile(st) ? :file : isdir(st) ? :dir : :other
        return DirEntry(name, kind, kind == :file ? Int(filesize(st)) : nothing)
    end
end

const PRODUCTION_CONFIGS = ("config.json", "config.yaml")

function list_productions(h::RemoteHost, remote_root::AbstractString)
    text = run_remote(h, `find $remote_root -mindepth 2 -maxdepth 4 -type f '(' -name config.json -o -name config.yaml ')'`)
    return sort!(unique!([relpath(dirname(line), remote_root) for line in eachsplit(chomp(text), '\n') if !isempty(line)]))
end

# Counts a symlink by its target string like `du -sb`, but no directory inodes.
function dir_sizes(h::SSHHost, dirs::AbstractVector{<:AbstractString})
    isempty(dirs) && return Int[]
    sizes = [parse(Int, first(split(line, '\t'))) for line in eachsplit(chomp(run_remote(h, `du -sb $dirs`)), '\n') if !isempty(line)]
    length(sizes) == length(dirs) || throw(ErrorException("du reported $(length(sizes)) sizes for $(length(dirs)) directories"))
    return sizes
end

function dir_sizes(::LocalHost, dirs::AbstractVector{<:AbstractString})
    return map(dirs) do dir
        isdir(dir) || throw(ArgumentError("not a directory: $dir"))
        return sum(Int(lstat(joinpath(root, f)).size) for (root, _, files) in walkdir(dir; follow_symlinks = false) for f in files;
                   init = 0)
    end
end

read_file(h::RemoteHost, path::AbstractString) = run_remote(h, `cat $path`)

# Paths with symlinks resolved; components that do not exist are kept as written.
function real_paths(h::SSHHost, paths::AbstractVector{<:AbstractString})
    lines = split(chomp(run_remote(h, `realpath -m -- $paths`)), '\n')
    length(lines) == length(paths) || throw(ErrorException("realpath reported $(length(lines)) paths for $(length(paths))"))
    return String.(lines)
end

function real_paths(::LocalHost, paths::AbstractVector{<:AbstractString})
    return map(paths) do path
        head, tail = path, String[]
        while !ispath(head)
            pushfirst!(tail, basename(head))
            head = dirname(head)
        end
        return String(normdir(joinpath(realpath(head), tail...)))
    end
end

# Paths relative to `dir` that this user cannot read; an unreadable directory is listed and not entered.
function unreadable_entries(h::RemoteHost, dir::AbstractString)
    out = run_remote(h, `find $dir -mindepth 1 ! -type l ! -exec test -r '{}' ';' -print -prune`)
    return [relpath(line, dir) for line in eachsplit(chomp(out), '\n') if !isempty(line)]
end

# Callers must not discard the standard error: a command can warn and still exit 0. A failing `on_line` kills the local
# command.
function stream_command(cmd::Cmd, on_line; cr::Bool = false)
    errfile = tempname()
    out, line = IOBuffer(), IOBuffer()
    try
        proc = open(pipeline(ignorestatus(cmd); stdin = devnull, stderr = errfile), "r")
        try
            while !eof(proc)
                c = read(proc, Char)
                write(out, c)
                (c == '\n' || (cr && c == '\r')) ? on_line(String(take!(line))) : write(line, c)
            end
            bytesavailable(line) > 0 && on_line(String(take!(line)))
        catch
            kill(proc)    # SIGTERM, then SIGKILL after 10 s: a child can stay stuck after SIGTERM while it compiles
            timedwait(() -> !process_running(proc), 10.0) == :ok || kill(proc, 9)
            rethrow()
        finally
            wait(proc)
        end
        err = read(errfile, String)
        success(proc) || throw(ErrorException("command failed with exit code $(proc.exitcode): $cmd\n$err"))
        return String(take!(out)), err
    finally
        rm(errfile; force = true)
    end
end

# ssh quotes a tilde, so the remote shell never expands one.
function expand_home(path::AbstractString, home::AbstractString)
    path == "~" && return String(home)
    startswith(path, "~/") && return joinpath(home, path[3:end])
    startswith(path, "~") && throw(ArgumentError("only ~ and ~/... are supported in remote paths, got \"$path\""))
    return String(path)
end

function expand_home(h::RemoteHost, path::AbstractString)
    return startswith(path, "~") ? expand_home(path, String(strip(run_remote(h, `sh -c $("printf %s \"\$HOME\"")`)))) : String(path)
end

# An exit status other than 0 and 1 is an error, so a lost connection never reads as "absent".
function remote_test(h::RemoteHost, flag::AbstractString, path::AbstractString)
    proc, _, err = run_capture(remote_command(h, `test $flag $path`))
    proc.exitcode in (0, 1) || throw(ErrorException("test $flag $path failed with exit code $(proc.exitcode)\n$err"))
    return proc.exitcode == 0
end

make_dir(h::RemoteHost, dir::AbstractString) = (run_remote(h, `mkdir -p $dir`); String(dir))

# Counted from the capacity column so a file system name with spaces does not shift the columns.
function parse_df(text::AbstractString)
    lines = filter(!isempty, split(chomp(text), '\n'))
    fields = length(lines) >= 2 ? split(last(lines)) : String[]
    capacity = findlast(f -> endswith(f, "%"), fields)
    (capacity !== nothing && capacity >= 4) || throw(ArgumentError("cannot parse df output: $(repr(text))"))
    return parse(Int, fields[capacity - 1]) * 1024
end

free_bytes(h::RemoteHost, dir::AbstractString) = parse_df(run_remote(h, `df -Pk $dir`))

# `-t` keeps the modification time so an unchanged file is not sent again; `checksum` also catches a same-size rewrite.
function push_file(h::SSHHost, file::AbstractString, remote_dir::AbstractString; checksum::Bool = false)
    make_dir(h, remote_dir)
    cmd = `rsync -t $(rsync_transport(h)) $(checksum ? ["--checksum"] : String[]) -- $file $(h.alias):$(rstrip(remote_dir, '/'))/`
    proc, _, err = run_capture(cmd)
    success(proc) || throw(ErrorException("rsync failed with exit code $(proc.exitcode): $cmd\n$err"))
    return joinpath(remote_dir, basename(file))
end

function push_file(::LocalHost, file::AbstractString, remote_dir::AbstractString; checksum::Bool = false)
    mkpath(remote_dir)
    return cp(file, joinpath(remote_dir, basename(file)); force = true)
end

# The only place the tool deletes on a host: `staging` and every path must be absolute, `..`-free and symlink-free, otherwise
# nothing is removed.
function remove_staged!(h::RemoteHost, staging::AbstractString, paths::AbstractVector{<:AbstractString})
    root = String(rstrip(staging, '/'))
    (isabspath(root) && length(splitpath(root)) >= 2 && !(".." in splitpath(root))) ||
        throw(ArgumentError("refusing to remove below $(repr(staging)): the staging directory must be an absolute path other than /"))
    for path in paths
        (isabspath(path) && startswith(path, root * "/") && !(".." in splitpath(path))) ||
            throw(ArgumentError("refusing to remove $path: it is not below the staging directory $root"))
    end
    link = find_symlink(h, root)
    link === nothing || throw(ArgumentError("staging directory $root contains a symlink ($link); refusing to remove anything"))
    remove_paths!(h, root, paths)
    return length(paths)
end

function find_symlink(h::RemoteHost, root::String)
    links = split(run_remote(h, `find $root -type l`), '\n'; keepempty = false)
    return isempty(links) ? nothing : String(first(links))
end

function staged_ancestors(root::String, paths)
    dirs = Set{String}()
    for path in paths
        dir = dirname(path)
        while length(dir) > length(root)
            push!(dirs, dir)
            dir = dirname(dir)
        end
    end
    return sort!(collect(dirs); by = dir -> -length(dir))
end

function remove_paths!(h::SSHHost, root::String, paths)
    foreach(chunk -> run_remote(h, `rm -f -- $(collect(String, chunk))`), Iterators.partition(paths, 100))
    foreach(chunk -> run_remote(h, `rmdir --ignore-fail-on-non-empty -- $(collect(String, chunk))`),
            Iterators.partition(staged_ancestors(root, paths), 100))
    return nothing
end

function remove_paths!(::LocalHost, root::String, paths)
    foreach(path -> rm(path; force = true), paths)
    for dir in staged_ancestors(root, paths)
        isdir(dir) && isempty(readdir(dir)) && rm(dir)
    end
    return nothing
end
