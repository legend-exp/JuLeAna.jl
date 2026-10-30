# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Test
using Logging: Logging, ConsoleLogger, NullLogger, with_logger
using Serialization: deserialize
using Distributed: Distributed, addprocs, myid, rmprocs, @everywhere
using LegendDataManagement: LegendDataManagement, DataPeriod, DataRun, FileKey, LegendData, lreport
using LegendDataManagement.LDMUtils: create_logtbl
using ParallelProcessingTools: FlexWorkerPool, ppt_worker_pool, ppt_worker_pool!

module LegendRunStepTest
ping(det) = @debug "debug of $det"
end

# Records what `display` hands to it: shown text as is, `image/png` as `mime => x`.
struct RecordingDisplay <: AbstractDisplay
    shown::Vector{Any}
end
Base.display(d::RecordingDisplay, x) = (push!(d.shown, x); nothing)
function Base.display(d::RecordingDisplay, mime::MIME"image/png", x)
    return (push!(d.shown, mime => x); nothing)
end

# Stands in for the VS Code plot pane: records the HTML pages it is handed.
struct PlotPaneDisplay <: AbstractDisplay
    shown::Vector{Any}
end
function Base.displayable(::PlotPaneDisplay, ::MIME"application/vnd.julia-vscode.plotpane+html")
    return true
end
function Base.display(d::PlotPaneDisplay, ::MIME"application/vnd.julia-vscode.plotpane+html", x)
    return (push!(d.shown, x); nothing)
end

# Stands in for `LegendData`: every run is in the run info, and every period is its own
# partition.
struct FakeData end
LegendDataManagement.is_lrun(::FakeData, key) = true
JuLeAna.partition_periods(::FakeData, period) = [period]
# Periods 3 and 4 share a partition.
struct SpanData end
LegendDataManagement.is_lrun(::SpanData, key) = true
function JuLeAna.partition_periods(::SpanData, period)
    return period.no in (3, 4) ? DataPeriod.([3, 4]) : [period]
end
# Runs that are in the run info but are no analysis runs.
struct NoAnalysisData end
LegendDataManagement.is_lrun(::NoAnalysisData, key) = true
LegendDataManagement.is_analysis_run(::NoAnalysisData, key) = false
# Runs that are not in the run info.
struct NoRunData end
LegendDataManagement.is_lrun(::NoRunData, key) = false
JuLeAna.partition_periods(::Union{NoAnalysisData,NoRunData}, period) = [period]

function stub_status(periods, runs, run_steps, partition_steps)
    run_status, partition_status = JuLeAna.RunStatus(), JuLeAna.PartitionStatus()
    for p in periods
        run_status[p] = Dict{Symbol,Dict{DataRun,Bool}}([s => Dict{DataRun,Bool}(runs .=> false) for s in run_steps])
        partition_status[p] = Dict{Symbol,Bool}([s => false for s in partition_steps])
    end
    return run_status, partition_status
end

const REPORT = """
# Energy calibration
| Key | Value |
|:---|:---|
| Period | p03 |

| Detector | Status | Filter Type | Error |
|:---|:---|:---|:---|
| V01 | <span style="color:green">Success</span> | trap | - |
| V02 | <span style="color:red">Failure</span> | trap | fit failed |

| Filekey | Status | Failed Detectors |
|:---|:---|:---|
| l200-p03-r001-cal-20230101T000000Z | Failure | ["V03", "V04"] |
"""

