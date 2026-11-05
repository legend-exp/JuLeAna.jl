# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "selection.jl" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "test", FIXTURE_ROOT, local_root; mount_root = "/Volumes/cslg4")
    rundir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                      "jlevt", "phy", "p18", "r000")

    @testset "effective_mode" begin
        a = Node("a", joinpath(FIXTURE_ROOT, "temp"), :dir)
        b = Node("b", joinpath(FIXTURE_ROOT, "temp", "jl-dev"), :dir; parent = a)
        a.children = [b]
        @test effective_mode(b) == :none
        a.mode = :copy
        @test effective_mode(b) == :copy
        b.mode = :link
        @test effective_mode(b) == :link
    end

    @testset "set_mode! clears descendants, copy survives under link" begin
        root = production_tree(h, p)
        tier = root.children[findfirst(c -> c.label == "tier", root.children)]
        expand!(h, p, tier)
        jlevt = tier.children[1]
        expand!(h, p, jlevt)
        phy = jlevt.children[1]
        expand!(h, p, phy)
        p18 = phy.children[1]
        expand!(h, p, p18)
        r000 = p18.children[1]
        expand!(h, p, r000)

        set_mode!(r000.children[1], :copy)
        set_mode!(r000.children[2], :copy)
        @test [c.mode for c in r000.children] == [:copy, :copy]

        # :copy anywhere below a :link ancestor survives: copy a few files,
        # link the rest of the directory.
        set_mode!(jlevt, :link)
        @test jlevt.mode == :link
        @test [c.mode for c in r000.children] == [:copy, :copy]
        @test phy.mode == :none && p18.mode == :none && r000.mode == :none
        @test effective_mode(r000) == :link
        @test effective_mode(r000.children[1]) == :copy

        # Any other mode clears everything below it.
        set_mode!(jlevt, :copy)
        @test [c.mode for c in r000.children] == [:none, :none]
        @test_throws "mode must be" set_mode!(jlevt, :sideways)
    end

    @testset "exclude! pushes an inherited mode onto the siblings" begin
        hitdir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                          "jlhit", "cal", "p18", "r000")
        root = production_tree(h, p)
        r000 = find_node!(h, p, root, relpath(hitdir, FIXTURE_ROOT))
        @test length(r000.children) == 3

        set_mode!(r000, :copy)
        exclude!(r000.children[2])
        @test r000.mode == :none
        @test [c.mode for c in r000.children] == [:copy, :none, :copy]
        @test effective_mode(r000.children[2]) == :none

        sel = Selection(p, "cslg4", root)
        mandatory = [joinpath("test", "config.json"), "config_fixture.json",
                     joinpath("test", "legend-metadata")]
        @test setdiff(sel.copy, mandatory) ==
              sort([relative(p, r000.children[1].remote_path),
                    relative(p, r000.children[3].remote_path)])
    end

    @testset "exclude! pushes each level's own mode onto that level's siblings" begin
        # A synthetic tree, unrelated to the fixture on disk: exclude! only ever
        # touches Node.mode and the paths Selection() collects from it.
        node(label, rel; parent = nothing) = Node(label, joinpath(FIXTURE_ROOT, "synthetic", rel), :dir; parent)
        mandatory = [joinpath("test", "config.json"), "config_fixture.json",
                     joinpath("test", "legend-metadata")]

        @testset "a multi-level path clears every ancestor and marks every sibling" begin
            root = node("root", "a-root")
            anc = node("anc", "a-root/anc"; parent = root)
            kid1 = node("kid1", "a-root/anc/kid1"; parent = anc)
            kid2 = node("kid2", "a-root/anc/kid2"; parent = anc)
            anc.children = [kid1, kid2]
            gc1 = node("gc1", "a-root/anc/kid2/gc1"; parent = kid2)
            gc2 = node("gc2", "a-root/anc/kid2/gc2"; parent = kid2)
            kid2.children = [gc1, gc2]
            root.children = [anc]

            set_mode!(anc, :copy)
            exclude!(gc2)

            @test anc.mode == :none && kid2.mode == :none && gc2.mode == :none
            @test kid1.mode == :copy && gc1.mode == :copy
            @test effective_mode(gc2) == :none

            sel = Selection(p, "cslg4", root)
            @test setdiff(sel.copy, mandatory) ==
                  sort([relative(p, kid1.remote_path), relative(p, gc1.remote_path)])
            @test sel.link == String[]
        end

        @testset "a :link ancestor with a :copy descendant pushes each level's own mode" begin
            root = node("root", "b-root")
            anc = node("anc", "b-root/anc"; parent = root)
            kid1 = node("kid1", "b-root/anc/kid1"; parent = anc)
            kid2 = node("kid2", "b-root/anc/kid2"; parent = anc)
            anc.children = [kid1, kid2]
            gc1 = node("gc1", "b-root/anc/kid2/gc1"; parent = kid2)
            gc2 = node("gc2", "b-root/anc/kid2/gc2"; parent = kid2)
            kid2.children = [gc1, gc2]
            root.children = [anc]

            set_mode!(kid2, :copy)   # set before the link, so it survives the link below
            set_mode!(anc, :link)
            @test kid2.mode == :copy

            exclude!(gc2)

            @test anc.mode == :none && kid2.mode == :none && gc2.mode == :none
            @test kid1.mode == :link
            @test gc1.mode == :copy

            sel = Selection(p, "cslg4", root)
            @test setdiff(sel.copy, mandatory) == [relative(p, gc1.remote_path)]
            @test sel.link == [relative(p, kid1.remote_path)]
        end

        @testset "the production root can be the supplying ancestor" begin
            root = node("root", "c-root")
            x1 = node("x1", "c-root/x1"; parent = root)
            x2 = node("x2", "c-root/x2"; parent = root)
            root.children = [x1, x2]
            y1 = node("y1", "c-root/x2/y1"; parent = x2)
            y2 = node("y2", "c-root/x2/y2"; parent = x2)
            x2.children = [y1, y2]

            set_mode!(root, :copy)
            exclude!(y2)

            @test root.mode == :none && x2.mode == :none && y2.mode == :none
            @test x1.mode == :copy && y1.mode == :copy

            sel = Selection(p, "cslg4", root)
            @test setdiff(sel.copy, mandatory) ==
                  sort([relative(p, x1.remote_path), relative(p, y1.remote_path)])
            @test sel.link == String[]
        end
    end

    @testset "first_n_filekeys!" begin
        r000 = Node("r000", rundir, :dir)
        expand!(h, p, r000)
        @test first_n_filekeys!(r000, 1) == 1
        @test [c.mode for c in r000.children] == [:copy, :none]
        @test first_n_filekeys!(r000, 5) == 2
        @test [c.mode for c in r000.children] == [:copy, :copy]

        hitdir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                          "jlhit", "cal", "p18", "r000")
        hit = Node("r000", hitdir, :dir)
        expand!(h, p, hit)
        @test_throws "no filekey groups" first_n_filekeys!(hit, 1)
        @test_throws "has not been listed" first_n_filekeys!(Node("x", rundir, :dir), 1)
    end

    @testset "Selection requires a metadata root" begin
        no_metadata = Production(p.name, p.remote_root, p.local_root, p.mount_root,
                                 p.config, filter(kv -> first(kv) != "metadata", p.roots),
                                 p.overlays, p.config_file, p.setup_config)
        root = production_tree(h, no_metadata)
        @test_throws "has no \"metadata\" path key" Selection(no_metadata, "cslg4", root)
    end

    @testset "Selection round trip" begin
        root = production_tree(h, p)
        node = find_node!(h, p, root, relpath(rundir, FIXTURE_ROOT))
        @test node.label == "r000"
        set_mode!(node.children[1], :copy)

        raw = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")
        set_mode!(find_node!(h, p, root, relpath(raw, FIXTURE_ROOT)), :link)

        sel = Selection(p, "cslg4", root)
        @test sel.host == "cslg4"
        @test sel.production == "test"
        @test sel.mount_root == "/Volumes/cslg4"
        # config.json and legend-metadata are always copied (spec section 8).
        @test joinpath("test", "config.json") in sel.copy
        @test joinpath("test", "legend-metadata") in sel.copy
        @test "config_fixture.json" in sel.copy
        @test relpath(joinpath(rundir, "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"),
                      FIXTURE_ROOT) in sel.copy
        @test sel.link == [relpath(raw, FIXTURE_ROOT)]

        path = save_selection(joinpath(mktempdir(), "sync", "test.yaml"), sel)
        @test isfile(path)
        back = load_selection(path, p)
        @test back.copy == sel.copy
        @test back.link == sel.link
        @test back.mount_root == "/Volumes/cslg4"
        @test back.created == sel.created

        # A hand-written selection without copy entries still gets the mandatory ones.
        bare = Selection("cslg4", "test", sel.remote_root, sel.local_root, nothing,
                         String[], [first(sel.link)], sel.created)
        bare_path = save_selection(joinpath(mktempdir(), "bare.yaml"), bare)
        loaded = load_selection(bare_path, p)
        @test loaded.copy == sort(mandatory_copies(p))
        @test joinpath("test", "config.json") in loaded.copy
        @test joinpath("test", "legend-metadata") in loaded.copy
        @test loaded.link == bare.link
        @test loaded.host == "cslg4" && loaded.created == bare.created && loaded.mount_root === nothing

        # A selection without a mount root round-trips as nothing, not "".
        plain = Production(h, "test", FIXTURE_ROOT, local_root)
        sel2 = Selection(plain, "cslg4", production_tree(h, plain))
        path2 = save_selection(joinpath(mktempdir(), "test.yaml"), sel2)
        @test load_selection(path2, plain).mount_root === nothing
    end

    @testset "mismatch errors" begin
        root = production_tree(h, p)
        sel = Selection(p, "cslg4", root)
        path = save_selection(joinpath(mktempdir(), "test.yaml"), sel)

        other_dir = mktempdir()
        cp(joinpath(FIXTURE_ROOT, "test"), joinpath(other_dir, "test"))
        write(joinpath(other_dir, "test", "config.json"),
              replace(read(joinpath(FIXTURE_ROOT, "test", "config.json"), String),
                      FIXTURE_ROOT => other_dir))
        cp(joinpath(FIXTURE_ROOT, "temp"), joinpath(other_dir, "temp"))
        elsewhere = Production(h, "test", other_dir, local_root)
        @test_throws "has remote root" load_selection(path, elsewhere)

        renamed = Selection("cslg4", "preprod", sel.remote_root, sel.local_root,
                            nothing, sel.copy, sel.link, sel.created)
        path3 = save_selection(joinpath(mktempdir(), "preprod.yaml"), renamed)
        @test_throws "is for production preprod" load_selection(path3, p)
        # A selection belongs to the host its tree was built from.
        @test load_selection(path, p; host = sel.host).production == p.name
        @test_throws "saved for host $(sel.host), but the current host is other" load_selection(path, p; host = "other")
    end

    @testset "apply_selection! reconstructs the tree" begin
        root = production_tree(h, p)
        node = find_node!(h, p, root, relpath(rundir, FIXTURE_ROOT))
        set_mode!(node.children[2], :copy)
        sel = Selection(p, "cslg4", root)

        fresh = production_tree(h, p)
        apply_selection!(h, p, fresh, sel)
        rebuilt = find_node!(h, p, fresh, relpath(rundir, FIXTURE_ROOT))
        @test [c.mode for c in rebuilt.children] == [:none, :copy]
        @test effective_mode(find_node!(h, p, fresh, joinpath("test", "legend-metadata"))) == :copy

        @test_throws "is not in the production tree" find_node!(h, p, fresh, joinpath("temp", "nope"))
    end

    @testset "a nested production copies its overlays and keeps its path" begin
        n = Production(h, "temp/jl-dev", FIXTURE_ROOT, local_root)
        sel = Selection(n, "cslg4", production_tree(h, n))
        @test sel.production == "temp/jl-dev"
        @test sel.copy == sort(["temp/jl-dev/config.json", "config_fixture.json",
                                "temp/config_site.yaml", "temp/jl-dev/legend-metadata"])
        path = save_selection(joinpath(mktempdir(), "temp-jl-dev.yaml"), sel)
        @test load_selection(path, n).production == "temp/jl-dev"
        @test_throws "is for production temp/jl-dev" load_selection(path, p)
        root = production_tree(h, n)
        apply_selection!(h, n, root, sel)
        @test effective_mode(find_node!(h, n, root, "temp/jl-dev/legend-metadata")) == :copy
    end
end
