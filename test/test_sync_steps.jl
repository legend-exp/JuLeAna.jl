# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "steps.jl" begin
    h = LocalHost()
    collect_into(v) = p -> push!(v, p)

    @testset "Steps numbers the steps and rejects unknown names" begin
        seen = StepProgress[]
        steps = Steps(["a", "b"], collect_into(seen))
        steps("b"; done = 2, total = 4, bytes = 2048, detail = "fast")
        @test seen == [StepProgress("b", 2, 2, 2, 4, 2048, "fast")]
        @test_throws "unknown step c" steps("c")
        NO_STEPS("anything")   # no report, no lookup
        @test length(seen) == 1
    end

    @testset "format_step" begin
        @test format_step(StepProgress("copying", 2, 5, 45, 100, 1048576, "3.2MB/s  ETA 0:00:10")) ==
              "[2/5] copying 45/100  1.0 M  3.2MB/s  ETA 0:00:10"
        @test format_step(StepProgress("checking files to copy", 3, 3, 0, nothing, nothing, "")) ==
              "[3/3] checking files to copy"
    end

    @testset "StepPrinter updates a line and breaks it when the step changes" begin
        io = IOBuffer()
        printer = StepPrinter(io)
        printer(StepProgress("a", 1, 2, 1, 3, nothing, ""))
        printer(StepProgress("a", 1, 2, 2, 3, nothing, ""))
        printer(StepProgress("b", 2, 2, 0, nothing, nothing, ""))
        text = String(take!(io))
        @test count('\r', text) == 3
        @test count('\n', text) == 1
        @test occursin("[1/2] a 2/3", text)
        @test failed_step(printer) == "b"
        @test failed_step(StepPrinter(io)) == ""
    end

    @testset "apply! reports the steps of an estimate in execution order" begin
        dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        helper = HelperConfig(; staging = joinpath(mktempdir(), "stage"))
        sel = Selection("local", "xprod", EXTRACT_ROOT, p.local_root, nothing, ["xprod/config.json", "xprod/legend-metadata"], String[],
                        now(),
                        [ExtractEntry(relative(p, dsp), ["B00000C"])])
        @test apply_steps(sel; dry_run = true) == ["planning extraction", "sizing extract groups", "checking files to copy"]
        seen = StepProgress[]
        apply!(h, p, sel; dry_run = true, helper, report = collect_into(seen))
        names = unique(s.step for s in seen)
        @test names == ["planning extraction", "sizing extract groups", "checking files to copy"]
        @test all(s -> s.count == 3, seen)
        @test [s.index for s in seen] == sort([s.index for s in seen])
        sized = filter(s -> s.step == "sizing extract groups", seen)
        @test last(sized).done == last(sized).total == 2

        seen = StepProgress[]
        result = estimate_selection(h, p, sel; helper, report = collect_into(seen))
        @test unique(s.step for s in seen)[end] == "staging free space"
        @test all(s -> s.count == 4, seen)
        @test result.staging == helper.staging && result.free > 0
    end

    @testset "apply! reports the steps of a transfer" begin
        dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        helper = HelperConfig(; staging = joinpath(mktempdir(), "stage"))
        sel = Selection("local", "xprod", EXTRACT_ROOT, p.local_root, nothing, ["xprod/config.json", "xprod/legend-metadata"], String[],
                        now(),
                        [ExtractEntry(relative(p, dsp), ["B00000C"])])
        seen = StepProgress[]
        apply!(h, p, sel; helper, report = collect_into(seen))
        @test unique(s.step for s in seen) == ["planning extraction", "sizing extract groups", "extracting on the host", "copying",
                                               "pulling extracted files", "creating links", "cleaning up staging"]
        extracting = filter(s -> s.step == "extracting on the host", seen)
        @test (last(extracting).done, last(extracting).total) == (2, 2) && last(extracting).bytes > 0
        copying = filter(s -> s.step == "copying", seen)
        @test all(s -> s.total == 100, copying)

        # A selection without extract entries lists no extraction steps.
        plain = Selection("local", "xprod", EXTRACT_ROOT, p.local_root, nothing, ["xprod/config.json"], String[], now(), ExtractEntry[])
        @test apply_steps(plain; dry_run = false) == ["copying", "creating links"]
    end

    @testset "the period listing counts runs" begin
        p = Production(h, "tprod", TIER_DET_ROOT, mktempdir())
        helper = HelperConfig(; staging = mktempdir())
        root = production_tree(h, p)
        pks = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier", "jlpks", "cal", "p18")
        period = find_node!(h, p, root, relative(p, pks))
        row = ensure_detectors!(period)
        seen = StepProgress[]
        expand_detectors!(h, helper, row; steps = detector_steps(collect_into(seen), row))
        @test all(s -> s.step == "reading first files" && s.count == 1, seen)
        @test (last(seen).done, last(seen).total) == (2, 2)
    end

    @testset "apply_selection! counts its entries" begin
        p = Production(h, "test", FIXTURE_ROOT, mktempdir())
        root = production_tree(h, p)
        sel = Selection("local", "test", FIXTURE_ROOT, p.local_root, nothing, ["test/config.json", "test/legend-metadata"], String[], now(),
                        ExtractEntry[])
        seen = StepProgress[]
        apply_selection!(h, p, root, sel; steps = Steps(["listing directories"], collect_into(seen)))
        @test [(s.done, s.total) for s in seen] == [(0, 2), (1, 2), (2, 2)]
    end

    @testset "the headless run prints the steps and names a failing step" begin
        local_root = mktempdir()
        out = joinpath(mktempdir(), "sel.yaml")
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        root = production_tree(h, p)
        save_selection(out, Selection(p, "local", root))
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test", out, out, true, false)
        path = tempname()
        code = open(path, "w") do io
            redirect_stdout(() -> main(options, h), io)
        end
        text = read(path, String)
        @test code == 0
        @test occursin("[1/1] checking files to copy", text)
        @test_throws ArgumentError run_headless(Options("local", joinpath(FIXTURE_ROOT, "absent"), local_root, nothing, "test", "", out,
                                                        true, false), h)
    end
end
