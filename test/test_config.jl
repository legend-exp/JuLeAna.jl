# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Test
using LegendTestData: legend_test_data_path
using Distributed: nprocs
using Logging: global_logger
using ParallelProcessingTools: ppt_worker_pool, ppt_worker_pool!
using LegendDataManagement: LegendDataManagement, DataPeriod, DataRun, LegendData, readlprops, start_filekey, writelprops
using LegendDataManagement.LDMUtils: get_preportfilename, get_rreportfilename

const TEST_METADATA = joinpath(legend_test_data_path(), "data", "legend", "metadata")

# Write a data config in `root` with the LegendTestData metadata and tiers under
# `root/tier`, create the run directories `dirs` (relative to the tier root) and
# return the path of the data config.
function legend_test_setup(root::AbstractString, dirs)
    config = joinpath(root, "config.json")
    write(config, """
        {"setups": {"l200": {
            "paths": {"metadata": "$TEST_METADATA", "tier": "$root/tier", "par": "$root/par",
                      "log": "$root/log", "plt": "$root/plt"},
            "dataset": "valid"}}}
        """)
    for d in dirs
        mkpath(joinpath(root, "tier", d))
    end
    return config
end

# `LegendData(:l200)` for the data config `config`.
function legend_test_data(config::AbstractString)
    return withenv(() -> LegendData(:l200), "LEGEND_DATA_CONFIG" => config)
end

const TEST_DIRS = ["raw/cal/p02/r006", "raw/cal/p02/r007", "raw/cal/p03/r000", "raw/cal/p13", "raw/phy/p16/r006"]

const RUN_REPORT = """
| Detector | Status | Filter Type | Error |
|:---|:---|:---|:---|
| V01 | <span style="color:green">Success</span> | trap | - |
| V02 | <span style="color:red">Failure</span> | trap | fit failed |
"""

const PARTITION_REPORT = """
| Detector | Status | Partition | Error |
|:---|:---|:---|:---|
| V01 | Success | 1 | - |
"""

function spec(name, level, rank; kwargs...)
    return ProcessorSpec(; name, level, category = :cal, rank, kwargs...)
end

