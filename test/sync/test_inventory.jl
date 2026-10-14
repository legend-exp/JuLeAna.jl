@testset "inventory.jl" begin
    h = LocalHost()
    local_root = mktempdir()
    p = Production(h, "test", FIXTURE_ROOT, local_root)

    @testset "tier_file_id" begin
        @test tier_file_id("l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5") ==
              (:filekey, "20251107T191821Z")
        @test tier_file_id("l200-p18-r000-cal-B00000C-tier_jlhit.lh5") ==
              (:detector, "B00000C")
        @test tier_file_id("l200-p18-r000-cal-V01234A-tier_jlhit.lh5") ==
              (:detector, "V01234A")
        # Non-LEGEND names are not an error: READMEs and scratch files occur.
        @test tier_file_id("README.txt") === nothing
        @test tier_file_id("l200-p18-r000-cal-nonsense-tier_jlhit.lh5") === nothing
    end

    @testset "production_tree" begin
        root = production_tree(h, p)
        @test root.kind == :production
        @test root.label == "Production: test"
        @test [c.label for c in root.children] ==
              ["config.json", "metadata", "par", "tier", "tier/jlhit", "tier/jlpks"]
        @test root.children[1].kind == :file
        @test root.children[1].size > 0
        @test all(c -> c.kind == :section, root.children[2:end])
        # Section sizes stay unknown: sizing tier/raw at startup is not affordable.
        @test all(c -> c.size === nothing, root.children[2:end])
        @test all(c -> c.parent === root, root.children)
        @test root.local_state == :missing
    end

    @testset "lazy expansion and directory sizes" begin
        root = production_tree(h, p)
        tier = root.children[findfirst(c -> c.label == "tier", root.children)]
        @test tier.children === nothing
        expand!(h, p, tier)
        @test [c.label for c in tier.children] == ["jlevt", "jlhit"]
        @test all(c -> c.kind == :dir, tier.children)
        @test tier.children[1].size == 4096 + 8192
        @test tier.children[2].size == 2048 + 1024 + 18
        # Expanding twice must not list twice.
        listed = tier.children
        expand!(h, p, tier)
        @test tier.children === listed
        @test_throws "cannot be expanded" expand!(h, p, root.children[1])
    end

    @testset "filekey grouping" begin
        dir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                       "jlevt", "phy", "p18", "r000")
        node = Node("r000", dir, :dir)
        expand!(h, p, node)
        @test [c.kind for c in node.children] == [:group, :group]
        # Timestamp order, not readdir order.
        @test [c.label for c in node.children] ==
              ["20251107T191821Z", "20251107T192416Z"]
        @test [c.size for c in node.children] == [4096, 8192]
        # A group stands for exactly one file and carries it as its child.
        file = only(node.children[1].children)
        @test file.kind == :file
        @test file.label == "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"
        @test file.parent === node.children[1]
        @test [g.label for g in filekey_groups(node)] ==
              ["20251107T191821Z", "20251107T192416Z"]
    end

    @testset "detector grouping and unparseable names" begin
        dir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                       "jlhit", "cal", "p18", "r000")
        node = Node("r000", dir, :dir)
        expand!(h, p, node)
        @test [(c.label, c.kind) for c in node.children] ==
              [("B00000C", :group), ("V01234A", :group), ("README.txt", :file)]
        @test isempty(filekey_groups(node))
    end

    @testset "detectors row comes first" begin
        base = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18")
        run = Node("r000", joinpath(base, "r000"), :dir)
        expand!(h, p, run; detectors = true)
        @test first(run.children).kind == :detectors
        @test [c.kind for c in run.children] == [:detectors, :group, :group]
        period = Node("p18", base, :dir)
        expand!(h, p, period; detectors = true)
        @test first(period.children).kind == :detectors
        @test ensure_detectors!(period) === first(period.children)
    end

    @testset "local_state" begin
        dir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                       "jlevt", "phy", "p18", "r000")
        node = Node("r000", dir, :dir)
        expand!(h, p, node)
        @test node_local_state(p, node) == :missing

        # One of the two files now present locally: the directory is partial.
        target = to_local(p, joinpath(dir, "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"))
        mkpath(dirname(target))
        write(target, zeros(UInt8, 4096))
        @test node_local_state(p, node) == :partial

        write(to_local(p, joinpath(dir, "l200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5")),
              zeros(UInt8, 8192))
        @test node_local_state(p, node) == :present

        linked = joinpath(local_root, "a-link")
        symlink("/nowhere", linked)
        @test node_local_state(p, Node("x", joinpath(FIXTURE_ROOT, "a-link"), :dir)) == :linked
    end
end
