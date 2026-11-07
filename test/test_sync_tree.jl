# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Detector rows are attached without starting the helper, so any helper run in these tests is a failure.
@testset "inventory" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "test", FIXTURE_ROOT, local_root)
    tier = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier")
    evtrun = joinpath(tier, "jlevt", "phy", "p18", "r000")
    hitrun = joinpath(tier, "jlhit", "cal", "p18", "r000")

    @testset "tier file names" begin
        @test tier_file_id("l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5") == (:filekey, "20251107T191821Z")
        @test tier_file_id("l200-p18-r000-cal-B00000C-tier_jlhit.lh5") == (:detector, "B00000C")
        # READMEs and scratch files occur in run directories and are no error.
        @test tier_file_id("README.txt") === nothing && tier_file_id("l200-p18-r000-cal-nonsense-tier_jlhit.lh5") === nothing
    end

    @testset "production tree, lazy expansion and directory sizes" begin
        root = production_tree(h, p)
        @test root.kind == :production && root.label == "Production: test" && root.local_state == :missing
        @test [c.label for c in root.children] == ["config.json", "metadata", "par", "tier", "tier/jlhit", "tier/jlpks"]
        @test root.children[1].kind == :file && root.children[1].size > 0
        @test all(c -> c.kind == :section && c.size === nothing && c.parent === root, root.children[2:end])   # sizing tier/raw at startup is not affordable
        tier_node = root.children[4]
        @test tier_node.children === nothing
        expand!(h, p, tier_node)
        @test [c.label for c in tier_node.children] == ["jlevt", "jlhit"] && all(c -> c.kind == :dir, tier_node.children)
        @test [c.size for c in tier_node.children] == [4096 + 8192, 2048 + 1024 + 18]
        listed = tier_node.children
        expand!(h, p, tier_node)
        @test tier_node.children === listed
        @test_throws "cannot be expanded" expand!(h, p, root.children[1])
    end

    @testset "filekey and detector grouping" begin
        node = Node("r000", evtrun, :dir)
        expand!(h, p, node)
        # Timestamp order, not readdir order; a group stands for exactly one file.
        @test [(c.kind, c.label, c.size) for c in node.children] == [(:group, "20251107T191821Z", 4096), (:group, "20251107T192416Z", 8192)]
        file = only(node.children[1].children)
        @test file.kind == :file && file.label == "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5" && file.parent === node.children[1]
        @test [g.label for g in filekey_groups(node)] == ["20251107T191821Z", "20251107T192416Z"]

        hit = Node("r000", hitrun, :dir)
        expand!(h, p, hit)
        @test [(c.label, c.kind) for c in hit.children] == [("B00000C", :group), ("V01234A", :group), ("README.txt", :file)]
        @test isempty(filekey_groups(hit))
    end

    @testset "the detectors row comes first when asked and local state follows the files" begin
        period = Node("p18", dirname(evtrun), :dir)
        expand!(h, p, period; detectors = true)
        @test first(period.children).kind == :detectors && ensure_detectors!(period) === first(period.children)
        run = Node("r000", evtrun, :dir)
        expand!(h, p, run; detectors = true)
        @test [c.kind for c in run.children] == [:detectors, :group, :group]
        plain = Node("r000", evtrun, :dir)
        expand!(h, p, plain)
        @test node_local_state(p, plain) == :missing
        first_file = to_local(p, joinpath(evtrun, "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"))
        mkpath(dirname(first_file))
        write(first_file, zeros(UInt8, 4096))
        @test node_local_state(p, plain) == :partial && node_local_state(p, run) == :partial   # the detectors row does not count
        write(to_local(p, joinpath(evtrun, "l200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5")), zeros(UInt8, 8192))
        @test node_local_state(p, plain) == :present
        symlink("/nowhere", joinpath(local_root, "a-link"))
        @test node_local_state(p, Node("x", joinpath(FIXTURE_ROOT, "a-link"), :dir)) == :linked
    end
end

