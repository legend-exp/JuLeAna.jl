# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# A path whose reader fails the way a bug would, not the way a broken file does.
struct NotAPath <: AbstractString end
PropDicts.readprops(::NotAPath; kwargs...) = throw(MethodError(identity, ()))

@testset "remote commands" begin
    h = LocalHost()
    ssh = SSHHost("cslg4", nothing)
    work = mktempdir()
    hitdir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit", "cal", "p18", "r000")
    evtdir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
    pid_gone(file) = !success(pipeline(`kill -0 $(parse(Int, strip(read(file, String))))`; stderr = devnull))

    @testset "directory listings and sizes" begin
        entries = parse_dir_listing("d\t4096\tphy\nf\t8192\tx.lh5\nl\t12\tcurrent\n")
        @test entries[1] == DirEntry("phy", :dir, nothing)
        @test entries[2] == DirEntry("x.lh5", :file, 8192)
        @test entries[3].kind == :link
        @test_throws "cannot parse directory listing line" parse_dir_listing("garbage\n")
        by_name = Dict(e.name => e for e in list_dir(h, hitdir))
        @test length(by_name) == 3 && by_name["l200-p18-r000-cal-B00000C-tier_jlhit.lh5"].size == 2048
        @test all(e -> e.kind == :dir && e.size === nothing, list_dir(h, dirname(dirname(dirname(hitdir)))))
        @test_throws "not a directory" list_dir(h, joinpath(FIXTURE_ROOT, "nope"))
        @test dir_sizes(h, [evtdir, hitdir]) == [4096 + 8192, 2048 + 1024 + 18]
        @test_throws "not a directory" dir_sizes(h, [joinpath(FIXTURE_ROOT, "nope")])
        @test occursin(FIXTURE_ROOT, read_file(h, joinpath(FIXTURE_ROOT, "test", "config.json")))
        @test_throws "not a file" read_file(h, joinpath(FIXTURE_ROOT, "nope.json"))
        @test strip(run_remote(h, `echo hello`)) == "hello"
        @test_throws "remote command failed" run_remote(h, `false`)
    end

    @testset "ssh options and the control master" begin
        s = SSHHost("cslg4", joinpath(homedir(), ".ssh", "juleana-sync-%C"))
        parts = collect(ssh_command(s, "du -sb /x").exec)
        @test parts[1] == "ssh" && last(parts) == "du -sb /x"
        alias = findfirst(==("cslg4"), parts)
        @test findfirst(==("-n"), parts) < alias && findfirst(==("BatchMode=yes"), parts) < alias
        @test "ControlPath=$(s.control_path)" in parts && any(p -> occursin("ControlPersist", p), parts)
        # A control socket path must fit a Unix domain socket (about 100 bytes), hence OpenSSH's short %C hash.
        @test occursin("%C", s.control_path) && length(s.control_path) < 90
        @test rsync_source(s, "/mnt/x") == "cslg4:/mnt/x/" && rsync_source(h, "/tmp/root") == "/tmp/root/"
        # rsync's transport is batch too and keeps its standard input (no -n); a dropped connection ends the command.
        words = split(Sync.rsync_transport(s)[2])
        @test words[1] == "ssh" && "BatchMode=yes" in words && "-n" ∉ words && "ControlPath=$(s.control_path)" in words
        for option in ("ConnectTimeout=20", "ServerAliveInterval=15", "ServerAliveCountMax=4")
            @test option in parts && option in words
        end
        @test isempty(Sync.rsync_transport(h))
        @test_throws "whitespace" Sync.rsync_transport(SSHHost("cslg4", "/tmp/a b/sock-%C"))

        @test has_control_master("user flo\ncontrolmaster auto\ncontrolpath /home/x/.ssh/master-%C\n")
        @test has_control_master("ControlMaster ask\n")
        @test !has_control_master("controlmaster no\n") && !has_control_master("user flo\n")
        @test collect(ssh_command(SSHHost("viper", nothing), "uname -a").exec) ==
              ["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
               "viper", "uname -a"]
        @test_throws "ssh could not reach juleana-sync-no-such-host.invalid" run_remote(SSHHost("juleana-sync-no-such-host.invalid",
                                                                                                nothing), `true`)
    end

    @testset "the remote shell receives every argument unchanged" begin
        @test remote_command(h, `echo a b`) == `echo a b`
        args = ["(", ")", "a;b", "a|b", "*", "~/x", "\$HOME", "it's", "%h\t%f"]
        remote = last(remote_command(ssh, `printf '%s\n' $args`).exec)
        @test readlines(`sh -c $remote`) == args
        @test_throws "only ~ and ~/" expand_home("~other/x", "/home/u")
        @test expand_home("~/.juliaup/bin/julia", "/home/u") == "/home/u/.juliaup/bin/julia" && expand_home("/abs/x", "/home/u") == "/abs/x"
        @test expand_home(h, "~/x") == joinpath(homedir(), "x") && expand_home(ssh, "/abs/path") == "/abs/path"
    end

    @testset "spawned processes do not inherit standard input" begin
        # A command that reads its input blocks forever unless the tool gives it the null device.
        pipe = Pipe()
        Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
        task = redirect_stdin(pipe) do
            Threads.@spawn (run_remote(h, `cat`), stream_remote(h, `cat`, identity))
        end
        @test timedwait(() -> istaskdone(task), 30.0) == :ok
        istaskdone(task) && @test fetch(task) == ("", "")
        close(pipe)
    end

    @testset "stream_remote delivers lines and stops the command with a failing callback" begin
        lines = String[]
        @test stream_remote(h, `sh -c 'echo one; echo two; echo careful >&2'`, line -> push!(lines, line)) == "careful\n"
        @test lines == ["one", "two"]
        @test_throws "exit code 3" stream_remote(h, `sh -c 'echo x; exit 3'`, identity)
        # "forty" is printed by the command but is not in the command text.
        @test_throws "forty" stream_remote(h, `sh -c 'printf "%s%s\n" for ty >&2; exit 3'`, identity)

        # The child ignores SIGTERM, so the call has to kill it for the callback's error to arrive.
        pidfile = joinpath(work, "pid")
        script = "echo \$\$ > $pidfile; trap '' TERM; echo one; exec sleep 600"
        task = Threads.@spawn try
            stream_remote(h, `sh -c $script`, line -> error("stop here"))
        catch err
            err
        end
        @test timedwait(() -> istaskdone(task), 30.0) == :ok
        istaskdone(task) && @test occursin("stop here", sprint(showerror, fetch(task)))
        @test pid_gone(pidfile)
    end

    @testset "host files: free space, push, staged removal" begin
        file = joinpath(work, "present.txt")
        write(file, "x")
        @test file_exists(h, file) && !file_exists(h, joinpath(work, "absent.txt"))
        @test make_dir(h, joinpath(work, "a", "b")) == joinpath(work, "a", "b") && isdir(joinpath(work, "a", "b"))
        text = "Filesystem     1024-blocks      Used Available Capacity Mounted on\n/dev/nvme0n1p2   262144000 100000000 162144000      39% /tmp\n"
        @test parse_df(text) == 162144000 * 1024
        @test parse_df("Filesystem     1024-blocks Used Available Capacity Mounted on\nmy server:/a b   1000 400 600      40% /mnt/x\n") ==
              600 * 1024
        @test_throws "cannot parse df output" parse_df("Filesystem\n")

        @test collect(push_command(ssh, "/a/job.toml", "/stage"; checksum = true).exec) ==
              ["rsync", "-t", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4",
               "--checksum", "--", "/a/job.toml", "cslg4:/stage/"]
        dest = push_file(h, file, joinpath(work, "dest", "dir"))
        write(file, "changed")
        push_file(h, file, joinpath(work, "dest", "dir"))
        @test read(dest, String) == "changed"

        # Staged files are removed below an absolute staging root without symlinks, and nothing else is.
        staging = joinpath(work, "stage")
        a = joinpath(staging, "prod", "x", "a.lh5")
        mkpath(dirname(a))
        write(a, "1")
        mkpath(joinpath(staging, "other", "empty"))
        @test remove_staged!(h, staging, [a]) == 1
        @test !isdir(joinpath(staging, "prod")) && isdir(joinpath(staging, "other", "empty"))
        outside = joinpath(work, "outside.txt")
        write(outside, "3")
        for path in (outside, joinpath(staging, "..", "outside.txt"), "relative.txt")
            @test_throws "not below the staging directory" remove_staged!(h, staging, [path])
        end
        for bad_root in ("/", "", "relative/stage")
            @test_throws "staging directory must be an absolute path" remove_staged!(h, bad_root, [outside])
        end
        linked = joinpath(work, "linked")
        staged = joinpath(linked, "d", "f.lh5")
        mkpath(dirname(staged))
        write(staged, "5")
        symlink(outside, joinpath(linked, "d", "escape"))
        @test_throws "contains a symlink" remove_staged!(h, linked, [staged])
        @test isfile(staged) && isfile(outside)
    end

    @testset "rsync stops with a failing progress callback" begin
        pidfile = joinpath(work, "rsync-pid")
        script = "echo \$\$ > $pidfile; printf '  1,000  50%%  1.00MB/s  0:00:01\\r'; exec sleep 60"
        t = @elapsed @test_throws "callback failed" run_rsync(`sh -c $script`, _ -> error("callback failed"))
        @test t < 30 && pid_gone(pidfile)
        prog = parse_progress("      1,234,567  45%   12.34MB/s    0:00:12")
        @test (prog.bytes, prog.fraction, prog.rate, prog.eta) == (1234567, 0.45, "12.34MB/s", "0:00:12")
        @test parse_progress("sending incremental file list") === nothing
    end
