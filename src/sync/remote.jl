# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    abstract type RemoteHost

A machine the tool reads from. `SSHHost` is the real case; `LocalHost` runs the
same operations on this machine and is what the tests drive.
"""
abstract type RemoteHost end

"""
    SSHHost(alias::AbstractString)
    SSHHost(alias, control_path::Union{Nothing,AbstractString})

A host reached through an `ssh` alias from `~/.ssh/config`. The one-argument form
asks `ssh -G alias` for the effective configuration and fails with ssh's own error
when that does not succeed.

When the configuration already enables `ControlMaster` (see
[`has_control_master`](@ref)), the user's master connection is reused as it is:
`control_path` is `nothing` and the tool adds no `Control*` option, because
overriding the socket would force a new login, which can need a second factor
and a terminal.

Otherwise all commands share one multiplexed connection: `control_path` is the
socket `ControlMaster` opens, so expanding a tree node costs a round trip and not
a handshake. The socket lives under `~/.ssh`, OpenSSH's recommended location for
control sockets, and is named with the `%C` token: OpenSSH's own hash of the local
host, remote host, port and user. A Unix domain socket path is limited to about
100 bytes; `%C` keeps the name short and unique regardless of how long the alias
or remote hostname is, which `%r@%h:%p` does not guarantee.
"""
struct SSHHost <: RemoteHost
    alias::String
    control_path::Union{Nothing,String}
end

function SSHHost(alias::AbstractString, control_path::Union{Nothing,AbstractString})
    return SSHHost(String(alias), control_path === nothing ? nothing : String(control_path))
end

function SSHHost(alias::AbstractString)
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(`ssh -G $alias`); stdin = devnull, stdout = out, stderr = err))
    success(proc) || throw(ErrorException("ssh -G $alias failed with exit code $(proc.exitcode)\n$(String(take!(err)))"))
    has_control_master(String(take!(out))) && return SSHHost(alias, nothing)
    sshdir = joinpath(homedir(), ".ssh")
    isdir(sshdir) || throw(ArgumentError("SSH control directory does not exist: $sshdir"))
    return SSHHost(alias, joinpath(sshdir, "juleana-sync-%C"))
end

"""
    has_control_master(ssh_g_output::AbstractString)::Bool

Whether the output of `ssh -G` enables `ControlMaster` (any value other than `no`
or `false`). A missing line counts as disabled.
"""
function has_control_master(ssh_g_output::AbstractString)
    m = match(r"^controlmaster[ \t]+(\S+)"mi, ssh_g_output)
    return m !== nothing && lowercase(m.captures[1]) ∉ ("no", "false")
end

"""
    LocalHost()

Runs every operation on this machine. `list_dir` and `dir_sizes` are implemented
with Julia filesystem calls rather than `find`/`du`, because the BSD versions
shipped with macOS support neither `-printf` nor `-sb`.
"""
struct LocalHost <: RemoteHost end

"""
    DirEntry(name, kind, size)

One entry of a directory listing. `kind` is `:file`, `:dir`, `:link` or `:other`.
`size` is the file size in bytes, and `nothing` for anything that is not a regular
file: a directory's size comes from `dir_sizes`.
"""
struct DirEntry
    name::String
    kind::Symbol
    size::Union{Nothing,Int}
end

"""
    ssh_command(h::SSHHost, remote::AbstractString)::Cmd

The `ssh` invocation that runs the single shell command `remote` on `h`. `-n` keeps
ssh from reading standard input, and `BatchMode=yes` keeps it from prompting on the
terminal, which the interface holds in raw mode: a connection that needs a password,
passphrase or host-key confirmation fails at once with ssh's error.
"""
ssh_command(h::SSHHost, remote::AbstractString) = `ssh -n -o BatchMode=yes $(ssh_options(h)) $(h.alias) $remote`

"""
    ssh_options(h::SSHHost)::Vector{String}

