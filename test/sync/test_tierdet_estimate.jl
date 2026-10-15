@testset "tier/detector layout: estimate" begin
    h = LocalHost()
    helper = HelperConfig(; staging = mktempdir())
    local_root = mktempdir()
    p = Production(h, "tprod", TIER_DET_ROOT, local_root)
    tier = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier")
    p18 = joinpath(tier, "jlpks", "cal", "p18")
    r000 = joinpath(p18, "r000")
    r001 = joinpath(p18, "r001")

    # The tree with p18 listed, its period rows inspected, and both runs listed with their rows.
    function tree()
        root = production_tree(h, p)
        period = find_node!(h, p, root, relative(p, p18))
        rows = expand_detectors!(h, helper, ensure_detectors!(period))
        runs = [find_node!(h, p, root, relative(p, r)) for r in (r000, r001)]
        run_rows = [expand_detectors!(h, helper, ensure_detectors!(run)) for run in runs]
        root, rows, runs, run_rows
    end

    @testset "Estimate carries the pairs and formats them" begin
        @test Estimate(1, 2, 3, true).not_in_run == Tuple{String,String}[]
        @test Estimate(1, 2, 3, true, 5, 1, false).not_in_run == Tuple{String,String}[]
        pairs = [("a/r001", "aux"), ("a/r002", "aux")]
        @test format_not_in_run(pairs) == "aux in a/r001, aux in a/r002"
        est = Estimate(0, 0, 0, true, 2048, 2, true, pairs)
        @test format_estimate(est) == "selected: 0 B copy (0 files), 0 links, 2.0 K extract (2 files), 2 not in run"
        @test format_estimate(Estimate(0, 0, 0, true, 2048, 2, true)) ==
              "selected: 0 B copy (0 files), 0 links, 2.0 K extract (2 files)"
        @test Estimate(1, 2, 3, true, 5, 1, false, pairs) == Estimate(1, 2, 3, true, 5, 1, false, copy(pairs))
        @test Estimate(1, 2, 3, true, 5, 1, false, pairs) != Estimate(1, 2, 3, true, 5, 1, false)
        @test hash(Estimate(1, 2, 3, true)) == hash(Estimate(1, 2, 3, true, 0, 0, true))
    end

    @testset "running_estimate counts a period mark once" begin
        root, rows, runs, run_rows = tree()
        set_mode!(rows.children[1], :extract)                 # B00000C: 400*2 + 400
        est = running_estimate(root)
        @test (est.extract_bytes, est.extract_files, est.extract_exact) == (1200, 3, false)

        set_mode!(rows.children[3], :extract)                 # aux: 1200*2
        @test running_estimate(root).extract_bytes == 1200 + 2400
        @test running_estimate(root).extract_files == 3

        # A run-level mark on a covered detector adds nothing.
        set_mode!(run_rows[1].children[1], :extract)
        est2 = running_estimate(root)
        @test (est2.extract_bytes, est2.extract_files) == (3600, 3)

        # A run-level mark on a detector the period does not mark adds its run's share.
        set_mode!(run_rows[2].children[2], :extract)          # V01234A in r001: 800 * 1
        est3 = running_estimate(root)
        @test (est3.extract_bytes, est3.extract_files) == (3600 + 800, 3)

        # Files copied whole inside a run reduce only the run-level share.
        set_mode!(rows.children[1], :none)
        set_mode!(rows.children[3], :none)
        set_mode!(run_rows[1].children[1], :none)
        set_mode!(run_rows[2].children[2], :none)
        set_mode!(run_rows[1].children[2], :extract)          # V01234A in r000: 800 * 2
        set_mode!(filekey_groups(runs[1])[2], :copy)
        est4 = running_estimate(root)
        @test (est4.extract_bytes, est4.extract_files) == (800 * 1, 1)
        @test est4.files == 1
    end

    @testset "the exact estimate lists the pairs next to the bytes" begin
        root, rows, _, _ = tree()
        set_mode!(rows.children[3], :extract)                 # aux
        set_mode!(rows.children[1], :extract)                 # B00000C
        sel = Selection(p, "local", root)
        est = apply!(h, p, sel; dry_run = true, helper)
        # r000: (400 + 1200) + (800 + 2400); r001: 400 only, aux is not in r001
        @test (est.extract_bytes, est.extract_files, est.extract_exact) == (5200, 3, true)
        @test est.not_in_run == [(relative(p, r001), "aux")]
        @test endswith(format_estimate(est), ", 1 not in run")
        @test !isdir(joinpath(local_root, "tprod", "generated"))
        @test !isdir(staging_production_dir(helper.staging, p))
    end

    @testset "a headless run applies a saved selection with a period entry" begin
        h = LocalHost()
        function headless(local_root; dry_run, yes)
            p = Production(h, "tprod", TIER_DET_ROOT, local_root)
            sel = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing,
                            ["tprod/config.json", "tprod/legend-metadata"], String[], now(),
                            [ExtractEntry(relative(p, p18), ["B00000C", "aux"])])
            selpath = save_selection(joinpath(mktempdir(), "tprod.yaml"), sel)
            options = Options("local", TIER_DET_ROOT, local_root, nothing, "tprod", selpath, selpath,
                              dry_run, yes, 0, HelperConfig(; staging = joinpath(mktempdir(), "stage")))
            path = tempname()
            code = open(path, "w") do io
                redirect_stdout(() -> main(options, h), io)
            end
            code, read(path, String)
        end
        root = mktempdir()
        code, text = headless(root; dry_run = true, yes = false)
        @test code == 0
        @test occursin("extract (3 files)", text) && occursin("1 not in run", text)
        @test occursin("not in run: aux in $(relative(p, r001))", text)
        @test !isdir(joinpath(root, "tprod", "generated"))

        code, text = headless(root; dry_run = false, yes = true)
        @test code == 0
        @test occursin("extracted 3 files, 5 groups", text)
        @test occursin("not in run, left out: aux in $(relative(p, r001))", text)
        local_file = to_local(Production(h, "tprod", TIER_DET_ROOT, root),
                              joinpath(r001, "l200-p18-r001-cal-20251108T101010Z-tier_jlpks.lh5"))
        @test h5open(f -> collect(keys(f["jlpks"])), local_file, "r") == ["B00000C"]
    end
end