end

@testset "helper environment" begin
    h = LocalHost()
    work = mktempdir()

    @testset "host configuration resolution" begin
        c = HelperConfig()
        @test remote_julia(h, c) == Base.julia_cmd() && julia_project(h, c) == dirname(Base.active_project())
        @test staging_dir(h, c) == joinpath(tempdir(), "juleana-sync-" * get(ENV, "USER", "user"))
        # The project must list the helper's packages.
        bare = mktempdir()
        write(joinpath(bare, "Project.toml"), "[deps]\nHDF5 = \"f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f\"\n")
        saved = Base.active_project()
        try
            Base.set_active_project(joinpath(bare, "Project.toml"))
            @test_throws "ParallelProcessingTools" julia_project(h, c)
            @test_throws bare julia_project(h, c)
        finally
            Base.set_active_project(saved)
        end
        c2 = HelperConfig(; julia = "/opt/julia/bin/julia", julia_project = "/envs/x", staging = "/scratch/s")
        ssh = SSHHost("cslg4", nothing)
        # Absolute settings need no connection, so these cannot reach ssh.
        @test remote_julia(ssh, c2) == Cmd(["/opt/julia/bin/julia"]) && julia_project(ssh, c2) == "/envs/x" &&
              staging_dir(ssh, c2) == "/scratch/s"
        user = readchomp(`id -un`)
        withenv("TMPDIR" => nothing, "USER" => nothing) do
            @test read(`sh -c $REMOTE_STAGING_SCRIPT`, String) == "/tmp/juleana-sync-$user"
        end
        withenv("TMPDIR" => "/scratch", "USER" => "alice") do
            @test read(`sh -c $REMOTE_STAGING_SCRIPT`, String) == "/scratch/juleana-sync-$user"
        end
        remote = remote_command(ssh, helper_command(ssh, c2, "/stage/extract.jl", "inspect", "/stage/job.toml", 2))
        @test occursin("env OPENBLAS_NUM_THREADS=1 /opt/julia/bin/julia ", last(remote.exec))
    end

    @testset "environment check and bootstrap" begin
        ready = ensure_environment(h, HelperConfig())
        @test startswith(ready.julia, "julia version") && ready.present && isempty(ready.lacking) && environment_ready(ready)

        stub = write_stub_julia(joinpath(work, "stub-julia"))
        env = joinpath(work, "env")
        c = HelperConfig(; julia = stub, julia_project = env)
        absent = ensure_environment(h, c)
        @test !absent.present && absent.lacking == ["HDF5", "ParallelProcessingTools"] && !environment_ready(absent)
        problem = environment_problem(absent, h, c)
        @test occursin("does not exist", problem) && occursin("Pkg.add", problem)
        code = last(collect(bootstrap_command(h, c).exec))
        @test occursin("""Pkg.PackageSpec(name = "HDF5", version = "0.17")""", code)
        @test occursin("""Pkg.PackageSpec(name = "ParallelProcessingTools", version = "0.4")""", code)
        @test environment_ready(bootstrap_environment!(h, c)) && isfile(joinpath(env, "Project.toml"))

        # An existing environment is never modified, and neither is the active project.
        partial = joinpath(work, "partial")
        mkpath(partial)
        write(joinpath(partial, "Project.toml"), "[deps]\nHDF5 = \"f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f\"\n")
        pc = HelperConfig(; julia = stub, julia_project = partial)
        @test ensure_environment(h, pc).lacking == ["ParallelProcessingTools"]
        @test occursin("lacks ParallelProcessingTools", environment_problem(ensure_environment(h, pc), h, pc))
        @test_throws "already exists; refusing to modify it" bootstrap_environment!(h, pc)
        @test !occursin("ParallelProcessingTools =", read(joinpath(partial, "Project.toml"), String))
        @test_throws "refusing to modify the active project" bootstrap_environment!(h, HelperConfig())
        @test_throws "no such file or directory" ensure_environment(h, HelperConfig(; julia = joinpath(work, "no-julia")))
    end
