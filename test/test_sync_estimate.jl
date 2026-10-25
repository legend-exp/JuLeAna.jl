# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "estimate.jl" begin
    @testset "format_bytes" begin
        @test format_bytes(0) == "0 B"
        @test format_bytes(1023) == "1023 B"
        @test format_bytes(1024) == "1.0 K"
        @test format_bytes(4096 + 8192) == "12.0 K"
        @test format_bytes(27 * 1024^3) == "27.0 G"
    end

    @testset "running_estimate" begin
        root = Node("root", "/r", :production)
        dir = Node("dir", "/r/dir", :dir; size = 3000, parent = root)
        a = Node("a", "/r/dir/a", :group; size = 1000, parent = dir)
        b = Node("b", "/r/dir/b", :group; size = 2000, parent = dir)
        unsized = Node("u", "/r/u", :dir; parent = root)
        root.children = [dir, unsized]
        dir.children = [a, b]

        @test running_estimate(root) == Estimate(0, 0, 0, true)
        @test format_estimate(running_estimate(root)) ==
              "selected: 0 B copy (0 files), 0 links"

        set_mode!(a, :copy)
        @test running_estimate(root) == Estimate(1000, 1, 0, true)

        # Copying the parent counts the parent once, not the parent plus children.
        set_mode!(dir, :copy)
        @test running_estimate(root) == Estimate(3000, 0, 0, true)

        # A selected node with no fetched size makes the total incomplete.
        set_mode!(unsized, :copy)
        est = running_estimate(root)
        @test est.bytes == 3000
        @test est.complete == false
        @test format_estimate(est) == "selected: 2.9 K? copy (0 files), 0 links"

        # A copy inside a link is counted; the link itself contributes no bytes.
        set_mode!(dir, :link)
        set_mode!(unsized, :none)
        set_mode!(a, :copy)
        set_mode!(b, :copy)
        @test running_estimate(root) == Estimate(3000, 2, 1, true)
    end

    @testset "parse_rsync_stats" begin
        captured = """
        Number of files: 3 (reg: 2, dir: 1)
        Number of created files: 3 (reg: 2, dir: 1)
        Number of deleted files: 0
        Number of regular files transferred: 2
        Total file size: 12,288 bytes
        Total transferred file size: 12,288 bytes
        Literal data: 0 bytes
        Matched data: 0 bytes
        File list size: 0
        File list generation time: 0.001 seconds
        File list transfer time: 0.000 seconds
        Total bytes sent: 143
        Total bytes received: 24

        sent 143 bytes  received 24 bytes  334.00 bytes/sec
        total size is 12,288  speedup is 73.58 (DRY RUN)
        """
        @test parse_rsync_stats(captured, 3) == Estimate(12288, 2, 3, true)
        @test format_estimate(parse_rsync_stats(captured, 3)) ==
              "selected: 12.0 K copy (2 files), 3 links"
        @test_throws "printed no transfer totals" parse_rsync_stats("rsync: nope\n", 0)
    end
end
