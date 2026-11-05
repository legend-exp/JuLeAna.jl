# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    ProcessorGraph

Dependency graph of the run-level and partition-level processors of a configuration, as
returned by [`processor_graph`](@ref).

Node `i` is the processor `names[i]` of level `levels[i]` (`:run` or `:partition`) and
rank `ranks[i]`. An edge `u → v` of `graph` (a `Graphs.SimpleDiGraph`) means that `v`
names `u` in its `dependencies`: `u` must finish before `v`, in a period, starts.
Processors that no path connects can run at the same time.
"""
struct ProcessorGraph
    names::Vector{Symbol}
    levels::Vector{Symbol}
    ranks::Vector{Int}
    graph::Graphs.SimpleDiGraph{Int}
end

"""
    processor_graph(cfg::ProcessingConfig)
    processor_graph(specs)

Return the [`ProcessorGraph`](@ref) of all processors of `cfg`, enabled or not, or of
`specs`, an iterable of objects with the properties `name`, `level` (`:run` or
`:partition`), `rank` and `dependencies` like [`ProcessorSpec`](@ref).

Throws an `ArgumentError` if a processor name occurs twice, a dependency names an unknown
processor, or the dependencies form a cycle: processing would then wait forever. The
error names the processors of the cycle.
"""
function processor_graph(cfg::ProcessingConfig)
    return processor_graph(vcat(collect(values(cfg.processors)), collect(values(cfg.p_processors))))
end

function processor_graph(specs)
    specs = collect(specs)
    names = [Symbol(s.name) for s in specs]
    allunique(names) || throw(ArgumentError("processor graph: processor names must be unique, got $(names)"))
    index = Dict(n => i for (i, n) in pairs(names))
    graph = Graphs.SimpleDiGraph(length(names))
    for (v, s) in pairs(specs), dep in s.dependencies

        u = get(index, Symbol(dep), nothing)
        isnothing(u) && throw(ArgumentError("processor graph: `$(names[v])` depends on unknown processor `$dep`"))
        Graphs.add_edge!(graph, u, v)
    end
    if Graphs.is_cyclic(graph)
        cycles = filter(c -> length(c) > 1 || Graphs.has_edge(graph, c[1], c[1]), Graphs.strongly_connected_components(graph))
        throw(ArgumentError("processor graph: the dependencies of these processors form a cycle, " *
                            "so processing would wait forever: " *
                            join((join(sort(names[c]), ", ") for c in cycles), "; ")))
    end
    return ProcessorGraph(names, [Symbol(s.level) for s in specs], [Int(s.rank) for s in specs], graph)
end

"""
    topological_order(g::ProcessorGraph)

Return the processor names of `g` in an order in which every processor comes after all
processors it waits for. Among processors that are free at the same point, run-level
processors come first, then lower rank, then name.
"""
topological_order(g::ProcessorGraph) = g.names[topological_nodes(g)]

function topological_nodes(g::ProcessorGraph)
    indegree = [length(Graphs.inneighbors(g.graph, v)) for v in Graphs.vertices(g.graph)]
    key(v) = (g.levels[v] === :run ? 0 : 1, g.ranks[v], g.names[v])
    free = sort!([v for v in Graphs.vertices(g.graph) if indegree[v] == 0]; by = key)
    result = Int[]
    while !isempty(free)
        v = popfirst!(free)
        push!(result, v)
        for w in Graphs.outneighbors(g.graph, v)
            indegree[w] -= 1
            indegree[w] == 0 && push!(free, w)
        end
        sort!(free; by = key)
    end
    return result
end

"""
    required_processors(g::ProcessorGraph, names)

Return the set of the processors in `names` together with all processors they depend on,
directly or through other processors.
"""
function required_processors(g::ProcessorGraph, names)
    index = Dict(n => i for (i, n) in pairs(g.names))
    chosen = Set{Symbol}(Symbol.(names))
    todo = [index[n] for n in chosen]
    while !isempty(todo)
        v = pop!(todo)
        for u in Graphs.inneighbors(g.graph, v)
            g.names[u] in chosen || (push!(chosen, g.names[u]); push!(todo, u))
        end
    end
    return chosen
end

"""
    waited_processors(g::ProcessorGraph, selected)

Return a `Dict` that maps each processor in `selected` to the selected processors it waits
for: the nearest selected processors before it in `g`, reached through processors that
are not selected. A processor that is not selected passes on what it waits for, so
selecting a processor without the ones it depends on keeps their requirements.