end

@testset "steps" begin
    collect_into(v) = p -> push!(v, p)

    @testset "Steps numbers the steps and format_step prints them" begin
        seen = StepProgress[]
        steps = Steps(["a", "b"], collect_into(seen))
        steps("b"; done = 2, total = 4, bytes = 2048, detail = "fast")
        @test seen == [StepProgress("b", 2, 2, 2, 4, 2048, "fast")]
        @test_throws "unknown step c" steps("c")
        @test format_step(StepProgress("copying", 2, 5, 45, 100, 1048576, "3.2MB/s  ETA 0:00:10")) ==
              "[2/5] copying 45/100  1.0 M  3.2MB/s  ETA 0:00:10"
        @test format_step(StepProgress("checking files to copy", 3, 3, 0, nothing, nothing, "")) == "[3/3] checking files to copy"
    end

    @testset "the printer breaks its line when the step changes and names a failing step" begin
        io, err = IOBuffer(), IOBuffer()
        printer = StepPrinter(io)
        printer(StepProgress("a", 1, 2, 1, 3, nothing, ""))
        printer(StepProgress("a", 1, 2, 2, 3, nothing, ""))
        printer(StepProgress("b", 2, 2, 0, nothing, nothing, ""))
        text = String(take!(io))
        @test count('\r', text) == 3 && count('\n', text) == 1 && occursin("[1/2] a 2/3", text)
        @test failed_step(printer) == "b" && failed_step(StepPrinter(io)) == ""
        @test_throws "boom" with_failed_step(() -> error("boom"), printer, err)
        @test String(take!(io)) == "\n" && String(take!(err)) == "failed in step \"b\"\n"
        @test with_failed_step(() -> 7, printer, err) == 7
        # No step reported yet: nothing is printed.
        @test_throws "early" with_failed_step(() -> error("early"), StepPrinter(io), err)
        @test isempty(take!(io)) && isempty(take!(err))
    end