The connection-sharing options of `h`: none when the ssh configuration has its own
ControlMaster, the tool's control socket otherwise.
"""
function ssh_options(h::SSHHost)
    return h.control_path === nothing ? String[] :
           ["-o", "ControlMaster=auto", "-o", "ControlPath=$(h.control_path)", "-o", "ControlPersist=60s"]
end

"""
    rsync_transport(h::RemoteHost)::Vector{String}

The rsync arguments that select the ssh transport for `h`: a batch-mode ssh with the
options of [`ssh_options`](@ref), and none for a `LocalHost`. The transport keeps its
standard input, which is rsync's channel to the remote side, so it gets no `-n`.
"""
function rsync_transport(h::SSHHost)
    words = ["ssh", "-o", "BatchMode=yes", ssh_options(h)...]
    any(w -> any(isspace, w), words) &&
        throw(ArgumentError("an ssh option contains whitespace, which rsync -e cannot carry: $(join(words, ' '))"))
    return ["-e", join(words, ' ')]
end
rsync_transport(::LocalHost) = String[]

"""
    remote_command(h::RemoteHost, cmd::Cmd)::Cmd

The command that runs `cmd` on `h`: wrapped in `ssh` for an `SSHHost`, unchanged
for `LocalHost`.
"""
remote_command(h::SSHHost, cmd::Cmd) = ssh_command(h, Base.shell_escape(cmd))
remote_command(::LocalHost, cmd::Cmd) = cmd

"""
    run_remote(h::RemoteHost, cmd::Cmd)::String

Run `cmd` on `h` and return its standard output. A nonzero exit is an error
carrying the command and the captured standard error.
"""
function run_remote(h::RemoteHost, cmd::Cmd)
    full = remote_command(h, cmd)
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(full); stdin = devnull, stdout = out, stderr = err))
    success(proc) || throw(ErrorException("remote command failed with exit code $(proc.exitcode): $full\n$(String(take!(err)))"))
    return String(take!(out))
end

"""
    parse_dir_listing(text::AbstractString)::Vector{DirEntry}

Parse the output of `find DIR -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%f\\n'`.
"""
function parse_dir_listing(text::AbstractString)
    entries = DirEntry[]
    for line in eachsplit(chomp(text), '\n')
        isempty(line) && continue
        fields = split(line, '\t')
        length(fields) == 3 ||
            throw(ArgumentError("cannot parse directory listing line (expected type, size and name separated by tabs): $(repr(line))"))
        type_char, size_str, name = fields
        kind = type_char == "f" ? :file :
               type_char == "d" ? :dir :
               type_char == "l" ? :link : :other
        push!(entries, DirEntry(String(name), kind,
                                kind == :file ? parse(Int, size_str) : nothing))
    end
    return entries
end

"""
    list_dir(h::RemoteHost, dir::AbstractString)::Vector{DirEntry}

List the immediate children of `dir`. The listing never descends: the tool must
not walk a shared filesystem recursively.
"""
list_dir(h::SSHHost, dir::AbstractString) = parse_dir_listing(run_remote(h, `find $dir -mindepth 1 -maxdepth 1 -printf '%y\t%s\t%f\n'`))

function list_dir(::LocalHost, dir::AbstractString)
    isdir(dir) || throw(ArgumentError("not a directory: $dir"))
    map(readdir(dir)) do name
        path = joinpath(dir, name)
        st = lstat(path)
        kind = islink(st) ? :link : isfile(st) ? :file : isdir(st) ? :dir : :other
        return DirEntry(name, kind, kind == :file ? Int(filesize(st)) : nothing)
    end
end

"""
    list_productions(h::RemoteHost, remote_root::AbstractString)::Vector{String}

The directories at most three levels below `remote_root` that hold a
`config.json`, relative to `remote_root` and sorted. These are the productions;
no other part of the tree is searched.

