# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "per-detector tier: estimate" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "dprod", PERDET_ROOT, local_root; mount_root = "/")
    p16 = joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
    p16_rel = relative(p, p16)
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())

    function tree(; list_runs = true)
        root = production_tree(h, p)
        period = find_node!(h, p, root, p16_rel)
        rows = expand_detectors!(h, broken, ensure_detectors!(period; whole_files = true))
        runs = run_dirs(period)
        list_runs && foreach(run -> expand!(h, p, run), runs)
        root, rows, runs
    end

    @testset "a marked row counts its files once" begin
        for list_runs in (true, false)
            root, rows, runs = tree(; list_runs)
            b, v = rows.children
            @test running_estimate(root) == Estimate(0, 0, 0, true)
            set_mode!(b, :copy)                                  # 100 + 300 in two files
            @test running_estimate(root) == Estimate(400, 2, 0, true)
            set_mode!(v, :link)                                  # one file
            @test running_estimate(root) == Estimate(400, 2, 1, true)
            set_mode!(b, :link)
            set_mode!(v, :copy)
            @test running_estimate(root) == Estimate(200, 1, 2, true)
            set_mode!(b, :none)
            set_mode!(v, :none)
            @test running_estimate(root) == Estimate(0, 0, 0, true)
        end
    end

    @testset "a file marked on its own is added to the rows" begin
        root, rows, runs = tree()
        set_mode!(rows.children[1], :copy)
        set_mode!(runs[1].children[2], :copy)                    # V01234A of r000: 200
        @test running_estimate(root) == Estimate(600, 3, 0, true)
    end

    @testset "a row without a size makes the estimate incomplete" begin
        root, rows, runs = tree()
        rows.children[1].size = nothing
        set_mode!(rows.children[1], :copy)
        @test !running_estimate(root).complete
    end

    @testset "the exact estimate counts the same files" begin
        root, rows, runs = tree()
        set_mode!(rows.children[1], :copy)
        set_mode!(rows.children[2], :link)
        sel = Selection(p, "local", root)
        est = apply!(h, p, sel; dry_run = true, helper = broken)
        mandatory = sum(filesize, joinpath.(PERDET_ROOT, "dprod", ["config.json", "legend-metadata/README.md"]))
        @test est.bytes == mandatory + 400
        @test est.files == 4                                     # config.json, README.md and the two B00000C files
        @test est.links == 1
        @test est.not_in_run == [(joinpath(p16_rel, "r001"), "V01234A")]
    end

    @testset "a headless run reports the pairs" begin
        function headless(local_root; dry_run, yes)
            sel = Selection("local", "dprod", PERDET_ROOT, local_root, nothing,
                            ["dprod/config.json", "dprod/legend-metadata"], String[], now(),
                            ExtractEntry[], [DetectorEntry(p16_rel, ["B00000C", "V01234A"], :copy)])
            selpath = save_selection(joinpath(mktempdir(), "dprod.yaml"), sel)
            options = Options("local", PERDET_ROOT, local_root, nothing, "dprod", selpath, selpath,
                              dry_run, yes, 0, broken)
            path = tempname()
            code = open(path, "w") do io
                redirect_stdout(() -> main(options, h), io)
            end
            code, read(path, String)
        end
        root = mktempdir()
        code, text = headless(root; dry_run = true, yes = false)
        @test code == 0
        @test occursin("1 not in run", text)
        @test occursin("not in run: V01234A in $(joinpath(p16_rel, "r001"))", text)
        @test !isdir(joinpath(root, "dprod", "generated"))

        code, text = headless(root; dry_run = false, yes = true)
        @test code == 0
        @test occursin("not in run, left out: V01234A in $(joinpath(p16_rel, "r001"))", text)
        @test sort(readdir(joinpath(root, p16_rel, "r000"))) ==
              ["l200-p16-r000-cal-B00000C-tier_jlqcs.lh5", "l200-p16-r000-cal-V01234A-tier_jlqcs.lh5"]
    end
end
