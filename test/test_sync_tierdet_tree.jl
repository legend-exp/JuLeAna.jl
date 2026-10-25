# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "tier/detector layout: inventory" begin
    h = LocalHost()
    helper = HelperConfig(; staging = mktempdir())
    p = Production(h, "tprod", TIER_DET_ROOT, mktempdir())
    tier = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier")
    p18 = joinpath(tier, "jlpks", "cal", "p18")
    p19 = joinpath(tier, "jlpks", "cal", "p19")
    first_file = joinpath(p18, "r000", "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5")
    old_file = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000",
                        "l200-p18-r000-cal-20251107T191821Z-tier_jldsp.lh5")

    # A period directory listed with its run directories, as the interface holds it.
    function listed_period(path = p18)
        period = Node(basename(path), path, :dir)
        expand!(h, p, period; detectors = true)
        for run in run_dirs(period)
            expand!(h, p, run; detectors = true)
        end
        period
    end

    @testset "inspect_files reports the layout" begin
        found = inspect_files(h, helper, [first_file, old_file])
        @test found[1] == (["B00000C", "V01234A", "aux"], [400, 800, 1200], "jlpks")
        @test found[2] == (["B00000C", "V01234A", "aux"], [400, 800, 1200], "")
    end

    @testset "a run directory lists the detectors of the tier/detector layout" begin
        period = listed_period()
        run = run_dirs(period)[1]
        detectors = expand_detectors!(h, helper, run.children[1])
        @test [c.label for c in detectors.children] == ["B00000C", "V01234A", "aux"]
        @test [c.size for c in detectors.children] == [400, 800, 1200]
        @test detectors.children[1].remote_path == joinpath(p18, "r000", "detectors", "B00000C")
        @test all(c -> isempty(c.holders), detectors.children)
    end

    @testset "a period directory gets a detectors row when a run holds filekey files" begin
        period = listed_period()
        @test [c.kind for c in period.children] == [:detectors, :dir, :dir]
        row = period.children[1]
        @test (row.label, row.remote_path, row.parent) == ("detectors", joinpath(p18, "detectors"), period)
        @test row.children === nothing
        @test all(r -> any(c -> c.kind == :detectors, r.children), run_dirs(period))
        @test ensure_detectors!(period) === row

        cal = Node("cal", joinpath(tier, "jlpks", "cal"), :dir)
        expand!(h, p, cal; detectors = true)
        @test [c.kind for c in cal.children] == [:dir, :dir, :dir]

        empty_period = listed_period(p19)
        @test [c.kind for c in empty_period.children] == [:dir]
        empty_run = only(run_dirs(empty_period))
        @test !any(c -> c.kind == :detectors, empty_run.children)
        @test_throws "holds no filekey files and no run directories" ensure_detectors!(empty_run)
        @test_throws "has not been listed yet" ensure_detectors!(Node("p", p18, :dir))
    end

    @testset "filekey_files and run_dirs" begin
        @test filekey_files(h, joinpath(p18, "r000")) ==
              [first_file, replace(first_file, "20251107T191821Z" => "20251107T192416Z")]
        @test filekey_files(h, joinpath(p19, "r000")) == String[]
        @test [r.label for r in run_dirs(listed_period())] == ["r000", "r001"]
        @test run_dirs(Node("x", p18, :dir)) == Node[]
    end

    @testset "the period row is the union with summed sizes" begin
        period = listed_period()
        detectors = expand_detectors!(h, helper, period.children[1])
        @test [c.label for c in detectors.children] == ["B00000C", "V01234A", "aux"]
        # first-file bytes times the run's file count: r000 has two files, r001 one
        @test [c.size for c in detectors.children] == [400 * 2 + 400, 800 * 2 + 800, 1200 * 2]
        @test detectors.size == 6000
        @test detectors.children[3].remote_path == joinpath(p18, "detectors", "aux")
        @test detectors.children[1].holders == [joinpath(p18, "r000") => 2, joinpath(p18, "r001") => 1]
        @test detectors.children[3].holders == [joinpath(p18, "r000") => 2]
        @test all(c -> c.kind == :detector && c.parent === detectors, detectors.children)
        @test has_detectors(detectors)

        direct = period_detector_nodes(h, helper, listed_period())
        @test [(c.label, c.size) for c in direct] == [(c.label, c.size) for c in detectors.children]
        @test_throws "has no run directory with filekey files" period_detector_nodes(
            h, helper, listed_period(p19))
    end

    @testset "a period without a detector axis has an empty row" begin
        evt = listed_period(joinpath(tier, "jlevt", "phy", "p18"))
        @test evt.children[1].kind == :detectors
        row = expand_detectors!(h, helper, evt.children[1])
        @test row.children == Node[]
        @test !has_detectors(row)
    end

    @testset "run-level rows inherit a period-level mark" begin
        period = listed_period()
        detectors = expand_detectors!(h, helper, period.children[1])
        runs = run_dirs(period)
        r000 = expand_detectors!(h, helper, runs[1].children[1]).children
        r001 = expand_detectors!(h, helper, runs[2].children[1]).children
        set_mode!(detectors.children[1], :extract)                  # B00000C for the period
        @test covering_extract(r000[1]) === detectors.children[1]
        @test covering_extract(r001[1]) === detectors.children[1]
        @test r000[1].mode == :none && effective_mode(r000[1]) == :extract
        @test checkbox(r000[1]) == "[e]"
        @test checkbox(r000[2]) == "[ ]"
        @test covering_extract(r000[3]) === nothing
        @test covering_extract(detectors.children[1]) === nothing
        @test covering_extract(runs[1]) === nothing
        set_mode!(detectors.children[1], :none)
        @test checkbox(r000[1]) == "[ ]"
    end
