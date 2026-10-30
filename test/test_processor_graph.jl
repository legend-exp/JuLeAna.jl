# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Test

@testset "processor graph" begin
    rspec(name, rank; deps = Symbol[]) = ProcessorSpec(; name, level = :run, category = :cal, rank, dependencies = deps)
    pspec(name, rank; deps = Symbol[]) = ProcessorSpec(; name, level = :partition, category = :cal, rank, dependencies = deps)
    edge(g, u, v) = JuLeAna.Graphs.has_edge(g.graph, findfirst(==(u), g.names), findfirst(==(v), g.names))
    # every edge goes from a lower to a higher layer, and the positions of each layer are 1:n
    function valid_layout(g, layout)
        edges_ok = all(e -> first(layout[JuLeAna.Graphs.src(e)]) < first(layout[JuLeAna.Graphs.dst(e)]), JuLeAna.Graphs.edges(g.graph))
        layers_ok = all(unique(first.(layout))) do l
            sort([p for (k, p) in layout if k == l]) == 1:count(x -> first(x) == l, layout)
        end
        return edges_ok && layers_ok
    end

    @testset "chain within a level" begin
        g = processor_graph([rspec(:c, 3; deps = [:b]), rspec(:a, 1), rspec(:b, 2; deps = [:a])])
        @test topological_order(g) == [:a, :b, :c]
        @test edge(g, :a, :b) && edge(g, :b, :c) && !edge(g, :a, :c)
        @test required_processors(g, [:c]) == Set([:a, :b, :c])
        layout = layered_layout(g)
        @test [first(layout[findfirst(==(n), g.names)]) for n in (:a, :b, :c)] == [1, 2, 3]
        @test valid_layout(g, layout)
        # processors without dependencies are not ordered by rank: both are in the first layer
        g = processor_graph([rspec(:y, 1), rspec(:x, 2)])
        @test isempty(JuLeAna.Graphs.edges(g.graph)) && first.(layered_layout(g)) == [1, 1]
        # equal ranks are listed by name
        @test topological_order(processor_graph([rspec(:y, 1), rspec(:x, 1)])) == [:x, :y]
    end

    @testset "dependencies across levels" begin
        specs = [rspec(:r1, 1), rspec(:r2, 2; deps = [:r1]), rspec(:r3, 3; deps = [:r2, :p2]), pspec(:p1, 1; deps = [:r2]),
                 pspec(:p2, 2; deps = [:p1])]
        g = processor_graph(specs)
        @test edge(g, :r2, :p1) && edge(g, :p2, :r3) && edge(g, :p1, :p2)
        @test !edge(g, :r1, :p1)
        @test required_processors(g, [:r3]) == Set([:r3, :p2, :p1, :r2, :r1])
        @test required_processors(g, [:p2]) == Set([:p2, :p1, :r2, :r1])
        @test dependent_processors(g, [:r2]) == Set([:r2, :p1, :p2, :r3])
        @test dependent_processors(g, [:p2]) == Set([:p2, :r3])
        @test dependent_processors(g, [:r3]) == Set([:r3])
        @test all(a -> all(b -> (b in required_processors(g, [a])) == (a in dependent_processors(g, [b])), g.names), g.names)
        order = topological_order(g)
        for e in JuLeAna.Graphs.edges(g.graph)
            @test findfirst(==(g.names[JuLeAna.Graphs.src(e)]), order) < findfirst(==(g.names[JuLeAna.Graphs.dst(e)]), order)
        end
        @test valid_layout(g, layered_layout(g))
    end

    @testset "diamond" begin
        g = processor_graph([rspec(:a, 1), pspec(:b, 1; deps = [:a]), pspec(:c, 2; deps = [:a, :b]), rspec(:d, 2; deps = [:c])])
        @test required_processors(g, [:d]) == Set([:a, :b, :c, :d])
        layout = layered_layout(g)
        @test valid_layout(g, layout)
        @test first(layout[findfirst(==(:d), g.names)]) == 4
    end

    @testset "cycles and bad input" begin
        @test_throws "form a cycle" processor_graph([rspec(:r2, 2; deps = [:p1]), rspec(:r3, 3; deps = [:r2]), pspec(:p1, 1; deps = [:r3])])
        err = try
            processor_graph([rspec(:r1, 1; deps = [:p1]), pspec(:p1, 1; deps = [:r1]), rspec(:r0, 0)])
        catch e
            e
        end
        @test err isa ArgumentError && occursin("p1, r1", err.msg) && !occursin("r0", err.msg)
        @test_throws "unknown processor `nope`" processor_graph([rspec(:r1, 1; deps = [:nope])])
        @test_throws "must be unique" processor_graph([rspec(:r1, 1), pspec(:r1, 1)])
        @test_throws "form a cycle" ProcessingConfig(; processors = Dict(:r1 => rspec(:r1, 1; deps = [:p1])),
                                                     p_processors = Dict(:p1 => pspec(:p1, 1; deps = [:r1])))
    end

    @testset "waited processors" begin
        # r1 → r2 → r3 → r4 (run), r2 → p1 → p2 → r4
        specs = [rspec(:r1, 1), rspec(:r2, 2; deps = [:r1]), rspec(:r3, 3; deps = [:r2]), rspec(:r4, 4; deps = [:r3, :p2]),
                 pspec(:p1, 1; deps = [:r2]), pspec(:p2, 2; deps = [:p1])]
        g = processor_graph(specs)
        # all selected: each step waits for its direct predecessors
        w = waited_processors(g, [:r1, :r2, :r3, :r4, :p1, :p2])
        @test w[:r1] == Pair{Symbol,Bool}[]
        @test w[:r2] == [:r1 => true]
        @test w[:p1] == [:r2 => false]
        @test w[:p2] == [:p1 => false]
        @test w[:r4] == [:p2 => false, :r3 => true]
        # p2 waits for what the unselected p1 before it waits for, in all runs
        @test waited_processors(g, [:r1, :r2, :p2])[:p2] == [:r2 => false]
        # r4 waits for r2 through the unselected p1 and p2, so in all runs, and for r2
        # in its own run through r3: the wait in all runs covers both
        @test waited_processors(g, [:r2, :r4])[:r4] == [:r2 => false]
        # through run steps only, the wait is for the same run
        @test waited_processors(g, [:r1, :r3])[:r3] == [:r1 => true]
        @test isempty(waited_processors(g, [:p2])[:p2])

        # r2 has the chains r3 → r4 and p1 → p2 → r4, and four processors after it
        chains = JuLeAna.waiting_chains(w)
        @test chains[:r1] == (; chain = 4, successors = 5)
        @test chains[:r2] == (; chain = 3, successors = 4)
        @test chains[:p1] == (; chain = 2, successors = 2)
        @test chains[:r3] == chains[:p2] == (; chain = 1, successors = 1)
        @test chains[:r4] == (; chain = 0, successors = 0)
        # only selected processors count
        @test JuLeAna.waiting_chains(waited_processors(g, [:r2, :r4]))[:r2] == (; chain = 1, successors = 1)
    end

    @testset "configs and snapshot entries" begin
        cfg = ProcessingConfig(joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        g = processor_graph(cfg)
        @test Set(g.names) == union(keys(cfg.processors), keys(cfg.p_processors))
        @test !JuLeAna.Graphs.is_cyclic(g.graph)
        @test valid_layout(g, layered_layout(g))
        # any objects with name, level, rank and dependencies work, e.g. snapshot entries
        entries = [(; name = :a, level = :run, rank = 1, dependencies = Symbol[]),
                   (; name = :b, level = :partition, rank = 1, dependencies = [:a])]
        @test topological_order(processor_graph(entries)) == [:a, :b]
    end
end