Each entry is a vector of pairs `name => same_run`. `same_run` is `true` for a run-level
processor that a run-level processor waits for through run-level processors only: the
wait is for the same run. Otherwise a run-level processor is waited for in all runs, and
a partition-level processor in the same period.
"""
function waited_processors(g::ProcessorGraph, selected)
    index = Dict(n => i for (i, n) in pairs(g.names))
    chosen = Set{Int}(index[Symbol(n)] for n in selected)
    result = Dict{Symbol,Vector{Pair{Symbol,Bool}}}()
    for v in chosen
        waits = Dict{Int,Bool}()
        # `same_run`: the path from the node to `v` has only run-level processors
        seen = Set{Tuple{Int,Bool}}()
        todo = [(v, g.levels[v] === :run)]
        while !isempty(todo)
            w, same_run = pop!(todo)
            for u in Graphs.inneighbors(g.graph, w)
                if u in chosen
                    waits[u] = get(waits, u, true) && same_run && g.levels[u] === :run
                else
                    state = (u, same_run && g.levels[u] === :run)
                    state in seen || (push!(seen, state); push!(todo, state))
                end
            end
        end
        result[g.names[v]] = sort!([g.names[u] => s for (u, s) in waits]; by = first)
    end
    return result
end

"""
    JuLeAna.waiting_chains(waits::AbstractDict)

For the processors of `waits`, a `Dict` like [`waited_processors`](@ref) returns, return a
`Dict` that maps each processor to `(; chain, successors)`: `chain` is the number of
processors in the longest chain of processors of `waits` that wait for it, one after the
other, and `successors` the number of processors of `waits` that wait for it, directly or
through other processors. Both are 0 for a processor that no processor waits for.
"""
function waiting_chains(waits::AbstractDict)
    dependents = Dict{Symbol,Vector{Symbol}}(step => Symbol[] for step in keys(waits))
    for (step, waited) in waits, (u, _) in waited

        push!(dependents[u], step)
    end
    chain = Dict{Symbol,Int}()
    function chain_of(step)
        haskey(chain, step) && return chain[step]
        return chain[step] = maximum((1 + chain_of(d) for d in dependents[step]); init = 0)
    end
    function successors(step)
        seen, todo = Set{Symbol}(), copy(dependents[step])
        while !isempty(todo)
            d = pop!(todo)
            d in seen || (push!(seen, d); append!(todo, dependents[d]))
        end
        return length(seen)
    end
    return Dict(step => (; chain = chain_of(step), successors = successors(step)) for step in keys(waits))
end

"""
    dependent_processors(g::ProcessorGraph, names)

Return the set of the processors in `names` together with all processors that depend on
one of them, directly or through other processors. This is the reverse of
[`required_processors`](@ref): `b` is in `required_processors(g, [a])` exactly if `a` is
in `dependent_processors(g, [b])`.
"""
function dependent_processors(g::ProcessorGraph, names)
    index = Dict(n => i for (i, n) in pairs(g.names))
    chosen = Set{Symbol}(Symbol.(names))
    todo = [index[n] for n in chosen]
    while !isempty(todo)
        u = pop!(todo)
        for v in Graphs.outneighbors(g.graph, u)
            g.names[v] in chosen || (push!(chosen, g.names[v]); push!(todo, v))
        end
    end
    return chosen
end

"""
    layered_layout(g::ProcessorGraph)

Place the processors of `g` in layers for drawing: return a vector with one `(layer,
position)` pair per node of `g`, both starting at 1. The layer of a processor is one more
than the highest layer of the processors it depends on, so every edge points to a higher
layer. Within a layer, processors are
ordered to reduce edge crossings: by the mean position of their neighbors in the layers
above, then below, a few times over.
"""
function layered_layout(g::ProcessorGraph)
    nodes = Graphs.vertices(g.graph)
    layer = ones(Int, length(nodes))
    for v in topological_nodes(g), u in Graphs.inneighbors(g.graph, v)

        layer[v] = max(layer[v], layer[u] + 1)
    end
    layers = [sort!([v for v in nodes if layer[v] == l]; by = v -> (g.levels[v] === :run ? 0 : 1, g.ranks[v], g.names[v]))
              for l in 1:maximum(layer; init = 0)]
    position = zeros(Int, length(nodes))
    renumber!(l) = foreach(((p, v),) -> position[v] = p, pairs(layers[l]))
    foreach(renumber!, eachindex(layers))
    for _ in 1:4,
        (range, neighbors) in
        ((2:length(layers), v -> Graphs.inneighbors(g.graph, v)), ((length(layers) - 1):-1:1, v -> Graphs.outneighbors(g.graph, v)))

        for l in range
            barycenter(v) = (ns = neighbors(v); isempty(ns) ? position[v] : sum(position[ns]) / length(ns))
            sort!(layers[l]; by = barycenter)
            renumber!(l)
        end
    end
    return [(layer[v], position[v]) for v in nodes]
end
