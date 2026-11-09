# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# No helper process starts in this file: the helper of the tests that touch extract entries cannot run.
@testset "rsync" begin
    h = LocalHost()
    p = Production(h, "test", FIXTURE_ROOT, mktempdir())

    @testset "the installed rsync is accepted, Apple's openrsync and rsync before 3.1 are rejected" begin
        @test check_rsync() >= v"3.1"
        with_rsync("#!/bin/sh\necho 'openrsync: protocol version 29'\n") do
            @test_throws "found Apple openrsync" check_rsync()
        end
        with_rsync("#!/bin/sh\necho 'rsync  version 3.0.9  protocol version 30'\n") do
            @test_throws "rsync 3.0.9 is too old" check_rsync()
        end
        with_rsync("#!/bin/sh\necho 'garbage'\n") do
            @test_throws "cannot read an rsync version" check_rsync()
        end
    end

    @testset "the rsync command mirrors with times, permissions and symlinks" begin
        args = collect(rsync_command(h, p, "/tmp/files.txt"; dry_run = false).exec)
        @test args[1] == "rsync" &&
              all(in(args),
                  ["-r", "-t", "-p", "-l", "--partial-dir=.juleana-partial", "--files-from=/tmp/files.txt", "--info=progress2", "--stats"])
        @test "--dry-run" ∉ args && "-e" ∉ args && args[end - 1] == FIXTURE_ROOT * "/" && args[end] == p.local_root * "/"
        dry = collect(rsync_command(h, p, "/tmp/files.txt"; dry_run = true).exec)
        @test "--dry-run" in dry && "--info=progress2" ∉ dry
        ssh = collect(rsync_command(SSHHost("cslg4", nothing), p, "/tmp/files.txt"; dry_run = false).exec)
        @test ssh[end - 1] == "cslg4:" * FIXTURE_ROOT * "/"
        @test ssh[findfirst(==("-e"), ssh) .+ (0:1)] ==
              ["-e", "ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"]
    end

    @testset "link mode needs a mounted mount root" begin
        @test_throws "no mount root configured" check_mount(p)
        @test_throws "is not a mount point" check_mount(Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = mktempdir()))
        @test check_mount(Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")) == "/"
    end
end

@testset "transfer" begin
    h = LocalHost()
    evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
    file = joinpath(evt, "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5")
    sel(p, copy, link = String[]; mount = nothing) = Selection("local", "test", FIXTURE_ROOT, p.local_root, mount, copy, link, now())

    @testset "a dry run estimates and leaves the mirror untouched, a real transfer mirrors and is idempotent" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        s = sel(p, [joinpath("test", "config.json"), joinpath("test", "legend-metadata"), evt])
        config = filesize(joinpath(FIXTURE_ROOT, "test", "config.json"))
        est = apply!(h, p, sel(p, [joinpath("test", "config.json"), evt]); dry_run = true)
        @test (est.files, est.bytes, est.links) == (3, 4096 + 8192 + config, 0) && !isdir(joinpath(p.local_root, "temp"))
        @test apply_steps(s; dry_run = true) == ["checking files to copy"] &&
              apply_steps(s; dry_run = false) == ["copying", "creating links"]

        seen = Progress[]
        result = apply!(h, p, s; progress = prog -> push!(seen, prog))
        @test result isa TransferResult && (result.files, result.links) == (4, 0) && isempty(result.skipped) && result.warnings == ""
        @test filesize(joinpath(p.local_root, evt, "l200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5")) == 8192
        @test isfile(joinpath(p.local_root, "test", "legend-metadata", "README.md"))
        @test read(joinpath(p.local_root, "test", "config.json"), String) == read(joinpath(FIXTURE_ROOT, "test", "config.json"), String)
        @test result.config == joinpath(p.local_root, "test", "config_local.yaml") && isfile(result.config)
        @test occursin("LEGEND_DATA_CONFIG=$(result.config)", summary_text(result))
        @test all(prog -> 0 <= prog.fraction <= 1 && !isempty(prog.rate), seen)   # a small file may finish before rsync prints a reading
        @test apply!(h, p, s).bytes == 0

        # Remote symlinks are mirrored as symlinks.
        symlink("config.json", joinpath(FIXTURE_ROOT, "test", "current"))
        q = Production(h, "test", FIXTURE_ROOT, mktempdir())
        apply!(h, q, sel(q, [joinpath("test", "config.json"), joinpath("test", "current")]))
        @test islink(joinpath(q.local_root, "test", "current")) && readlink(joinpath(q.local_root, "test", "current")) == "config.json"
        rm(joinpath(FIXTURE_ROOT, "test", "current"))
    end

    @testset "apply! refuses a missing local root and links without a mount" begin
        gone = Production(h, "test", FIXTURE_ROOT, joinpath(mktempdir(), "missing"))
        @test_throws "does not exist" apply!(h, gone, sel(gone, ["test/config.json"]))
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        @test_throws "no mount root configured" apply!(h, p, sel(p, String[], ["temp"]))
    end

    @testset "only symlinks that the tool created are removed" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        s = sel(p, [file])
        path = joinpath(p.local_root, file)
        mkpath(dirname(path))
        symlink("/nowhere", path)
        @test remove_stale_links!(p, s) == 1 && !ispath(path)
        write(path, zeros(UInt8, 4096))
        @test remove_stale_links!(p, s) == 0 && isfile(path)
        rm(path)
        mkpath(joinpath(path, "inner"))
        @test remove_stale_links!(p, s) == 0 && isdir(joinpath(path, "inner"))
    end

    @testset "links: a linked directory is one symlink, a copy below it forces real directories" begin
        jlhit, jlevt = joinpath("temp", "jl-dev", "generated", "tier", "jlhit"), joinpath("temp", "jl-dev", "generated", "tier", "jlevt")
        p = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")
        created, skipped = create_links!(h, p, sel(p, String[], [jlhit]; mount = "/"))
        @test created == 1 && isempty(skipped) && readlink(joinpath(p.local_root, jlhit)) == joinpath("/", jlhit)

        p2 = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")
        created, skipped = create_links!(h, p2, sel(p2, [file], [jlevt]; mount = "/"))
        @test created == 1 && isempty(skipped) && isdir(joinpath(p2.local_root, evt)) && !islink(joinpath(p2.local_root, jlevt))
        @test !ispath(joinpath(p2.local_root, file)) &&
              islink(joinpath(p2.local_root, evt, "l200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5"))

        # Real data already at a link target is kept and reported.
        p3 = Production(h, "test", FIXTURE_ROOT, mktempdir(); mount_root = "/")
        mkpath(joinpath(p3.local_root, jlhit))
        write(joinpath(p3.local_root, jlhit, "already-here.lh5"), "x")
        created, skipped = create_links!(h, p3, sel(p3, String[], [jlhit]; mount = "/"))
        @test created == 0 && skipped == [jlhit] && isfile(joinpath(p3.local_root, jlhit, "already-here.lh5"))
    end
end

@testset "per-detector files" begin
    h = LocalHost()
    tier = joinpath(PERDET_ROOT, "dprod", "generated", "tier")
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())
    base = ["dprod/config.json"]
    p = Production(h, "dprod", PERDET_ROOT, mktempdir())
    p16_rel = relative(p, joinpath(tier, "jlqcs", "cal", "p16"))
    qcs(run, detector) = joinpath(p16_rel, run, "l200-p16-$run-cal-$detector-tier_jlqcs.lh5")
    function selection(entries; copy = base, link = String[], extract = ExtractEntry[], root = PERDET_ROOT, local_root = p.local_root)
        return Selection("local", "dprod", root, local_root, nothing, copy, link, now(), extract, entries)
    end
    entry(detectors, mode; dir = p16_rel) = DetectorEntry(dir, detectors, mode)

    @testset "an entry resolves to the files of the named detectors" begin
        copies, links, absent = plan_detector_files(h, p, selection([entry(["B00000C", "V01234A"], :copy)]))
        @test copies == [qcs("r000", "B00000C"), qcs("r000", "V01234A"), qcs("r001", "B00000C")]
        @test isempty(links) && absent == [(joinpath(p16_rel, "r001"), "V01234A")]
        copies, links, _ = plan_detector_files(h, p, selection([entry(["V01234A"], :link)]))
        @test isempty(copies) && links == [qcs("r000", "V01234A")]
        @test plan_detector_files(h, p, selection([entry(["Z99999Z"], :copy)]))[3] ==
              [(joinpath(p16_rel, "r000"), "Z99999Z"), (joinpath(p16_rel, "r001"), "Z99999Z")]
        # A file that the copy or link list already covers is not added again.
        covered = selection([entry(["B00000C"], :copy)]; copy = [base; qcs("r000", "B00000C")])
        @test plan_detector_files(h, p, covered)[1] == [qcs("r001", "B00000C")]
        @test plan_detector_files(h, p, selection([entry(["B00000C"], :copy)]; copy = [base; joinpath(p16_rel, "r001")]))[1] ==
              [qcs("r000", "B00000C")]
        @test plan_detector_files(h, p, selection([entry(["B00000C"], :link)]; link = [joinpath(p16_rel, "r000")]))[2] ==
              [qcs("r001", "B00000C")]
        # A run without per-detector files is reported for every detector.
        root = make_per_detector_remote()
        mkpath(joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16", "r002"))
        q = Production(h, "dprod", root, mktempdir())
        @test plan_detector_files(h, q, selection([entry(["B00000C"], :copy)]; root, local_root = q.local_root))[3] ==
              [(joinpath(p16_rel, "r002"), "B00000C")]
    end

    @testset "entries that cannot be resolved are an error" begin
        for dir in (relative(p, joinpath(tier, "jlqcs", "cal", "p17")), relative(p, joinpath(tier, "jlqcs", "cal")))
            @test_throws "detector file entry $dir: no run directory holds per-detector files" plan_detector_files(h, p,
                                                                                                                   selection([entry(["B00000C"],
                                                                                                                                    :copy;
                                                                                                                                    dir)]))
        end
        both = selection([entry(["B00000C"], :copy), entry(["B00000C", "V01234A"], :link)])
        @test_throws "detector B00000C of $p16_rel is in a copy and a link entry" plan_detector_files(h, p, both)
    end

    @testset "apply! copies and links exactly the detector's files and reports the runs that lack it" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root = "/")
        s = selection([entry(["B00000C"], :copy), entry(["V01234A"], :link)]; local_root = q.local_root)
        copies, links, absent = plan_detector_files(h, q, s)
        est = apply!(h, q, s; dry_run = true, helper = broken)
        @test est.bytes == filesize(joinpath(PERDET_ROOT, "dprod", "config.json")) + 100 + 300 && (est.files, est.links) == (3, 1)
        @test est.not_in_run == absent == [(joinpath(p16_rel, "r001"), "V01234A")] && endswith(format_estimate(est), ", 1 not in run")
        @test !ispath(joinpath(q.local_root, p16_rel))
        result = apply!(h, q, s; helper = broken)
        @test (result.files, result.links, result.not_in_run) == (est.files, est.links, est.not_in_run)
        @test occursin("not in run, left out: V01234A in $(joinpath(p16_rel, "r001"))", summary_text(result))
        walked = [(relpath(joinpath(dir, f), q.local_root), islink(joinpath(dir, f)))
                  for (dir, _, fs) in walkdir(joinpath(q.local_root, "dprod", "generated")) for f in fs]
        @test sort([f for (f, link) in walked if !link]) == copies && [f for (f, link) in walked if link] == links
        @test readlink(joinpath(q.local_root, links[1])) == to_mount(q, joinpath(PERDET_ROOT, links[1]))
        @test filesize(joinpath(q.local_root, qcs("r001", "B00000C"))) == 300 && apply!(h, q, s; helper = broken).files == 0

        # A copy entry wins over a link of the same file.
        w = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root = "/")
        result = apply!(h, w, selection([entry(["B00000C"], :link)]; copy = [base; qcs("r000", "B00000C")], local_root = w.local_root);
                        helper = broken)
        @test isfile(joinpath(w.local_root, qcs("r000", "B00000C"))) && !islink(joinpath(w.local_root, qcs("r000", "B00000C")))
        @test islink(joinpath(w.local_root, qcs("r001", "B00000C"))) && result.links == 1

        # A link entry without a mount root fails before anything is written.
        none = Production(h, "dprod", PERDET_ROOT, mktempdir())
        @test_throws "no mount root configured" apply!(h, none, selection([entry(["B00000C"], :link)]; local_root = none.local_root);
                                                       helper = broken)
        @test !ispath(joinpath(none.local_root, p16_rel))
    end

    @testset "only the extract part of a selection starts the helper" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir())
        run = ExtractEntry(relative(p, joinpath(tier, "jldsp", "cal", "p16", "r000")), ["B00000C"])
        s = selection([entry(["B00000C"], :copy)]; extract = [run], local_root = q.local_root)
        @test_throws "/nonexistent/julia" apply!(h, q, s; dry_run = true, helper = broken)
        @test !ispath(joinpath(q.local_root, p16_rel))
        @test apply_steps(selection([entry(["B00000C", "V01234A"], :copy)]); dry_run = true) ==
              ["listing detector files", "checking files to copy"]
    end

    @testset "a saved selection picks up a run added later" begin
        root = make_per_detector_remote()
        q = Production(h, "dprod", root, mktempdir())
        tree = production_tree(h, q)
        rows = expand_detectors!(h, broken, ensure_detectors!(find_node!(h, q, tree, p16_rel); whole_files = true))
        set_mode!(rows.children[1], :copy)
        saved = save_selection(joinpath(mktempdir(), "dprod.yaml"), Selection(q, "local", tree))
        added = joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16", "r002")
        mkpath(added)
        write(joinpath(added, "l200-p16-r002-cal-B00000C-tier_jlqcs.lh5"), repeat("n", 50))
        loaded = load_selection(saved, q)
        copies, _, absent = plan_detector_files(h, q, loaded)
        @test length(copies) == 3 && copies[end] == qcs("r002", "B00000C") && isempty(absent)
        apply!(h, q, loaded; helper = broken)
        @test filesize(joinpath(q.local_root, qcs("r002", "B00000C"))) == 50
        fresh = production_tree(h, q)
        apply_selection!(h, q, fresh, loaded; helper = broken)
        frow = find_node!(h, q, fresh, p16_rel).children[1].children[1]
        @test frow.mode == :copy && frow.size == 450 && length(frow.holders) == 3
    end
