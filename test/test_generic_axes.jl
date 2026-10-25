# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Functions taking `AbstractArray` arguments must give the same values for offset and
# lazily wrapped inputs, and an index-matched result must carry the input axes.

using JuLeAna
using Test
using OffsetArrays: OffsetArray
using LegendDataManagement: LegendDataManagement, FileKey, DataPeriod, DataRun, ProcessStatus

# Stands in for `LegendData`: every run is in the run info.
struct AxesFakeData end
LegendDataManagement.is_lrun(::AxesFakeData, key) = true

@testset "generic axes" begin
    FkLog = NamedTuple{(:Filekey, :Status, :A, :B, :Error)}
    filekeys = [FileKey("l200-p03-r00$i-cal-20230311T235840Z") for i in 0:3]
    row(k) = (processed = true, log = FkLog((k, ProcessStatus(1), "a", "b", "")))

    # `parallel` returns one pair per item, so the result axes track the iterator.
    @testset "parallel: $name" for (name, x) in (("vec", filekeys), ("mat", reshape(filekeys, 2, 2)))
        ref = parallel(row, x, FkLog)
        @test axes(ref) == axes(x)
        @test all(i -> ref[i].first == x[i], eachindex(x, ref))

        xo = OffsetArray(x, ntuple(_ -> -2, ndims(x)))
        yo = parallel(row, xo, FkLog)
        @test collect(yo) == collect(ref)
        @test axes(yo) == axes(xo)

        @test parallel(row, view(x, ntuple(_ -> Colon(), ndims(x))...), FkLog) == ref
    end

    @testset "watch_tasks: $name" for (name, wrap) in (("offset", x -> OffsetArray(x, -3)), ("view", x -> view(x, :)))
        finished = Threads.Atomic{Int}(0)
        tasks = wrap([Threads.@spawn sleep(0.02 * k) for k in 1:4])
        watcher = Threads.@spawn JuLeAna.watch_tasks(() -> Threads.atomic_add!(finished, 1), tasks; poll = 0.01)
        @test timedwait(() -> istaskdone(watcher), 10) === :ok
        @test finished[] == length(tasks)
    end

    @testset "parse_commandline" begin
        args = ["-c", "x.json", "-p", "3", "4", "-r", "1", "2", "--reprocess"]
        @test JuLeAna.parse_commandline(OffsetArray(args, -5)) == JuLeAna.parse_commandline(args)
    end

    # Periods and step lists are consumed as collections: offset axes must not change
    # which steps run or which status entries are set.
    @testset "run_processing" begin
        p3 = DataPeriod(3)
        runs = DataRun.(1:2)
        calls = Tuple{Symbol,DataPeriod}[]
        calls_lock = ReentrantLock()
        record!(step, period) = lock(() -> push!(calls, (step, period)), calls_lock)
        run_a(cfg, l200, period, run; reprocess::Bool = false) = (record!(:run_a, period); nothing)
        p_part_b(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = (record!(:p_part_b, period); false)
        cfg = ProcessingConfig(; processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
                               p_processors = Dict(:p_part_b =>
                                                       ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal, rank = 1,
                                                                     dependencies = [:run_a])))
        stubs = Dict{Symbol,Any}(:run_a => run_a, :p_part_b => p_part_b)
        run_status, partition_status = JuLeAna.RunStatus(), JuLeAna.PartitionStatus()
        run_status[p3] = Dict{Symbol,Dict{DataRun,Bool}}([:run_a => Dict{DataRun,Bool}(runs .=> false)])
        partition_status[p3] = Dict{Symbol,Bool}([:p_part_b => false])

        periods = OffsetArray([p3], -1)
        run_steps, partition_steps = OffsetArray([:run_a], 5), OffsetArray([:p_part_b], -2)
        run_processing(cfg, AxesFakeData(), periods, run_steps, partition_steps, run_status, partition_status; processors = stubs,
                       check_dependencies = false)
        @test count(==((:run_a, p3)), calls) == length(runs)
        @test count(==((:p_part_b, p3)), calls) == 1
        @test all(values(run_status[p3][:run_a])) && partition_status[p3][:p_part_b]

        @test_throws "unregistered processor(s) p_part_b" run_processing(cfg, AxesFakeData(), periods, OffsetArray(Symbol[], 3),
                                                                         partition_steps, run_status, partition_status;
                                                                         processors = Dict{Symbol,Any}(:run_a => run_a))
    end
end
