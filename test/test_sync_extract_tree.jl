# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "extract: detectors in the tree and the selection" begin
    h = LocalHost()
    local_root = mktempdir()
    helper = HelperConfig(; staging = mktempdir())
    p = Production(h, "xprod", EXTRACT_ROOT, local_root)
    tier = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier")
    dsp = joinpath(tier, "jldsp", "cal", "p18", "r000")
    evt = joinpath(tier, "jlevt", "phy", "p18", "r000")

    @testset "expand! adds the detectors child only when asked" begin
        plain = Node("r000", dsp, :dir)
        expand!(h, p, plain)
        @test [c.kind for c in plain.children] == [:group, :group]

        node = Node("r000", dsp, :dir)
        expand!(h, p, node; detectors = true)
        @test [c.kind for c in node.children] == [:detectors, :group, :group]
        detectors = node.children[1]
        @test detectors.label == "detectors"
        @test detectors.remote_path == joinpath(dsp, "detectors")
        @test detectors.parent === node
        @test detectors.children === nothing
        @test ensure_detectors!(node) === detectors
        @test length(node.children) == 3
        @test [g.label for g in filekey_groups(node)] == ["20251107T191821Z", "20251107T192416Z"]
        @test_throws "has not been listed" ensure_detectors!(Node("x", dsp, :dir))
        empty_dir = Node("e", mktempdir(), :dir; children = Node[])
        @test_throws "holds no filekey files" ensure_detectors!(empty_dir)
    end

    @testset "the detectors child does not disturb the local state" begin
        mirror = mktempdir()
        pm = Production(h, "xprod", EXTRACT_ROOT, mirror)
        mkpath(dirname(to_local(pm, dsp)))
        cp(dsp, to_local(pm, dsp))
        node = Node("r000", dsp, :dir)
        expand!(h, pm, node; detectors = true)
        @test node.local_state == :present
        @test node_local_state(pm, node) == :present
    end

    @testset "expand_detectors! lists the groups of the first file" begin
        node = Node("r000", dsp, :dir)
        expand!(h, p, node; detectors = true)
        detectors = node.children[1]
        expand_detectors!(h, helper, detectors)
        @test [c.label for c in detectors.children] == ["B00000C", "V01234A", "aux"]
        @test all(c -> c.kind == :detector && c.parent === detectors, detectors.children)
        @test [c.size for c in detectors.children] == [400, 800, 1200]
        @test detectors.size == 2400
        @test detectors.children[1].remote_path == joinpath(dsp, "detectors", "B00000C")
        @test has_detectors(detectors)
        # A second call lists nothing again.
        children = detectors.children
        expand_detectors!(h, helper, detectors)
        @test detectors.children === children
        @test_throws "not a detectors node" expand_detectors!(h, helper, node)
    end

    @testset "a tier with one group named after it has no detectors" begin
        node = Node("r000", evt, :dir)
        expand!(h, p, node; detectors = true)
        detectors = node.children[1]
        @test detectors.kind == :detectors
        @test has_detectors(detectors)                  # not inspected yet
        expand_detectors!(h, helper, detectors)
        @test detectors.children == Node[]
        @test !has_detectors(detectors)
    end

    @testset ":extract is only for detector rows" begin
        node = Node("r000", dsp, :dir)
        expand!(h, p, node; detectors = true)
        @test_throws "only detector rows can be extracted" set_mode!(node, :extract)
        @test_throws "mode must be" set_mode!(node, :sideways)
        detectors = expand_detectors!(h, helper, node.children[1])
        set_mode!(detectors.children[1], :extract)
        @test detectors.children[1].mode == :extract
        @test effective_mode(detectors.children[1]) == :extract
        # A run with an extracted detector cannot be copied whole.
        @test_throws "detector B00000C of r000 is marked for extraction" set_mode!(node, :copy)
        @test node.mode == :none && detectors.children[1].mode == :extract
    end

    @testset "detector rows take no :copy or :link" begin
        node = Node("r000", dsp, :dir)
        expand!(h, p, node; detectors = true)
        detectors = expand_detectors!(h, helper, node.children[1])
        @test_throws "use :extract, not :copy" set_mode!(detectors.children[1], :copy)
        @test_throws "use :extract, not :link" set_mode!(detectors, :link)
        @test detectors.children[1].mode == :none

        # Taking one filekey out of a copied run leaves the detectors row alone.
        set_mode!(node, :copy)
        exclude!(filekey_groups(node)[1])
        @test [g.mode for g in filekey_groups(node)] == [:none, :copy]
        @test detectors.mode == :none
    end

    @testset "a run transferred whole takes no per-detector changes" begin
        node = Node("r000", dsp, :dir)
        expand!(h, p, node; detectors = true)
        detectors = expand_detectors!(h, helper, node.children[1])
        for mode in (:copy, :link)
            set_mode!(node, mode)
            @test_throws "already transferred whole" set_mode!(detectors.children[1], :extract)
            @test_throws "unmark the run instead" exclude!(detectors.children[1])
            @test_throws "unmark the run instead" exclude!(detectors)
            @test node.mode == mode
        end
        set_mode!(node, :none)
        set_mode!(detectors.children[1], :extract)
        @test detectors.children[1].mode == :extract
        exclude!(detectors.children[1])
        @test detectors.children[1].mode == :none
    end

    @testset "ExtractEntry normalizes its groups" begin
        e = ExtractEntry("run", ["b", "a", "a"])
        @test e.groups == ["a", "b"]
        @test hash(e) == hash(ExtractEntry("run", ["a", "b"]))
    end

    @testset "ExtractEntry rejects paths that leave the remote root and empty groups" begin
        @test_throws "dir must be relative, got /abs/run" ExtractEntry("/abs/run", ["a"])
        @test_throws "dir must not contain .., got a/../b" ExtractEntry("a/../b", ["a"])
        @test_throws "dir must not contain .., got .." ExtractEntry("..", ["a"])
        @test_throws "no groups for dir run" ExtractEntry("run", String[])
        good = Selection("local", "xprod", EXTRACT_ROOT, local_root, nothing, String[], String[], now(),
                         [ExtractEntry("good/run", ["a"])])
        path = save_selection(joinpath(mktempdir(), "bad.yaml"), good)
        write(path, replace(read(path, String), "good/run" => "/etc"))
        @test_throws "dir must be relative, got /etc" load_selection(path, p)
    end

    @testset "extract entries round trip through a file" begin
        none = Selection("local", "xprod", EXTRACT_ROOT, local_root, nothing,
                         String[], String[], now())
        path = save_selection(joinpath(mktempdir(), "none.yaml"), none)
        @test load_selection(path, p).extract == ExtractEntry[]

        two = Selection("local", "xprod", EXTRACT_ROOT, local_root, nothing, String[], String[], now(),
                        [ExtractEntry("a/run", ["z", "m"]), ExtractEntry("b/run", ["y", "x"])])
        path = save_selection(joinpath(mktempdir(), "two.yaml"), two)
        @test load_selection(path, p).extract == [ExtractEntry("a/run", ["m", "z"]),
                                                  ExtractEntry("b/run", ["x", "y"])]
    end

    @testset "a selection is written as YAML and reads back field by field" begin
        period = relative(p, dirname(dsp))
        copies = sort!([mandatory_copies(p); relative(p, joinpath(evt, "1234"))])
        sel = Selection("local", "xprod", EXTRACT_ROOT, local_root, nothing, copies,
                        [relative(p, evt)], DateTime(2026, 10, 14, 9, 5, 3, 7),
                        [ExtractEntry(relative(p, dsp), ["0815", "B00000C", "aux"]),
                         ExtractEntry(period, ["true", "V00000A"])])
        path = save_selection(joinpath(mktempdir(), "xprod.yaml"), sel)
        @test endswith(path, ".yaml")
        @test !startswith(read(path, String), "{")
        raw = YAML.load_file(path)
        @test raw["mount_root"] == ""
        @test raw["created"] == "2026-10-14T09:05:03.007"
        @test raw["extract"][2]["groups"] == ["V00000A", "true"]
        back = load_selection(path, p)
        for field in fieldnames(Selection)
            @test getfield(back, field) == getfield(sel, field)
        end
        @test back.mount_root === nothing
        @test_throws "a selection file must end in .yaml, got x.json" save_selection("x.json", sel)

        blank = Selection("local", "xprod", EXTRACT_ROOT, local_root, nothing,
                          String[], String[], DateTime(2026, 1, 2))
        path = save_selection(joinpath(mktempdir(), "blank.yaml"), blank)
        raw = YAML.load_file(path)
        @test (raw["copy"], raw["link"], raw["extract"]) == ([], [], [])
        back = Selection(readprops(path; subst_pathvar = false, subst_env = false))
        for field in fieldnames(Selection)
            @test getfield(back, field) == getfield(blank, field)
        end
    end

    @testset "a selection saved as JSON still loads" begin
        sel = Selection("local", "xprod", EXTRACT_ROOT, local_root, nothing,
                        sort(mandatory_copies(p)), [relative(p, evt)], DateTime(2026, 10, 14, 9, 5, 3),
                        [ExtractEntry(relative(p, dsp), ["aux"])])
        path = joinpath(mktempdir(), "legacy.json")
        writeprops(path, selection_propdict(sel))
        back = load_selection(path, p)
        for field in fieldnames(Selection)
            @test getfield(back, field) == getfield(sel, field)
        end
    end

    @testset "the selection records extract entries" begin
        root = production_tree(h, p)
        run = find_node!(h, p, root, relative(p, dsp))
        expand_detectors!(h, helper, ensure_detectors!(run))
        detectors = run.children[1]
        set_mode!(detectors.children[3], :extract)      # aux
        set_mode!(detectors.children[1], :extract)      # B00000C
        set_mode!(filekey_groups(run)[2], :copy)

        sel = Selection(p, "local", root)
        @test sel.extract == [ExtractEntry(relative(p, dsp), ["B00000C", "aux"])]
        @test relative(p, joinpath(dsp, "l200-p18-r000-cal-20251107T192416Z-tier_jldsp.lh5")) in sel.copy
        @test !any(c -> occursin("detectors", c), sel.copy)

        path = save_selection(joinpath(mktempdir(), "xprod.yaml"), sel)
        back = load_selection(path, p)
        @test back.extract == sel.extract
        @test back.copy == sel.copy

        # A selection file written before extraction existed still loads.
        old_path = joinpath(mktempdir(), "old.json")
        writeprops(old_path, PropDict(
            :host => sel.host, :production => sel.production, :remote_root => sel.remote_root,
            :local_root => sel.local_root, :mount_root => "", :copy => sel.copy,
            :link => sel.link, :created => string(sel.created)))
        @test load_selection(old_path, p).extract == ExtractEntry[]

        # The eight-argument constructor means "nothing to extract".
        plain = Selection("local", "xprod", sel.remote_root, sel.local_root, nothing,
                          String[], String[], now())
        @test plain.extract == ExtractEntry[]
        @test selection_propdict(plain).extract == []
    end

    @testset "apply_selection! restores the extract entries" begin
        root = production_tree(h, p)
        run = find_node!(h, p, root, relative(p, dsp))
        expand_detectors!(h, helper, ensure_detectors!(run))
        set_mode!(run.children[1].children[2], :extract)     # V01234A
        sel = Selection(p, "local", root)

        fresh = production_tree(h, p)
        apply_selection!(h, p, fresh, sel; helper)
        restored = find_node!(h, p, fresh, relative(p, dsp))
        @test [c.mode for c in restored.children[1].children] == [:none, :extract, :none]

        bad = Selection("local", "xprod", sel.remote_root, sel.local_root, nothing,
                        sel.copy, String[], now(), [ExtractEntry(relative(p, dsp), ["Z99999Z"])])
        @test_throws "detector group Z99999Z" apply_selection!(h, p, production_tree(h, p), bad; helper)
    end
end
