# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "per-detector tier: inventory" begin
    h = LocalHost()
    p = Production(h, "dprod", PERDET_ROOT, mktempdir())
    tier = joinpath(PERDET_ROOT, "dprod", "generated", "tier")
    p16 = joinpath(tier, "jlqcs", "cal", "p16")
    # A helper that cannot run: listing a per-detector period must never start it.
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())

    function listed_period(path = p16)
        period = Node(basename(path), path, :dir)
        expand!(h, p, period; detectors = true)
        period
    end

    @testset "a period of per-detector files gets a detectors row" begin
        period = listed_period()
        @test [c.kind for c in period.children] == [:detectors, :dir, :dir]
        row = period.children[1]
        @test (row.label, row.remote_path, row.parent) == ("detectors", joinpath(p16, "detectors"), period)
        @test row.whole_files
        @test row.children === nothing
        @test ensure_detectors!(period; whole_files = true) === row

        # Run directories, categories and periods without per-detector files get no row.
        run = only(filter(c -> c.label == "r000", period.children))
        expand!(h, p, run; detectors = true)
        @test all(c -> c.kind == :group, run.children)
        cal = Node("cal", joinpath(tier, "jlqcs", "cal"), :dir)
        expand!(h, p, cal; detectors = true)
        @test [c.kind for c in cal.children] == [:dir, :dir]
        empty_period = listed_period(joinpath(tier, "jlqcs", "cal", "p17"))
        @test [c.kind for c in empty_period.children] == [:dir]
    end

    @testset "a period of filekey files keeps the helper-based row" begin
        period = listed_period(joinpath(tier, "jldsp", "cal", "p16"))
        @test period.children[1].kind == :detectors
        @test !period.children[1].whole_files
    end

    @testset "the row lists the union of the detector files without the helper" begin
        period = listed_period()
        row = expand_detectors!(h, broken, period.children[1])
        @test [c.label for c in row.children] == ["B00000C", "V01234A"]
        @test [c.size for c in row.children] == [100 + 300, 200]
        @test row.size == 600
        @test row.children[1].remote_path == joinpath(p16, "detectors", "B00000C")
        @test row.children[1].holders == [joinpath(p16, "r000") => 1, joinpath(p16, "r001") => 1]
        @test row.children[2].holders == [joinpath(p16, "r000") => 1]
        @test all(c -> c.kind == :detector && c.whole_files && c.parent === row, row.children)
        @test has_detectors(row)
        direct = period_file_nodes(h, listed_period())
        @test [(c.label, c.size, c.holders) for c in direct] ==
              [(c.label, c.size, c.holders) for c in row.children]
    end

    @testset "a period without per-detector files has nothing to list" begin
        empty_period = listed_period(joinpath(tier, "jlqcs", "cal", "p17"))
        @test_throws "holds no per-detector files" period_file_nodes(h, empty_period)
    end

    @testset "two files of one detector in a run are an error" begin
        root = make_per_detector_remote()
        q = Production(h, "dprod", root, mktempdir())
        dir = joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16", "r001")
        write(joinpath(dir, "l200-p16-r001-phy-B00000C-tier_jlqcs.lh5"), "y")
        period = Node("p16", dirname(dir), :dir)
        expand!(h, q, period; detectors = true)
        @test_throws "r001 holds two files for detector B00000C: l200-p16-r001-cal-B00000C-tier_jlqcs.lh5 and l200-p16-r001-phy-B00000C-tier_jlqcs.lh5" period_file_nodes(h, period)
    end

    @testset "a directory with both kinds of tier file is an error" begin
        root = make_per_detector_remote()
        q = Production(h, "dprod", root, mktempdir())
        run = joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16", "r000")
        write(joinpath(run, "l200-p16-r000-cal-20251107T191821Z-tier_jlqcs.lh5"), "z")
        msg = "r000 holds filekey files and per-detector files, for example " *
              "l200-p16-r000-cal-20251107T191821Z-tier_jlqcs.lh5 and l200-p16-r000-cal-B00000C-tier_jlqcs.lh5"
        @test_throws msg expand!(h, q, Node("r000", run, :dir))
        @test_throws msg expand!(h, q, Node("p16", dirname(run), :dir); detectors = true)
    end

    @testset "run-level group rows are unchanged" begin
        period = listed_period()
        run = only(filter(c -> c.label == "r000", period.children))
        expand!(h, p, run; detectors = true)
        @test [(c.label, c.size) for c in run.children] == [("B00000C", 100), ("V01234A", 200)]
        @test all(c -> !c.whole_files, run.children)
    end
end