@testset "selection modes" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "test", FIXTURE_ROOT, local_root; mount_root = "/Volumes/cslg4")
    tier = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier")
    rundir = joinpath(tier, "jlevt", "phy", "p18", "r000")
    hitdir = joinpath(tier, "jlhit", "cal", "p18", "r000")
    mandatory = [joinpath("test", "config.json"), "config_fixture.json", joinpath("test", "legend-metadata")]
    rel(path) = relpath(path, FIXTURE_ROOT)

    @testset "set_mode! clears descendants but keeps a copy below a link" begin
        a = Node("a", joinpath(FIXTURE_ROOT, "temp"), :dir)
        b = Node("b", joinpath(FIXTURE_ROOT, "temp", "jl-dev"), :dir; parent = a)
        a.children = [b]
        @test effective_mode(b) == :none
        a.mode = :copy
        @test effective_mode(b) == :copy
        b.mode = :link
        @test effective_mode(b) == :link

        root = production_tree(h, p)
        r000 = find_node!(h, p, root, rel(rundir))
        jlevt = r000.parent.parent.parent
        set_mode!.(r000.children, :copy)
        set_mode!(jlevt, :link)
        @test jlevt.mode == :link && [c.mode for c in r000.children] == [:copy, :copy] && r000.mode == :none
        @test effective_mode(r000) == :link && effective_mode(r000.children[1]) == :copy
        set_mode!(jlevt, :copy)
        @test [c.mode for c in r000.children] == [:none, :none]
        @test_throws "mode must be" set_mode!(jlevt, :sideways)
    end

    @testset "exclude! pushes each level's own mode onto its siblings" begin
        root = production_tree(h, p)
        r000 = find_node!(h, p, root, rel(hitdir))
        set_mode!(r000, :copy)
        exclude!(r000.children[2])
        @test r000.mode == :none && [c.mode for c in r000.children] == [:copy, :none, :copy] && effective_mode(r000.children[2]) == :none
        @test setdiff(Selection(p, "cslg4", root).copy, mandatory) ==
              sort([relative(p, r000.children[1].remote_path), relative(p, r000.children[3].remote_path)])

        # A :link ancestor with a :copy descendant: each level keeps its own mode for the siblings.
        node(label, path; parent = nothing) = Node(label, joinpath(FIXTURE_ROOT, "synthetic", path), :dir; parent)
        top = node("root", "b-root")
        anc = node("anc", "b-root/anc"; parent = top)
        kid1, kid2 = node("kid1", "b-root/anc/kid1"; parent = anc), node("kid2", "b-root/anc/kid2"; parent = anc)
        gc1, gc2 = node("gc1", "b-root/anc/kid2/gc1"; parent = kid2), node("gc2", "b-root/anc/kid2/gc2"; parent = kid2)
        top.children, anc.children, kid2.children = [anc], [kid1, kid2], [gc1, gc2]
        set_mode!(kid2, :copy)
        set_mode!(anc, :link)
        exclude!(gc2)
        @test anc.mode == :none && kid2.mode == :none && gc2.mode == :none && kid1.mode == :link && gc1.mode == :copy
        sel = Selection(p, "cslg4", top)
        @test setdiff(sel.copy, mandatory) == [relative(p, gc1.remote_path)] && sel.link == [relative(p, kid1.remote_path)]
    end

    @testset "first_n_filekeys! marks the first filekey groups" begin
        r000 = Node("r000", rundir, :dir)
        expand!(h, p, r000)
        @test first_n_filekeys!(r000, 1) == 1 && [c.mode for c in r000.children] == [:copy, :none]
        @test first_n_filekeys!(r000, 5) == 2 && [c.mode for c in r000.children] == [:copy, :copy]
        hit = Node("r000", hitdir, :dir)
        expand!(h, p, hit)
        @test_throws "no filekey groups" first_n_filekeys!(hit, 1)
        @test_throws "has not been listed" first_n_filekeys!(Node("x", rundir, :dir), 1)
    end

    @testset "a selection round trip keeps copies, links and the mandatory copies" begin
        no_metadata = Production(p.name, p.remote_root, p.local_root, p.mount_root, p.config,
                                 filter(kv -> first(kv) != "metadata", p.roots),
                                 p.overlays, p.config_file, p.setup_config)
        @test_throws "has no \"metadata\" path key" Selection(no_metadata, "cslg4", production_tree(h, no_metadata))

        root = production_tree(h, p)
        set_mode!(find_node!(h, p, root, rel(rundir)).children[1], :copy)
        hit = joinpath(tier, "jlhit")
        set_mode!(find_node!(h, p, root, rel(hit)), :link)
        sel = Selection(p, "cslg4", root)
        @test (sel.host, sel.production, sel.mount_root, sel.link) == ("cslg4", "test", "/Volumes/cslg4", [rel(hit)])
        @test all(in(sel.copy), mandatory) && rel(joinpath(rundir, "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5")) in sel.copy
        path = save_selection(joinpath(mktempdir(), "sync", "test.yaml"), sel)
        back = load_selection(path, p)
        @test (back.copy, back.link, back.mount_root, back.created) == (sel.copy, sel.link, "/Volumes/cslg4", sel.created)
        @test load_selection(path, p; host = "cslg4").production == "test"

        # A hand-written selection without copy entries still gets the mandatory ones; no mount root stays nothing.
        bare = Selection("cslg4", "test", sel.remote_root, sel.local_root, nothing, String[], [first(sel.link)], sel.created)
        loaded = load_selection(save_selection(joinpath(mktempdir(), "bare.yaml"), bare), p)
        @test loaded.copy == sort(mandatory_copies(p)) && loaded.link == bare.link && loaded.mount_root === nothing
        @test_throws "a selection file must end in .yaml, got x.json" save_selection("x.json", sel)
    end

    @testset "a selection is refused for another host, production or remote root" begin
        root = production_tree(h, p)
        sel = Selection(p, "cslg4", root)
        path = save_selection(joinpath(mktempdir(), "test.yaml"), sel)
        @test_throws "saved for host cslg4, but the current host is other" load_selection(path, p; host = "other")
        other_dir = mktempdir()
        cp(joinpath(FIXTURE_ROOT, "test"), joinpath(other_dir, "test"))
        write(joinpath(other_dir, "test", "config.json"),
              replace(read(joinpath(FIXTURE_ROOT, "test", "config.json"), String), FIXTURE_ROOT => other_dir))
        cp(joinpath(FIXTURE_ROOT, "temp"), joinpath(other_dir, "temp"))
        @test_throws "has remote root" load_selection(path, Production(h, "test", other_dir, local_root))
        renamed = Selection("cslg4", "preprod", sel.remote_root, sel.local_root, nothing, sel.copy, sel.link, sel.created)
        @test_throws "is for production preprod" load_selection(save_selection(joinpath(mktempdir(), "p.yaml"), renamed), p)
    end

    @testset "apply_selection! reconstructs the tree and rejects unknown paths" begin
        root = production_tree(h, p)
        set_mode!(find_node!(h, p, root, rel(rundir)).children[2], :copy)
        sel = Selection(p, "cslg4", root)
        fresh = production_tree(h, p)
        apply_selection!(h, p, fresh, sel)
        @test [c.mode for c in find_node!(h, p, fresh, rel(rundir)).children] == [:none, :copy]
        @test effective_mode(find_node!(h, p, fresh, joinpath("test", "legend-metadata"))) == :copy
        @test_throws "is not in the production tree" find_node!(h, p, fresh, joinpath("temp", "nope"))

        n = Production(h, "temp/jl-dev", FIXTURE_ROOT, local_root)
        nested = Selection(n, "cslg4", production_tree(h, n))
        @test nested.copy ==
              sort(["temp/jl-dev/config.json", "config_fixture.json", "temp/config_site.yaml", "temp/jl-dev/legend-metadata"])
        path = save_selection(joinpath(mktempdir(), "nested.yaml"), nested)
        @test load_selection(path, n).production == "temp/jl-dev"
        @test_throws "is for production temp/jl-dev" load_selection(path, p)
    end
