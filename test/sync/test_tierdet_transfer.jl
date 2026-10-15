@testset "tier/detector layout: planning and apply!" begin
    h = LocalHost()
    tier = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier")
    p18 = joinpath(tier, "jlpks", "cal", "p18")
    r000 = joinpath(p18, "r000")
    r001 = joinpath(p18, "r001")
    files = [joinpath(r000, "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5"),
             joinpath(r000, "l200-p18-r000-cal-20251107T192416Z-tier_jlpks.lh5"),
             joinpath(r001, "l200-p18-r001-cal-20251108T101010Z-tier_jlpks.lh5")]

    function setup()
        stage = joinpath(mktempdir(), "stage")
        Production(h, "tprod", TIER_DET_ROOT, mktempdir()), HelperConfig(; staging = stage), stage
    end
    selection(p, entries; copy = ["tprod/config.json", "tprod/legend-metadata"]) =
        Selection("local", "tprod", TIER_DET_ROOT, p.local_root, nothing, copy, String[], now(), entries)
    period(p, groups) = ExtractEntry(relative(p, p18), groups)
    groups_of(path) = h5open(f -> collect(keys(f["jlpks"])), path, "r")

    @testset "a period entry expands to one job per run" begin
        p, helper, stage = setup()
        plan, absent = plan_extraction(h, p, selection(p, [period(p, ["B00000C", "aux"])]), stage; helper)
        @test [j.source for j in plan] == files
        @test [j.groups for j in plan] == [["B00000C", "aux"], ["B00000C", "aux"], ["B00000C"]]
        @test [j.relative for j in plan] == [relative(p, f) for f in files]
        @test [j.destination for j in plan] == [joinpath(stage, "tprod", relative(p, f)) for f in files]
        @test absent == [(relative(p, r001), "aux")]
    end

    @testset "a run that holds none of the detectors gets no job" begin
        p, helper, stage = setup()
        plan, absent = plan_extraction(h, p, selection(p, [period(p, ["aux"])]), stage; helper)
        @test [j.source for j in plan] == files[1:2]
        @test absent == [(relative(p, r001), "aux")]

        plan, absent = plan_extraction(h, p, selection(p, [period(p, ["Z99999Z"])]), stage; helper)
        @test isempty(plan)
        @test absent == [(relative(p, r000), "Z99999Z"), (relative(p, r001), "Z99999Z")]
    end

    @testset "run and period entries merge per run" begin
        p, helper, stage = setup()
        sel = selection(p, [period(p, ["B00000C", "aux"]),
                            ExtractEntry(relative(p, r001), ["V01234A"]),
                            ExtractEntry(relative(p, r000), ["B00000C"])])
        plan, absent = plan_extraction(h, p, sel, stage; helper)
        @test [j.source for j in plan] == files                     # each file once
        @test [j.groups for j in plan] == [["B00000C", "aux"], ["B00000C", "aux"], ["B00000C", "V01234A"]]
        @test absent == [(relative(p, r001), "aux")]

        # Two period entries for the same directory do not extract anything twice.
        twice = selection(p, [period(p, ["B00000C"]), period(p, ["B00000C", "V01234A"])])
        plan2, absent2 = plan_extraction(h, p, twice, stage; helper)
        @test [j.groups for j in plan2] == fill(["B00000C", "V01234A"], 3)
        @test isempty(absent2)
    end

    @testset "files copied whole are left out of a period extraction" begin
        p, helper, stage = setup()
        sel = selection(p, [period(p, ["B00000C"])]; copy = [relative(p, files[2]), relative(p, r001)])
        plan, _ = plan_extraction(h, p, sel, stage; helper)
        @test [j.source for j in plan] == files[1:1]
    end

    @testset "an entry without filekey files is an error" begin
        p, helper, stage = setup()
        empty_period = ExtractEntry(relative(p, joinpath(tier, "jlpks", "cal", "p19")), ["B00000C"])
        @test_throws "holds no filekey files and no run directory with filekey files" plan_extraction(
            h, p, selection(p, [empty_period]), stage; helper)
    end

    @testset "run directories without tier files and without a detector axis are reported" begin
        root = mktempdir()
        ptier = joinpath(root, "tprod", "generated", "tier")
        mkpath(ptier)
        write(joinpath(root, "tprod", "config.json"), raw"""
        {"setups": {"l200": {"paths": {"tier": "$_/generated/tier/"}}}}
        """)
        p = Production(h, "tprod", root, mktempdir())
        stage = joinpath(mktempdir(), "stage")
        helper = HelperConfig(; staging = stage)
        run_file(period, run, ts) = joinpath(ptier, "jlpks", "cal", period, run,
                                             "l200-$period-$run-cal-$ts-tier_jlpks.lh5")
        p21 = joinpath(ptier, "jlpks", "cal", "p21")
        p21files = [run_file("p21", "r000", "20251201T000000Z"), run_file("p21", "r000", "20251201T000500Z")]
        for f in p21files
            write_lh5_tier_det(f; groups = ["B00000C"], tier = "jlpks")
        end
        mkpath(joinpath(p21, "r001"))
        write(joinpath(p21, "r001", "README.txt"), "no tier files\n")
        entry = ExtractEntry(relative(p, p21), ["B00000C"])
        plan, absent = plan_extraction(h, p, selection(p, [entry]), stage; helper)
        @test [j.source for j in plan] == p21files
        @test [j.groups for j in plan] == [["B00000C"], ["B00000C"]]
        @test absent == [(relative(p, joinpath(p21, "r001")), "B00000C")]

        # One run has a detector axis, the other one tier group without detectors.
        p22 = joinpath(ptier, "jlpks", "cal", "p22")
        axis = run_file("p22", "r000", "20251201T000000Z")
        write_lh5_tier_det(axis; groups = ["B00000C", "V01234A"], tier = "jlpks")
        write_lh5(run_file("p22", "r001", "20251201T001000Z"); groups = ["jlpks"], inner = "tables")
        entry = ExtractEntry(relative(p, p22), ["B00000C", "V01234A"])
        plan, absent = plan_extraction(h, p, selection(p, [entry]), stage; helper)
        @test [j.source for j in plan] == [axis]
        @test [j.groups for j in plan] == [["B00000C", "V01234A"]]
        @test absent == [(relative(p, joinpath(p22, "r001")), "B00000C"),
                         (relative(p, joinpath(p22, "r001")), "V01234A")]

        pnode = Node("p22", p22, :dir)
        expand!(h, p, pnode; detectors = true)
        rows = period_detector_nodes(h, helper, pnode)
        @test [r.label for r in rows] == ["B00000C", "V01234A"]
        @test all(r -> r.holders == [joinpath(p22, "r000") => 1], rows)
    end

    @testset "a later file that lacks a detector fails loudly" begin
        p, helper, stage = setup()
        p20 = joinpath(tier, "jlpks", "cal", "p20")
        r002_files = [joinpath(p20, "r002", "l200-p20-r002-cal-20251201T000000Z-tier_jlpks.lh5"),
                      joinpath(p20, "r002", "l200-p20-r002-cal-20251201T000500Z-tier_jlpks.lh5")]
        sel = selection(p, [ExtractEntry(relative(p, p20), ["V01234A"])])
        plan, absent = plan_extraction(h, p, sel, stage; helper)
        @test isempty(absent)                                       # the first file of r002 holds it
        @test [j.source for j in plan] == r002_files
        @test_throws "group V01234A is not in $(r002_files[2])" plan_bytes(h, helper, plan)
        @test_throws "group V01234A is not in $(r002_files[2])" apply!(h, p, sel; helper)
        @test !isfile(to_local(p, r002_files[1]))                   # nothing was written
    end

    @testset "a copied run that does not hold the detector is simply not extracted" begin
        p, helper, stage = setup()
        sel = selection(p, [period(p, ["aux"])]; copy = [relative(p, r001)])
        plan, absent = plan_extraction(h, p, sel, stage; helper)
        @test [j.source for j in plan] == files[1:2]
        @test absent == [(relative(p, r001), "aux")]
    end

    @testset "a period without a detector axis is an error" begin
        p, helper, stage = setup()
        evt = ExtractEntry(relative(p, joinpath(tier, "jlevt", "phy", "p18")), ["B00000C"])
        @test_throws "extract entry $(evt.dir): the tier has no per-detector groups" plan_extraction(
            h, p, selection(p, [evt]), stage; helper)
    end

    @testset "apply! extracts a period and rebuilds with the union" begin
        p, helper, stage = setup()
        sel = selection(p, [period(p, ["B00000C", "aux"])])
        seen = ExtractProgress[]
        result = apply!(h, p, sel; helper, extract_progress = e -> push!(seen, e))
        @test (result.extracted_files, result.extracted_groups) == (3, 5)
        @test result.not_in_run == [(relative(p, r001), "aux")]
        @test [(e.done, e.total) for e in seen] == [(1, 3), (2, 3), (3, 3)]
        @test groups_of(to_local(p, files[1])) == ["B00000C", "aux"]
        @test groups_of(to_local(p, files[3])) == ["B00000C"]
        h5open(to_local(p, files[1]), "r") do out
            @test read_attribute(out["jlpks"], "origin") == "fixture"
            @test read(out["jlpks"]["aux"]["waveform"]) == collect(Int32, 1:300)
            @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"]
        end
        text = summary_text(result)
        @test occursin("extracted 3 files, 5 groups", text)
        @test occursin("not in run, left out: aux in $(relative(p, r001))", text)
        @test !isdir(joinpath(stage, "tprod"))

        apply!(h, p, selection(p, [period(p, ["V01234A"])]); helper)
        @test groups_of(to_local(p, files[1])) == ["B00000C", "V01234A", "aux"]
        @test groups_of(to_local(p, files[3])) == ["B00000C", "V01234A"]
        quiet = apply!(h, p, selection(p, [period(p, ["V01234A"])]); helper)
        @test isempty(quiet.not_in_run)
        @test !occursin("not in run", summary_text(quiet))
    end
end
