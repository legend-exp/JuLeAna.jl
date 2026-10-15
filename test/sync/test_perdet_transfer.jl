@testset "per-detector tier: planning and apply!" begin
    h = LocalHost()
    tier = joinpath(PERDET_ROOT, "dprod", "generated", "tier")
    p16 = joinpath(tier, "jlqcs", "cal", "p16")
    # A helper that cannot run: planning and transferring detector files must not start it.
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())
    base = ["dprod/config.json"]

    qcs(period_rel, run, detector) = joinpath(period_rel, run,
        "l200-$(basename(period_rel))-$run-cal-$detector-tier_jlqcs.lh5")
    p = Production(h, "dprod", PERDET_ROOT, mktempdir())
    p16_rel = relative(p, p16)
    selection(p, entries; copy = base, link = String[]) =
        Selection("local", "dprod", PERDET_ROOT, p.local_root, p.mount_root, copy, link, now(),
                  ExtractEntry[], entries)
    entry(detectors, mode; dir = p16_rel) = DetectorEntry(dir, detectors, mode)

    @testset "an entry resolves to the files of the named detectors" begin
        sel = selection(p, [entry(["B00000C", "V01234A"], :copy)])
        copies, links, absent = plan_detector_files(h, p, sel)
        @test copies == [qcs(p16_rel, "r000", "B00000C"), qcs(p16_rel, "r000", "V01234A"),
                         qcs(p16_rel, "r001", "B00000C")]
        @test isempty(links)
        @test absent == [(joinpath(p16_rel, "r001"), "V01234A")]

        copies, links, absent = plan_detector_files(h, p, selection(p, [entry(["V01234A"], :link)]))
        @test isempty(copies)
        @test links == [qcs(p16_rel, "r000", "V01234A")]

        # A detector that no run holds is reported for every run.
        _, _, none = plan_detector_files(h, p, selection(p, [entry(["Z99999Z"], :copy)]))
        @test none == [(joinpath(p16_rel, "r000"), "Z99999Z"), (joinpath(p16_rel, "r001"), "Z99999Z")]
        @test plan_detector_files(h, p, selection(p, DetectorEntry[])) == (String[], String[], Tuple{String,String}[])
    end

    @testset "files the copy list already covers are not added again" begin
        sel = selection(p, [entry(["B00000C"], :copy)];
                        copy = [base; qcs(p16_rel, "r000", "B00000C")])
        copies, _, _ = plan_detector_files(h, p, sel)
        @test copies == [qcs(p16_rel, "r001", "B00000C")]
        sel = selection(p, [entry(["B00000C"], :copy)]; copy = [base; joinpath(p16_rel, "r001")])
        @test plan_detector_files(h, p, sel)[1] == [qcs(p16_rel, "r000", "B00000C")]
        sel = selection(p, [entry(["B00000C"], :link)]; copy = [base; p16_rel])
        @test plan_detector_files(h, p, sel)[2] == String[]
        sel = selection(p, [entry(["B00000C"], :link)]; link = [joinpath(p16_rel, "r000")])
        @test plan_detector_files(h, p, sel)[2] == [qcs(p16_rel, "r001", "B00000C")]
    end

    @testset "a run without per-detector files is reported for every detector" begin
        root = make_per_detector_remote()
        period = joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
        mkpath(joinpath(period, "r002"))
        write(joinpath(period, "r002", "README.txt"), "none\n")
        q = Production(h, "dprod", root, mktempdir())
        sel = Selection("local", "dprod", root, q.local_root, nothing, base, String[], now(),
                        ExtractEntry[], [entry(["B00000C"], :copy)])
        _, _, absent = plan_detector_files(h, q, sel)
        @test absent == [(joinpath(p16_rel, "r002"), "B00000C")]
    end

    @testset "two files of one detector in a run are an error" begin
        root = make_per_detector_remote()
        q = Production(h, "dprod", root, mktempdir())
        write(joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16", "r001",
                       "l200-p16-r001-phy-B00000C-tier_jlqcs.lh5"), "y")
        sel = Selection("local", "dprod", root, q.local_root, nothing, base, String[], now(),
                        ExtractEntry[], [entry(["B00000C"], :copy)])
        @test_throws "$(joinpath(p16_rel, "r001")) holds two files for detector B00000C: l200-p16-r001-cal-B00000C-tier_jlqcs.lh5 and l200-p16-r001-phy-B00000C-tier_jlqcs.lh5" plan_detector_files(h, q, sel)
    end

    @testset "an entry without per-detector files is an error" begin
        empty_dir = relative(p, joinpath(tier, "jlqcs", "cal", "p17"))
        @test_throws "detector file entry $empty_dir: no run directory holds per-detector files" plan_detector_files(
            h, p, selection(p, [entry(["B00000C"], :copy; dir = empty_dir)]))
        no_runs = relative(p, joinpath(tier, "jlqcs", "cal"))
        @test_throws "detector file entry $no_runs: no run directory holds per-detector files" plan_detector_files(
            h, p, selection(p, [entry(["B00000C"], :copy; dir = no_runs)]))
        both = selection(p, [entry(["B00000C"], :copy), entry(["B00000C", "V01234A"], :link)])
        @test_throws "detector B00000C of $p16_rel is in a copy and a link entry" plan_detector_files(h, p, both)
    end

    @testset "apply! copies exactly the detector's files" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir())
        sel = selection(q, [entry(["B00000C", "V01234A"], :copy)])
        result = apply!(h, q, sel; helper = broken)
        @test result.not_in_run == [(joinpath(p16_rel, "r001"), "V01234A")]
        @test result.files == 4                       # 3 detector files and config.json
        local_run(run) = joinpath(q.local_root, p16_rel, run)
        @test sort(readdir(local_run("r000"))) ==
              basename.([qcs(p16_rel, "r000", "B00000C"), qcs(p16_rel, "r000", "V01234A")])
        @test readdir(local_run("r001")) == [basename(qcs(p16_rel, "r001", "B00000C"))]
        @test filesize(joinpath(q.local_root, qcs(p16_rel, "r001", "B00000C"))) == 300
        @test !ispath(joinpath(q.local_root, "dprod", "generated", "tier", "jldsp"))
        text = summary_text(result)
        @test occursin("not in run, left out: V01234A in $(joinpath(p16_rel, "r001"))", text)
        @test occursin("transferred", text)

        # A second run moves nothing and reports the same pair.
        again = apply!(h, q, sel; helper = broken)
        @test again.files == 0
    end

    @testset "only the extract part of a selection needs the helper" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir())
        extract = ExtractEntry(relative(p, joinpath(tier, "jldsp", "cal", "p16", "r000")), ["B00000C"])
        sel = Selection("local", "dprod", PERDET_ROOT, q.local_root, nothing, base, String[], now(),
                        [extract], [entry(["B00000C"], :copy)])
        @test_throws "/nonexistent/julia" apply!(h, q, sel; dry_run = true, helper = broken)
        @test !ispath(joinpath(q.local_root, p16_rel))
        # Without the extract entry the same detector files are planned and transferred.
        apply!(h, q, selection(q, [entry(["B00000C"], :copy)]); helper = broken)
        @test isfile(joinpath(q.local_root, qcs(p16_rel, "r000", "B00000C")))
    end

    @testset "a link entry creates symlinks under the mount root" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root = "/")
        sel = selection(q, [entry(["B00000C"], :link)])
        result = apply!(h, q, sel; helper = broken)
        @test result.links == 2
        for run in ("r000", "r001")
            file = qcs(p16_rel, run, "B00000C")
            @test islink(joinpath(q.local_root, file))
            @test readlink(joinpath(q.local_root, file)) == to_mount(q, joinpath(PERDET_ROOT, file))
        end
        @test !ispath(joinpath(q.local_root, qcs(p16_rel, "r000", "V01234A")))

        # A link entry without a mount root fails before anything is written.
        none = Production(h, "dprod", PERDET_ROOT, mktempdir())
        @test_throws "no mount root configured" apply!(h, none, selection(none, [entry(["B00000C"], :link)]);
                                                       helper = broken)
        @test !ispath(joinpath(none.local_root, p16_rel))
    end

    @testset "a copy entry wins over a link of the same file" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root = "/")
        file = qcs(p16_rel, "r000", "B00000C")
        sel = selection(q, [entry(["B00000C"], :link)]; copy = [base; file])
        result = apply!(h, q, sel; helper = broken)
        @test isfile(joinpath(q.local_root, file)) && !islink(joinpath(q.local_root, file))
        @test islink(joinpath(q.local_root, qcs(p16_rel, "r001", "B00000C")))
        @test result.links == 1
    end

    @testset "the dry run resolves the same files" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root = "/")
        sel = selection(q, [entry(["B00000C"], :copy), entry(["V01234A"], :link)])
        est = apply!(h, q, sel; dry_run = true, helper = broken)
        @test est.bytes == filesize(joinpath(PERDET_ROOT, "dprod", "config.json")) + 100 + 300
        @test est.files == 3
        @test est.links == 1
        @test est.not_in_run == [(joinpath(p16_rel, "r001"), "V01234A")]
        @test endswith(format_estimate(est), ", 1 not in run")
        @test !ispath(joinpath(q.local_root, p16_rel))
    end

    @testset "the dry run and the transfer act on the planned files" begin
        q = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root = "/")
        sel = selection(q, [entry(["B00000C"], :copy), entry(["V01234A"], :link)])
        copies, links, absent = plan_detector_files(h, q, sel)
        est = apply!(h, q, sel; dry_run = true, helper = broken)
        @test est.files == length(copies) + length(base)
        @test est.links == length(links)
        @test est.not_in_run == absent
        result = apply!(h, q, sel; helper = broken)
        @test result.files == est.files && result.links == est.links
        @test result.not_in_run == est.not_in_run
        mirrored = [relpath(joinpath(root, f), q.local_root)
                    for (root, _, fs) in walkdir(joinpath(q.local_root, "dprod", "generated"))
                    for f in fs if !islink(joinpath(root, f))]
        linked = [relpath(joinpath(root, f), q.local_root)
                  for (root, _, fs) in walkdir(joinpath(q.local_root, "dprod", "generated"))
                  for f in fs if islink(joinpath(root, f))]
        @test sort(mirrored) == copies
        @test sort(linked) == links
    end

    @testset "a saved selection picks up a run added later" begin
        root = make_per_detector_remote()
        q = Production(h, "dprod", root, mktempdir())
        tree = production_tree(h, q)
        period = find_node!(h, q, tree, p16_rel)
        rows = expand_detectors!(h, broken, ensure_detectors!(period; whole_files = true))
        set_mode!(rows.children[1], :copy)                       # B00000C
        saved = save_selection(joinpath(mktempdir(), "dprod.yaml"), Selection(q, "local", tree))

        added = joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16", "r002")
        mkpath(added)
        write(joinpath(added, "l200-p16-r002-cal-B00000C-tier_jlqcs.lh5"), repeat("n", 50))

        sel = load_selection(saved, q)
        copies, _, absent = plan_detector_files(h, q, sel)
        @test copies[end] == qcs(p16_rel, "r002", "B00000C")
        @test length(copies) == 3 && isempty(absent)
        apply!(h, q, sel; helper = broken)
        @test filesize(joinpath(q.local_root, qcs(p16_rel, "r002", "B00000C"))) == 50

        fresh = production_tree(h, q)
        apply_selection!(h, q, fresh, sel; helper = broken)
        frows = find_node!(h, q, fresh, p16_rel).children[1].children
        @test [c.mode for c in frows] == [:copy, :none]
        @test frows[1].size == 450 && length(frows[1].holders) == 3
    end
end