end

@testset "local mirror conflicts of an extraction" begin
    h = LocalHost()
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())
    dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
    files = [joinpath(dsp, "l200-p18-r000-cal-20251107T191821Z-tier_jldsp.lh5"),
             joinpath(dsp, "l200-p18-r000-cal-20251107T192416Z-tier_jldsp.lh5")]
    function selection(p, groups; copy = ["xprod/config.json"])
        return Selection("local", "xprod", EXTRACT_ROOT, p.local_root, nothing, copy, String[], now(),
                         [ExtractEntry(relative(p, dsp), groups)])
    end
    plan_for(p) = first(plan_extraction(h, p, selection(p, ["B00000C"]), joinpath(mktempdir(), "stage"); helper = broken))

    @testset "a run entry is planned without the helper, one job per file" begin
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        stage = joinpath(tempdir(), "stage")
        @test staging_production_dir(stage, p) == joinpath(stage, "xprod")
        @test staging_production_dir(stage, Production(h, "temp/jl-dev", FIXTURE_ROOT, p.local_root)) == joinpath(stage, "temp-jl-dev")
        plan, absent = plan_extraction(h, p, selection(p, ["B00000C", "aux"]; copy = [relative(p, files[2])]), stage; helper = broken)
        @test [j.source for j in plan] == files[1:1] && plan[1].groups == ["B00000C", "aux"] && isempty(absent)   # a file copied whole is left out
        @test plan[1].destination == joinpath(stage, "xprod", relative(p, files[1])) && plan[1].relative == relative(p, files[1])
        @test isempty(first(plan_extraction(h, p, selection(p, ["B00000C"]; copy = [relative(p, dsp)]), stage; helper = broken)))
    end

    @testset "a full copy, a symlink or a link above a file is never replaced" begin
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        mkpath(dirname(to_local(p, files[1])))
        cp(files[1], to_local(p, files[1]))
        @test reduced_groups(files[1]) === nothing && reduced_groups(to_local(p, files[1])) === nothing
        @test_throws "absent.lh5" reduced_groups(joinpath(mktempdir(), "absent.lh5"))
        runnable, conflicts = reconcile_local(p, plan_for(p))
        @test conflicts == [relative(p, files[1])] && [j.source for j in runnable] == files[2:2]

        q = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        mkpath(dirname(to_local(q, files[1])))
        symlink("/nowhere", to_local(q, files[1]))
        runnable, conflicts = reconcile_local(q, plan_for(q))
        @test conflicts == [relative(q, files[1])] && [j.source for j in runnable] == files[2:2] &&
              readlink(to_local(q, files[1])) == "/nowhere"

        r = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        mkpath(dirname(dirname(to_local(r, files[1]))))
        symlink("/nowhere", dirname(to_local(r, files[1])))
        runnable, conflicts = reconcile_local(r, plan_for(r))
        @test conflicts == [relative(r, f) for f in files] && isempty(runnable)
    end

    @testset "the staging directory must have room" begin
        @test check_staging_space("/s", 10^6, 1000) === nothing
        @test_throws "has 1.0 K free but the extraction needs about 4.0 K" check_staging_space("/s", 1024, 4096)
        @test_throws "in $(joinpath(config_dir(), "hosts.yaml")) or pass --staging" check_staging_space("/s", 1024, 4096)
    end
end