end

@testset "productions" begin
    h = LocalHost()
    p = Production(h, "test", FIXTURE_ROOT, LOCAL_ROOT)
    remote = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt")

    @testset "\$_ expansion, root resolution and path mapping" begin
        @test first.(p.roots) == ["metadata", "par", "tier", "tier/jlhit", "tier/jlpks"]
        roots = Dict(p.roots)
        # "$_" is the directory holding the production's config.json; an absolute key may point into another top-level directory.
        @test roots["metadata"] == joinpath(FIXTURE_ROOT, "test", "legend-metadata")
        @test roots["tier"] == joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier")
        @test relative(p, remote) == joinpath("temp", "jl-dev", "generated", "tier", "jlevt") && relative(p, FIXTURE_ROOT) == ""
        @test to_local(p, remote) == joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt")
        @test_throws "is not inside the remote root" relative(p, "/elsewhere/x")
        @test_throws "no mount root configured" to_mount(p, remote)
        pm = Production(h, "test", FIXTURE_ROOT, LOCAL_ROOT; mount_root = "/Volumes/cslg4")
        @test to_mount(pm, remote) == joinpath("/Volumes/cslg4", "temp", "jl-dev", "generated", "tier", "jlevt")
    end

    @testset "configs that must be rejected" begin
        dir = joinpath(FIXTURE_ROOT, "test")
        outside = parse_production_config("""{"setups": {"l200": {"paths": {"tier": "/somewhere/else/tier"}}}}""", dir)
        @test_throws "outside the remote root" production_roots(outside, FIXTURE_ROOT)
        two = parse_production_config("""{"setups": {"l200": {"paths": {"tier": "\$_/a"}}, "l1000": {"paths": {"tier": "\$_/b"}}}}""", dir)
        @test_throws "exactly one setup" production_roots(two, FIXTURE_ROOT)
        @test_throws "Unknown variable" parse_production_config("""{"setups": {"l200": {"paths": {"tier": "\$NOPE/tier"}}}}""", dir)
        @test_throws "not a directory" Production(h, "nosuch", FIXTURE_ROOT, LOCAL_ROOT)
    end

    @testset "production names must stay below the root and equivalent spellings agree" begin
        for name in ("../escape", "temp/../../x", "/etc", "temp/x/../../test")
            @test_throws name Production(h, name, FIXTURE_ROOT, LOCAL_ROOT)
        end
        @test_throws "relative path" Production(h, "", FIXTURE_ROOT, LOCAL_ROOT)
        @test Production(h, "test/", FIXTURE_ROOT, LOCAL_ROOT).name == "test"
        @test Production(h, "./temp//jl-dev/", FIXTURE_ROOT, LOCAL_ROOT).name == "temp/jl-dev"
        @test list_productions(h, FIXTURE_ROOT) == ["temp/jl-dev", "test"]
    end

    @testset "config_local.yaml maps the roots into the mirror" begin
        mkpath(joinpath(LOCAL_ROOT, "test"))
        path = write_local_config(p)
        @test path == joinpath(LOCAL_ROOT, "test", "config_local.yaml") && !isfile(joinpath(LOCAL_ROOT, "test", "config.json"))
        @test !startswith(read(path, String), "{")
        paths = only(values(readprops(path).setups)).paths
        @test String(paths[Symbol("metadata")]) == joinpath(LOCAL_ROOT, "test", "legend-metadata")
        @test String(paths[Symbol("tier/jlhit")]) == joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")
        data = withenv("LEGEND_DATA_CONFIG" => path) do
            LegendDataManagement.LegendData(:l200)
        end
        @test data_path(data, "tier", "jlhit") == joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")
        @test data_path(data, "metadata") == joinpath(LOCAL_ROOT, "test", "legend-metadata")
        # A value equal to the remote root maps to the local root like any path inside it.
        raw = """{"setups": {"l200": {"paths": {"tier": "\$_/a", "root": "$FIXTURE_ROOT"}}}}"""
        cfg = parse_production_config(raw, joinpath(FIXTURE_ROOT, "test"))
        pr = Production("test", FIXTURE_ROOT, LOCAL_ROOT, nothing, cfg, production_roots(cfg, FIXTURE_ROOT), String[], "config.json", false)
        @test String(only(values(local_config(pr).setups)).paths[Symbol("root")]) == LOCAL_ROOT
    end

    @testset "overlays win over the production config, deeper ones last" begin
        n = Production(h, "temp/jl-dev", FIXTURE_ROOT, LOCAL_ROOT)
        @test n.overlays == ["config_fixture.json", "temp/config_site.yaml"] && p.overlays == ["config_fixture.json"]
        roots = Dict(n.roots)
        @test roots["metadata"] == joinpath(FIXTURE_ROOT, "temp", "jl-dev", "legend-metadata")
        # Each overlay's "\$_" is the directory the overlay sits in.
        @test roots["tier/jlpks"] == joinpath(FIXTURE_ROOT, "preprod", "jlpeaks") &&
              roots["tier/raw"] == joinpath(FIXTURE_ROOT, "temp", "raw-fixture")
        paths = only(values(readprops(write_local_config(n)).setups)).paths
        @test String(paths[Symbol("tier/raw")]) == joinpath(LOCAL_ROOT, "temp", "raw-fixture")

        root = mktempdir()
        mkpath(joinpath(root, "a", "b", "prod"))
        write(joinpath(root, "a", "b", "prod", "config.json"),
              """{"setups": {"l200": {"paths": {"metadata": "\$_/m", "tier": "\$_/t"}}}}""")
        write(joinpath(root, "config_x.json"), """{"setups": {"l200": {"paths": {"tier": "\$_/from-root", "par": "\$_/p"}}}}""")
        write(joinpath(root, "a", "b", "config_y.yml"), """setups: {l200: {paths: {tier: "\$_/from-deep"}}}""")
        write(joinpath(root, "a", "config_z.yaml"), """setups: {l200: {paths: {tier: "\$_/from-mid"}}}""")
        write(joinpath(root, "a", "b", "notes.json"), "{}")
        @test overlay_files(h, root, "a/b/prod") == ["config_x.json", "a/config_z.yaml", "a/b/config_y.yml"]
        roots = Dict(Production(h, "a/b/prod", root, mktempdir()).roots)
        @test roots["tier"] == joinpath(root, "a", "b", "from-deep") && roots["par"] == joinpath(root, "p")
        @test roots["metadata"] == joinpath(root, "a", "b", "prod", "m")
    end

    @testset "productions with config.yaml and a setup folder" begin
        root = mktempdir()
        old = mkpath(joinpath(root, "juleana", "preprod", "old"))
        write(joinpath(old, "config.json"),
              """{"setups": {"l200": {"paths": {"metadata": "\$_/legend-metadata/", "tier": "\$_/generated/tier/"}}}}""")
        mkpath(joinpath(old, "legend-metadata"))
        mkpath(joinpath(old, "generated", "tier", "jlpks"))
        new = mkpath(joinpath(root, "juleana", "ref", "new"))
        write(joinpath(new, "config.yaml"), """
            setups:
              l200:
                paths:
                  metadata: '\$_/legend-metadata/'
                  tier: '\$_/generated/tier/'
                  tier/jlpks: '\$_/../../preprod/old/generated/tier/jlpks/'
                  tier/jllog: '\$_/generated/jllog/'
                  par: '\$_/generated/jlpar/'
            """)
        write(joinpath(mkpath(joinpath(new, "legend-metadata")), "README.md"), "metadata\n")
        foreach(d -> mkpath(joinpath(new, "generated", d)), ("tier", "jllog", "jlpar"))
        write(joinpath(mkpath(joinpath(new, "setup", "config")), "processing_config.yaml"), "processors: {}\n")
        write(joinpath(mkpath(joinpath(new, "setup", "software", "snap")), "SNAPSHOT.toml"), "julia = \"1.12\"\n")

        @test list_productions(h, root) == ["juleana/preprod/old", "juleana/ref/new"]
        q = Production(h, "juleana/ref/new", root, mktempdir())
        @test q.config_file == "config.yaml" && q.setup_config
        @test Dict(q.roots)["tier/jlpks"] == joinpath(root, "juleana", "preprod", "old", "generated", "tier", "jlpks")
        tree = production_tree(h, q)
        @test [c.label for c in tree.children] == ["config.yaml", "metadata", "par", "tier", "tier/jllog", "tier/jlpks", "setup"]
        @test last(tree.children).kind == :section
        @test mandatory_copies(q) ==
              [joinpath("juleana", "ref", "new", "config.yaml"), joinpath("juleana", "ref", "new", "setup", "config"),
               joinpath("juleana", "ref", "new", "legend-metadata")]
        # The mandatory copies make a usable mirror; the software snapshots stay behind.
        apply!(h, q, Selection(q, "local", tree))
        mirror = joinpath(q.local_root, "juleana", "ref", "new")
        @test isfile(joinpath(mirror, "config.yaml")) && isfile(joinpath(mirror, "setup", "config", "processing_config.yaml"))
        @test isfile(joinpath(mirror, "legend-metadata", "README.md")) && !isdir(joinpath(mirror, "setup", "software"))
        paths = only(values(readprops(joinpath(mirror, "config_local.yaml")).setups)).paths
        @test String(paths[Symbol("tier/jlpks")]) == joinpath(q.local_root, "juleana", "preprod", "old", "generated", "tier", "jlpks")

        o = Production(h, "juleana/preprod/old", root, mktempdir())
        @test o.config_file == "config.json" && !o.setup_config
        @test mandatory_copies(o) ==
              [joinpath("juleana", "preprod", "old", "config.json"), joinpath("juleana", "preprod", "old", "legend-metadata")]
        both = mkpath(joinpath(mktempdir(), "both"))
        write(joinpath(both, "config.json"), "{}")
        write(joinpath(both, "config.yaml"), "{}\n")
        @test_throws "holds both config.json and config.yaml" Production(h, "both", dirname(both), mktempdir())
        @test_throws "holds neither config.json nor config.yaml" Production(h, "juleana", root, mktempdir())
    end