end

@testset "extract rows" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "tprod", TIER_DET_ROOT, local_root)
    tier = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier")
    p18, r000_path, r001_path = joinpath(tier, "jlpks", "cal", "p18"), joinpath(tier, "jlpks", "cal", "p18", "r000"),
                                joinpath(tier, "jlpks", "cal", "p18", "r001")
    helper = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())

    # The period `p18` with its detector rows (B00000C and V01234A in both runs, aux in r000 only) and the rows of both runs.
    function tree(root = production_tree(h, p))
        period = find_node!(h, p, root, relative(p, p18))
        rows = rows!(ensure_detectors!(period), ("B00000C", 400 * 2 + 400, [r000_path => 2, r001_path => 1]),
                     ("V01234A", 800 * 2 + 800, [r000_path => 2, r001_path => 1]), ("aux", 1200 * 2, [r000_path => 2]))
        runs = [find_node!(h, p, root, relative(p, r)) for r in (r000_path, r001_path)]
        run_rows = [rows!(ensure_detectors!(runs[1]), ("B00000C", 400, []), ("V01234A", 800, []), ("aux", 1200, [])),
                    rows!(ensure_detectors!(runs[2]), ("B00000C", 400, []), ("V01234A", 800, []))]
        return root, period, rows, runs, run_rows
    end

    @testset "the period row is the union of its runs with summed sizes (listed by the helper)" begin
        _, period, rows, _, _ = tree()
        fresh = Node("p18", p18, :dir)
        expand!(h, p, fresh; detectors = true)
        foreach(run -> expand!(h, p, run; detectors = true), run_dirs(fresh))
        real = period_detector_nodes(h, counted_helper(), fresh)
        @test [(c.label, c.size, c.holders) for c in real] == [(c.label, c.size, c.holders) for c in rows.children]
        @test rows.size == 6000 && has_detectors(rows) && all(c -> c.kind == :detector && c.parent === rows, rows.children)
        @test [c.kind for c in period.children] == [:detectors, :dir, :dir]
        empty = Node("p19", joinpath(tier, "jlpks", "cal", "p19"), :dir)
        expand!(h, p, empty; detectors = true)
        foreach(run -> expand!(h, p, run; detectors = true), run_dirs(empty))
        @test [c.kind for c in empty.children] == [:dir] && !any(c -> c.kind == :detectors, only(run_dirs(empty)).children)
        @test_throws "has no run directory with filekey files" period_detector_nodes(h, helper, empty)
        @test_throws "holds no filekey files and no run directories" ensure_detectors!(only(run_dirs(empty)))
        @test_throws "has not been listed yet" ensure_detectors!(Node("p", p18, :dir))
        cal = Node("cal", joinpath(tier, "jlpks", "cal"), :dir)
        expand!(h, p, cal; detectors = true)
        @test [c.kind for c in cal.children] == [:dir, :dir, :dir]
        @test filekey_files(h, r000_path) == [joinpath(r000_path, "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5"),
                                              joinpath(r000_path, "l200-p18-r000-cal-20251107T192416Z-tier_jlpks.lh5")]
    end

    @testset "a mark is only for detector rows and a run transferred whole takes none" begin
        _, period, rows, (r000, r001), run_rows = tree()
        @test_throws "only detector rows can be extracted" set_mode!(r000, :extract)
        @test_throws "use :extract, not :copy" set_mode!(rows.children[1], :copy)
        @test_throws "use :extract, not :link" set_mode!(rows, :link)
        for mode in (:copy, :link), (node, name) in ((r000, "r000"), (period, "p18"), (period.parent, "cal"))
            set_mode!(node, mode)
            @test_throws "cannot extract B00000C from p18: " set_mode!(rows.children[1], :extract)
            @test_throws "cannot extract B00000C from r000: r000 is already transferred whole (:$mode on $name)" set_mode!(run_rows[1].children[1],
                                                                                                                           :extract)
            set_mode!(node, :none)
        end
        @test rows.children[1].mode == :none && run_rows[1].children[1].mode == :none
        set_mode!(rows.children[1], :extract)
        @test effective_mode(rows.children[1]) == :extract
        for mode in (:copy, :link), node in (period, r000, r001, period.parent)
            @test_throws "cannot mark $(node.label) :$mode: detector B00000C of p18 is marked for extraction" set_mode!(node, mode)
        end
        # A mark of a detector that a run does not hold leaves that run copyable.
        set_mode!(rows.children[1], :none)
        set_mode!(rows.children[3], :extract)
        set_mode!(r001, :copy)
        @test r001.mode == :copy
        @test_throws "r001 is already transferred whole (:copy on r001)" set_mode!(rows.children[1], :extract)
        @test_throws "cannot mark r000 :copy" set_mode!(r000, :copy)
    end

    @testset "run rows inherit a period mark and cannot drop it" begin
        _, period, rows, (r000, _), run_rows = tree()
        set_mode!(rows.children[1], :extract)
        r = run_rows[1].children
        @test covering_extract(r[1]) === rows.children[1] && covering_extract(run_rows[2].children[1]) === rows.children[1]
        @test covering_extract(r[3]) === nothing && covering_extract(rows.children[1]) === nothing && covering_extract(r000) === nothing
        @test r[1].mode == :none && effective_mode(r[1]) == :extract && (checkbox(r[1]), checkbox(r[2])) == ("[e]", "[ ]")
        @test_throws "it is extracted for the whole period; unmark the period row $(rows.children[1].remote_path) instead" exclude!(r[1])
        set_mode!(rows.children[1], :none)
        set_mode!(r000, :copy)
        @test_throws "unmark the run instead" exclude!(r[1])
        @test_throws "unmark the run instead" exclude!(run_rows[1])
        @test_throws "already transferred whole" set_mode!(r[1], :extract)
        set_mode!(r000, :none)
        set_mode!(r[1], :extract)
        exclude!(r[1])
        @test r[1].mode == :none
    end

    @testset "marks are recorded as entries, saved and restored" begin
        root, period, rows, _, run_rows = tree()
        set_mode!(rows.children[3], :extract)
        set_mode!(rows.children[1], :extract)
        set_mode!(run_rows[1].children[2], :extract)
        sel = Selection(p, "local", root)
        @test sel.extract == [ExtractEntry(relative(p, p18), ["B00000C", "aux"]), ExtractEntry(relative(p, r000_path), ["V01234A"])]
        path = save_selection(joinpath(mktempdir(), "tprod.yaml"), sel)
        @test all(e -> haskey(e, "dir"), YAML.load_file(path)["extract"])
        back = load_selection(path, p)
        @test back.extract == sel.extract && back.copy == sel.copy
        applied, _, arows, _, arun_rows = tree()
        apply_selection!(h, p, applied, back; helper)
        @test [c.mode for c in arows.children] == [:extract, :none, :extract] &&
              [c.mode for c in arun_rows[1].children] == [:none, :extract, :none]
        @test Selection(p, "local", applied).extract == sel.extract

        bad_period = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing, String[], String[], now(),
                               [ExtractEntry(relative(p, p18), ["Z99999Z"])])
        @test_throws "detector group Z99999Z of $(relative(p, p18)) is not in any run of the period" apply_selection!(h, p, tree()[1],
                                                                                                                      bad_period; helper)
        bad_run = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing, String[], String[], now(),
                            [ExtractEntry(relative(p, r001_path), ["aux"])])
        @test_throws "detector group aux of $(relative(p, r001_path)) is not in the first file of the run" apply_selection!(h, p, tree()[1],
                                                                                                                            bad_run; helper)
        # A selection that contradicts itself fails when applied.
        clash = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing, [relative(p, r000_path)], String[], now(),
                          [ExtractEntry(relative(p, p18), ["B00000C"])])
        @test_throws "r000 is already transferred whole (:copy on r000)" apply_selection!(h, p, tree()[1], clash; helper)
    end

    @testset "entries cannot leave the remote root" begin
        e = ExtractEntry("run", ["b", "a", "a"])
        @test e.groups == ["a", "b"] && hash(e) == hash(ExtractEntry("run", ["a", "b"]))
        @test_throws "dir must be relative, got /abs/run" ExtractEntry("/abs/run", ["a"])
        @test_throws "dir must not contain .., got a/../b" ExtractEntry("a/../b", ["a"])
        @test_throws "no groups for dir run" ExtractEntry("run", String[])
        good = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing, String[], String[], now(), [ExtractEntry("good/run", ["a"])])
        path = save_selection(joinpath(mktempdir(), "bad.yaml"), good)
        write(path, replace(read(path, String), "good/run" => "/etc"))
        @test_throws "dir must be relative, got /etc" load_selection(path, p)
        two = Selection("local", "tprod", TIER_DET_ROOT, local_root, nothing, sort(mandatory_copies(p)), String[],
                        DateTime(2026, 10, 14, 9, 5, 3, 7),
                        [ExtractEntry("a/run", ["z", "m"]), ExtractEntry("b/run", ["true", "x"])])
        path = save_selection(joinpath(mktempdir(), "two.yaml"), two)
        @test YAML.load_file(path)["extract"][2]["groups"] == ["true", "x"] && YAML.load_file(path)["created"] == "2026-10-14T09:05:03.007"
        back = load_selection(path, p)
        @test all(f -> getfield(back, f) == getfield(two, f), fieldnames(Selection))
    end
