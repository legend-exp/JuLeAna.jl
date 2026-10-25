# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Test
using Logging: Logging, with_logger
using LegendDataManagement: DataPeriod, DataRun, FileKey, ProcessStatus

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

const NoTuiLog = NamedTuple{(:Filekey, :Status, :Error)}

@testset "run_no_tui" begin
    root = mktempdir()
    data_config = legend_test_setup(root, TEST_DIRS)
    l200 = legend_test_data(data_config)
    p2 = DataPeriod(2)
    args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
    cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                           p_processors = Dict{Symbol,ProcessorSpec}())
    runs = DataRun.([6, 7])
    function loader(parsed_args)
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [p2], runs, run_steps(cfg), partition_steps(cfg))
        return DataflowSession(; args = parsed_args, l200, config = cfg, periods, runs, run_steps = run_steps(cfg),
                               partition_steps = partition_steps(cfg), run_status, partition_status)
    end
    # Run `run_no_tui` with `step` as the energy calibration and return the exit code and
    # the text of the logged messages.
    function run_logged(step; loader = loader, before_wait = nothing)
        logger = Test.TestLogger(; min_level = Logging.Info)
        code = with_logger(logger) do
            JuLeAna.run_no_tui(args; processors = Dict{Symbol,Any}(:process_energy_calibration_cal => step), loader, interval = 0.05,
                               record_software = false, record_metadata = false)
        end
        return code, [string(r.message) for r in logger.logs if r.message isa AbstractString]
    end

    @testset "finished" begin
        code, messages = run_logged((cfg, l200, period, run; reprocess = false) -> nothing)
        @test code == 0
        summary = only(filter(startswith("Processing finished after"), messages))
        @test occursin("\nSteps: 2 done", summary)
        @test !occursin("Failed:", summary)
    end

    @testset "failed" begin
        failing(cfg, l200, period, run; reprocess = false) = run == DataRun(6) ? error("stub failure") : nothing
        code, messages = run_logged(failing)
        @test code == 1
        summary = only(filter(startswith("Processing failed after"), messages))
        @test occursin("Steps: 1 done, 1 failed", summary)
        @test occursin("\nFailed: p02-r006 process_energy_calibration_cal", summary)
        @test occursin("Error: ", summary) && occursin("stub failure", summary)
    end

    @testset "session setup fails" begin
        code, messages = run_logged((cfg, l200, period, run; reprocess = false) -> nothing; loader = parsed_args -> error("no data"))
        @test code == 1
        @test any(m -> occursin("Setting up the session failed", m) && occursin("no data", m), messages)
    end

    @testset "interrupts stop the run" begin
        started = Threads.Atomic{Int}(0)
        filekeys = [FileKey("l200-p02-r006-cal-20230101T00000$(i)Z") for i in 1:4]
        slow_step(cfg, l200, period, run; reprocess = false) = parallel(filekeys, NoTuiLog) do fk
            Threads.atomic_add!(started, 1)
            sleep(1)
            (processed = true, log = NoTuiLog((fk, ProcessStatus(1), "")))
        end
        for interrupts in (1, 2)
            started[] = 0
            ctrl = DataflowController(loader(args); processors = Dict{Symbol,Any}(:process_energy_calibration_cal => slow_step),
                                      record_software = false, record_metadata = false)
            dispatch!(ctrl, SelectRuns([6]))
            dispatch!(ctrl, StartProcessing())
            @test timedwait(() -> started[] >= 1, 60) === :ok
            # `waiter` throws like Ctrl-C would, `interrupts` times, then waits for the run
            left = Ref(interrupts)
            waiter(c) = left[] > 0 ? (left[] -= 1; throw(InterruptException())) : wait(c)
            logger = Test.TestLogger(; min_level = Logging.Info)
            t0 = time()
            with_logger(() -> JuLeAna.wait_with_interrupts(ctrl; waiter), logger)
            messages = [string(r.message) for r in logger.logs]
            @test snapshot(ctrl).outcome === :stopped
            @test any(startswith("Stopping: running items finish"), messages)
            step = only(progress(ctrl).steps)
            if interrupts == 1
                # the running item finished
                @test step.done == 1 && step.notrun == 3
            else
                @test any(startswith("Stopping without waiting for the running items"), messages)
                @test step.done == 0 && step.notrun == 4
                @test time() - t0 < 1
            end
        end
    end
end