The rule differs from `JuLeAna.find_productions`, which reads a local folder: it accepts `config.yaml`, stops at the first
config it finds and reads four levels, while this one runs on the host and descends below a config.
"""
function list_productions(h::SSHHost, remote_root::AbstractString)
    text = run_remote(h, `find $remote_root -mindepth 2 -maxdepth 4 -name config.json -type f -printf '%h\n'`)
    return sort!([relpath(line, remote_root) for line in eachsplit(chomp(text), '\n') if !isempty(line)])
end

function list_productions(::LocalHost, remote_root::AbstractString)
    isdir(remote_root) || throw(ArgumentError("not a directory: $remote_root"))
    found = String[]
    for (dir, dirs, files) in walkdir(remote_root; follow_symlinks = false)
        depth = dir == remote_root ? 0 : length(splitpath(relpath(dir, remote_root)))
        depth >= 1 && "config.json" in files && isfile(joinpath(dir, "config.json")) &&
            push!(found, relpath(dir, remote_root))
        depth >= 3 && empty!(dirs)
    end
    return sort!(found)
end

"""
    dir_sizes(h::RemoteHost, dirs::AbstractVector{<:AbstractString})::Vector{Int}

Apparent size in bytes of each directory in `dirs`, in the order given. One call
covers all of them so that expanding a node costs a single round trip.
"""
function dir_sizes(h::SSHHost, dirs::AbstractVector{<:AbstractString})
    isempty(dirs) && return Int[]
    text = run_remote(h, `du -sb $dirs`)
    sizes = Int[]
    for line in eachsplit(chomp(text), '\n')
        isempty(line) && continue
        push!(sizes, parse(Int, first(split(line, '\t'))))
    end
    length(sizes) == length(dirs) || throw(ErrorException("du reported $(length(sizes)) sizes for $(length(dirs)) directories"))
    return sizes
end

# Sums the apparent size of every non-directory entry below `dir`: regular
# files by their content length, symlinks by the length of their target
# string (lstat's size for a symlink), matching what `du -sb` reports for a
# symlink on the remote. `du -sb` additionally counts directory inodes, so a
# remote total exceeds this one by a few kilobytes per directory, which is
# immaterial for a transfer size estimate.
function dir_sizes(::LocalHost, dirs::AbstractVector{<:AbstractString})
    map(dirs) do dir
        isdir(dir) || throw(ArgumentError("not a directory: $dir"))
        total = 0
        for (root, _, files) in walkdir(dir; follow_symlinks = false), f in files
            total += Int(lstat(joinpath(root, f)).size)
        end
        return total
    end
end

"""
    read_file(h::RemoteHost, path::AbstractString)::String

Read a small text file: the tool uses this for a production's `config.json`.
"""
function read_file(h::SSHHost, path::AbstractString)
    run_remote(h, `test -f $path`)
    return run_remote(h, `cat $path`)
end

function read_file(::LocalHost, path::AbstractString)
    isfile(path) || throw(ArgumentError("not a file: $path"))
    return read(path, String)
end

"""
    rsync_source(h::RemoteHost, root::AbstractString)::String

The source argument rsync needs for `root` on `h`. The trailing slash is part of
the contract: with `--files-from`, rsync resolves the file list against it.
"""
rsync_source(h::SSHHost, root::AbstractString) = "$(h.alias):$(rstrip(root, '/'))/"
rsync_source(::LocalHost, root::AbstractString) = "$(rstrip(root, '/'))/"

"""
    stream_remote(h::RemoteHost, cmd::Cmd, on_line)::String

Run `cmd` on `h` and call `on_line(line)` for each line of standard output as it
arrives. A nonzero exit is an error carrying the command and the captured standard
error; a failing `on_line` kills the local command and rethrows (for an `SSHHost`
this ends the client, not necessarily the process on the remote). Returns the standard
error text of a successful run, which callers must not discard: a command can
warn and still exit 0.
"""
function stream_remote(h::RemoteHost, cmd::Cmd, on_line)
    full = remote_command(h, cmd)
    errfile = tempname()
    proc, text = try
        proc = open(pipeline(ignorestatus(full); stdin = devnull, stderr = errfile), "r")
        try
            for line in eachline(proc)
                on_line(line)
            end
        catch
            # A child can stay stuck after SIGTERM while it compiles, so it is killed after 10 s
            # (9 is SIGKILL; Base.SIGKILL is not public).
            kill(proc)
            timedwait(() -> !process_running(proc), 10.0) == :ok || kill(proc, 9)
            rethrow()
        finally
            wait(proc)
        end
        proc, read(errfile, String)
    finally
        rm(errfile; force = true)
    end
    success(proc) || throw(ErrorException("remote command failed with exit code $(proc.exitcode): $full\n$text"))
    return text
end

"""
    remote_home(h::RemoteHost)::String