@testset "config" begin
    root = mktempdir()
    data_config = legend_test_setup(root, TEST_DIRS)
    l200 = legend_test_data(data_config)
    p2, p3, p13, p16 = DataPeriod.((2, 3, 13, 16))

    @testset "available periods and runs" begin
        # the runinfo decides, not the data on disk (p13 has no runs on disk)
        @test JuLeAna.available_periods(l200) == [p2, p3, p13, p16]
        @test JuLeAna.available_runs(l200, p2) == DataRun.(0:7)
        @test JuLeAna.available_runs(l200, p16) == DataRun.(6:9)
        @test JuLeAna.available_runs(l200, DataPeriod(99)) == DataRun[]
        # the dataset `valid` lists runs of p02 and p03 only
        valid = withenv(() -> LegendData(:l200; dataset = :valid), "LEGEND_DATA_CONFIG" => data_config)
        @test JuLeAna.available_periods(valid) == [p2, p3]
        @test JuLeAna.available_runs(valid, p3) == DataRun.(0:5)
        @test JuLeAna.available_runs(valid, p16) == DataRun[]
    end

    @testset "processable_runs" begin
        @test JuLeAna.processable_runs(l200, p2, nothing) == DataRun.(0:7)
        @test JuLeAna.processable_runs(l200, p2, [DataRun(7)]) == [DataRun(7)]
        @test (@test_logs (:warn, "Run r008 not found in period p02") JuLeAna.processable_runs(l200, p2, DataRun.([6, 8]))) == [DataRun(6)]
    end

    cfg = ProcessingConfig(;
                           processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1),
                                             :process_dsp_cal => spec(:process_dsp_cal, :run, 2; enabled = false)),
                           p_processors = Dict(:p_process_aoe_cut_cal => spec(:p_process_aoe_cut_cal, :partition, 1)))

    @testset "setup_dependency_graph" begin
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [p2, p3, DataPeriod(99)], nothing,
                                                                               [:process_energy_calibration_cal], Symbol[])
        @test periods == [p2, p3]
        @test sort(collect(keys(run_status[p2][:process_energy_calibration_cal]))) == DataRun.(0:7)
        # only the selected steps start as unfinished
        @test !any(values(run_status[p2][:process_energy_calibration_cal]))
        @test all(values(run_status[p2][:process_dsp_cal]))
        @test partition_status[p3][:p_process_aoe_cut_cal]

        periods, run_status, _ = @test_logs (:warn, "Run r007 not found in period p03") JuLeAna.setup_dependency_graph(l200, cfg, [p2, p3],
                                                                                                                       [DataRun(7)],
                                                                                                                       Symbol[],
                                                                                                                       [:p_process_aoe_cut_cal])
        @test periods == [p2]
        @test collect(keys(run_status[p2][:process_energy_calibration_cal])) == [DataRun(7)]
    end

    @testset "DataflowSession" begin
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [p2], nothing, Symbol[], Symbol[])
        session = DataflowSession(; args = Dict{String,Any}(), l200, config = cfg, periods, run_steps = [:process_energy_calibration_cal],
                                  partition_steps = [:p_process_aoe_cut_cal], run_status, partition_status)
        @test isnothing(session.runs)

        # resetting marks the session's scheduled steps as unfinished
        @test all(values(session.run_status[p2][:process_energy_calibration_cal]))
        @test JuLeAna.reset_dependency_graph!(session) === session
        @test !any(values(session.run_status[p2][:process_energy_calibration_cal]))
        @test !session.partition_status[p2][:p_process_aoe_cut_cal]

        session.runs = [DataRun(6)]
        JuLeAna.reset_dependency_graph!(session)
        @test collect(keys(session.run_status[p2][:process_energy_calibration_cal])) == [DataRun(6)]

        shown = sprint(show, session)
        @test occursin("1 period(s)", shown)
        @test occursin("1 run(s)", shown)
        @test occursin("1 run and 1 partition steps", shown)
        session.runs = nothing
        @test occursin("all runs", sprint(show, session))

        # p02 is the only period of its default partitions
        @test JuLeAna.partition_periods(l200, p2) == [p2]

        # `run_processing(session)` runs the session's steps and marks them as finished
        calls = Tuple{Symbol,DataPeriod,Any}[]
        calls_lock = ReentrantLock()
        run_stub(cfg, l200, period, run; kwargs...) = (lock(() -> push!(calls, (:run, period, run)), calls_lock); nothing)
        partition_stub(cfg, l200, period; kwargs...) = (lock(() -> push!(calls, (:partition, period, nothing)), calls_lock); false)
        JuLeAna.reset_dependency_graph!(session)
        run_processing(session;
                       processors = Dict{Symbol,Any}(:process_energy_calibration_cal => run_stub, :p_process_aoe_cut_cal => partition_stub))
        @test sort(calls; by = string) == sort([[(:run, p2, r) for r in DataRun.(0:7)]; (:partition, p2, nothing)]; by = string)
        @test all(values(session.run_status[p2][:process_energy_calibration_cal]))
        @test session.partition_status[p2][:p_process_aoe_cut_cal]
    end

    @testset "load_qc_evaluator" begin
        fk = start_filekey(l200, (p2, DataRun(6), :cal))
        @test ismissing(@test_logs (:info, r"The ML quality cut is disabled") match_mode = :any load_qc_evaluator(l200, fk))
    end

    @testset "mirror_override_folders" begin
        dir = mktempdir()
        overrides = mkpath(joinpath(dir, "overrides", "ppars", "pz", "V01"))
        write(joinpath(overrides, "fixed_tau.yaml"), "tau: 1")
        mkpath(joinpath(dir, "overrides", "rpars", "ml"))
        base = mkpath(joinpath(dir, "par", "ppars"))
        @test sort(JuLeAna.mirror_override_folders(joinpath(dir, "overrides"), joinpath(dir, "par"))) ==
              sort(joinpath.(dir, "par", ["ppars/pz", "ppars/pz/V01", "rpars", "rpars/ml"]))
        @test isdir(joinpath(base, "pz", "V01")) && isempty(readdir(joinpath(base, "pz", "V01")))
        @test isempty(JuLeAna.mirror_override_folders(joinpath(dir, "overrides"), joinpath(dir, "par")))
        # the metadata of LegendTestData has no parameter overrides
        @test isempty(JuLeAna.mirror_override_folders(l200))
    end

    @testset "setup_processing" begin
        props = readlprops(joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        props.config.env_variables = Dict("LEGEND_DATA_CONFIG" => data_config)
        processing_config = joinpath(root, "processing_config.yaml")
        writelprops(processing_config, props)
        log_path = joinpath(root, "logs")
        args = JuLeAna.parse_commandline(["-c", processing_config, "-p", "2", "13", "-p", "3", "-r", "6", "-o", log_path, "--or"])
        @test args["dataset"] == "default"
        @test JuLeAna.parse_commandline(["-c", processing_config, "--dataset", "valid"])["dataset"] == "valid"
        bad_args = JuLeAna.parse_commandline(["-c", processing_config, "--dataset", "no_such_dataset"])
        withenv("LEGEND_DATA_CONFIG" => nothing) do
            @test_throws "dataset no_such_dataset is not in the metadata datasets/runlists" JuLeAna.setup_processing(bad_args)
        end
        # `setup_processing` sets `ENV` from the config's `env_variables`
        l200_setup, config, periods = withenv("LEGEND_DATA_CONFIG" => nothing) do
            JuLeAna.setup_processing(args)
        end
        @test l200_setup isa LegendData
        @test periods == [p2, p13, p3]
        @test config.periods == [p2, p13, p3]
        @test config.runs == [DataRun(6)]
        @test config.only_runs
        @test config.log_path == log_path
        @test isdir(log_path)
        @test config.env_variables == Dict("LEGEND_DATA_CONFIG" => data_config)

        # the session of the terminal interface: no terminal output and no workers
        n, logger, pool = nprocs(), global_logger(), ppt_worker_pool()
        workdir = mktempdir()
        session = try
            cd(workdir) do
                withenv("LEGEND_DATA_CONFIG" => nothing) do
                    JuLeAna.setup_session(args; console = false, start_workers = false)
                end
            end
        finally
            global_logger(logger)
            ppt_worker_pool!(pool)
        end
        @test session isa DataflowSession
        # only p02 and p13 have run r006 to process; `--or` schedules no partition steps
        @test session.periods == [p2, p13]
        @test session.run_steps == run_steps(session.config) && isempty(session.partition_steps)
        @test nprocs() == n
        @test isempty(readdir(workdir))
        @test isfile(joinpath(log_path, "head.log"))

        # SLURM without `submit_jobs`: the start script goes to the config folder of the data
        # production, which LEGEND_DATA_CONFIG of the config names, and nothing is started
        slurm_args = merge(args, Dict{String,Any}("runmode" => "slurm", "submit_jobs" => false))
        try
            cd(workdir) do
                withenv("LEGEND_DATA_CONFIG" => nothing, "SLURM_NTASKS" => "2") do
                    JuLeAna.setup_session(slurm_args; console = false)
                end
            end
        finally
            global_logger(logger)
            ppt_worker_pool!(pool)
        end
        @test occursin("srun --job-name=julia-", read(joinpath(dirname(data_config), "setup", "config", "startjlworkers.sh"), String))
        @test isempty(readdir(workdir)) && nprocs() == n
    end
end