@testset "per-detector tier: selection" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "dprod", PERDET_ROOT, local_root)
    p16 = joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
    p16_rel = relative(p, p16)
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())

    # The production tree with p16 and its runs listed and the period's detector files inspected.
    function period_tree()
        root = production_tree(h, p)
        period = find_node!(h, p, root, p16_rel)
        rows = expand_detectors!(h, broken, ensure_detectors!(period; whole_files = true))
        runs = run_dirs(period)
        foreach(run -> expand!(h, p, run), runs)
        root, period, rows, runs
    end
    entry(detectors, mode; dir = p16_rel) = DetectorEntry(dir, detectors, mode)

    @testset "DetectorEntry validates and compares by value" begin
        e = entry(["V01234A", "B00000C", "V01234A"], :link)
        @test (e.dir, e.detectors, e.mode) == (p16_rel, ["B00000C", "V01234A"], :link)
        @test e == entry(["B00000C", "V01234A"], :link)
        @test hash(e) == hash(entry(["B00000C", "V01234A"], :link))
        @test e != entry(["B00000C", "V01234A"], :copy)
        @test_throws "dir must be relative, got /abs" DetectorEntry("/abs", ["B00000C"], :copy)
        @test_throws "dir must not contain .., got a/../b" DetectorEntry("a/../b", ["B00000C"], :copy)
        @test_throws "no detectors for dir $p16_rel" DetectorEntry(p16_rel, String[], :copy)
        @test_throws "empty detector name" DetectorEntry(p16_rel, [""], :copy)
        @test_throws "mode must be :copy or :link" DetectorEntry(p16_rel, ["B00000C"], :extract)
    end

    @testset "space and l mark a row, x is refused" begin
        root, period, rows, runs = period_tree()
        b, v = rows.children
        set_mode!(b, :copy)
        set_mode!(v, :link)
        @test (b.mode, v.mode) == (:copy, :link)
        @test (checkbox(b), checkbox(v)) == ("[x]", "[~]")
        set_mode!(b, :none)
        @test b.mode == :none
        @test_throws "hold one detector each" set_mode!(b, :extract)
        @test_throws "mark one of the detector rows below it :copy" set_mode!(rows, :copy)
        @test b.mode == :none
    end

    @testset "run rows show the period mark and cannot be toggled" begin
        root, period, rows, runs = period_tree()
        b = rows.children[1]
        set_mode!(b, :copy)
        r000_b = runs[1].children[1]
        r000_v = runs[1].children[2]
        r001_b = runs[2].children[1]
        @test [g.label for g in runs[1].children] == ["B00000C", "V01234A"]
        @test covering_detector(r000_b) === b
        @test covering_detector(r001_b) === b
        @test covering_detector(r000_v) === nothing
        @test covering_detector(only(r001_b.children)) === b       # the file below the group
        @test covering_detector(b) === nothing
        @test r000_b.mode == :none && effective_mode(r000_b) == :copy
        @test effective_mode(only(r000_b.children)) == :copy
        @test (checkbox(r000_b), checkbox(r000_v)) == ("[x]", "[ ]")
        set_mode!(b, :link)
        @test checkbox(r001_b) == "[~]"

        @test_throws "unmark the period's detector" set_mode!(r000_b, :copy)
        @test_throws "unmark the period's detector" set_mode!(r000_b, :link)
        @test_throws "unmark the period's detector" exclude!(r000_b)
        @test r000_b.mode == :none
        # A file of another detector in the same run is not covered.
        set_mode!(r000_v, :copy)
        @test r000_v.mode == :copy
        set_mode!(r000_v, :none)

        set_mode!(b, :none)
        @test covering_detector(r000_b) === nothing
        @test checkbox(r000_b) == "[ ]"
        set_mode!(r000_b, :copy)
        @test r000_b.mode == :copy
    end

    @testset "row marks and whole copies exclude each other" begin
        root, period, rows, runs = period_tree()
        b, v = rows.children
        for mode in (:copy, :link)
            set_mode!(runs[1], mode)
            @test_throws "cannot mark B00000C :$mode in p16: r000 is already transferred whole (:$mode on r000)" set_mode!(b, mode)
            set_mode!(runs[1], :none)
            set_mode!(period, mode)
            @test_throws "p16 is already transferred whole (:$mode on p16)" set_mode!(b, mode)
            set_mode!(period, :none)
            set_mode!(period.parent, mode)
            @test_throws "p16 is already transferred whole (:$mode on cal)" set_mode!(b, mode)
            set_mode!(period.parent, :none)
            @test b.mode == :none
        end
        # r001 does not hold V01234A, so copying it does not matter for that detector.
        set_mode!(runs[2], :copy)
        set_mode!(v, :copy)
        @test v.mode == :copy
        @test_throws "r001 is already transferred whole (:copy on r001)" set_mode!(b, :link)
        set_mode!(runs[2], :none)

        set_mode!(b, :link)
        for node in (period, runs[1], runs[2], period.parent)
            for mode in (:copy, :link)
                @test_throws "cannot mark $(node.label) :$mode: detector B00000C of p16 is marked :link; unmark the detector first" set_mode!(node, mode)
            end
            @test node.mode == :none
        end
        set_mode!(b, :none)
        set_mode!(v, :none)
        set_mode!(runs[2], :copy)                                  # B00000C unmarked: allowed
        @test runs[2].mode == :copy
        set_mode!(runs[2], :none)

        # V01234A is only in r000: r001 may be copied while V01234A is marked.
        set_mode!(v, :link)
        set_mode!(runs[2], :copy)
        @test runs[2].mode == :copy
        @test_throws "cannot mark r000 :copy" set_mode!(runs[1], :copy)
    end

    @testset "a file marked individually blocks the row mark" begin
        root, period, rows, runs = period_tree()
        b = rows.children[1]
        set_mode!(runs[1].children[1], :copy)
        @test_throws "file B00000C of r000 is marked individually" set_mode!(b, :copy)
        @test b.mode == :none
        set_mode!(runs[1].children[1], :none)
        set_mode!(b, :copy)
        @test b.mode == :copy
    end

    @testset "marks are saved by intent and restored" begin
        root, period, rows, runs = period_tree()
        set_mode!(rows.children[1], :copy)
        set_mode!(rows.children[2], :link)
        sel = Selection(p, "local", root)
        @test sel.detector_files == [entry(["B00000C"], :copy), entry(["V01234A"], :link)]
        @test !(p16_rel in sel.copy) && !(p16_rel in sel.link)
        @test !any(c -> endswith(c, "B00000C"), sel.copy)

        path = save_selection(joinpath(mktempdir(), "dprod.yaml"), sel)
        saved = YAML.load_file(path)
        @test saved["detector_files"] == [Dict("dir" => p16_rel, "detectors" => ["B00000C"], "mode" => "copy"),
                                          Dict("dir" => p16_rel, "detectors" => ["V01234A"], "mode" => "link")]
        back = load_selection(path, p)
        @test back.detector_files == sel.detector_files

        fresh = production_tree(h, p)
        apply_selection!(h, p, fresh, back; helper = broken)
        fperiod = find_node!(h, p, fresh, p16_rel)
        @test [c.mode for c in fperiod.children[1].children] == [:copy, :link]
        @test Selection(p, "local", fresh).detector_files == sel.detector_files
    end

    @testset "entries of several periods and merged detectors" begin
        root, period, rows, runs = period_tree()
        set_mode!(rows.children[1], :copy)
        set_mode!(rows.children[2], :copy)
        @test Selection(p, "local", root).detector_files == [entry(["B00000C", "V01234A"], :copy)]
    end

    @testset "a selection file without the key still loads" begin
        old = joinpath(mktempdir(), "old.json")
        writeprops(old, PropDict(
            :host => "local", :production => "dprod", :remote_root => PERDET_ROOT,
            :local_root => local_root, :mount_root => "", :copy => String[], :link => String[],
            :created => string(now())))
        @test load_selection(old, p).detector_files == DetectorEntry[]
        @test Selection("local", "dprod", PERDET_ROOT, local_root, nothing, String[], String[], now(),
                        ExtractEntry[]).detector_files == DetectorEntry[]
        bad = joinpath(mktempdir(), "bad.json")
        writeprops(bad, PropDict(
            :host => "local", :production => "dprod", :remote_root => PERDET_ROOT,
            :local_root => local_root, :mount_root => "", :copy => String[], :link => String[],
            :detector_files => [PropDict(:detectors => ["B00000C"], :mode => "copy")],
            :created => string(now())))
        @test_throws "detector_files entry without a \"dir\" key" load_selection(bad, p)
    end

    @testset "apply_selection! names the entry that does not match" begin
        sel(entries; copy = String[]) = Selection("local", "dprod", PERDET_ROOT, local_root, nothing,
                                                  copy, String[], now(), ExtractEntry[], entries)
        @test_throws "detector Z99999Z of $p16_rel: no run of the period holds a file for it" apply_selection!(
            h, p, production_tree(h, p), sel([entry(["Z99999Z"], :copy)]); helper = broken)
        empty_dir = relative(p, joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jlqcs", "cal", "p17"))
        @test_throws "holds no per-detector files" apply_selection!(
            h, p, production_tree(h, p), sel([entry(["B00000C"], :copy; dir = empty_dir)]); helper = broken)
        @test_throws "p16 is already transferred whole (:copy on p16)" apply_selection!(
            h, p, production_tree(h, p), sel([entry(["B00000C"], :link)]; copy = [p16_rel]); helper = broken)
        both = sel([entry(["B00000C"], :copy), entry(["B00000C"], :link)])
        @test_throws "detector B00000C of $p16_rel is marked both :copy and :link" apply_selection!(
            h, p, production_tree(h, p), both; helper = broken)
    end
end
