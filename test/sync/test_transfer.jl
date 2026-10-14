@testset "transfer.jl" begin
    h = LocalHost()

    @testset "check_rsync" begin
        version = check_rsync()
        @test version isa VersionNumber
        @test version >= v"3.1"
    end

    @testset "rsync_command" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        cmd = rsync_command(h, p, "/tmp/files.txt"; dry_run = false)
        args = collect(cmd.exec)
        @test args[1] == "rsync"
        @test "-r" in args
        @test "-t" in args
        @test "-p" in args
        @test "--partial-dir=.juleana-partial" in args
        @test "-l" in args
        @test "--files-from=/tmp/files.txt" in args
        @test "--info=progress2" in args
        @test "--stats" in args
        @test "--dry-run" ∉ args
        @test args[end - 1] == FIXTURE_ROOT * "/"
        @test args[end] == p.local_root * "/"

        dry = collect(rsync_command(h, p, "/tmp/files.txt"; dry_run = true).exec)
        @test "--dry-run" in dry
        @test "--info=progress2" ∉ dry

        ssh = collect(rsync_command(SSHHost("cslg4", nothing), p, "/tmp/files.txt"; dry_run = false).exec)
        @test ssh[end - 1] == "cslg4:" * FIXTURE_ROOT * "/"
        @test ["-e", "ssh -o BatchMode=yes"] == ssh[findfirst(==("-e"), ssh) .+ (0:1)]
        @test "-e" ∉ collect(rsync_command(h, p, "/tmp/files.txt"; dry_run = false).exec)
    end

    @testset "parse_progress" begin
        prog = parse_progress("      1,234,567  45%   12.34MB/s    0:00:12")
        @test prog.bytes == 1234567
        @test prog.fraction ≈ 0.45
        @test prog.rate == "12.34MB/s"
        @test prog.eta == "0:00:12"
        @test parse_progress("") === nothing
        @test parse_progress("sending incremental file list") === nothing
    end

    @testset "check_mount" begin
        nomount = Production(h, "test", FIXTURE_ROOT, mktempdir())
        @test_throws "no mount root configured" check_mount(nomount)

        notmounted = Production(h, "test", FIXTURE_ROOT, mktempdir();
                                mount_root = mktempdir())
        @test_throws "is not a mount point" check_mount(notmounted)

        # A plain temp directory sits on the same device as its parent, so the
        # device comparison rejects it even though `mount`'s output would have
        # matched it as a substring of some unrelated mounted path.
        plain = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = mktempdir())
        @test_throws "is not a mount point" check_mount(plain)

        mounted = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")
        @test check_mount(mounted) == "/"
    end

    @testset "dry run against the fixture" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        sel = Selection("local", "test", FIXTURE_ROOT, p.local_root, nothing,
                        [joinpath("test", "config.json"), evt], String[], now())
        est = apply!(h, p, sel; dry_run = true)
        @test est isa Estimate
        @test est.files == 3            # config.json plus the two jlevt files
        @test est.bytes == 4096 + 8192 + filesize(joinpath(FIXTURE_ROOT, "test", "config.json"))
        @test est.links == 0
        # A dry run must leave the mirror untouched.
        @test !isdir(joinpath(p.local_root, "temp"))
    end

    @testset "real transfer" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        sel = Selection("local", "test", FIXTURE_ROOT, p.local_root, nothing,
                        [joinpath("test", "config.json"),
                         joinpath("test", "legend-metadata"), evt], String[], now())

        seen = Progress[]
        result = apply!(h, p, sel; progress = prog -> push!(seen, prog))
        @test result isa TransferResult
        @test result.files == 4          # config.json, the metadata README, two jlevt files
        @test result.links == 0
        @test isempty(result.skipped)
        @test isfile(joinpath(p.local_root, evt,
                             "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"))
        @test filesize(joinpath(p.local_root, evt,
                                "l200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5")) == 8192
        @test isfile(joinpath(p.local_root, "test", "legend-metadata", "README.md"))
        # The mirrored config.json is untouched and config_local.yaml sits beside it.
        @test read(joinpath(p.local_root, "test", "config.json"), String) ==
              read(joinpath(FIXTURE_ROOT, "test", "config.json"), String)
        @test result.config == joinpath(p.local_root, "test", "config_local.yaml")
        @test isfile(result.config)
        @test result.warnings == ""
        @test occursin("LEGEND_DATA_CONFIG=$(result.config)", summary_text(result))
        # Every progress reading is well formed; tiny fixtures may transfer
        # before rsync ever prints one, so `seen` itself may be empty.
        @test all(prog -> 0 <= prog.fraction <= 1, seen)
        @test all(prog -> !isempty(prog.rate), seen)

        # Re-running transfers nothing: -t and -p make the files match.
        again = apply!(h, p, sel)
        @test again.bytes == 0
    end

    @testset "remote symlinks are mirrored as symlinks" begin
        symlink("config.json", joinpath(FIXTURE_ROOT, "test", "current"))
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        sel = Selection("local", "test", FIXTURE_ROOT, p.local_root, nothing,
                        [joinpath("test", "config.json"), joinpath("test", "current")],
                        String[], now())
        apply!(h, p, sel)
        @test islink(joinpath(p.local_root, "test", "current"))
        @test readlink(joinpath(p.local_root, "test", "current")) == "config.json"
    end

    @testset "stale symlinks are replaced, real data is not" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        file = joinpath(evt, "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5")
        sel = Selection("local", "test", FIXTURE_ROOT, p.local_root, nothing,
                        [file], String[], now())

        mkpath(joinpath(p.local_root, evt))
        symlink("/nowhere", joinpath(p.local_root, file))
        @test remove_stale_links!(p, sel) == 1
        @test !ispath(joinpath(p.local_root, file))

        # A real file in the same place is kept: nothing but links is ever removed.
        write(joinpath(p.local_root, file), zeros(UInt8, 4096))
        @test remove_stale_links!(p, sel) == 0
        @test isfile(joinpath(p.local_root, file))
    end

    @testset "create_links!" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")
        jlhit = joinpath("temp", "jl-dev", "generated", "tier", "jlhit")
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt")

        # A linked directory with nothing copied below it becomes one symlink.
        plain = Selection("local", "test", FIXTURE_ROOT, p.local_root, "/",
                          String[], [jlhit], now())
        created, skipped = create_links!(h, p, plain)
        @test created == 1
        @test isempty(skipped)
        @test islink(joinpath(p.local_root, jlhit))
        @test readlink(joinpath(p.local_root, jlhit)) == joinpath("/", jlhit)

        # A copy below a link forces real directories down to the copied file, and
        # the siblings on the way are linked individually.
        p2 = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")
        file = joinpath(evt, "phy", "p18", "r000",
                        "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5")
        mixed = Selection("local", "test", FIXTURE_ROOT, p2.local_root, "/",
                          [file], [evt], now())
        created2, skipped2 = create_links!(h, p2, mixed)
        @test isempty(skipped2)
        @test isdir(joinpath(p2.local_root, evt, "phy", "p18", "r000"))
        @test !islink(joinpath(p2.local_root, evt))
        @test !ispath(joinpath(p2.local_root, file))       # rsync brings this one
        @test islink(joinpath(p2.local_root, evt, "phy", "p18", "r000",
                              "l200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5"))
        @test created2 == 1

        # Real data already at a link target is kept and reported.
        p3 = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")
        mkpath(joinpath(p3.local_root, jlhit))
        write(joinpath(p3.local_root, jlhit, "already-here.lh5"), "x")
        created3, skipped3 = create_links!(h, p3, Selection(
            "local", "test", FIXTURE_ROOT, p3.local_root, "/", String[], [jlhit], now()))
        @test created3 == 0
        @test skipped3 == [jlhit]
        @test isfile(joinpath(p3.local_root, jlhit, "already-here.lh5"))
    end

    @testset "apply! requires an existing local root" begin
        missing_root = joinpath(mktempdir(), "missing")
        p = Production(h, "test", FIXTURE_ROOT, missing_root)
        sel = Selection("local", "test", FIXTURE_ROOT, missing_root, nothing,
                        [joinpath("test", "config.json")], String[], now())
        @test_throws "does not exist" apply!(h, p, sel)
    end

    @testset "apply! refuses links without a mount" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        sel = Selection("local", "test", FIXTURE_ROOT, p.local_root, nothing,
                        String[], ["temp"], now())
        @test_throws "no mount root configured" apply!(h, p, sel)
    end
end