end

@testset "per-detector tier rows" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "dprod", PERDET_ROOT, local_root)
    p16 = joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
    p16_rel = relative(p, p16)
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())
    entry(detectors, mode; dir = p16_rel) = DetectorEntry(dir, detectors, mode)

    function tree(root = production_tree(h, p))
        period = find_node!(h, p, root, p16_rel)
        rows = expand_detectors!(h, broken, ensure_detectors!(period; whole_files = true))
        runs = run_dirs(period)
        foreach(run -> expand!(h, p, run), runs)
        return root, period, rows, runs
    end

    @testset "the period lists the union of the detector files without the helper" begin
        period = Node("p16", p16, :dir)
        expand!(h, p, period; detectors = true)
        @test [c.kind for c in period.children] == [:detectors, :dir, :dir] && period.children[1].whole_files
        row = expand_detectors!(h, broken, period.children[1])
        @test [(c.label, c.size) for c in row.children] == [("B00000C", 400), ("V01234A", 200)] && row.size == 600
        @test row.children[1].holders == [joinpath(p16, "r000") => 1, joinpath(p16, "r001") => 1] && all(c -> c.whole_files, row.children)
        run = only(filter(c -> c.label == "r000", period.children))
        expand!(h, p, run; detectors = true)
        @test [(c.label, c.size, c.whole_files) for c in run.children] == [("B00000C", 100, false), ("V01234A", 200, false)]
        # Categories, empty periods and periods of filekey files get no per-detector row.
        for (dir, kinds) in ((joinpath(dirname(p16)), [:dir, :dir]), (joinpath(dirname(p16), "p17"), [:dir]))
            node = Node(basename(dir), dir, :dir)
            expand!(h, p, node; detectors = true)
            @test [c.kind for c in node.children] == kinds
        end
        @test_throws "holds no per-detector files" period_file_nodes(h, let n = Node("p17", joinpath(dirname(p16), "p17"), :dir)
                                                                         expand!(h, p, n)
                                                                         n
                                                                     end)
        dsp = Node("p16", joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jldsp", "cal", "p16"), :dir)
        expand!(h, p, dsp; detectors = true)
        @test dsp.children[1].kind == :detectors && !dsp.children[1].whole_files
    end

    @testset "a run directory with two files of one detector or with both kinds of tier file is an error" begin
        root = make_per_detector_remote()
        dir = joinpath(root, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
        q = Production(h, "dprod", root, mktempdir())
        write(joinpath(dir, "r001", "l200-p16-r001-phy-B00000C-tier_jlqcs.lh5"), "y")
        period = Node("p16", dir, :dir)
        expand!(h, q, period; detectors = true)
        @test_throws "r001 holds two files for detector B00000C" period_file_nodes(h, period)
        write(joinpath(dir, "r000", "l200-p16-r000-cal-20251107T191821Z-tier_jlqcs.lh5"), "z")
        @test_throws "r000 holds filekey files and per-detector files" expand!(h, q, Node("r000", joinpath(dir, "r000"), :dir))
    end

    @testset "space and l mark a row, runs show the mark and refuse to change it" begin
        _, period, rows, runs = tree()
        b, v = rows.children
        set_mode!(b, :copy)
        set_mode!(v, :link)
        @test (checkbox(b), checkbox(v)) == ("[x]", "[~]")
        @test_throws "hold one detector each" set_mode!(b, :extract)
        @test_throws "mark one of the detector rows below it :copy" set_mode!(rows, :copy)
        r000_b, r000_v, r001_b = runs[1].children[1], runs[1].children[2], runs[2].children[1]
        @test covering_detector(r000_b) === b && covering_detector(only(r001_b.children)) === b && covering_detector(r000_v) === v
        @test covering_detector(b) === nothing && effective_mode(only(r000_b.children)) == :copy && checkbox(r000_b) == "[x]"
        for f in (n -> set_mode!(n, :copy), n -> set_mode!(n, :link), exclude!)
            @test_throws "unmark the period's detector" f(r000_b)
        end
        set_mode!(b, :none)
        set_mode!(v, :none)
        set_mode!(r000_b, :copy)
        @test r000_b.mode == :copy
        @test_throws "file B00000C of r000 is marked individually" set_mode!(b, :copy)
    end

    @testset "row marks and whole copies exclude each other" begin
        _, period, rows, runs = tree()
        b, v = rows.children
        for mode in (:copy, :link), (node, name) in ((runs[1], "r000"), (period, "p16"), (period.parent, "cal"))
            set_mode!(node, mode)
            @test_throws "is already transferred whole (:$mode on $name)" set_mode!(b, mode)
            set_mode!(node, :none)
        end
        set_mode!(b, :link)
        for node in (period, runs[1], runs[2], period.parent), mode in (:copy, :link)
            @test_throws "cannot mark $(node.label) :$mode: detector B00000C of p16 is marked :link; unmark the detector first" set_mode!(node,
                                                                                                                                          mode)
        end
        set_mode!(b, :none)
        # r001 does not hold V01234A, so copying it is allowed while V01234A is marked.
        set_mode!(v, :copy)
        set_mode!(runs[2], :copy)
        @test runs[2].mode == :copy
        @test_throws "cannot mark r000 :copy" set_mode!(runs[1], :copy)
    end

    @testset "marks are saved by intent and restored" begin
        root, _, rows, _ = tree()
        set_mode!(rows.children[1], :copy)
        set_mode!(rows.children[2], :link)
        sel = Selection(p, "local", root)
        @test sel.detector_files == [entry(["B00000C"], :copy), entry(["V01234A"], :link)]
        @test !(p16_rel in sel.copy) && !any(c -> endswith(c, "B00000C"), sel.copy)
        path = save_selection(joinpath(mktempdir(), "dprod.yaml"), sel)
        @test YAML.load_file(path)["detector_files"][1] == Dict("dir" => p16_rel, "detectors" => ["B00000C"], "mode" => "copy")
        back = load_selection(path, p)
        @test back.detector_files == sel.detector_files
        fresh = production_tree(h, p)
        apply_selection!(h, p, fresh, back; helper = broken)
        @test [c.mode for c in find_node!(h, p, fresh, p16_rel).children[1].children] == [:copy, :link]
        set_mode!(rows.children[1], :copy)
        set_mode!(rows.children[2], :copy)
        @test Selection(p, "local", root).detector_files == [entry(["B00000C", "V01234A"], :copy)]

        sel(entries; copy = String[]) = Selection("local", "dprod", PERDET_ROOT, local_root, nothing, copy, String[], now(), ExtractEntry[],
                                                  entries)
        apply(s) = apply_selection!(h, p, production_tree(h, p), s; helper = broken)
        @test_throws "detector Z99999Z of $p16_rel: no run of the period holds a file for it" apply(sel([entry(["Z99999Z"], :copy)]))
        @test_throws "p16 is already transferred whole (:copy on p16)" apply(sel([entry(["B00000C"], :link)]; copy = [p16_rel]))
        @test_throws "detector B00000C of $p16_rel is marked both :copy and :link" apply(sel([entry(["B00000C"], :copy),
                                                                                              entry(["B00000C"], :link)]))
        @test_throws "dir must be relative, got /abs" DetectorEntry("/abs", ["B00000C"], :copy)
        @test_throws "mode must be :copy or :link" DetectorEntry(p16_rel, ["B00000C"], :extract)
        @test_throws "no detectors for dir $p16_rel" DetectorEntry(p16_rel, String[], :copy)
    end
end

@testset "estimates" begin
    h = LocalHost()

    @testset "formatting" begin
        @test [format_bytes(n) for n in (0, 1023, 1024, 4096 + 8192, 27 * 1024^3)] == ["0 B", "1023 B", "1.0 K", "12.0 K", "27.0 G"]
        @test format_estimate(Estimate(0, 0, 0, true)) == "selected: 0 B copy (0 files), 0 links"
        @test format_estimate(Estimate(0, 0, 0, true, 1288490188, 2, false)) ==
              "selected: 0 B copy (0 files), 0 links, ~1.2 G extract (2 files)"
        pairs = [("a/r001", "aux"), ("a/r002", "aux")]
        @test format_not_in_run(pairs) == "aux in a/r001, aux in a/r002"
        @test format_estimate(Estimate(0, 0, 0, true, 2048, 2, true, pairs)) ==
              "selected: 0 B copy (0 files), 0 links, 2.0 K extract (2 files), 2 not in run"
        stats = "Number of regular files transferred: 2\nTotal file size: 12,288 bytes\nTotal transferred file size: 12,288 bytes\nsent 143 bytes  received 24 bytes\ntotal size is 12,288  speedup is 73.58 (DRY RUN)\n"
        @test parse_rsync_stats(stats, 3) == Estimate(12288, 2, 3, true)
        @test_throws "printed no transfer totals" parse_rsync_stats("rsync: nope\n", 0)
    end

    @testset "the running estimate counts a copy once and marks an unknown size" begin
        root = Node("root", "/r", :production)
        dir = Node("dir", "/r/dir", :dir; size = 3000, parent = root)
        a, b = Node("a", "/r/dir/a", :group; size = 1000, parent = dir), Node("b", "/r/dir/b", :group; size = 2000, parent = dir)
        unsized = Node("u", "/r/u", :dir; parent = root)
        root.children, dir.children = [dir, unsized], [a, b]
        @test running_estimate(root) == Estimate(0, 0, 0, true)
        set_mode!(a, :copy)
        @test running_estimate(root) == Estimate(1000, 1, 0, true)
        set_mode!(dir, :copy)
        @test running_estimate(root) == Estimate(3000, 0, 0, true)   # the parent counts once, not with its children
        set_mode!(unsized, :copy)
        @test !running_estimate(root).complete && format_estimate(running_estimate(root)) == "selected: 2.9 K? copy (0 files), 0 links"
        set_mode!(unsized, :none)
        set_mode!(dir, :link)
        set_mode!.([a, b], :copy)
        @test running_estimate(root) == Estimate(3000, 2, 1, true)   # a copy inside a link counts; the link adds no bytes
    end

    @testset "the running estimate of extract and per-detector rows" begin
        p = Production(h, "tprod", TIER_DET_ROOT, mktempdir())
        p18 = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier", "jlpks", "cal", "p18")
        r000, r001 = joinpath(p18, "r000"), joinpath(p18, "r001")
        root = production_tree(h, p)
        period = find_node!(h, p, root, relative(p, p18))
        rows = rows!(ensure_detectors!(period), ("B00000C", 1200, [r000 => 2, r001 => 1]), ("V01234A", 2400, [r000 => 2, r001 => 1]),
                     ("aux", 2400, [r000 => 2]))
        runs = [find_node!(h, p, root, relative(p, r)) for r in (r000, r001)]
        run_rows = [rows!(ensure_detectors!(r), ("B00000C", 400, []), ("V01234A", 800, [])).children for r in runs]
        set_mode!(rows.children[1], :extract)
        est = running_estimate(root)
        @test (est.extract_bytes, est.extract_files, est.extract_exact) == (1200, 3, false)
        set_mode!(rows.children[3], :extract)
        set_mode!(run_rows[1][1], :extract)   # a run mark of a covered detector adds nothing
        @test (running_estimate(root).extract_bytes, running_estimate(root).extract_files) == (3600, 3)
        set_mode!(run_rows[2][2], :extract)   # a run mark of another detector adds that run's share
        @test running_estimate(root).extract_bytes == 3600 + 800
        set_mode!.(rows.children, :none)
        set_mode!(run_rows[1][1], :none)
        set_mode!(run_rows[2][2], :none)
        set_mode!(run_rows[1][2], :extract)
        set_mode!(filekey_groups(runs[1])[2], :copy)   # a file copied whole leaves the run share
        est = running_estimate(root)
        @test (est.extract_bytes, est.extract_files, est.files) == (800, 1, 1)

        d = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root = "/")
        dp16 = relative(d, joinpath(PERDET_ROOT, "dprod", "generated", "tier", "jlqcs", "cal", "p16"))
        droot = production_tree(h, d)
        dperiod = find_node!(h, d, droot, dp16)
        drows = expand_detectors!(h, HelperConfig(; julia = "/nonexistent/julia"), ensure_detectors!(dperiod; whole_files = true))
        b, v = drows.children
        set_mode!(b, :copy)
        @test running_estimate(droot) == Estimate(400, 2, 0, true)
        set_mode!(v, :link)
        @test running_estimate(droot) == Estimate(400, 2, 1, true)
        set_mode!(v, :none)
        foreach(run -> expand!(h, d, run), run_dirs(dperiod))
        set_mode!(run_dirs(dperiod)[1].children[2], :copy)   # a file marked on its own that no row covers is added
        @test running_estimate(droot) == Estimate(600, 3, 0, true)
        b.size = nothing
        @test !running_estimate(droot).complete
    end
end