end

@testset "settings and options" begin
    h = LocalHost()
    hosts = joinpath(mktempdir(), "hosts.yaml")
    write(hosts, "alpha:\n  remote_root: /data/a\nbeta:\n  remote_root: /data/b\n  staging: /scratch/b\n")

    @testset "the configuration directory and the precedence of the settings" begin
        mktempdir() do xdg
            withenv("XDG_CONFIG_HOME" => xdg) do
                @test config_dir() == joinpath(xdg, "juleana", "sync") && default_selection_dir() == config_dir()
                @test default_hosts_file() == Sync.PACKAGED_HOSTS_FILE && default_local_root() == ""
                @test default_selection_path("h", "a/b") == joinpath(config_dir(), "h", "a-b.yaml")
                @test_throws "--local-root must be set" parse_options(String[])
                mkpath(config_dir())
                write(joinpath(config_dir(), "hosts.yaml"), "alpha:\n  remote_root: /srv/x\n")
                write(joinpath(config_dir(), "settings.yaml"), "local_root: /srv/mirror\n")
                @test default_hosts_file() == joinpath(config_dir(), "hosts.yaml") && SyncSettings().local_root == ""
                @test user_settings().local_root == "/srv/mirror"
                @test parse_options(["--host", "alpha"]).local_root == "/srv/mirror"
                @test parse_options(["--host", "alpha", "--local-root", "/tmp"]).local_root == "/tmp"
                @test parse_options(["--host", "alpha"]).remote_root == "/srv/x"
                # A selection saved to the default path creates the configuration directory.
                sel = Selection("cslg4", "a/b", "/r", "/l", nothing, String[], String[], DateTime(2025, 1, 1))
                @test isfile(save_selection(default_selection_path("cslg4", "a/b"), sel))
            end
        end
    end

    @testset "broken configuration files are reported with the file name" begin
        mktempdir() do xdg
            withenv("XDG_CONFIG_HOME" => xdg) do
                mkpath(config_dir())
                settings, hostsfile = joinpath(config_dir(), "settings.yaml"), joinpath(config_dir(), "hosts.yaml")
                write(settings, "local_root: [unclosed\n")
                @test_throws "settings.yaml" default_local_root()
                write(settings, "local_root:\n  - a\n")
                @test_throws "local_root in $settings must be a path" default_local_root()
                write(hostsfile, "alpha: [unclosed\n")
                for f in (host_remote_root, host_helper_config)
                    @test_throws "hosts.yaml" f(hostsfile, "alpha")
                end
                @test_throws "hosts.yaml" hosts_choices(hostsfile)
                write(hostsfile, "alpha:\n  staging: /s\n")
                @test_throws "host alpha in $hostsfile needs a remote_root" host_remote_root(hostsfile, "alpha")
            end
        end
        dir = mktempdir()
        for (name, text) in ("scanner.yaml" => "a: 'unclosed\n", "parser.yaml" => "a: [1, 2\n", "format.txt" => "x\n")
            write(joinpath(dir, name), text)
            @test_throws "cannot read $(joinpath(dir, name)): " Sync.read_config(joinpath(dir, name))
        end
        @test_throws "cannot read $(joinpath(dir, "missing.yaml")): " Sync.read_config(joinpath(dir, "missing.yaml"))
        @test_throws MethodError Sync.read_config(NotAPath())   # a fault that is not about the file keeps its type
    end

    @testset "each field reports its own reason" begin
        s = SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "alpha")
        @test SETTINGS_FIELDS == (:host, :remote_root, :production, :local_root, :mount_root, :staging, :jobs, :selection)
        @test isempty(settings_errors(s)) && hosts_choices(hosts) == ["alpha", "beta"]
        @test field_error(SyncSettings(), :local_root) == "Local root must be set"
        unlisted = SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "gamma")
        @test field_error(unlisted, :remote_root) == "Remote root: host gamma is not listed in $hosts; add it there or set Remote root"
        @test field_error(unlisted, :remote_root; cli = true) == "host gamma is not listed in $hosts; add it there or pass --remote-root"
        @test field_error(SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "a b"), :host) ==
              "Host must be an ssh alias without whitespace, got \"a b\""
        s.production, s.jobs, s.staging, s.selection = "../x", "-1", "rel/dir", "/tmp/x.json"
        @test field_error(s, :production) == "Production must be a relative path below the remote root, got \"../x\""
        @test field_error(s, :jobs) == "Jobs must be an integer >= 0, got -1" &&
              field_error(s, :jobs; cli = true) == "--jobs must not be negative, got -1"
        @test field_error(s, :staging) == "Staging must be an absolute path or start with ~, got rel/dir"
        @test field_error(s, :selection; cli = true) == "--out must end in .yaml, got /tmp/x.json"
        @test Set(first.(settings_errors(s))) == Set([:production, :jobs, :staging, :selection])
        @test_throws "Production must be a relative path" Options(s)
        @test_throws "production name must be a relative path" Options(s; cli = true)   # the first invalid field in panel order
        paths = SyncSettings(; hosts_file = hosts, host = "alpha", local_root = joinpath(tempdir(), "no-such-dir-sync"),
                             mount_root = "/no/mount")
        @test isempty(settings_errors(paths))   # paths are checked only when asked
        @test field_error(paths, :local_root; check_paths = true) == "Local root $(paths.local_root) is not an existing directory"
        @test field_error(paths, :mount_root; check_paths = true) == "Mount root /no/mount is not an existing directory"
    end

    @testset "preselect_production matches the mirror and the host roots" begin
        roots = ["/home/u/mirror", "/data/l200"]
        @test preselect_production("/home/u/mirror/juleana/ref/x", roots) == "juleana/ref/x" &&
              preselect_production("/data/l200/test/", roots) == "test"
        for path in ("/data/l2001/test", "/data/l200", "/elsewhere/x")   # a name prefix and the root itself are no productions
            @test preselect_production(path, roots) === nothing
        end
        @test host_remote_roots(hosts) == ["/data/a", "/data/b"]
    end

    @testset "parse_options: defaults, overrides and the selection file name" begin
        o = parse_options(["--local-root", "/tmp/m"])
        @test (o.host, o.remote_root, o.production, o.mount_root, o.from) ==
              ("cslg4", "/mnt/scratch/projects/legend/data/l200", "", nothing, nothing)
        @test (o.dry_run, o.yes, o.out, o.jobs) == (false, false, "", 0)
        @test parse_options(["--host", "viper", "--local-root", "/tmp/m"]).remote_root == "/ptmp/oschulz/legend/data/l200"
        @test parse_options(["--local-root", "/m", "--production", "juleana/tmp/jl-v0.7.0dev1"]).out ==
              joinpath(default_selection_dir(), "cslg4", "juleana-tmp-jl-v0.7.0dev1.yaml")
        o = parse_options(["--host", "alpha", "--production", "preprod", "--remote-root", "/data/l200", "--local-root", "rel/mirror",
                           "--mount-root", "rel/mount", "--from", "/tmp/sel.yaml", "--dry-run", "--yes", "--jobs", "4", "--staging",
                           "/ptmp/s"];
                          hosts_file = hosts)
        @test (o.host, o.production, o.remote_root, o.from, o.jobs, o.helper.staging) ==
              ("alpha", "preprod", "/data/l200", "/tmp/sel.yaml", 4, "/ptmp/s")
        @test (o.local_root, o.mount_root) == (abspath("rel/mirror"), abspath("rel/mount")) && o.dry_run && o.yes
        @test parse_options(["--local-root", "/m", "--out", "/tmp/x.yaml"]).out == "/tmp/x.yaml"
        @test parse_options(["--host", "beta", "--local-root", "/m"]; hosts_file = hosts).helper.staging == "/scratch/b"
        @test_throws "--out must end in .yaml, got /tmp/x.json" parse_options(["--local-root", "/m", "--out", "/tmp/x.json"])
        @test_throws "host zeta is not listed in $hosts" parse_options(["--host", "zeta", "--local-root", "/m"]; hosts_file = hosts)
        @test parse_options(["--host", "zeta", "--remote-root", "/x", "--local-root", "/m"]; hosts_file = hosts).remote_root == "/x"
        @test_throws "only mean something together with --from" parse_options(["--local-root", "/m", "--dry-run"])
        @test_throws "--jobs must be an integer" parse_options(["--local-root", "/m", "--jobs", "two"])
        @test_throws "--staging must be an absolute path" parse_options(["--local-root", "/m", "--staging", "rel/stage"])

        r = parse_settings(["--host", "beta", "--production", "p/q", "--jobs", "3", "--local-root", "/tmp"]; hosts_file = hosts)
        opts = Options(r.settings; r.from, r.dry_run, r.yes)
        @test (opts.remote_root, opts.jobs, selection_path(r.settings)) ==
              ("/data/b", 3, joinpath(default_selection_dir(), "beta", "p-q.yaml"))
        @test SyncSettings(opts; hosts_file = hosts).selection == ""   # the default path is not stored as an explicit one
    end

    @testset "headless runs" begin
        function headless(options)
            path = tempname()
            code = open(io -> redirect_stdout(() -> main(options, h), io), path, "w")
            return code, read(path, String)
        end
        local_root = mktempdir()
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        sel = Selection("local", "test", FIXTURE_ROOT, local_root, nothing, [joinpath("test", "config.json"), evt], String[], now())
        out = save_selection(joinpath(mktempdir(), "test.yaml"), sel)
        code, text = headless(Options("local", FIXTURE_ROOT, local_root, nothing, "test", out, out, true, false))
        @test code == 0 && occursin("selected: ", text) && occursin("copy (5 files)", text) &&
              occursin("[1/1] checking files to copy", text)
        @test !isdir(joinpath(local_root, "temp"))
        code, text = headless(Options("local", FIXTURE_ROOT, local_root, nothing, "test", out, out, false, true))
        @test code == 0 && occursin("transferred ", text) && occursin("LEGEND_DATA_CONFIG=", text)
        @test isfile(joinpath(local_root, evt, "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"))

        # --from alone takes the production from the selection; when both are given they must agree.
        nested = Selection("local", "temp/jl-dev", FIXTURE_ROOT, local_root, nothing,
                           ["temp/jl-dev/config.json", "config_fixture.json",
                            "temp/config_site.yaml", "temp/jl-dev/legend-metadata"],
                           String[], now())
        from = save_selection(joinpath(mktempdir(), "sel.yaml"), nested)
        args = ["--host", "local", "--remote-root", FIXTURE_ROOT, "--local-root", local_root, "--from", from, "--dry-run"]
        @test headless(parse_options(args))[1] == 0
        @test_throws "is for production temp/jl-dev" main(parse_options([args; "--production"; "test"]), h)
        @test_throws "is for production temp/jl-dev" run_headless(Options("local", FIXTURE_ROOT, local_root, nothing, "test", from, from,
                                                                          true, true), h)
        @test_throws "saved for host local, but the current host is viper" run_headless(Options("viper", FIXTURE_ROOT, local_root, nothing,
                                                                                                "test", "", out, true, false), h)
        @test_throws ArgumentError run_headless(Options("local", joinpath(FIXTURE_ROOT, "absent"), local_root, nothing, "test", "", out,
                                                        true, false), h)

        # A failure inside a late step names that step on standard error and ends the printed line.
        bad = save_selection(joinpath(mktempdir(), "bad.yaml"),
                             Selection("local", "test", FIXTURE_ROOT, local_root, nothing,
                                       ["test/config.json", "test/absent-dir"], String[], now()))
        stdout_path, stderr_path = tempname(), tempname()
        open(stdout_path, "w") do out_io
            open(stderr_path, "w") do err_io
                redirect_stdout(out_io) do
                    redirect_stderr(err_io) do
                        @test_throws Exception run_headless(Options("local", FIXTURE_ROOT, local_root, nothing, "test", bad, bad, true,
                                                                    false), h)
                    end
                end
            end
        end
        @test occursin("failed in step \"checking files to copy\"", read(stderr_path, String)) && endswith(read(stdout_path, String), "\n")
    end
end
