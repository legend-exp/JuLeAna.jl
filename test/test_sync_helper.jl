# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "helper.jl" begin
    h = LocalHost()
    ssh = SSHHost("cslg4", nothing)
    work = mktempdir()

    @testset "remote_command wraps only for ssh" begin
        @test remote_command(h, `echo a b`) == `echo a b`
        @test collect(remote_command(ssh, `echo 'a b'`).exec) == ["ssh", "-n", "-o", "BatchMode=yes", "cslg4", "echo 'a b'"]
    end

    @testset "stream_remote delivers lines and returns standard error" begin
        lines = String[]
        warnings = stream_remote(h, `sh -c 'echo one; echo two; echo careful >&2'`,
                                 line -> push!(lines, line))
        @test lines == ["one", "two"]
        @test warnings == "careful\n"
        @test_throws "exit code 3" stream_remote(h, `sh -c 'echo x; exit 3'`, identity)
        # "forty" is printed by the command but is not in the command text.
        @test_throws "forty" stream_remote(h, `sh -c 'printf "%s%s\n" for ty >&2; exit 3'`, identity)
        # An error in the callback stops the command and propagates.
        @test_throws "stop here" stream_remote(h, `sh -c 'echo one; sleep 5'`,
                                               line -> error("stop here"))
    end

    @testset "stream_remote kills a child that ignores SIGTERM" begin
        # The callback fails while the child ignores SIGTERM: the call must still return, with the callback's error.
        task = Threads.@spawn try
            stream_remote(h, `sh -c 'trap "" TERM; echo one; exec sleep 600'`, line -> error("stop here"))
        catch err
            err
        end
        @test timedwait(() -> istaskdone(task), 30.0) == :ok
        istaskdone(task) && @test occursin("stop here", sprint(showerror, fetch(task)))
    end

    @testset "home expansion" begin
        @test expand_home("~/.juliaup/bin/julia", "/home/u") == "/home/u/.juliaup/bin/julia"
        @test expand_home("~", "/home/u") == "/home/u"
        @test expand_home("/abs/x", "/home/u") == "/abs/x"
        @test_throws "only ~ and ~/" expand_home("~other/x", "/home/u")
        @test remote_home(h) == homedir()
        @test expand_home(h, "~/x") == joinpath(homedir(), "x")
        @test expand_home(h, "/abs") == "/abs"
        # A path without a tilde needs no connection, so this cannot reach ssh.
        @test expand_home(ssh, "/abs/path") == "/abs/path"
    end

    @testset "file_exists, make_dir, free_bytes" begin
        file = joinpath(work, "present.txt")
        write(file, "x")
        @test file_exists(h, file)
        @test !file_exists(h, joinpath(work, "absent.txt"))
        @test make_dir(h, joinpath(work, "a", "b")) == joinpath(work, "a", "b")
        @test isdir(joinpath(work, "a", "b"))
        @test free_bytes(h, work) > 0

        text = """
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        /dev/nvme0n1p2   262144000 100000000 162144000      39% /tmp
        """
        @test parse_df(text) == 162144000 * 1024
        @test_throws "cannot parse df output" parse_df("Filesystem\n")
        @test parse_df("""
        Filesystem     1024-blocks Used Available Capacity Mounted on
        my server:/a b   1000 400 600      40% /mnt/x
        """) == 600 * 1024
        @test_throws "cannot parse df output" parse_df("Filesystem\nno capacity column here at all\n")
    end

    @testset "pushing a file" begin
        @test collect(push_command(ssh, "/a/extract.jl", "/stage").exec) ==
              ["rsync", "-t", "-e", "ssh -o BatchMode=yes", "--", "/a/extract.jl", "cslg4:/stage/"]
        @test collect(push_command(ssh, "/a/job.toml", "/stage"; checksum = true).exec) ==
              ["rsync", "-t", "-e", "ssh -o BatchMode=yes", "--checksum", "--", "/a/job.toml", "cslg4:/stage/"]
        src = joinpath(work, "pushed.txt")
        write(src, "payload")
        dest = push_file(h, src, joinpath(work, "dest", "dir"))
        @test dest == joinpath(work, "dest", "dir", "pushed.txt")
        @test read(dest, String) == "payload"
        write(src, "changed")
        push_file(h, src, joinpath(work, "dest", "dir"))
        @test read(dest, String) == "changed"
    end

    @testset "remove_staged! only removes below the staging directory" begin
        staging = joinpath(work, "stage")
        a = joinpath(staging, "prod", "x", "a.lh5")
        mkpath(dirname(a))
        write(a, "1")
        keep = joinpath(staging, "keep.txt")
        write(keep, "2")
        sibling = joinpath(staging, "other", "empty")   # empty before the call, not staged
        mkpath(sibling)
        @test remove_staged!(h, staging, [a]) == 1
        @test !ispath(a)
        @test !isdir(joinpath(staging, "prod"))      # directories emptied by the removal are pruned
        @test isdir(sibling)                          # other empty directories are left alone
        @test isfile(keep) && isdir(staging)

        outside = joinpath(work, "outside.txt")
        write(outside, "3")
        @test_throws "not below the staging directory" remove_staged!(h, staging, [outside])
        @test_throws "not below the staging directory" remove_staged!(h, staging, [joinpath(staging, "..", "outside.txt")])
        @test_throws "not below the staging directory" remove_staged!(h, staging, ["relative.txt"])
        @test isfile(outside)

        # A degenerate or relative staging root removes nothing and is rejected up front.
        victim = joinpath(work, "victim.txt")
        write(victim, "4")
        for bad_root in ("/", "//", "", "relative/stage")
            @test_throws "staging directory must be an absolute path" remove_staged!(h, bad_root, [victim])
        end
        @test isfile(victim)

        # A symlink anywhere under staging blocks every removal.
        linked = joinpath(work, "linked")
        staged = joinpath(linked, "d", "f.lh5")
        mkpath(dirname(staged))
        write(staged, "5")
        symlink(outside, joinpath(linked, "d", "escape"))
        @test_throws "contains a symlink" remove_staged!(h, linked, [staged])
        @test isfile(staged) && isfile(outside)
        rm(joinpath(linked, "d", "escape"))
        symlink(dirname(outside), joinpath(linked, "dirlink"))
        @test_throws "contains a symlink" remove_staged!(h, linked, [staged])
        @test isfile(staged) && isfile(outside)
    end

    @testset "host configuration resolution" begin
        c = HelperConfig()
        @test (c.julia, c.julia_project, c.staging) == (nothing, nothing, nothing)
        @test remote_julia(h, c) == Base.julia_cmd()
        @test julia_project(h, c) == dirname(Base.active_project())
        @test staging_dir(h, c) ==
              joinpath(tempdir(), "juleana-sync-" * get(ENV, "USER", "user"))

        # The active project must hold the helper's packages.
        saved, load_path = Base.active_project(), copy(LOAD_PATH)
        try
            Base.set_active_project(nothing)
            empty!(LOAD_PATH)
            push!(LOAD_PATH, "@stdlib")
            @test_throws "no active project" julia_project(h, c)
            bare = mktempdir()
            write(joinpath(bare, "Project.toml"), "[deps]\nHDF5 = \"f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f\"\n")
            Base.set_active_project(joinpath(bare, "Project.toml"))
            @test_throws "ParallelProcessingTools" julia_project(h, c)
            @test_throws bare julia_project(h, c)
            empty!(LOAD_PATH)
            append!(LOAD_PATH, load_path)
            Base.set_active_project(saved)
            @test julia_project(h, c) == dirname(saved)
        finally
            empty!(LOAD_PATH)
            append!(LOAD_PATH, load_path)
            Base.set_active_project(saved)
        end

        c2 = HelperConfig(; julia = "/opt/julia/bin/julia", julia_project = "/envs/x",
                          staging = "/scratch/s")
        @test remote_julia(h, c2) == Cmd(["/opt/julia/bin/julia"])
        @test julia_project(h, c2) == "/envs/x"
        @test staging_dir(h, c2) == "/scratch/s"
        # Absolute settings never need a connection, so these cannot reach ssh.
        @test remote_julia(ssh, c2) == Cmd(["/opt/julia/bin/julia"])
        @test julia_project(ssh, c2) == "/envs/x"
        @test staging_dir(ssh, c2) == "/scratch/s"

        @test DEFAULT_REMOTE_JULIA == "~/.juliaup/bin/julia"
        @test DEFAULT_REMOTE_PROJECT == "~/.julia/environments/juleana-sync"
        user = readchomp(`id -un`)
        withenv("TMPDIR" => nothing, "USER" => nothing) do
            @test read(`sh -c $REMOTE_STAGING_SCRIPT`, String) == "/tmp/juleana-sync-$user"
        end
        withenv("TMPDIR" => "/scratch", "USER" => "alice") do
            @test read(`sh -c $REMOTE_STAGING_SCRIPT`, String) == "/scratch/juleana-sync-$user"
        end
    end

    @testset "hosts.yaml keys" begin
        @test basename(default_hosts_file()) == "hosts.yaml"
        @test isfile(default_hosts_file())
        file = joinpath(work, "hosts.yaml")
        write(file, """
        alpha:
          remote_root: /srv/alpha
          julia: /opt/j/bin/julia
          julia_project: ~/envs/sync
          staging: /ptmp/u/stage
        beta:
          remote_root: /srv/beta
          staging: ~
        """)
        @test host_remote_root(file, "alpha") == "/srv/alpha"
        @test host_remote_root(file, "beta") == "/srv/beta"
        @test_throws "host gamma is not listed in $file" host_remote_root(file, "gamma")
        a = host_helper_config(file, "alpha")
        @test (a.julia, a.julia_project, a.staging) ==
              ("/opt/j/bin/julia", "~/envs/sync", "/ptmp/u/stage")
        b = host_helper_config(file, "beta")
        @test (b.julia, b.julia_project, b.staging) == (nothing, nothing, nothing)
        @test host_helper_config(file, "gamma") == HelperConfig()
    end

    @testset "environment check and bootstrap" begin
        ready = ensure_environment(h, HelperConfig())
        @test startswith(ready.julia, "julia version")
        @test ready.project == dirname(Base.active_project())
        @test ready.present && isempty(ready.lacking)
        @test environment_ready(ready)

        # The stand-in executable answers --version and writes a Project.toml
        # when told to add packages.
        stub = write_stub_julia(joinpath(work, "stub-julia"))
        env = joinpath(work, "env")
        c = HelperConfig(; julia = stub, julia_project = env)

        absent = ensure_environment(h, c)
        @test absent.julia == "julia version 9.9.9"
        @test !absent.present
        @test absent.lacking == ["HDF5", "ParallelProcessingTools"]
        @test !environment_ready(absent)
        problem = environment_problem(absent, h, c)
        @test occursin("does not exist", problem)
        @test occursin("Pkg.add", problem)

        args = collect(bootstrap_command(h, c).exec)
        @test args[1] == stub
        @test "--project=$env" in args
        @test "-e" in args
        @test occursin("""Pkg.PackageSpec(name = "HDF5", version = "0.17")""", last(args))
        @test occursin("""Pkg.PackageSpec(name = "ParallelProcessingTools", version = "0.4")""", last(args))

        done = bootstrap_environment!(h, c)
        @test environment_ready(done)
        @test isfile(joinpath(env, "Project.toml"))

        mkpath(joinpath(work, "partial"))
        write(joinpath(work, "partial", "Project.toml"), "[deps]\nHDF5 = \"f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f\"\n")
        partial = ensure_environment(h, HelperConfig(; julia = stub, julia_project = joinpath(work, "partial")))
        @test partial.present
        @test partial.lacking == ["ParallelProcessingTools"]
        @test occursin("lacks ParallelProcessingTools", environment_problem(partial, h, c))

        @test_throws "already exists; refusing to modify it" bootstrap_environment!(h,
                                                                                    HelperConfig(; julia = stub,
                                                                                                 julia_project = joinpath(work, "partial")))
        @test !occursin("ParallelProcessingTools =", read(joinpath(work, "partial", "Project.toml"), String))
        @test_throws "refusing to modify the active project" bootstrap_environment!(h, HelperConfig())
        @test_throws "no such file or directory" ensure_environment(h, HelperConfig(; julia = joinpath(work, "no-julia")))
    end

    @testset "run_helper and inspect_files drive the script" begin
        files = [write_lh5(joinpath(work, "tier", "a.lh5")),
                 write_lh5(joinpath(work, "tier", "b.lh5"); scale = 2)]
        staging = joinpath(work, "staging")
        c = HelperConfig(; staging)
        seen = Dict{String,Any}[]
        records = run_helper(h, c, "inspect", Dict("files" => files);
                             on_record = r -> push!(seen, r))
        @test length(records) == 2
        @test seen == records
        found = inspect_files(h, c, reverse(files))
        @test found[1] == (["B00000C", "V01234A", "aux"], [800, 1600, 2400], "")
        @test found[2] == (["B00000C", "V01234A", "aux"], [400, 800, 1200], "")
        # The script is pushed to the staging directory; the job file is removed again.
        @test isfile(joinpath(staging, "extract.jl"))
        @test !isfile(joinpath(staging, "jobs", "inspect.toml"))

        # The helper process starts with one BLAS thread already requested.
        probe = joinpath(work, "probe-julia")
        write(probe,
              "#!/bin/sh\necho \"\$OPENBLAS_NUM_THREADS\" > '$(joinpath(work, "blas-env"))'\n" *
              "exec '$(joinpath(Sys.BINDIR, "julia"))' \"\$@\"\n")
        chmod(probe, 0o755)
        withenv("OPENBLAS_NUM_THREADS" => nothing) do
            run_helper(h, HelperConfig(; staging, julia = probe), "inspect", Dict("files" => files))
        end
        @test strip(read(joinpath(work, "blas-env"), String)) == "1"

        # The prefix survives the ssh quoting.
        remote = remote_command(ssh,
                                helper_command(ssh, HelperConfig(; julia = "/opt/julia/bin/julia", julia_project = "/opt/proj"),
                                               "/stage/extract.jl", "inspect", "/stage/job.toml", 2))
        @test occursin("env OPENBLAS_NUM_THREADS=1 /opt/julia/bin/julia ", last(remote.exec))

        bad = Dict("job" => [Dict("source" => files[1], "groups" => ["nope"],
                                  "destination" => joinpath(work, "x.lh5"))])
        @test_throws "group nope not found" run_helper(h, c, "extract", bad)
        @test_throws "unexpected output from the remote helper" parse_record("hello")
        @test parse_record("r = {event = \"summary\", files = 2}") ==
              Dict("event" => "summary", "files" => 2)
    end
end