The home directory of the user on `h`.
"""
remote_home(h::SSHHost) = String(strip(run_remote(h, `sh -c $("printf %s \"\$HOME\"")`)))
remote_home(::LocalHost) = homedir()

"""
    expand_home(path, home)::String
    expand_home(h::RemoteHost, path)::String

Replace a leading `~` or `~/` of `path` by `home`. `ssh` quotes a tilde, so the
remote shell would never expand one; every remote path is made absolute before it
is placed in a command. Only the current user's home is supported. The form that
takes a host asks it for its home directory only when `path` starts with a tilde.
"""
function expand_home(path::AbstractString, home::AbstractString)
    path == "~" && return String(home)
    startswith(path, "~/") && return joinpath(home, path[3:end])
    startswith(path, "~") && throw(ArgumentError("only ~ and ~/... are supported in remote paths, got \"$path\""))
    return String(path)
end

expand_home(h::RemoteHost, path::AbstractString) = startswith(path, "~") ? expand_home(path, remote_home(h)) : String(path)

"""
    file_exists(h::RemoteHost, path::AbstractString)::Bool

Whether the regular file `path` exists on `h`. An exit status other than 0 (yes)
and 1 (no) from the remote `test` is an error, so a lost connection never reads
as "absent".
"""
function file_exists(h::SSHHost, path::AbstractString)
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(remote_command(h, `test -f $path`)); stdin = devnull, stderr = err))
    proc.exitcode in (0, 1) ||
        throw(ErrorException("test -f $path on $(h.alias) failed with exit code $(proc.exitcode)\n$(String(take!(err)))"))
    return proc.exitcode == 0
end
file_exists(::LocalHost, path::AbstractString) = isfile(path)

"""
    dir_exists(h::RemoteHost, path::AbstractString)::Bool

Whether the directory `path` exists on `h`, with the same error handling as
[`file_exists`](@ref).
"""
function dir_exists(h::SSHHost, path::AbstractString)
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(remote_command(h, `test -d $path`)); stdin = devnull, stderr = err))
    proc.exitcode in (0, 1) ||
        throw(ErrorException("test -d $path on $(h.alias) failed with exit code $(proc.exitcode)\n$(String(take!(err)))"))
    return proc.exitcode == 0
end
dir_exists(::LocalHost, path::AbstractString) = isdir(path)

"""
    make_dir(h::RemoteHost, dir::AbstractString)::String

Create `dir` and its parents on `h` (`mkdir -p`) and return `dir`.
"""
make_dir(h::SSHHost, dir::AbstractString) = (run_remote(h, `mkdir -p $dir`); String(dir))
make_dir(::LocalHost, dir::AbstractString) = (mkpath(dir); String(dir))

"""
    parse_df(text::AbstractString)::Int

Bytes available according to the output of `df -Pk DIR`. The POSIX format puts
the block counts in fixed columns: file system, 1024-blocks, used, available.
"""
function parse_df(text::AbstractString)
    lines = filter(!isempty, split(chomp(text), '\n'))
    length(lines) >= 2 || throw(ArgumentError("cannot parse df output: $(repr(text))"))
    fields = split(last(lines))
    # Counted from the capacity column, so a file system name with spaces does not shift the columns.
    capacity = findlast(f -> endswith(f, "%"), fields)
    (capacity !== nothing && capacity >= 4) || throw(ArgumentError("cannot parse df output: $(repr(text))"))
    return parse(Int, fields[capacity - 1]) * 1024
end

"""
    free_bytes(h::RemoteHost, dir::AbstractString)::Int

