@testset "extract: plan and estimate" begin
    h = LocalHost()
    local_root = mktempdir()
    helper = HelperConfig(; staging = mktempdir())
    p = Production(h, "xprod", EXTRACT_ROOT, local_root)
    dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
    files = [joinpath(dsp, "l200-p18-r000-cal-20251107T191821Z-tier_jldsp.lh5"),
             joinpath(dsp, "l200-p18-r000-cal-20251107T192416Z-tier_jldsp.lh5")]

    # A run with B00000C (400 bytes in the first file) and aux (1200) marked.
    function marked_tree()
        root = production_tree(h, p)
        run = find_node!(h, p, root, relative(p, dsp))
        detectors = expand_detectors!(h, helper, ensure_detectors!(run))
        set_mode!(detectors.children[1], :extract)
        set_mode!(detectors.children[3], :extract)
        root, run
    end

    @testset "Estimate keeps its four-argument form and formats the extract part" begin
        @test Estimate(1, 2, 3, true) == Estimate(1, 2, 3, true, 0, 0, true)
        @test format_estimate(Estimate(0, 0, 0, true, 1288490188, 2, false)) ==
              "selected: 0 B copy (0 files), 0 links, ~1.2 G extract (2 files)"
        @test format_estimate(Estimate(0, 0, 0, true, 2048, 2, true)) ==
              "selected: 0 B copy (0 files), 0 links, 2.0 K extract (2 files)"
    end

    @testset "running_estimate is approximate and skips files copied whole" begin
        root, run = marked_tree()
        est = running_estimate(root)
        @test (est.extract_bytes, est.extract_files, est.extract_exact) == ((400 + 1200) * 2, 2, false)
        @test est.complete && est.bytes == 0

        set_mode!(filekey_groups(run)[2], :copy)
        est2 = running_estimate(root)
        @test (est2.extract_bytes, est2.extract_files) == ((400 + 1200) * 1, 1)
        @test est2.files == 1 && est2.bytes == filesize(files[2])

        for row in run.children[1].children       # unmarking every detector ends the extraction
            set_mode!(row, :none)
        end
        est3 = running_estimate(root)
        @test (est3.extract_bytes, est3.extract_files, est3.extract_exact) == (0, 0, true)
    end

    @testset "plan_extraction lays out the staging tree" begin
        root, run = marked_tree()
        sel = Selection(p, "local", root)
        staging = joinpath(tempdir(), "stage")
        @test staging_production_dir(staging, p) == joinpath(staging, "xprod")
        @test staging_production_dir(staging, Production(h, "temp/jl-dev", FIXTURE_ROOT, local_root)) ==
              joinpath(staging, "temp-jl-dev")

        plan, _ = plan_extraction(h, p, sel, staging)
        @test [j.source for j in plan] == files
        @test [j.relative for j in plan] == [relative(p, f) for f in files]
        @test [j.destination for j in plan] == [joinpath(staging, "xprod", relative(p, f)) for f in files]
        @test all(j -> j.groups == ["B00000C", "aux"], plan)

        copied = Selection("local", "xprod", sel.remote_root, sel.local_root, nothing,
                           [relative(p, files[2])], String[], now(), sel.extract)
        @test [j.source for j in first(plan_extraction(h, p, copied, staging))] == files[1:1]
        above = Selection("local", "xprod", sel.remote_root, sel.local_root, nothing,
                          [relative(p, dsp)], String[], now(), sel.extract)
        @test isempty(first(plan_extraction(h, p, above, staging)))
    end

    @testset "plan_bytes inspects every source file" begin
        root, _ = marked_tree()
        plan, _ = plan_extraction(h, p, Selection(p, "local", root), joinpath(tempdir(), "stage"))
        @test plan_bytes(h, helper, plan) == (400 + 1200) + (800 + 2400)
        @test plan_bytes(h, helper, ExtractJob[]) == 0
        bad = [ExtractJob(files[1], "/x", "x", ["Z99999Z"])]
        @test_throws "group Z99999Z not found in $(files[1])" plan_bytes(h, helper, bad)
        @test_throws "inspected 1 files for a plan of 2 jobs" plan_group_bytes(plan, [(["aux"], [1])])
        @test_throws "1 sizes for the 2 groups of $(files[1])" plan_group_bytes(plan, [(["aux"], [1]), (["aux"], [1, 2])])

        # The totals equal those of sizing every group of every file.
        full = inspect_files(h, helper, [j.source for j in plan])
        expected = sum(zip(plan, full)) do (job, (names, bytes, _))
            sum(g -> bytes[findfirst(==(g), names)], job.groups)
        end
        @test plan_bytes(h, helper, plan) == expected

        # The helper job carries each file's groups. A failed run keeps its job file.
        @test_throws "not found" plan_bytes(h, helper, bad)
        job = TOML.parsefile(joinpath(helper.staging, "jobs", "inspect.toml"))
        @test job["job"] == [Dict("file" => files[1], "groups" => ["Z99999Z"])]
        sized = inspect_files(h, helper, [j.source for j in plan]; groups = [j.groups for j in plan])
        @test [bytes for (_, bytes, _) in sized] == [[400, 1200], [800, 2400]]
        @test [names for (names, _, _) in sized] == [first(f) for f in full]
        @test_throws "2 group lists for 1 files" inspect_files(h, helper, files[1:1]; groups = [["aux"], ["aux"]])
    end

    @testset "apply! dry run adds the exact extract numbers" begin
        root, _ = marked_tree()
        sel = Selection(p, "local", root)
        est = apply!(h, p, sel; dry_run = true, helper)
        @test (est.extract_bytes, est.extract_files, est.extract_exact) == (4800, 2, true)
        @test est.files == 2                          # config.json and the metadata README
        @test !isdir(joinpath(local_root, "xprod", "generated"))
        @test !isdir(staging_production_dir(helper.staging, p))   # nothing was extracted

        broken = HelperConfig(; julia_project = mktempdir(), staging = helper.staging)
        @test_throws "does not exist" apply!(h, p, sel; dry_run = true, helper = broken)
        # Without extract entries the helper is never needed.
        plain = Selection(p, "local", production_tree(h, p))
        @test apply!(h, p, plain; dry_run = true, helper = broken).extract_files == 0
    end
end
