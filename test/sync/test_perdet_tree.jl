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

    @testset "run-level group rows are unchanged" begin
        period = listed_period()
        run = only(filter(c -> c.label == "r000", period.children))
        expand!(h, p, run; detectors = true)
        @test [(c.label, c.size) for c in run.children] == [("B00000C", 100), ("V01234A", 200)]
        @test all(c -> !c.whole_files, run.children)
    end
end