@testset "dataflow" begin
    @testset "processor registry" begin
        @test length(JuLeAna.PROCESSORS) == 32
        @test all(((name, f),) -> nameof(f) === name, JuLeAna.PROCESSORS)
        @test all(name -> occursin(r"^(p_)?process_", string(name)), keys(JuLeAna.PROCESSORS))
        @test count(name -> startswith(string(name), "p_process_"), keys(JuLeAna.PROCESSORS)) == 12

        n = length(JuLeAna.PROCESSORS)
        @test_throws "processor `process_dsp_cal` is already registered" JuLeAna.register_processor!(JuLeAna.process_dsp_cal)
        @test length(JuLeAna.PROCESSORS) == n
    end

    @testset "parse_commandline" begin
        args = JuLeAna.parse_commandline(["-c", "x.json", "-p", "3", "-r", "1", "2", "--reprocess"])
        @test args["config"] == "x.json"
        @test args["periods"] == [["3"]]
        @test args["runs"] == [[1, 2]]
        @test args["reprocess"]
        @test !args["only_runs"] && !args["only_partitions"] && !args["submit_jobs"]
        @test !args["analysis_runs_only"] && !args["ignore_config"] && !args["no_tui"]
        @test isnothing(args["runmode"])
        @test args["log_path"] == ""
        @test isnothing(args["processor_log_level"])
        @test JuLeAna.parse_commandline(["-c", "x.json", "--processor-log-level", "warn"])["processor_log_level"] == "warn"
        @test isnothing(args["processor_plot_level"])
        @test JuLeAna.parse_commandline(["-c", "x.json", "--processor-plot-level", "debug"])["processor_plot_level"] == "debug"

        args = JuLeAna.parse_commandline(["-c", "x.json", "-p", "3", "4", "-p", "6", "--rm", "slurm", "--op"])
        @test args["periods"] == [["3", "4"], ["6"]]
        @test isempty(args["runs"])
        @test args["runmode"] == "slurm"
        @test args["only_partitions"]

        @test JuLeAna.parse_commandline(["-c", "x.json", "-p", "6,1-3", "-p", "7,2"])["periods"] == [["6,1-3"], ["7,2"]]
        @test JuLeAna.parse_commandline(["-c", "x.json", "--no-tui"])["no_tui"]
        @test JuLeAna.parse_commandline(["-c", "x.json", "--no_tui"])["no_tui"]
    end

    @testset "setup folder of the data production" begin
        production = mktempdir()
        withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.yaml")) do
            @test JuLeAna.production_setup_dir() == joinpath(production, "setup")
            @test !ispath(joinpath(production, "setup"))
            mkpath(joinpath(production, "setup", "config"))
            @test JuLeAna.production_setup_dir() == joinpath(production, "setup")
        end
        for (old, new) in ("config" => "setup/config", "software" => "setup/software", "metadata-records" => "setup/metadata")
            legacy = mktempdir()
            mkpath(joinpath(legacy, old))
            withenv("LEGEND_DATA_CONFIG" => joinpath(legacy, "config.yaml")) do
                @test_throws ArgumentError JuLeAna.production_setup_dir()
                @test_throws "$legacy" JuLeAna.production_setup_dir()
                @test_throws "$old/ to $new/" JuLeAna.production_setup_dir()
                @test_throws "$old/ to $new/" JuLeAna.production_config_dir()
            end
        end
    end

    @testset "config folder of the data production" begin
        production = mktempdir()
        shipped = joinpath(dirname(@__DIR__), "config", "processing_config.yaml")
        withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
            @test JuLeAna.production_config_dir() == joinpath(production, "setup", "config")
            # without --config: the shipped config is copied into the production
            installed = joinpath(production, "setup", "config", "processing_config.yaml")
            @test JuLeAna.default_config_file() == installed && !ispath(installed)
            @test_logs (:info, r"Copied the processing config shipped with JuLeAna") @test JuLeAna.parse_commandline(String[])["config"] ==
                                                                                           installed
            @test read(installed) == read(shipped)
            # an existing config is kept
            write(installed, "{}")
            @test_logs JuLeAna.parse_commandline(["-p", "3"])["config"] == installed
            @test read(installed, String) == "{}"
            # an old processing_config.json is ignored with a warning, the yaml is installed
            rm(installed)
            legacy = joinpath(production, "setup", "config", "processing_config.json")
            write(legacy, "{\"config\": {}}")
            @test_logs (:warn, r"Ignoring .*processing_config\.json") (:info, r"Copied the processing config") JuLeAna.install_default_config()
            @test read(installed) == read(shipped)
            @test read(legacy, String) == "{\"config\": {}}"
            @test_logs JuLeAna.install_default_config()
            # with --config nothing is copied
            fresh = mktempdir()
            withenv("LEGEND_DATA_CONFIG" => joinpath(fresh, "config.json")) do
                @test JuLeAna.parse_commandline(["-c", "x.json"])["config"] == "x.json"
                @test !ispath(joinpath(fresh, "setup"))
            end
            @test JuLeAna.parse_commandline(["-c", "x.json"])["config"] == "x.json"
        end
        other = mktempdir()
        withenv("LEGEND_DATA_CONFIG" => "$(joinpath(production, "a.json")):$(joinpath(production, "b.json"))") do
            @test JuLeAna.production_config_dir() == joinpath(production, "setup", "config")
        end
        # a site override before the data config of the production
        site = joinpath(other, "site.yaml")
        withenv("LEGEND_DATA_CONFIG" => "$site:$(joinpath(production, "config.json"))") do
            @test JuLeAna.data_config_files() == [site, joinpath(production, "config.json")]
            @test JuLeAna.production_config_dir() == joinpath(production, "setup", "config")
            @test JuLeAna.current_production() == (basename(production), dirname(production))
            @test JuLeAna.with_production_config("/elsewhere/config.json") == "$site:/elsewhere/config.json"
        end
        withenv("LEGEND_DATA_CONFIG" => nothing) do
            # without a data production there is no default config
            @test isnothing(JuLeAna.parse_commandline(String[])["config"])
            @test JuLeAna.parse_commandline(["--new-production"])["new_production"]
            @test_throws "the environment variable LEGEND_DATA_CONFIG is not set" JuLeAna.production_config_dir()
            @test JuLeAna.with_production_config("/elsewhere/config.json") == "/elsewhere/config.json"
        end
    end

    @testset "parse_period_runs" begin
        p3, p6, p7 = DataPeriod.((3, 6, 7))
        @test JuLeAna.parse_period_runs([], []) == (nothing, nothing)
        @test JuLeAna.parse_period_runs([["3", "6"]], []) == ([p3, p6], nothing)
        @test JuLeAna.parse_period_runs([["3"], ["6"]], [[2, 1], [4]]) == ([p3, p6], DataRun.([2, 1, 4]))
        periods, runs = JuLeAna.parse_period_runs([["3", "6, 4-6,1"], ["7,2"]], [])
        @test periods == [p3, p6, p7]
        # periods given without runs keep all their runs
        @test runs == Dict(p6 => DataRun.([1, 4, 5, 6]), p7 => [DataRun(2)])
        @test JuLeAna.parse_period_runs([["6,2-2,2"]], [])[2] == Dict(p6 => [DataRun(2)])
        @test_throws "invalid period or run `x` in `-p 6,x`" JuLeAna.parse_period_runs([["6,x"]], [])
        @test_throws "invalid period or run `` in `-p 6,`" JuLeAna.parse_period_runs([["6,"]], [])
        @test_throws "invalid period or run `p6`" JuLeAna.parse_period_runs([["p6"]], [])
        @test_throws "period p06 is given more than once" JuLeAna.parse_period_runs([["6"], ["6,1"]], [])
        @test_throws "run range `3-1` in `-p 6,3-1` ends before it starts" JuLeAna.parse_period_runs([["6,3-1"]], [])
        @test_throws "`-r` cannot be combined" JuLeAna.parse_period_runs([["6,1"]], [[2]])

        # per-period runs go to the session, other run selections come from the config
        cfg = ProcessingConfig(; processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
                               p_processors = Dict{Symbol,ProcessorSpec}(), periods = [p6], runs = [DataRun(4)])
        args(opts...) = JuLeAna.parse_commandline(["-c", "x.json", opts...])
        @test JuLeAna.session_runs(args("-p", "6,1-2"), cfg) == Dict(p6 => DataRun.([1, 2]))
        @test JuLeAna.session_runs(args("-p", "6"), cfg) == [DataRun(4)]
    end

    @testset "run_processing" begin
        p3, p4 = DataPeriod(3), DataPeriod(4)
        runs = DataRun.(1:2)
        calls = Tuple{Symbol,DataPeriod}[]
        calls_lock = ReentrantLock()
        record!(step, period) = lock(() -> push!(calls, (step, period)), calls_lock)
        run_a(cfg, l200, period, run; reprocess::Bool = false) = (sleep(0.2); record!(:run_a, period); nothing)
        p_part_b(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = (record!(:p_part_b, period); false)
        cfg = ProcessingConfig(; processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
                               p_processors = Dict(:p_part_b =>
                                                       ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal, rank = 1,
                                                                     dependencies = [:run_a])))
        stubs = Dict{Symbol,Any}(:run_a => run_a, :p_part_b => p_part_b)

        # The partition step waits for its run dependency in all runs of the period.
        run_status, partition_status = stub_status([p3], runs, [:run_a], [:p_part_b])
        run_processing(cfg, FakeData(), [p3], [:run_a], [:p_part_b], run_status, partition_status; processors = stubs)
        @test calls == [(:run_a, p3), (:run_a, p3), (:p_part_b, p3)]
        @test all(values(run_status[p3][:run_a])) && partition_status[p3][:p_part_b]

        @test_throws "unregistered processor(s) p_part_b" run_processing(cfg, FakeData(), [p3], Symbol[], [:p_part_b],
                                                                         stub_status([p3], runs, [:run_a], [:p_part_b])...;
                                                                         processors = Dict{Symbol,Any}(:run_a => run_a))

        # A processor returning `true` finishes after the previous period; when that one
        # throws, only its failure is reported.
        p_part_c(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = period == p3 ?
                                                                                                (sleep(0.2); error("p03 failed")) : true
        cfg_c = ProcessingConfig(; processors = Dict{Symbol,ProcessorSpec}(),
                                 p_processors = Dict(:p_part_c =>
                                                         ProcessorSpec(; name = :p_part_c, level = :partition, category = :cal, rank = 1)))
        store = ProgressStore()
        err = try
            run_processing(cfg_c, FakeData(), [p3, p4], Symbol[], [:p_part_c], stub_status([p3, p4], runs, Symbol[], [:p_part_c])...;
                           processors = Dict{Symbol,Any}(:p_part_c => p_part_c), progress_store = store)
        catch e
            e
        end
        @test err isa CompositeException
        @test [sprint(showerror, JuLeAna.root_exception(x)) for x in err.exceptions] == ["p03 failed"]
        @test Dict(e.period => e.state for e in progress(store).steps) == Dict(p3 => :failed, p4 => :cancelled)

        # A partition step waits for the run dependencies of the unselected partition
        # step before it, and for those runs in all periods of its partitions.
        empty!(calls)
        run_slow(cfg, l200, period, run; reprocess::Bool = false) = (sleep(period == p4 ? 0.6 : 0.2); record!(:run_a, period); nothing)
        p_part_d(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = (record!(:p_part_d, period); false)
        cfg_d = ProcessingConfig(; processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
                                 p_processors = Dict(:p_part_b =>
                                                         ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal, rank = 1,
                                                                       dependencies = [:run_a]),
                                                     :p_part_d =>
                                                         ProcessorSpec(; name = :p_part_d, level = :partition, category = :cal, rank = 2,
                                                                       dependencies = [:p_part_b])))
        run_processing(cfg_d, SpanData(), [p3, p4], [:run_a], [:p_part_d], stub_status([p3, p4], runs, [:run_a], [:p_part_d])...;
                       processors = Dict{Symbol,Any}(:run_a => run_slow, :p_part_d => p_part_d))
        # both partition steps start only after all four runs
        @test count(==(:run_a) ∘ first, calls[1:4]) == 4
        @test sort(calls[5:6]) == [(:p_part_d, p3), (:p_part_d, p4)]
    end

    @testset "parallel steps" begin
        p3 = DataPeriod(3)
        runs = DataRun.(1:2)
        events = Tuple{Symbol,Symbol,DataRun}[]
        events_lock = ReentrantLock()
        log!(what, step, run) = lock(() -> push!(events, (what, step, run)), events_lock)
        step(name) = (cfg, l200, period, run; reprocess::Bool = false) -> (log!(:start, name, run); sleep(0.3); log!(:end, name, run);
                                                                           nothing)
        spec(name, rank, deps = Symbol[]) = ProcessorSpec(; name, level = :run, category = :cal, rank, dependencies = deps)
        # a and b do not depend on each other; c depends on both
        cfg = ProcessingConfig(; processors = Dict(:a => spec(:a, 2), :b => spec(:b, 1), :c => spec(:c, 3, [:a, :b])),
                               p_processors = Dict{Symbol,ProcessorSpec}())
        stubs = Dict{Symbol,Any}(n => step(n) for n in (:a, :b, :c))
        steps = [:b, :a, :c]
        run_processing(cfg, FakeData(), [p3], steps, Symbol[], stub_status([p3], runs, steps, Symbol[])...; processors = stubs)
        position(what, name, run) = findfirst(==((what, name, run)), events)
        for r in runs
            # a and b of a run overlap, c starts after both
            @test position(:start, :a, r) < position(:end, :b, r) && position(:start, :b, r) < position(:end, :a, r)
            @test position(:start, :c, r) > max(position(:end, :a, r), position(:end, :b, r))
        end

        # with one step at a time, the ready steps start by rank, then run
        empty!(events)
        run_processing(cfg, FakeData(), [p3], steps, Symbol[], stub_status([p3], runs, steps, Symbol[])...; processors = stubs,
                       max_parallel_steps = 1)
        @test [(n, r) for (what, n, r) in events if what === :start] ==
              [(:b, runs[1]), (:b, runs[2]), (:a, runs[1]), (:a, runs[2]), (:c, runs[1]), (:c, runs[2])]
        @test_throws "max_parallel_steps must be zero (no limit) or positive" run_processing(cfg, FakeData(), [p3], steps, Symbol[],
                                                                                             stub_status([p3], runs, steps, Symbol[])...;
                                                                                             processors = stubs, max_parallel_steps = -1)

        starts() = [(n, r) for (what, n, r) in events if what === :start]
        # a longer chain of steps that wait goes first, before rank: y → z
        empty!(events)
        cfg_h = ProcessingConfig(; processors = Dict(:x => spec(:x, 1), :y => spec(:y, 2), :z => spec(:z, 3, [:y])),
                                 p_processors = Dict{Symbol,ProcessorSpec}())
        steps_h = [:x, :y, :z]
        run_processing(cfg_h, FakeData(), [p3], steps_h, Symbol[], stub_status([p3], runs, steps_h, Symbol[])...;
                       processors = Dict{Symbol,Any}(n => step(n) for n in steps_h), max_parallel_steps = 1)
        @test starts() == [(:y, runs[1]), (:y, runs[2]), (:x, runs[1]), (:x, runs[2]), (:z, runs[1]), (:z, runs[2])]
        # for equal chains, more steps that wait go first, before rank: u → t, w → v1 and v2
        empty!(events)
        cfg_m = ProcessingConfig(;
                                 processors = Dict(:u => spec(:u, 1), :w => spec(:w, 2), :t => spec(:t, 4, [:u]),
                                                   :v1 => spec(:v1, 3, [:w]), :v2 => spec(:v2, 3, [:w])),
                                 p_processors = Dict{Symbol,ProcessorSpec}())
        steps_m = [:u, :w, :t, :v1, :v2]
        run_processing(cfg_m, FakeData(), [p3], steps_m, Symbol[], stub_status([p3], runs, steps_m, Symbol[])...;
                       processors = Dict{Symbol,Any}(n => step(n) for n in steps_m), max_parallel_steps = 1)
        @test starts()[1:4] == [(:w, runs[1]), (:w, runs[2]), (:u, runs[1]), (:u, runs[2])]

        # without dependency checks, a step still waits for its own level, but not for the other
        empty!(events)
        cfg_x = ProcessingConfig(; processors = Dict(:a => spec(:a, 1), :c => spec(:c, 2, [:a, :p])),
                                 p_processors = Dict(:p => ProcessorSpec(; name = :p, level = :partition, category = :cal, rank = 1)))
        p_stub(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = (sleep(1.0); log!(:end, :p, runs[1]); false)
        run_processing(cfg_x, FakeData(), [p3], [:a, :c], [:p], stub_status([p3], runs, [:a, :c], [:p])...;
                       processors = Dict{Symbol,Any}(:a => step(:a), :c => step(:c), :p => p_stub), check_dependencies = false)
        @test position(:start, :c, runs[1]) > position(:end, :a, runs[1])
        @test position(:start, :c, runs[1]) < position(:end, :p, runs[1])
    end

    @testset "worker queue" begin
        waituntil(cond) = timedwait(cond, 30; pollint = 0.01) === :ok
        pool = Distributed.WorkerPool([myid()])
        queue = JuLeAna.WorkerQueue()
        # the only worker is busy while the items queue up
        held = take!(pool)
        order = Int[]
        order_lock = ReentrantLock()
        item(key) = Threads.@spawn begin
            worker = take!(JuLeAna.QueuedPool(pool, queue, key))
            lock(() -> push!(order, key), order_lock)
            put!(pool, worker)
        end
        tasks = map(item, [3, 1, 2])
        @test waituntil(() -> length(queue.waiting) == 3)
        put!(pool, held)
        foreach(wait, tasks)
        @test order == [1, 2, 3]
        @test isempty(queue.waiting)

        # a stop ends the wait of the queued items
        stop = Threads.Atomic{Bool}(false)
        held = take!(pool)
        waiter = Threads.@spawn take!(JuLeAna.QueuedPool(JuLeAna.StoppablePool(pool, stop), queue, 1))
        @test waituntil(() -> length(queue.waiting) == 1)
        stop[] = true
        err = try
            fetch(waiter)
        catch e
            e
        end
        @test err isa TaskFailedException && err.task.exception isa ProcessingStopped
        @test isempty(queue.waiting)
        put!(pool, held)
    end

    @testset "stored_detectors" begin
        file = joinpath(mktempdir(), "dsp.lh5")
        JuLeAna.lh5open(file, "cw") do outdata
            @test isempty(JuLeAna.stored_detectors(outdata, "jldsp"))
            outdata[:jldsp, :V1] = JuLeAna.Table(e = [1.0, 2.0])
        end
        JuLeAna.lh5open(file, "cw") do outdata
            # the group is only found by its String name
            @test !haskey(outdata, :jldsp)
            @test JuLeAna.stored_detectors(outdata, "jldsp") == ["V1"]
            # a second detector is added to the existing file
            outdata[:jldsp, :V2] = JuLeAna.Table(e = [3.0])
        end
        @test sort(JuLeAna.lh5open(f -> JuLeAna.stored_detectors(f, "jldsp"), file)) == ["V1", "V2"]
    end

    @testset "run_step" begin
        Row = NamedTuple{(:Detector, :usability, :Status, :Error)}
        items = [(detector = :V1, usability = :on), (detector = :V2, usability = :on), (detector = :V3, usability = :off)]
        prod = mktempdir()
        setup = LegendDataManagement.SetupConfig(sort([["metadata"] => mkpath(joinpath(prod, "metadata")),
                                                       ["par"] => mkpath(joinpath(prod, "par")),
                                                       ["tier"] => mkpath(joinpath(prod, "tier"))]), "valid")
        l200 = LegendData(setup, :l200, :default)
        pars_file = joinpath(prod, "pars.yaml")
        calls = []
        # Stands in for a processor: V1 and V2 are already processed, plots go to the plot tier.
        function run_proc(cfg, l200, period, run; reprocess = false, scale = 1)
            push!(calls, (; period, run, reprocess, scale))
            result = parallel(items, Row) do itr
                det = itr.detector
                if !reprocess && !JuLeAna.redo_detector(det) && det in (:V1, :V2)
                    return (processed = false, log = Row((det, :on, 1, "Already processed --> skipped.")))
                end
                plot_dir = mkpath(joinpath(l200.tier[:jlplt], "rplt", "cal", string(period), string(run), "proc"))
                for name in ("proc_fit", "proc_check")
                    JuLeAna.CairoMakie.save(joinpath(plot_dir, "l200-$period-$run-cal-$det-$name.png"),
                                            JuLeAna.Makie.Figure(size = (40, 30)))
                    # the report orders plots by modification time, which file systems resolve to a few ms
                    sleep(0.05)
                end
                (processed = true, log = Row((det, :on, 1, "")), value = scale)
            end
            JuLeAna.write_pars(pars_file, JuLeAna.PropDict(:n => length(result)))
            JuLeAna.write_report(joinpath(mkpath(l200.tier[:jlrep]), "proc.md"), lreport("# Results", create_logtbl(result)))
            return nothing
        end
        part_proc(cfg, l200, period; reprocess = false, only_first_period = true) = (push!(calls, (; period, only_first_period)); nothing)
        cfg = ProcessingConfig(;
                               processors = Dict(:run_proc => ProcessorSpec(; name = :run_proc, level = :run, category = :cal, rank = 1,
                                                                            kwargs = Dict(:scale => 2))),
                               p_processors = Dict(:part_proc =>
                                                       ProcessorSpec(; name = :part_proc, level = :partition, category = :cal, rank = 1)))
        processors = Dict{Symbol,Any}(:run_proc => run_proc, :part_proc => part_proc)
        # the processors of the config by level and rank, then the others
        tbl = JuLeAna.processors(cfg; processors = merge(processors, Dict{Symbol,Any}(:extra => identity)))
        @test tbl.Processor == [:run_proc, :part_proc, :extra] && isequal(tbl.Level, [:run, :partition, missing])
        @test isequal(tbl.Rank, [1, 1, missing]) && tbl.Detectors == [true, true, true]
        pkg_tbl = JuLeAna.processors(joinpath(pkgdir(JuLeAna), "config", "processing_config.yaml"))
        @test first(pkg_tbl.Processor) == :process_daq_energy_calibration_cal &&
              sort(pkg_tbl.Processor) == sort!(collect(keys(JuLeAna.PROCESSORS)))
        @test !pkg_tbl.Detectors[findfirst(==(:process_evt_phy), pkg_tbl.Processor)]
        output_dir = mktempdir()
        step(args...; kw...) = run_step(args...; config = cfg, l200, processors, output_dir, kw...)
        markdown(out) = sprint(show, MIME"text/markdown"(), out.report)

        # temporary outputs: only V2 runs, nothing is written to the production
        out = step(:run_proc, 3, 1; detectors = ["V2"])
        @test last(calls) == (; period = DataPeriod(3), run = DataRun(1), reprocess = false, scale = 2)
        @test first.(out.results) == items[2:2] && last(only(out.results)).value == 2
        @test !isfile(pars_file) && !isdir(joinpath(prod, "tier", "jlplt")) && !isdir(joinpath(prod, "tier", "jlrep"))
        @test isfile(joinpath(out.output_dir, "jlrep", "proc.md")) && length(out.reports) == 1
        @test out.report_file == joinpath(output_dir, "reports", "run_proc.md")
        @test sprint(show, out) == "StepOutput(run_proc p03 r001: 1 results, report in $(out.report_file))"
        report = markdown(out)
        @test occursin("# run_proc: p03 r001", report) && occursin("Detectors: V2", report)
        @test occursin("## V2", report) && occursin("<img src=\"data:image/png;base64,", report) && !occursin("V1", report)
        # plots in the order they were saved
        @test findfirst("### l200-p03-r001-cal-V2-proc_fit", report) < findfirst("### l200-p03-r001-cal-V2-proc_check", report)
        @test read(out.report_file, String) == report * "\n"
        # outside a terminal, a plot is shown by its file name
        plain = sprint(show, MIME"text/plain"(), out.report)
        @test occursin(joinpath(output_dir, "jlplt"), plain) && occursin("proc_check.png", plain) && !occursin('\e', plain)
        # display_report: the text as a report, each plot as `image/png`, in report order
        recorder = RecordingDisplay([])
        pushdisplay(recorder)
        try
            JuLeAna.display_report(out.report)
        finally
            popdisplay(recorder)
        end
        @test !(first(recorder.shown) isa Pair) &&
              occursin("# run_proc: p03 r001", sprint(show, MIME"text/markdown"(), first(recorder.shown)))
        @test [basename(last(x).file) for x in recorder.shown if x isa Pair] ==
              ["l200-p03-r001-cal-V2-proc_fit.png", "l200-p03-r001-cal-V2-proc_check.png"]
        # in the VS Code plot pane: one HTML page with the tables and the plots, also from the report file
        pane = PlotPaneDisplay([])
        pushdisplay(pane)
        try
            JuLeAna.display_report(out.report)
            JuLeAna.display_report(out.report_file)
        finally
            popdisplay(pane)
        end
        @test length(pane.shown) == 2
        for page in pane.shown
            @test occursin("<h1>run_proc: p03 r001", page) && occursin("<table>", page)
            @test count("<img src=\"data:image/png;base64,", page) == 2
        end
        @test_throws "there is no report file at" JuLeAna.display_report(joinpath(output_dir, "missing.md"))

        # production outputs: the other detectors are skipped as processed, everything is written there
        out = step(:run_proc, 3, 1; detectors = [:V2], outputs = :production, scale = 3)
        @test last(calls).scale == 3 && first.(out.results) == items
        @test [r.log.Error for r in last.(out.results)] == ["Already processed --> skipped.", "", ""]
        @test isfile(pars_file) && isfile(joinpath(prod, "tier", "jlrep", "proc.md"))
        report = markdown(out)
        @test occursin("## V2", report) && !occursin("## V3", report) && !occursin("V1", report) && !occursin("| V3", report)
        # the report of each call is appended
        @test count("# run_proc: p03 r001", read(out.report_file, String)) == 2
        rm(pars_file)

        # all detectors: reprocess is on unless given
        out = step(:run_proc, 3, 1)
        @test last(calls).reprocess && first.(out.results) == items && occursin("Detectors: all", markdown(out))
        @test occursin("## V1", markdown(out))
        @test JuLeAna.session_output_dir() == JuLeAna.session_output_dir() && isdir(JuLeAna.session_output_dir())
        step(:run_proc, 3, 1; reprocess = false)
        @test !last(calls).reprocess
        # partition level
        step(:part_proc, 3; detectors = [:V1])
        @test last(calls) == (; period = DataPeriod(3), only_first_period = false)

        @test_throws "the run-level processor `run_proc` needs a run" step(:run_proc, 3)
        @test_throws "the partition-level processor `part_proc` takes no run" step(:part_proc, 3, 1)
        @test_throws "unregistered processor `missing_proc`" step(:missing_proc, 3, 1)
        @test_throws "`outputs` is :tmp, expected :temp or :production" step(:run_proc, 3, 1; outputs = :tmp)
        @test_throws "processor `process_evt_phy` cannot select detectors" run_step(:process_evt_phy, 3, 1; detectors = [:V1])
        # a chosen detector that is not among the items stops the step before any item runs
        n_calls = length(calls)
        for outputs in (:temp, :production)
            @test_throws "the detectors V9 chosen in `run_step` are not among the items; the items have the detectors V1, V2, V3" step(:run_proc,
                                                                                                                                       3, 1;
                                                                                                                                       detectors = [:V2,
                                                                                                                                                    :V9],
                                                                                                                                       outputs)
        end
        @test length(calls) == n_calls + 2 && !isfile(pars_file)

        # debug: the items run in the calling task, and the failed steps of all detectors are captured
        function failing_proc(cfg, l200, period, run; reprocess = false)
            parallel(items, Row) do itr
                det = itr.detector
                values = [1.0, 2.0]
                plot_dir = joinpath(l200.tier[:jlplt], "rplt", "cal", string(period), string(run), "proc")
                fitted = JuLeAna.@process_step "fit $det" on_error = () -> JuLeAna.CairoMakie.save(joinpath(mkpath(plot_dir),
                                                                                                            "l200-$period-$run-cal-$det-error_fit.png"),
                                                                                                   JuLeAna.Makie.Figure(size = (40, 30))) begin
                    det === :V1 ? sum(values) : error("no peaks in $det")
                end
                (processed = true, log = Row((det, :on, 1, "")), fitted, task = current_task())
            end
            return nothing
        end
        failing_cfg = ProcessingConfig(;
                                       processors = Dict(:failing_proc =>
                                                             ProcessorSpec(; name = :failing_proc, level = :run, category = :cal, rank = 1)),
                                       p_processors = Dict{Symbol,ProcessorSpec}())
        failing_step(; kw...) = run_step(:failing_proc, 3, 1; config = failing_cfg, l200, output_dir,
                                         processors = Dict{Symbol,Any}(:failing_proc => failing_proc), kw...)
        out = redirect_stdout(devnull) do
            @test_logs (:error, "fit V2 failed for V2: ErrorException(\"no peaks in V2\")") (:error,
                                                                                             "fit V3 failed for V3: ErrorException(\"no peaks in V3\")") match_mode = :any failing_step(;
                                                                                                                                                                                        debug = true)
        end
        @test JuLeAna.failures() === out.failures && JuLeAna.failure() === first(out.failures)
        @test [JuLeAna.failure_info(f).name for f in out.failures] == ["fit V2", "fit V3"]
        @test JuLeAna.failure().det == :V2 && JuLeAna.failure().values == [1.0, 2.0]
        @test [r.log.Error for r in last.(out.results)] ==
              ["", "fit V2: ErrorException(\"no peaks in V2\")", "fit V3: ErrorException(\"no peaks in V3\")"]
        @test first(out.results).second.task === current_task()
        @test occursin(", 2 failures, report in", sprint(show, out))
        # without debug, nothing is captured and the failures of the last call are gone
        out = @test_logs (:error, "fit V2 failed for V2: ErrorException(\"no peaks in V2\")") match_mode = :any failing_step()
        @test isempty(out.failures) && isempty(JuLeAna.failures())
        @test [r.log.Error for r in last.(out.results)] ==
              ["", "fit V2: ErrorException(\"no peaks in V2\")", "fit V3: ErrorException(\"no peaks in V3\")"]
        @test_throws "no failure was captured" JuLeAna.failure()
        # stops need Infiltrator, or another stop function
        @test_throws "run `using Infiltrator` first" failing_step(; pause = :all)
        @test_throws "run `using Infiltrator` first" failing_step(; debug = :infiltrate)
        @test_throws "`debug` is :yes, expected false, true or :infiltrate" failing_step(; debug = :yes)
        @test_throws "`pause` is \"fit V2\", expected :all or a vector of step names" failing_step(; pause = "fit V2")
        stops = []
        JuLeAna.STOP_HOOK[] = (mod, vars, file, line) -> push!(stops, vars)
        try
            out = redirect_stdout(devnull) do
                with_logger(() -> failing_step(; detectors = [:V2], debug = :infiltrate), NullLogger())
            end
            @test only(stops)[:det] == :V2 && only(out.failures).det == :V2
        finally
            JuLeAna.STOP_HOOK[] = nothing
        end
        # error plots: off in the config, on with the keyword; linked in the report, not embedded
        error_plot = joinpath(output_dir, "jlplt", "rplt", "cal", "p03", "r001", "proc", "l200-p03-r001-cal-V2-error_fit.png")
        @test !isfile(error_plot)
        out = with_logger(NullLogger()) do
            failing_step(; detectors = [:V2], error_plots = true)
        end
        @test isfile(error_plot)
        report = markdown(out)
        @test occursin("### l200-p03-r001-cal-V2-error_fit", report) && !occursin("<img", report)
        @test occursin("[l200-p03-r001-cal-V2-error_fit.png](../jlplt/rplt/cal/p03/r001/proc/l200-p03-r001-cal-V2-error_fit.png)", report)

        # a log level given to `run_step` also applies to the terminal
        function logging_proc(cfg, l200, period, run; reprocess = false)
            parallel(items, Row) do itr
                LegendRunStepTest.ping(itr.detector)
                (processed = true, log = Row((itr.detector, :on, 1, "")))
            end
        end
        terminal(; kw...) = sprint() do io
            with_logger(ConsoleLogger(io, Logging.Info)) do
                run_step(:failing_proc, 3, 1; config = failing_cfg, l200, output_dir, detectors = [:V2],
                         processors = Dict{Symbol,Any}(:failing_proc => logging_proc), kw...)
            end
        end
        @test occursin("debug of V2", terminal(; log_level = :debug))
        @test !occursin("debug of V2", terminal())
        @test_throws "`log_level` is :verbose, expected :debug, :info, :warn or :error" terminal(; log_level = :verbose)

        # plots: `save_plot` writes the plot formats, `@debug_plot` saves only at the debug plot level
        function plotting_proc(cfg, l200, period, run; reprocess = false)
            parallel(items, Row) do itr
                fk = FileKey("l200-$period-$run-cal-20230101T000000Z")
                JuLeAna.save_plot(JuLeAna.Makie.Figure(size = (40, 30)), l200, fk, itr.detector, :info_plot)
                JuLeAna.@debug_plot JuLeAna.save_plot(JuLeAna.Makie.Figure(size = (40, 30)), l200, fk, itr.detector, :debug_plot)
                (processed = true, log = Row((itr.detector, :on, 1, "")))
            end
        end
        function plots_step(; config = failing_cfg, kw...)
            dir = mktempdir()
            out = with_logger(NullLogger()) do
                run_step(:failing_proc, 3, 1; config, l200, output_dir = dir, detectors = [:V2],
                         processors = Dict{Symbol,Any}(:failing_proc => plotting_proc), kw...)
            end
            files = Dict(f => joinpath(root, f) for (root, _, fs) in walkdir(joinpath(dir, "jlplt")) for f in fs)
            return out, files
        end
        out, files = plots_step()
        @test haskey(files, "l200-p03-r001-cal-V2-info_plot.png") && !haskey(files, "l200-p03-r001-cal-V2-debug_plot.png")
        @test !any(endswith(".jls"), keys(files))
        out, files = plots_step(; plot_level = :debug)
        @test haskey(files, "l200-p03-r001-cal-V2-debug_plot.png")
        @test occursin("l200-p03-r001-cal-V2-debug_plot", markdown(out))
        jls_cfg = ProcessingConfig(; processors = failing_cfg.processors, p_processors = failing_cfg.p_processors,
                                   plot_formats = [:png, :jls])
        out, files = plots_step(; config = jls_cfg)
        @test haskey(files, "l200-p03-r001-cal-V2-info_plot.png")
        @test deserialize(files["l200-p03-r001-cal-V2-info_plot.jls"]) isa JuLeAna.Makie.Figure
        @test_throws "`plot_level` is :all, expected :info or :debug" plots_step(; plot_level = :all)

        # the selection reaches the workers
        original_pool = ppt_worker_pool()
        pool = FlexWorkerPool(withmyid = false, label = "run_step test"; maxoccupancy = 1)
        ppt_worker_pool!(pool)
        pid = only(addprocs(1; exeflags = "--project=$(Base.active_project())"))
        try
            @everywhere [pid] using JuLeAna
            push!(pool, pid)
            on_worker(cfg, l200, period, run; reprocess = false) = parallel(items, Row) do itr
                (processed = true, log = Row((itr.detector, :on, 1, "")), worker = myid(), redo = JuLeAna.redo_detector(itr.detector))
            end
            out = run_step(:on_worker, 3, 1;
                           config = ProcessingConfig(;
                                                     processors = Dict(:on_worker =>
                                                                           ProcessorSpec(; name = :on_worker, level = :run, category = :cal,
                                                                                         rank = 1)),
                                                     p_processors = Dict{Symbol,ProcessorSpec}()), l200,
                           processors = Dict{Symbol,Any}(:on_worker => on_worker), detectors = [:V1, :V3], outputs = :production)
            @test [(r.worker, r.redo) for r in last.(out.results)] == [(pid, true), (pid, false), (pid, true)]
        finally
            ppt_worker_pool!(original_pool)
            rmprocs(pid)
        end
    end

    @testset "skipped runs" begin
        p3, r1 = DataPeriod(3), DataRun(1)
        run_a(cfg, l200, period, run; reprocess::Bool = false) = error("run_a must be skipped")
        partition_calls = DataPeriod[]
        p_b(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = true) = (push!(partition_calls, period); nothing)
        processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1))
        p_processors = Dict(:p_b => ProcessorSpec(; name = :p_b, level = :partition, category = :cal, rank = 1, dependencies = [:run_a]))
        stubs = Dict{Symbol,Any}(:run_a => run_a, :p_b => p_b)
        for (data, analysis_runs_only, message) in ((NoAnalysisData(), true, "p03-r001-cal is not an analysis run, skip run_a"),
                                                    (NoRunData(), false, "p03-r001-cal is not in runinfo, skip run_a"))
            cfg = ProcessingConfig(; processors, p_processors, analysis_runs_only)
            run_status, partition_status = stub_status([p3], [r1], [:run_a], [:p_b])
            # the partition step that waits for the skipped run still runs
            task = Threads.@spawn @test_logs (:warn, message) match_mode = :any run_processing(cfg, data, [p3], [:run_a], [:p_b],
                                                                                               run_status, partition_status;
                                                                                               processors = stubs)
            @test timedwait(() -> istaskdone(task), 60) === :ok
            fetch(task)
            # a skipped run counts as finished for the steps that depend on it
            @test run_status[p3][:run_a][r1] && partition_status[p3][:p_b]
            @test last(partition_calls) == p3
        end
    end

    @testset "selected_steps and runprocs_mode" begin
        processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1))
        p_processors = Dict(:p_part_b => ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal, rank = 1))
        @test JuLeAna.selected_steps(ProcessingConfig(; processors, p_processors)) == ([:run_a], [:p_part_b])
        @test JuLeAna.selected_steps(ProcessingConfig(; processors, p_processors, only_runs = true)) == ([:run_a], Symbol[])
        @test JuLeAna.selected_steps(ProcessingConfig(; processors, p_processors, only_partitions = true)) == (Symbol[], [:p_part_b])

        env_variables = Dict("A" => "1")
        mode = JuLeAna.runprocs_mode(ProcessingConfig(; processors, p_processors, local_n = 3, env_variables,
                                                      local_julia_settings = ["--heap-size-hint=2G"]))
        @test mode isa JuLeAna.ParallelProcessingTools.OnLocalhost
        @test mode.n == 3
        @test mode.julia_flags == `--startup-file=no --threads=$(JuLeAna.local_worker_threads(3)) --heap-size-hint=2G`
        @test mode.env == env_variables
        # a thread count in the settings replaces the one shared out
        mode = JuLeAna.runprocs_mode(ProcessingConfig(; processors, p_processors, local_n = 3, local_julia_settings = ["--threads=5"]))
        @test mode.julia_flags == `--startup-file=no --threads=5`
        @test JuLeAna.local_worker_threads(Sys.CPU_THREADS) == 1
        @test JuLeAna.local_worker_threads(2 * Sys.CPU_THREADS) == 1
        @test JuLeAna.local_worker_threads(1) == Sys.CPU_THREADS
        mode = JuLeAna.runprocs_mode(ProcessingConfig(; processors, p_processors, runmode = :slurm, slurm_flags = ["--nodes=2"],
                                                      env_variables))
        @test mode isa JuLeAna.ParallelProcessingTools.OnSlurm
        @test mode.slurm_flags == `--nodes=2`
        @test mode.julia_flags == `--startup-file=no`
        @test mode.redirect_output
        @test mode.env == env_variables
    end

    @testset "report_failures" begin
        report = mktemp() do path, io
            write(io, REPORT)
            close(io)
            JuLeAna.read_report(path)
        end
        @test report.n_entries == 3
        @test report.n_failed == 2
        @test report.failures == [("V02 (trap)", "fit failed"), ("V03", ""), ("V04", "")]
    end
end