end

@testset "tier/detector layout: selection" begin
    h = LocalHost()
    helper = HelperConfig(; staging = mktempdir())
    local_root = mktempdir()
    p = Production(h, "tprod", TIER_DET_ROOT, local_root)
    tier = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier")
    p18 = joinpath(tier, "jlpks", "cal", "p18")
    r000_path = joinpath(p18, "r000")

    # The production tree with the period `p18` listed and its period-level rows inspected.
    function period_tree()
        root = production_tree(h, p)
        period = find_node!(h, p, root, relative(p, p18))
        rows = expand_detectors!(h, helper, ensure_detectors!(period))
        root, period, rows
    end

    @testset "ExtractEntry names a run or a period directory" begin
        e = ExtractEntry("a/p18", ["z", "m", "m"])
        @test (e.dir, e.groups) == ("a/p18", ["m", "z"])
        @test hash(e) == hash(ExtractEntry("a/p18", ["m", "z"]))
        @test_throws "dir must be relative, got /abs" ExtractEntry("/abs", ["a"])
        @test_throws "dir must not contain .., got a/../b" ExtractEntry("a/../b", ["a"])
        @test_throws "no groups for dir a/p18" ExtractEntry("a/p18", String[])
    end

    @testset "period and run entries are recorded, saved and restored" begin
        root, period, rows = period_tree()
        r000 = find_node!(h, p, root, relative(p, r000_path))
        run_rows = expand_detectors!(h, helper, ensure_detectors!(r000))
        set_mode!(rows.children[3], :extract)             # aux for the period
        set_mode!(rows.children[1], :extract)             # B00000C for the period
        set_mode!(run_rows.children[2], :extract)         # V01234A for r000 only
        sel = Selection(p, "local", root)
        @test sel.extract == [ExtractEntry(relative(p, p18), ["B00000C", "aux"]),
                              ExtractEntry(relative(p, r000_path), ["V01234A"])]

        path = save_selection(joinpath(mktempdir(), "tprod.yaml"), sel)
        back = load_selection(path, p)
        @test back.extract == sel.extract
        @test all(e -> haskey(e, "dir") && !haskey(e, "run_dir"), YAML.load_file(path)["extract"])

        fresh = production_tree(h, p)
        apply_selection!(h, p, fresh, back; helper)
        fperiod = find_node!(h, p, fresh, relative(p, p18))
        @test [c.mode for c in fperiod.children[1].children] == [:extract, :none, :extract]
        frun = find_node!(h, p, fresh, relative(p, r000_path))
        @test [c.mode for c in frun.children[1].children] == [:none, :extract, :none]
        @test Selection(p, "local", fresh).extract == sel.extract
    end

    @testset "a selection file with the former run_dir key still loads" begin
        old = joinpath(mktempdir(), "old.json")
        writeprops(old, PropDict(
            :host => "local", :production => "tprod", :remote_root => TIER_DET_ROOT,
            :local_root => local_root, :mount_root => "", :copy => String[], :link => String[],
            :extract => [PropDict(:run_dir => "tprod/x/r000", :groups => ["B00000C"])],
            :created => string(now())))
        @test load_selection(old, p).extract == [ExtractEntry("tprod/x/r000", ["B00000C"])]
    end

    @testset "apply_selection! names the entry that does not match" begin
        bad_period = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing, String[], String[], now(),
                               [ExtractEntry(relative(p, p18), ["Z99999Z"])])
        @test_throws "detector group Z99999Z of $(relative(p, p18)) is not in any run of the period" apply_selection!(
            h, p, production_tree(h, p), bad_period; helper)
        bad_run = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing, String[], String[], now(),
                            [ExtractEntry(relative(p, joinpath(p18, "r001")), ["aux"])])
        @test_throws "detector group aux of $(relative(p, joinpath(p18, "r001"))) is not in the first file of the run" apply_selection!(
            h, p, production_tree(h, p), bad_run; helper)
    end

    @testset "extract marks block copy and link marks" begin
        root, period, rows = period_tree()
        r000, r001 = run_dirs(period)                      # not listed: only the holders know them
        set_mode!(rows.children[1], :extract)              # B00000C, held by r000 and r001
        for mode in (:copy, :link)
            @test_throws "cannot mark p18 :$mode: detector B00000C of p18 is marked for extraction" set_mode!(period, mode)
            @test_throws "cannot mark r000 :$mode: detector B00000C of p18 is marked for extraction" set_mode!(r000, mode)
            @test_throws "cannot mark r001 :$mode: detector B00000C of p18 is marked for extraction" set_mode!(r001, mode)
            @test_throws "is marked for extraction" set_mode!(period.parent, mode)
        end
        @test period.mode == :none && r000.mode == :none && period.parent.mode == :none
        # V01234A is not marked, so a run that only holds it is unaffected by the B00000C mark.
        set_mode!(rows.children[1], :none)
        set_mode!(rows.children[3], :extract)              # aux, held by r000 only
        set_mode!(r001, :copy)
        @test r001.mode == :copy
        @test_throws "cannot mark r000 :copy" set_mode!(r000, :copy)
        set_mode!(r001, :none)

        # A run-level mark blocks the run, not its siblings; files of the run stay copyable.
        set_mode!(rows.children[3], :none)
        expand!(h, p, r000)
        run_rows = expand_detectors!(h, helper, ensure_detectors!(r000))
        set_mode!(run_rows.children[1], :extract)
        @test_throws "cannot mark r000 :copy: detector B00000C of r000" set_mode!(r000, :copy)
        set_mode!(filekey_groups(r000)[1], :copy)
        @test filekey_groups(r000)[1].mode == :copy
        set_mode!(r001, :copy)
        @test r001.mode == :copy
    end

    @testset "a run that does not hold the detector may be copied" begin
        root, period, rows = period_tree()
        r000, r001 = run_dirs(period)
        set_mode!(r001, :copy)
        set_mode!(rows.children[3], :extract)                  # aux, held by r000 only
        @test rows.children[3].mode == :extract
        @test_throws "r001 is already transferred whole (:copy on r001)" set_mode!(rows.children[1], :extract)
        sel = Selection(p, "local", root)
        @test relative(p, r001.remote_path) in sel.copy
        @test sel.extract == [ExtractEntry(relative(p, p18), ["aux"])]
        path = save_selection(joinpath(mktempdir(), "held.yaml"), sel)
        back = load_selection(path, p)
        fresh = production_tree(h, p)
        apply_selection!(h, p, fresh, back; helper)             # no error
        frows = find_node!(h, p, fresh, relative(p, p18)).children[1].children
        @test [c.mode for c in frows] == [:none, :none, :extract]
    end

    @testset "copy and link marks block extract marks" begin
        root, period, rows = period_tree()
        r000, r001 = run_dirs(period)
        expand!(h, p, r000)
        run_rows = expand_detectors!(h, helper, ensure_detectors!(r000))
        for mode in (:copy, :link)
            set_mode!(r000, mode)
            @test_throws "cannot extract B00000C from p18: r000 is already transferred whole (:$mode on r000)" set_mode!(rows.children[1], :extract)
            @test_throws "cannot extract B00000C from r000: r000 is already transferred whole (:$mode on r000)" set_mode!(run_rows.children[1], :extract)
            @test rows.children[1].mode == :none && run_rows.children[1].mode == :none
            set_mode!(r000, :none)
            set_mode!(period, mode)
            @test_throws "p18 is already transferred whole (:$mode on p18)" set_mode!(rows.children[1], :extract)
            @test_throws "r000 is already transferred whole (:$mode on p18)" set_mode!(run_rows.children[1], :extract)
            set_mode!(period, :none)
        end
        set_mode!(period.parent, :copy)
        @test_throws "p18 is already transferred whole (:copy on cal)" set_mode!(rows.children[1], :extract)
        set_mode!(period.parent, :none)
        set_mode!(rows.children[1], :extract)
        @test rows.children[1].mode == :extract
    end

    @testset "inherited and covered rows cannot be excluded" begin
        root, period, rows = period_tree()
        r000 = run_dirs(period)[1]
        expand!(h, p, r000)
        run_rows = expand_detectors!(h, helper, ensure_detectors!(r000))
        set_mode!(rows.children[1], :extract)
        @test_throws "it is extracted for the whole period; unmark the period row $(rows.children[1].remote_path) instead" exclude!(run_rows.children[1])
        set_mode!(rows.children[1], :none)
        set_mode!(r000, :copy)
        @test_throws "unmark the run instead" exclude!(run_rows.children[1])
    end

    @testset "a selection that contradicts itself fails when applied" begin
        bad = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing,
                        [relative(p, r000_path)], String[], now(),
                        [ExtractEntry(relative(p, p18), ["B00000C"])])
        @test_throws "r000 is already transferred whole (:copy on r000)" apply_selection!(
            h, p, production_tree(h, p), bad; helper)
        linked = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing,
                           String[], [relative(p, p18)], now(),
                           [ExtractEntry(relative(p, r000_path), ["B00000C"])])
        @test_throws "already transferred whole (:link on p18)" apply_selection!(
            h, p, production_tree(h, p), linked; helper)
    end
end