Bytes available to the user on the file system holding the existing directory `dir`.
"""
free_bytes(h::SSHHost, dir::AbstractString) = parse_df(run_remote(h, `df -Pk $dir`))
free_bytes(::LocalHost, dir::AbstractString) = Int(Base.diskstat(dir).available)

"""
    push_command(h::SSHHost, file, remote_dir; checksum = false)::Cmd

The rsync invocation that copies `file` into `remote_dir` on `h`. `-t` keeps the
modification time, so an unchanged file is not sent again. With `checksum`, rsync
compares content instead of size and time, which a file that is rewritten with the
same size within one second needs.
"""
function push_command(h::SSHHost, file::AbstractString, remote_dir::AbstractString; checksum::Bool = false)
    return `rsync -t $(rsync_transport(h)) $(checksum ? ["--checksum"] : String[]) -- $file $(h.alias):$(rstrip(remote_dir, '/'))/`
end

"""
    push_file(h::RemoteHost, file, remote_dir; checksum = false)::String

Copy `file` into `remote_dir` on `h`, creating the directory, and return the path
of the copy on `h`. `checksum` is passed to [`push_command`](@ref); a `LocalHost`
always copies.
"""
function push_file(h::SSHHost, file::AbstractString, remote_dir::AbstractString;
                   checksum::Bool = false)
    make_dir(h, remote_dir)
    out = IOBuffer()
    err = IOBuffer()
    cmd = push_command(h, file, remote_dir; checksum)
    proc = run(pipeline(ignorestatus(cmd); stdin = devnull, stdout = out, stderr = err))
    success(proc) || throw(ErrorException("rsync failed with exit code $(proc.exitcode): $cmd\n$(String(take!(err)))"))
    return joinpath(remote_dir, basename(file))
end

function push_file(::LocalHost, file::AbstractString, remote_dir::AbstractString;
                   checksum::Bool = false)
    mkpath(remote_dir)
    dest = joinpath(remote_dir, basename(file))
    cp(file, dest; force = true)
    return dest
end

"""
    remove_staged!(h::RemoteHost, staging, paths)::Int

Remove the files `paths` from `h`, then the ancestors of those files below
`staging` that this leaves empty, deepest first. Directories that were already
empty and are not an ancestor of a removed file are never touched. This is the
only place the tool deletes anything on a remote host, so every path must be
absolute, free of `..` components and below `staging`; anything else is an error
and nothing is removed. `staging` itself stays, and it must be an absolute path
with at least one component. Symlinks are never followed: a symlink anywhere
under `staging` is an error, since the tool creates none there.
"""
function remove_staged!(h::RemoteHost, staging::AbstractString,
                        paths::AbstractVector{<:AbstractString})
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

# The first symlink at or below `root`, or `nothing`.
function find_symlink(h::SSHHost, root::String)
    return (out = strip(run_remote(h, `find $root -type l -print -quit`)); isempty(out) ? nothing : String(out))
end

function find_symlink(::LocalHost, root::String)
    islink(root) && return root
    isdir(root) || return nothing
    for (dir, dirs, files) in walkdir(root; follow_symlinks = false)
        for name in Iterators.flatten((dirs, files))
            islink(joinpath(dir, name)) && return joinpath(dir, name)
        end
    end
end

# The directories between `root` (exclusive) and the files `paths`, deepest first.
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
    for chunk in Iterators.partition(paths, 100)
        run_remote(h, `rm -f -- $(collect(String, chunk))`)
    end
    for chunk in Iterators.partition(staged_ancestors(root, paths), 100)
        run_remote(h, `rmdir --ignore-fail-on-non-empty -- $(collect(String, chunk))`)
    end
end

function remove_paths!(::LocalHost, root::String, paths)
    foreach(path -> rm(path; force = true), paths)
    for dir in staged_ancestors(root, paths)
        isdir(dir) && isempty(readdir(dir)) && rm(dir)
    end
end
