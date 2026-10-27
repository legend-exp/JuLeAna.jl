# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Logging: Logging
using Test
using Dates: Minute
using LegendDataManagement: DataPeriod, DataRun, FileKey, ProcessStatus, readlprops, writelprops
using Distributed: addprocs, rmprocs, workers, @everywhere
using ParallelProcessingTools: FlexWorkerPool, ppt_worker_pool, ppt_worker_pool!

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

const StopLog = NamedTuple{(:Filekey, :Status, :Error)}

# Wait up to `timeout` seconds for `cond()`.
waituntil(cond; timeout = 60) = timedwait(cond, timeout; pollint = 0.05) === :ok

@testset "DataflowController" begin
    root = mktempdir()
    data_config = legend_test_setup(root, TEST_DIRS)
    l200 = legend_test_data(data_config)
    p2, p3 = DataPeriod.((2, 3))
    shipped_config = joinpath(dirname(@__DIR__), "config", "processing_config.yaml")

    calls = Tuple{Symbol,DataPeriod,Any,Dict{Symbol,Any}}[]
    calls_lock = ReentrantLock()
    record(step, period, run, kwargs) = lock(() -> push!(calls, (step, period, run, Dict{Symbol,Any}(pairs(kwargs)))), calls_lock)
    energy_stub(cfg, l200, period, run; reprocess = false, max_wvfs = 10) = (record(:process_energy_calibration_cal, period, run,
                                                                                    (; reprocess, max_wvfs)); nothing)
    aoe_stub(cfg, l200, period; reprocess = false, only_first_period = false) = (record(:p_process_aoe_cut_cal, period, nothing,
                                                                                        (; reprocess)); false)
    processors = merge(JuLeAna.PROCESSORS,
                       Dict{Symbol,Any}(:process_energy_calibration_cal => energy_stub, :p_process_aoe_cut_cal => aoe_stub))

    cfg = ProcessingConfig(;
                           processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1),
                                             :process_dsp_cal => spec(:process_dsp_cal, :run, 2; enabled = false)),
                           p_processors = Dict(:p_process_aoe_cut_cal => spec(:p_process_aoe_cut_cal, :partition, 1)))

    function new_session(config = cfg)
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, config, [p2, p3], nothing, run_steps(config),
                                                                               partition_steps(config))
        return DataflowSession(; args = Dict{String,Any}("config" => shipped_config), l200, config, periods, run_steps = run_steps(config),
                               partition_steps = partition_steps(config), run_status, partition_status)
    end

    @testset "state and snapshot" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        snap = snapshot(ctrl)
        @test snap.state === :ready
        @test isnothing(snap.outcome) && isnothing(snap.last_error)
        @test snap.available_periods == DataPeriod.([2, 3, 13, 16])
        @test snap.available_runs[p2] == DataRun.(0:7)
        @test snap.periods == [p2, p3]
        @test isnothing(snap.runs)
        @test snap.run_steps == [:process_energy_calibration_cal]
        @test snap.partition_steps == [:p_process_aoe_cut_cal]
        @test [p.name for p in snap.processors] == [:process_energy_calibration_cal, :process_dsp_cal, :p_process_aoe_cut_cal]
        dsp = snap.processors[2]
        @test dsp.level === :run && !dsp.enabled && !dsp.selected && dsp.rank == 2
        @test snap.config_file == shipped_config
        @test isnothing(snap.reprocess) &&
              snap.check_dependencies &&
              isnothing(snap.processor_log_level) &&
              isnothing(snap.processor_plot_level)
        @test occursin("DataflowController(:ready", sprint(show, ctrl))
    end

    @testset "rejected commands" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        @test_throws "StopProcessing is not possible while the controller is :ready" dispatch!(ctrl, StopProcessing())
        @test_throws "LoadSession is not possible while the controller is :ready" dispatch!(ctrl, LoadSession())
        @test_throws "periods not in the dataset: p99" dispatch!(ctrl, SelectPeriods([99]))
        @test_throws "runs not available in the selected periods: r009" dispatch!(ctrl, SelectRuns([9]))
        @test_throws "not in `processors` of the config: process_bogus" dispatch!(ctrl, SelectSteps([:process_bogus], Symbol[]))
        @test_throws "not in `p_processors` of the config: process_energy_calibration_cal" dispatch!(ctrl,
                                                                                                     SelectSteps(Symbol[],
                                                                                                                 [:process_energy_calibration_cal]))
        @test_throws "unknown processor `process_bogus`" dispatch!(ctrl, SetKwarg(:process_bogus, :x, 1))
        @test_throws "`process_energy_calibration_cal` does not accept keyword(s) unknown_kw" dispatch!(ctrl,
                                                                                                        SetKwarg(:process_energy_calibration_cal,
                                                                                                                 :unknown_kw, 1))
        dispatch!(ctrl, SelectSteps(Symbol[], Symbol[]))
        @test_throws "no processing steps selected" dispatch!(ctrl, StartProcessing())
        # rejected commands leave the state unchanged
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.periods == [p2, p3] && isempty(snap.run_steps)
        @test all(p -> isempty(p.overridden), snap.processors)

        idle = DataflowController(Dict{String,Any}("config" => shipped_config); processors, record_software = false,
                                  record_metadata = false)
        @test snapshot(idle).state === :idle
        @test isempty(snapshot(idle).processors)
        @test_throws "StartProcessing is not possible while the controller is :idle" dispatch!(idle, StartProcessing())
    end

    @testset "select, override and process" begin
        empty!(calls)
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        dispatch!(ctrl, SelectPeriods(["p02"]))
        dispatch!(ctrl, SelectRuns([6]))
        dispatch!(ctrl, SelectSteps([:process_energy_calibration_cal], [:p_process_aoe_cut_cal]))
        dispatch!(ctrl, SetKwarg("process_energy_calibration_cal", "max_wvfs", 5))
        dispatch!(ctrl, SetReprocess(true))
        dispatch!(ctrl, SetProcessorLogLevel(Logging.Warn))
        dispatch!(ctrl, SetProcessorPlotLevel(:debug))
        @test_throws "expected :info or :debug" dispatch!(ctrl, SetProcessorPlotLevel(:verbose))
        snap = snapshot(ctrl)
        @test snap.processor_log_level == Logging.Warn && snap.processor_plot_level === :debug
        @test snap.periods == [p2] && snap.runs == [DataRun(6)]
        energy = snap.processors[1]
        @test energy.kwargs[:max_wvfs] == 5 && energy.overridden == [:max_wvfs]
        @test snap.reprocess === true
        # the config of the session is unchanged
        @test !haskey(ctrl.session.config.processors[:process_energy_calibration_cal].kwargs, :max_wvfs)

        dispatch!(ctrl, StartProcessing())
        @test snapshot(ctrl).state in (:running, :ready)
        wait(ctrl)
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.outcome === :finished && isnothing(snap.last_error)
        @test snap.finished >= snap.started
        # the snapshot has the same type in every state, with and without a session
        @test snap isa JuLeAna.ControllerSnapshot
        @test snapshot(DataflowController(Dict{String,Any}("config" => nothing); loader = nothing, record_software = false,
                                          record_metadata = false)) isa JuLeAna.ControllerSnapshot
        @test sort(map(c -> c[1:3], calls); by = string) ==
              sort([(:process_energy_calibration_cal, p2, DataRun(6)), (:p_process_aoe_cut_cal, p2, nothing)]; by = string)
        energy_call = only(filter(c -> c[1] === :process_energy_calibration_cal, calls))
        @test energy_call[4] == Dict(:reprocess => true, :max_wvfs => 5)
        # the run is added to the processing history of the production
        entry = last(JuLeAna.read_history(JuLeAna.history_path(l200)))
        @test entry.outcome === :finished &&
              entry.started == floor(snap.started, JuLeAna.Second) &&
              entry.finished == floor(snap.finished, JuLeAna.Second)
        @test entry.host == gethostname()
        @test entry.software == JuLeAna.software_version() && startswith(entry.software, "JuLeAna ")
        @test Set((s.process, s.level, s.category, s.period, s.run, s.outcome) for s in entry.steps) ==
              Set([(:process_energy_calibration_cal, :run, :cal, p2, DataRun(6), :done),
                   (:p_process_aoe_cut_cal, :partition, :cal, p2, nothing, :done)])

        dispatch!(ctrl, ResetKwargs(:process_energy_calibration_cal))
        @test isempty(snapshot(ctrl).processors[1].overridden)
        dispatch!(ctrl, SetKwarg(:process_energy_calibration_cal, :max_wvfs, 7))
        dispatch!(ctrl, ResetKwargs())
        @test isempty(snapshot(ctrl).processors[1].overridden)
        dispatch!(ctrl, SelectRuns(nothing))
        @test isnothing(snapshot(ctrl).runs)
        dispatch!(ctrl, ResetDependencyGraph())
        @test !any(values(ctrl.session.run_status[p2][:process_energy_calibration_cal]))
    end

    @testset "software record" begin
        production = mkpath(joinpath(root, "recorded-production"))
        function run_recorded()
            ctrl = DataflowController(new_session(); processors, record_metadata = false)
            dispatch!(ctrl, SelectPeriods(["p02"]))
            dispatch!(ctrl, SelectRuns([6]))
            dispatch!(ctrl, SelectSteps([:process_energy_calibration_cal], Symbol[]))
            dispatch!(ctrl, StartProcessing())
            wait(ctrl)
            return ctrl, last(JuLeAna.read_history(JuLeAna.history_path(l200)))
        end
        ctrl, entry = withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
            run_recorded()
        end
        snapshot_name = only(readdir(joinpath(production, "setup", "software")))
        @test snapshot(ctrl).outcome === :finished && ctrl.software_snapshot == snapshot_name
        @test isfile(joinpath(production, "setup", "software", snapshot_name, "SNAPSHOT.toml"))
        @test entry.software == JuLeAna.software_version(snapshot_name) &&
              endswith(entry.software, ", snapshot setup/software/$snapshot_name")
        # a second run with the same software reuses the snapshot
        ctrl, entry = withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
            run_recorded()
        end
        @test readdir(joinpath(production, "setup", "software")) == [snapshot_name] && ctrl.software_snapshot == snapshot_name
        # without a production folder the run fails before processing and says so
        empty!(calls)
        ctrl, entry = withenv("LEGEND_DATA_CONFIG" => nothing) do
            run_recorded()
        end
        snap = snapshot(ctrl)
        @test snap.outcome === :failed && isempty(calls) && occursin("LEGEND_DATA_CONFIG is not set", snap.last_error)
        @test entry.outcome === :failed && entry.software == JuLeAna.software_version()
    end

    @testset "metadata record" begin
        # a production whose metadata is a git checkout of the test metadata
        production = mkpath(joinpath(root, "metadata-production"))
        metadata = joinpath(production, "legend-metadata")
        cp(TEST_METADATA, metadata)
        git(args...) = run(pipeline(`git -C $metadata -c user.name=Test -c user.email=test@example.org $args`; stdout = devnull))
        git("init", "-q", "-b", "main")
        git("add", "-A")
        git("commit", "-q", "-m", "test metadata")
        config = joinpath(production, "config.json")
        write(config, replace(read(data_config, String), TEST_METADATA => metadata))
        metadata_l200 = legend_test_data(config)
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(metadata_l200, cfg, [p2], nothing, run_steps(cfg),
                                                                               partition_steps(cfg))
        session = DataflowSession(; args = Dict{String,Any}("config" => shipped_config), l200 = metadata_l200, config = cfg, periods,
                                  run_steps = run_steps(cfg), partition_steps = partition_steps(cfg), run_status, partition_status)
        ctrl = DataflowController(session; processors, record_software = false)
        withenv("LEGEND_DATA_CONFIG" => config) do
            dispatch!(ctrl, SelectRuns([6]))
            dispatch!(ctrl, SelectSteps([:process_energy_calibration_cal], Symbol[]))
            dispatch!(ctrl, StartProcessing())
            wait(ctrl)
        end
        recorded = only(readdir(joinpath(production, "setup", "metadata")))
        @test snapshot(ctrl).outcome === :finished && ctrl.metadata_record == recorded && isnothing(ctrl.software_snapshot)
        folder = joinpath(production, "setup", "metadata", recorded)
        @test sort(readdir(joinpath(folder, "config"))) == ["1-config.json", "2-processing_config.yaml"]
        entry = last(JuLeAna.read_history(JuLeAna.history_path(metadata_l200)))
        @test entry.metadata == "setup/metadata/$recorded"
    end

    @testset "per-period runs" begin
        empty!(calls)
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        @test snapshot(ctrl).available_runs[p3] == DataRun.(0:5)
        dispatch!(ctrl, SelectRuns(Dict(2 => [7], "p03" => nothing)))
        snap = snapshot(ctrl)
        @test snap.periods == [p2, p3]
        # p03 keeps all its runs
        @test snap.runs == Dict(p2 => [DataRun(7)])
        @test_throws "runs not available in p02: r009" dispatch!(ctrl, SelectRuns(Dict(2 => [9])))
        @test_throws "periods not in the dataset: p99" dispatch!(ctrl, SelectRuns(Dict(99 => nothing)))
        @test snapshot(ctrl).runs == Dict(p2 => [DataRun(7)])

        dispatch!(ctrl, StartProcessing())
        wait(ctrl)
        @test snapshot(ctrl).outcome === :finished
        @test sort(map(c -> c[1:3], calls); by = string) == sort([(:process_energy_calibration_cal, p2, DataRun(7));
                                                                  [(:process_energy_calibration_cal, p3, r) for r in DataRun.(0:5)];
                                                                  (:p_process_aoe_cut_cal, p2, nothing); (:p_process_aoe_cut_cal, p3, nothing)]; by = string)

        # a period without any of the selected runs stays selected, but has nothing to process
        dispatch!(ctrl, SelectRuns([6]))
        snap = snapshot(ctrl)
        @test snap.periods == [p2, p3] && snap.runs == [DataRun(6)]
        @test ctrl.session.periods == [p2]
        dispatch!(ctrl, SelectRuns(nothing))
        @test ctrl.session.periods == [p2, p3]

        # periods that stay selected keep their runs
        dispatch!(ctrl, SelectRuns(Dict(2 => [6], 3 => [0])))
        dispatch!(ctrl, SelectPeriods([2]))
        snap = snapshot(ctrl)
        @test snap.periods == [p2] && snap.runs == Dict(p2 => [DataRun(6)])
        dispatch!(ctrl, SelectPeriods([3]))
        @test isnothing(snapshot(ctrl).runs)

        dispatch!(ctrl, SelectPeriods(Int[]))
        @test_throws "no periods selected" dispatch!(ctrl, StartProcessing())
    end

    @testset "analysis runs only" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        @test snapshot(ctrl).analysis_runs_only == cfg.analysis_runs_only
        dispatch!(ctrl, SetAnalysisRunsOnly(!cfg.analysis_runs_only))
        @test snapshot(ctrl).analysis_runs_only == !cfg.analysis_runs_only
        @test JuLeAna.effective_config(ctrl).analysis_runs_only == !cfg.analysis_runs_only
        # the session config is unchanged
        @test ctrl.session.config.analysis_runs_only == cfg.analysis_runs_only
    end

    @testset "run mode" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        other = cfg.runmode === :local ? :slurm : :local
        @test_throws "runmode must be :local or :slurm" SetRunmode(:cluster)
        @test snapshot(ctrl).runmode === cfg.runmode
        @test ctrl.workers.config.runmode === cfg.runmode
        dispatch!(ctrl, SetRunmode(other))
        @test snapshot(ctrl).runmode === other
        @test JuLeAna.effective_config(ctrl).runmode === other
        @test ctrl.workers.config.runmode === other
        # the session config is unchanged
        @test ctrl.session.config.runmode === cfg.runmode
        @test_throws "SetRunmode is not possible while the controller is :idle" dispatch!(DataflowController(Dict{String,Any}(); processors,
                                                                                                             record_software = false,
                                                                                                             record_metadata = false),
                                                                                          SetRunmode(other))
    end

    @testset "failed run" begin
        failing(cfg, l200, period, run; reprocess = false) = error("stub failure")
        ctrl = DataflowController(new_session();
                                  processors = merge(processors, Dict{Symbol,Any}(:process_energy_calibration_cal => failing)),
                                  record_software = false, record_metadata = false)
        dispatch!(ctrl, SelectSteps([:process_energy_calibration_cal], Symbol[]))
        dispatch!(ctrl, StartProcessing())
        wait(ctrl)
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.outcome === :failed
        @test occursin("stub failure", snap.last_error)
        entry = last(JuLeAna.read_history(JuLeAna.history_path(l200)))
        @test entry.outcome === :failed && any(s -> s.outcome === :failed, entry.steps)
    end

    @testset "stop" begin
        started, finished_batches = Threads.Atomic{Int}(0), Threads.Atomic{Int}(0)
        filekeys = [FileKey("l200-p02-r006-cal-20230101T00000$(i)Z") for i in 1:4]
        function slow_step(cfg, l200, period, run; reprocess = false)
            parallel(filekeys, StopLog) do fk
                Threads.atomic_add!(started, 1)
                sleep(0.5)
                (processed = true, log = StopLog((fk, ProcessStatus(1), "")))
            end
            # only reached when `parallel` returns
            Threads.atomic_add!(finished_batches, 1)
            return nothing
        end
        ctrl = DataflowController(new_session();
                                  processors = merge(processors, Dict{Symbol,Any}(:process_energy_calibration_cal => slow_step)),
                                  record_software = false, record_metadata = false)
        dispatch!(ctrl, SelectPeriods([2]))
        dispatch!(ctrl, SelectRuns([6]))
        dispatch!(ctrl, SelectSteps([:process_energy_calibration_cal], Symbol[]))
        dispatch!(ctrl, StartProcessing())
        @test_throws "SelectPeriods is not possible while the controller is :running" dispatch!(ctrl, SelectPeriods([2]))
        @test waituntil(() -> started[] >= 1)
        dispatch!(ctrl, StopProcessing())
        @test snapshot(ctrl).state in (:stopping, :ready)
        wait(ctrl)
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.outcome === :stopped && isnothing(snap.last_error)
        # without workers the items run one at a time on the main process
        @test started[] < length(filekeys)
        @test finished_batches[] == 0
        step = only(progress(ctrl).steps)
        @test step.state === :stopped && step.total == length(filekeys)
        @test step.notrun > 0 && step.done + step.notrun == length(filekeys)

        # the next run starts with the stop flag cleared
        dispatch!(ctrl, StartProcessing())
        # the progress of the last run is gone as soon as the next one starts
        @test progress(ctrl).fraction < 1
        wait(ctrl)
        @test snapshot(ctrl).outcome === :finished
        @test finished_batches[] == 1
        @test only(progress(ctrl).steps).state === :done
        @test progress(ctrl).fraction == 1
    end

    @testset "force stop" begin
        # the worker pool of a dataflow session never runs items on the main process
        original_pool = ppt_worker_pool()
        pool = FlexWorkerPool(withmyid = false, label = "force stop test"; maxoccupancy = 1)
        ppt_worker_pool!(pool)
        pid = only(addprocs(1; exeflags = "--project=$(Base.active_project())"))
        try
            @everywhere [pid] using JuLeAna
            push!(pool, pid)
            filekeys = [FileKey("l200-p02-r006-cal-20230101T00000$(i)Z") for i in 1:3]
            slow_item_step(cfg, l200, period, run; reprocess = false) = parallel(filekeys, StopLog) do fk
                sleep(8)
                (processed = true, log = StopLog((fk, ProcessStatus(1), "")))
            end
            ctrl = DataflowController(new_session();
                                      processors = merge(processors, Dict{Symbol,Any}(:process_energy_calibration_cal => slow_item_step)),
                                      record_software = false, record_metadata = false)
            dispatch!(ctrl, SelectPeriods([2]))
            dispatch!(ctrl, SelectRuns([6]))
            dispatch!(ctrl, SelectSteps([:process_energy_calibration_cal], Symbol[]))
            dispatch!(ctrl, StartProcessing())
            @test waituntil(() -> !isempty(busy_workers(ctrl)))
            busy = only(busy_workers(ctrl))
            @test busy.worker == pid && !busy.abandoned && busy.step === :process_energy_calibration_cal
            @test busy.period == p2 && busy.run == DataRun(6) && busy.item in string.(filekeys)
            t_stop = time()
            dispatch!(ctrl, StopProcessing(; force = true))
            # the run ends without waiting for the running item
            @test waituntil(() -> snapshot(ctrl).state === :ready; timeout = 60)
            @test time() - t_stop < 5
            snap = snapshot(ctrl)
            @test snap.outcome === :stopped && isnothing(snap.last_error)
            step = only(progress(ctrl).steps)
            @test step.state === :stopped && step.notrun == length(filekeys) && isempty(step.workers)
            # the worker is kept and stays busy with the abandoned item until it ends
            @test pid in workers()
            @test only(busy_workers(ctrl)).abandoned
            @test waituntil(() -> isempty(busy_workers(ctrl)); timeout = 30)
            @test waituntil(() -> isready(pool); timeout = 10)
            @test only(progress(ctrl).steps).notrun == length(filekeys)
        finally
            ppt_worker_pool!(original_pool)
            pid in workers() && rmprocs(pid)
        end
    end

    @testset "load and reload" begin
        session = new_session()
        ctrl = DataflowController(Dict{String,Any}("config" => shipped_config); processors, loader = args -> session,
                                  record_software = false, record_metadata = false)
        dispatch!(ctrl, LoadSession())
        wait(ctrl)
        @test snapshot(ctrl).state === :ready
        @test ctrl.session === session

        broken = DataflowController(Dict{String,Any}("config" => shipped_config); processors, loader = args -> error("no data"),
                                    record_software = false, record_metadata = false)
        dispatch!(broken, LoadSession())
        wait(broken)
        snap = snapshot(broken)
        @test snap.state === :idle && occursin("no data", snap.last_error)

        # reload reads the config file given on the command line
        props = readlprops(shipped_config)
        props.config.env_variables = Dict("LEGEND_DATA_CONFIG" => data_config)
        config_file = joinpath(root, "controller_config.json")
        writelprops(config_file, props)
        args = JuLeAna.parse_commandline(["-c", config_file, "-p", "2", "-o", joinpath(root, "controller_logs")])
        session = new_session()
        session = DataflowSession(; args, session.l200, session.config, session.periods, session.run_steps, session.partition_steps,
                                  session.run_status, session.partition_status)
        ctrl = DataflowController(session; processors, record_software = false, record_metadata = false)
        dispatch!(ctrl, SetKwarg(:process_energy_calibration_cal, :max_wvfs, 5))
        withenv("LEGEND_DATA_CONFIG" => nothing) do
            dispatch!(ctrl, ReloadConfig())
            wait(ctrl)
        end
        snap = snapshot(ctrl)
        @test snap.state === :ready && isnothing(snap.last_error)
        @test snap.periods == [p2]
        @test snap.run_steps == run_steps(ctrl.session.config)
        @test all(p -> isempty(p.overridden), snap.processors)
    end

    @testset "WriteConfig" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        dispatch!(ctrl, SetKwarg(:process_energy_calibration_cal, :max_wvfs, 5))
        dispatch!(ctrl, SetStepLevel(:process_energy_calibration_cal, :log_level, "debug"))
        dispatch!(ctrl, SetStepLevel(:p_process_aoe_cut_cal, :plot_level, :debug))
        dispatch!(ctrl, SelectSteps([:process_energy_calibration_cal], Symbol[]))
        dispatch!(ctrl, SetAnalysisRunsOnly(true))
        other_runmode = cfg.runmode === :local ? :slurm : :local
        dispatch!(ctrl, SetRunmode(other_runmode))
        written = joinpath(root, "written_config.yaml")
        write(written, "previous")
        production = mktempdir()
        withenv(() -> dispatch!(ctrl, WriteConfig(written)), "LEGEND_DATA_CONFIG" => joinpath(production, "config.json"))
        # a given path leaves the config folder of the data production alone
        @test !ispath(joinpath(production, "setup", "config"))
        @test snapshot(ctrl).config_file == written
        @test read(written * ".bak", String) == "previous"
        original, props = readlprops(shipped_config), readlprops(written)
        @test props.processors.process_energy_calibration_cal.kwargs.max_wvfs == 5
        # every processor is enabled exactly when it is selected
        @test props.processors.process_energy_calibration_cal.enabled
        @test !any(e -> e.enabled, values(props.p_processors))
        @test !any(e -> e.enabled, (e for (n, e) in props.processors if n != :process_energy_calibration_cal))
        @test props.processing.analysis_runs_only
        @test props.config == original.config
        written_cfg = ProcessingConfig(written)
        @test written_cfg.processors[:process_energy_calibration_cal].kwargs[:max_wvfs] == 5
        @test props.processors.process_energy_calibration_cal.log_level == "debug" &&
              props.p_processors.p_process_aoe_cut_cal.plot_level == "debug"
        @test written_cfg.processors[:process_energy_calibration_cal].log_level == Logging.Debug &&
              written_cfg.p_processors[:p_process_aoe_cut_cal].plot_level === :debug
        @test run_steps(written_cfg) == [:process_energy_calibration_cal] && isempty(partition_steps(written_cfg))
        # the file is YAML, not JSON, and reads back to the same config
        text = read(written, String)
        @test !startswith(lstrip(text), "{") && occursin(r"^config:"m, text)
        @test occursin(r"^  analysis_runs_only: true$"m, text)
        @test occursin(Regex("^  runmode: \"?$other_runmode\"?\$", "m"), text)
        @test props.config.runmode == string(other_runmode)
        @test readlprops(written) == props
        dispatch!(ctrl, ReloadConfig())
        wait(ctrl)
        @test run_steps(ctrl.session.config) == run_steps(written_cfg)

        # the processor log level is written when set and the key is removed when not
        @test !haskey(props.config, :processor_log_level)
        dispatch!(ctrl, SetProcessorLogLevel(Logging.Debug))
        withenv(() -> dispatch!(ctrl, WriteConfig(written)), "LEGEND_DATA_CONFIG" => joinpath(production, "config.json"))
        @test readlprops(written).config.processor_log_level == "debug"
        dispatch!(ctrl, ReloadConfig())
        wait(ctrl)
        @test snapshot(ctrl).processor_log_level == Logging.Debug
        dispatch!(ctrl, SetProcessorLogLevel(nothing))
        withenv(() -> dispatch!(ctrl, WriteConfig(written)), "LEGEND_DATA_CONFIG" => joinpath(production, "config.json"))
        @test !haskey(readlprops(written).config, :processor_log_level)

        # the processor plot level is written when set and the key is removed when not
        @test !haskey(props.config, :processor_plot_level)
        dispatch!(ctrl, SetProcessorPlotLevel(:debug))
        withenv(() -> dispatch!(ctrl, WriteConfig(written)), "LEGEND_DATA_CONFIG" => joinpath(production, "config.json"))
        @test readlprops(written).config.processor_plot_level == "debug"
        dispatch!(ctrl, ReloadConfig())
        wait(ctrl)
        @test snapshot(ctrl).processor_plot_level === :debug
        dispatch!(ctrl, SetProcessorPlotLevel(nothing))
        withenv(() -> dispatch!(ctrl, WriteConfig(written)), "LEGEND_DATA_CONFIG" => joinpath(production, "config.json"))
        @test !haskey(readlprops(written).config, :processor_plot_level)
    end

    @testset "worker commands" begin
        production = mktempdir()
        withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
            ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
            @test isempty(snapshot(ctrl).allocations)
            dispatch!(ctrl, EditStartScript("echo started; sleep 60"))
            @test read(joinpath(production, "setup", "config", "startjlworkers.sh"), String) == "echo started; sleep 60"
            dispatch!(ctrl, AddWorkers())
            dispatch!(ctrl, AddWorkers())
            @test [(a.id, a.state) for a in snapshot(ctrl).allocations] == [(1, :running), (2, :running)]
            @test !haskey(first(snapshot(ctrl).allocations), :output)
            dispatch!(ctrl, CancelAllocation(1))
            @test [a.state for a in snapshot(ctrl).allocations] == [:cancelled, :running]
            dispatch!(ctrl, CancelAll())
            @test [a.state for a in snapshot(ctrl).allocations] == [:cancelled, :cancelled]
            @test_throws "there is no worker allocation 3" dispatch!(ctrl, CancelAllocation(3))
            # postponing restarts the countdown
            dispatch!(ctrl, EditStartScript("sleep 60"))
            dispatch!(ctrl, AddWorkers())
            deadline = snapshot(ctrl).idle_deadline
            @test deadline - snapshot(ctrl).allocations[3].started == Minute(20)
            sleep(0.01)
            dispatch!(ctrl, PostponeIdleCancel())
            @test snapshot(ctrl).idle_deadline > deadline
            @test !JuLeAna.check_idle!(ctrl)
            dispatch!(ctrl, CancelAll())
            @test isnothing(snapshot(ctrl).idle_deadline)
            # idle allocations are cancelled
            short = DataflowController(new_session(ProcessingConfig(; cfg.processors, cfg.p_processors, idle_timeout_minutes = 0.002));
                                       processors, record_software = false, record_metadata = false)
            dispatch!(short, EditStartScript("sleep 60"))
            dispatch!(short, AddWorkers())
            @test !JuLeAna.check_idle!(short)
            sleep(0.2)
            @test JuLeAna.check_idle!(short)
            @test only(snapshot(short).allocations).state === :cancelled
            # a reloaded or new config generates the start script anew
            JuLeAna.set_worker_config!(ctrl.workers, ctrl.session.config)
            @test occursin("elastic_worker", JuLeAna.start_script!(ctrl.workers).text)

            idle = DataflowController(Dict{String,Any}("config" => shipped_config); processors, loader = _ -> new_session(),
                                      record_software = false, record_metadata = false)
            @test_throws ArgumentError dispatch!(idle, AddWorkers())
            @test_throws ArgumentError dispatch!(idle, EditStartScript("x"))
        end
    end

    @testset "create a production" begin
        git_env = ("GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.org", "GIT_COMMITTER_NAME" => "Test",
                   "GIT_COMMITTER_EMAIL" => "test@example.org")
        production = mktempdir()
        withenv(git_env..., "LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
            metadata = mktempdir()
            write(joinpath(metadata, "README.md"), "metadata")
            for args in (`init -b main`, `add .`, `commit -m init`)
                run(pipeline(`git -C $metadata $args`; stdout = devnull, stderr = devnull))
            end
            parent = mktempdir()
            loaded = Ref{Any}(nothing)
            ctrl = DataflowController(Dict{String,Any}("config" => shipped_config, "log_path" => "old"); processors,
                                      loader = args -> (loaded[] = copy(args); new_session()), record_software = false,
                                      record_metadata = false)
            dispatch!(ctrl, LoadSession())
            wait(ctrl)
            dispatch!(ctrl, EditStartScript("sleep 60"))
            dispatch!(ctrl, AddWorkers())
            spec = JuLeAna.ProductionSpec(; name = "prod", parent, metadata_url = metadata, copy_software = false)
            dispatch!(ctrl, CreateProduction(spec))
            wait(ctrl)
            config = joinpath(parent, "prod", "config.yaml")
            @test snapshot(ctrl).state === :ready && isnothing(snapshot(ctrl).last_error)
            @test ENV["LEGEND_DATA_CONFIG"] == config
            # the new production has no config folder yet, so the shipped config is loaded with a new log folder
            @test loaded[]["config"] == JuLeAna.default_config_file() && loaded[]["log_path"] == ""
            @test only(snapshot(ctrl).allocations).state === :cancelled
            @test any(contains("Loading the new production $(dirname(config))"), JuLeAna.production_log(ctrl))
            # a spec that fails its check is rejected at once
            @test_throws "$(joinpath(parent, "prod")) exists" dispatch!(ctrl, CreateProduction(spec))
            # a failing creation keeps the session and the data production
            bad = JuLeAna.ProductionSpec(; name = "bad", parent, metadata_url = joinpath(parent, "missing"), copy_software = false)
            dispatch!(ctrl, CreateProduction(bad))
            wait(ctrl)
            @test snapshot(ctrl).state === :ready && occursin("failed with exit code", snapshot(ctrl).last_error)
            @test ENV["LEGEND_DATA_CONFIG"] == config
            # without a processing config no session can be loaded
            nothing_ctrl = DataflowController(Dict{String,Any}("config" => nothing); processors, loader = _ -> new_session(),
                                              record_software = false, record_metadata = false)
            @test_throws "no processing config" dispatch!(nothing_ctrl, LoadSession())
        end
    end

    @testset "select a production and a dataset" begin
        parent = mktempdir()
        mkpath(joinpath(parent, "other"))
        write(joinpath(parent, "other", "config.json"), "{}")
        # a site override stays in front of the production
        site = joinpath(parent, "site.yaml")
        withenv("LEGEND_DATA_CONFIG" => "$site:$(joinpath(parent, "current", "config.json"))") do
            loaded = Ref{Any}(nothing)
            ctrl = DataflowController(Dict{String,Any}("config" => shipped_config, "log_path" => "old", "dataset" => "default"); processors,
                                      loader = args -> (loaded[] = copy(args); new_session()), record_software = false,
                                      record_metadata = false)
            @test snapshot(ctrl).dataset == "default"
            dispatch!(ctrl, SelectDataset(:valid))
            wait(ctrl)
            @test snapshot(ctrl).state === :ready && snapshot(ctrl).dataset == "valid"
            @test loaded[]["dataset"] == "valid" && loaded[]["log_path"] == ""
            dispatch!(ctrl, SelectProduction(joinpath(parent, "other")))
            wait(ctrl)
            @test snapshot(ctrl).state === :ready && snapshot(ctrl).dataset == "default"
            @test ENV["LEGEND_DATA_CONFIG"] == "$site:$(joinpath(parent, "other", "config.json"))"
            @test loaded[]["config"] == JuLeAna.default_config_file() && loaded[]["dataset"] == "default"
            # a folder without config.json is no production
            @test_throws "no config.json" dispatch!(ctrl, SelectProduction(joinpath(parent, "missing")))
            @test ENV["LEGEND_DATA_CONFIG"] == "$site:$(joinpath(parent, "other", "config.json"))"
            # a failing load leaves no session
            bad = DataflowController(Dict{String,Any}("config" => shipped_config, "dataset" => "default"); processors,
                                     loader = _ -> error("dataset nope is not in the run lists"), record_software = false,
                                     record_metadata = false)
            dispatch!(bad, SelectDataset(:nope))
            wait(bad)
            @test snapshot(bad).state === :idle && occursin("dataset nope", snapshot(bad).last_error)
            # not while processing
            running = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
            running.state = :running
            @test_throws "SelectDataset is not possible" dispatch!(running, SelectDataset(:valid))
            @test_throws "SelectProduction is not possible" dispatch!(running, SelectProduction(parent))
        end
    end

    @testset "kwarg resets and snapshot kwargs" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        energy() = only(filter(p -> p.name === :process_energy_calibration_cal, snapshot(ctrl).processors))
        @test energy().accepted == [:max_wvfs]
        @test isempty(energy().config_kwargs)
        dispatch!(ctrl, SetKwarg(:process_energy_calibration_cal, :max_wvfs, 5))
        @test energy().kwargs[:max_wvfs] == 5 && isempty(energy().config_kwargs)
        dispatch!(ctrl, ResetKwargs(:process_energy_calibration_cal, :max_wvfs))
        @test isempty(energy().overridden) && !haskey(energy().kwargs, :max_wvfs)
        @test isempty(ctrl.kwarg_overrides)
        # resetting a key that is not overridden changes nothing
        dispatch!(ctrl, ResetKwargs(:process_energy_calibration_cal, :max_wvfs))
        @test_throws "ResetKwargs: a key needs a processor" ResetKwargs(nothing, :max_wvfs)

        # level overrides change the levels of the processor in the effective config
        @test energy().log_level == Logging.Info && energy().plot_level === :info
        dispatch!(ctrl, SetStepLevel(:process_energy_calibration_cal, :log_level, "debug"))
        dispatch!(ctrl, SetStepLevel(:process_energy_calibration_cal, :plot_level, :debug))
        @test energy().log_level == Logging.Debug &&
              energy().plot_level === :debug &&
              energy().config_log_level == Logging.Info &&
              energy().config_plot_level === :info
        @test energy().overridden == [:log_level, :plot_level]
        spec = JuLeAna.effective_config(ctrl).processors[:process_energy_calibration_cal]
        @test spec.log_level == Logging.Debug && spec.plot_level === :debug
        dispatch!(ctrl, ResetKwargs(:process_energy_calibration_cal, :log_level))
        @test energy().log_level == Logging.Info && energy().overridden == [:plot_level]
        dispatch!(ctrl, ResetKwargs())
        @test isempty(energy().overridden) && isempty(ctrl.level_overrides)
        @test_throws "the log level must be" SetStepLevel(:process_energy_calibration_cal, :log_level, "verbose")
        @test_throws "the plot level must be" SetStepLevel(:process_energy_calibration_cal, :plot_level, :all)
        @test_throws "the key must be" SetStepLevel(:process_energy_calibration_cal, :max_wvfs, 1)
        @test_throws "unknown processor" dispatch!(ctrl, SetStepLevel(:nope, :log_level, "debug"))
    end
    @testset "step settings" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        energy() = only(filter(p -> p.name === :process_energy_calibration_cal, snapshot(ctrl).processors))
        step = :process_energy_calibration_cal
        dispatch!(ctrl, SetStepSetting(step, :rank, 7))
        dispatch!(ctrl, SetStepSetting(step, :category, "phy"))
        dispatch!(ctrl, SetStepSetting(step, :error_plots, true))
        dispatch!(ctrl, SetStepSetting(step, :detectors, "processable"))
        dispatch!(ctrl, SetStepSetting(step, :dependencies, ["process_dsp_cal"]))
        table = deepcopy(JuLeAna.DEFAULT_REPORT_STATUS)
        table[:off][:failure] = :failure
        dispatch!(ctrl, SetStepSetting(step, :report_status, Dict(:off => Dict(:failure => :failure))))
        @test energy().rank == 7 && energy().category === :phy && energy().error_plots && energy().detectors == "processable"
        @test energy().dependencies == [:process_dsp_cal] && energy().report_status == table
        @test energy().config_spec.rank == 1 && energy().config_spec.category === :cal && isnothing(energy().config_spec.detectors)
        @test energy().overridden == sort([:rank, :category, :error_plots, :detectors, :dependencies, :report_status])
        @test JuLeAna.effective_config(ctrl).processors[step].rank == 7

        # invalid values are refused and leave the overrides unchanged
        before = deepcopy(ctrl.setting_overrides)
        @test_throws "not a valid detector expression" dispatch!(ctrl, SetStepSetting(step, :detectors, ")("))
        @test_throws "names the processor itself" dispatch!(ctrl, SetStepSetting(step, :dependencies, [step]))
        @test_throws "unknown processor" dispatch!(ctrl, SetStepSetting(step, :dependencies, [:nope]))
        @test_throws "form a cycle" dispatch!(ctrl, SetStepSetting(:process_dsp_cal, :dependencies, [step]))
        @test_throws "must be \"cal\" or \"phy\"" dispatch!(ctrl, SetStepSetting(step, :category, :other))
        @test_throws "unknown processor" dispatch!(ctrl, SetStepSetting(:nope, :rank, 1))
        @test_throws "the key must be" SetStepSetting(step, :enabled, true)
        @test_throws "`rank` must be an Int" SetStepSetting(step, :rank, "1")
        @test_throws "unknown key" SetStepSetting(step, :report_status, Dict(:nope => Dict()))
        @test ctrl.setting_overrides == before

        dispatch!(ctrl, ResetKwargs(step))
        @test isempty(energy().overridden) && isempty(ctrl.setting_overrides)
    end

    @testset "report_index and report_overview" begin
        ctrl = DataflowController(new_session(); processors, record_software = false, record_metadata = false)
        jlrep = l200.tier[:jlrep]
        failed = JuLeAna.report_path(l200, :process_energy_calibration_cal, :run, p2, DataRun(6), :cal)
        mkpath(dirname(failed))
        write(failed, RUN_REPORT)
        before = sort!([joinpath(r, f) for (r, _, fs) in walkdir(jlrep) for f in fs])

        # the reports of the steps of the current or last run, none before the first run
        @test isempty(JuLeAna.report_index(ctrl))
        dispatch!(ctrl, StartProcessing())
        wait(ctrl)
        @test snapshot(ctrl).outcome === :finished
        rows = JuLeAna.report_index(ctrl)
        energy = filter(r -> r.process === :process_energy_calibration_cal, rows)
        @test [(r.period, r.run, r.state) for r in energy] == [[(p2, r, r == DataRun(6) ? :failed : :missing) for r in DataRun.(0:7)];
                                                               [(p3, r, :missing) for r in DataRun.(0:5)]]
        @test energy[7].path == failed && energy[7].n_failed == 1
        partition = filter(r -> r.level === :partition, rows)
        @test [(r.process, r.period, r.run, r.state) for r in partition] ==
              [(:p_process_aoe_cut_cal, p2, nothing, :missing), (:p_process_aoe_cut_cal, p3, nothing, :missing)]
        # a later change of the selection does not change the rows
        dispatch!(ctrl, SelectSteps(Symbol[], [:p_process_aoe_cut_cal]))
        dispatch!(ctrl, SelectPeriods([p3]))
        @test [(r.process, r.period, r.run) for r in JuLeAna.report_index(ctrl)] == [(r.process, r.period, r.run) for r in rows]

        overview = JuLeAna.report_overview(ctrl)
        @test [(o.name, o.level, o.category, o.nreports) for o in overview] == [("energy_calibration", :run, "cal", 1)]
        @test overview[1].counts == (; ok = 0, warning = 0, failed = 1)
        @test sort!([joinpath(r, f) for (r, _, fs) in walkdir(jlrep) for f in fs]) == before

        # all processors of the config against all runs of the runinfo
        grid = JuLeAna.history_grid(ctrl)
        @test [(r.process, r.level) for r in grid.rows] ==
              [(:process_energy_calibration_cal, :run), (:process_dsp_cal, :run), (:p_process_aoe_cut_cal, :partition)]
        @test [p.period for p in grid.periods] ⊇ [p2, p3]
        @test haskey(grid.rows[1].cells, (p2, DataRun(6)))

        idle = DataflowController(Dict{String,Any}("config" => shipped_config); processors, loader = _ -> new_session(),
                                  record_software = false, record_metadata = false)
        @test_throws "report_index: no session is loaded" JuLeAna.report_index(idle)
        @test_throws "report_overview: no session is loaded" JuLeAna.report_overview(idle)
        @test_throws "history_grid: no session is loaded" JuLeAna.history_grid(idle)
    end
end
