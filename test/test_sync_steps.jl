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

        # A shorter reading of the same step blanks what the longer one left behind.
        printer = StepPrinter(io)
        printer(StepProgress("a", 1, 1, 0, nothing, nothing, "a long detail text"))
        long = length(format_step(StepProgress("a", 1, 1, 0, nothing, nothing, "a long detail text")))
        take!(io)
        printer(StepProgress("a", 1, 1, 0, nothing, nothing, ""))
        @test length(rstrip(String(take!(io)), ' ')) < long
        printer(StepProgress("a", 1, 1, 0, nothing, nothing, "a long detail text"))
        take!(io)
        printer(StepProgress("a", 1, 1, 0, nothing, nothing, ""))
        @test length(String(take!(io))) - 1 >= long
    end

    @testset "with_failed_step names the step an error came from" begin
        io, err = IOBuffer(), IOBuffer()
        printer = StepPrinter(io)
        printer(StepProgress("copying", 2, 3, 1, 4, nothing, ""))
        take!(io)
        @test_throws "boom" with_failed_step(() -> error("boom"), printer, err)
        @test String(take!(io)) == "\n"
        @test String(take!(err)) == "failed in step \"copying\"\n"
        @test with_failed_step(() -> 7, printer, err) == 7
        @test isempty(take!(err))

        # No step reported yet: nothing is printed.
        fresh = StepPrinter(io)
        @test_throws "early" with_failed_step(() -> error("early"), fresh, err)
        @test isempty(take!(io)) && isempty(take!(err))
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

    @testset "apply! reports the steps of a detector file estimate" begin
        p = Production(h, "dprod", PERDET_ROOT, mktempdir())
        p16 = joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
        sel = Selection("local", "dprod", PERDET_ROOT, p.local_root, nothing, ["dprod/config.json"], String[], now(), ExtractEntry[],
                        [DetectorEntry(relative(p, p16), ["B00000C", "V01234A"], :copy)])
        names = apply_steps(sel; dry_run = true)
        @test names == ["listing detector files", "checking files to copy"]
        seen = StepProgress[]
        apply!(h, p, sel; dry_run = true, report = collect_into(seen))
        @test unique(s.step for s in seen) == names
        @test all(s -> s.count == length(names), seen)
        @test [s.index for s in seen] == sort([s.index for s in seen])
        listed = filter(s -> s.step == "listing detector files", seen)
        @test last(listed).done == last(listed).total == 2
    end

    @testset "detector_steps follow the real listing" begin
        # A period of per-detector files counts its run directories.
        p = Production(h, "dprod", PERDET_ROOT, mktempdir())
        p16 = joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
        period = expand!(h, p, find_node!(h, p, production_tree(h, p), relative(p, p16)))
        row = ensure_detectors!(period; whole_files = true)
        seen = StepProgress[]
        steps = detector_steps(collect_into(seen), row)
        period_file_nodes(h, period; steps)
        @test all(s -> s.step == "listing runs" && s.count == 1, seen)
        @test (last(seen).done, last(seen).total) == (2, 2)

        # A run reads its first file.
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        helper = HelperConfig(; staging = joinpath(mktempdir(), "stage"))
        dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
        run = expand!(h, p, find_node!(h, p, production_tree(h, p), relative(p, dsp)))
        row = ensure_detectors!(run)
        seen = StepProgress[]
        detector_nodes(h, helper, run; steps = detector_steps(collect_into(seen), row))
        @test [(s.step, s.index, s.count) for s in seen] == [("reading first file", 1, 1)]
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

        # A selection saved for another host is refused before anything is read from the host.
        @test_throws "saved for host local, but the current host is viper" run_headless(Options("viper", FIXTURE_ROOT, local_root, nothing,
                                                                                                "test", "", out, true, false), h)

        # A failure inside a late step names that step on stderr and ends the printed line.
        bad = joinpath(mktempdir(), "bad.yaml")
        save_selection(bad,
                       Selection("local", "test", FIXTURE_ROOT, p.local_root, nothing, ["test/config.json", "test/absent-dir"], String[],
                                 now(),
                                 ExtractEntry[]))
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
        @test occursin("failed in step \"checking files to copy\"", read(stderr_path, String))
        @test endswith(read(stdout_path, String), "\n")
    end
end
