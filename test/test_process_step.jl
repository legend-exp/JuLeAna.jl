# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using JuLeAna: @process_step, ProcessStepError
using Test
using Logging
using Base.ScopedValues: with
using LegendDataManagement: DataPeriod, DataRun, DetectorId, FileKey, ProcessStatus

# At top level, so that `Base.@locals` sees no variables of an enclosing scope
function capture_nested(x)
    outer = x
    @process_step "outer" begin
        mid = 2x
        @process_step "inner $x" begin
            inner_new = 3x
            error("boom")
        end
    end
end

module RerunTarget
using JuLeAna: @process_step
# visible only in this module, so a rerun must run in it
above(values, threshold) = filter(>(threshold), values)
function mean_above(values, threshold)
    @process_step "mean above $threshold" begin
        selected = above(values, threshold)
        isempty(selected) && error("nothing above $threshold")
        sum(selected) / length(selected)
    end
end
end

function rerun_nested(x)
    @process_step "outer" begin
        y = @process_step "inner" sqrt(x)
        y > 2 || error("too small")
        y
    end
end

function rerun_continue()
    for i in 1:2
        @process_step "loop step" begin
            i == 2 && continue
            error("first")
        end
    end
end

rerun_context(fail) = @process_step "context" begin
    fail && error("x")
    (JuLeAna.WRITE_PARS[], JuLeAna.CURRENT_ITEM[])
end

const HOOK_CALLS = Ref(0)
function hooked(fail_hook)
    @process_step "hooked" on_error = () -> (HOOK_CALLS[] += 1; fail_hook && error("no plot")) error("step")
end
hooked_outer() = @process_step "outer" on_error = () -> (HOOK_CALLS[] += 100) begin
    @process_step "inner" error("step")
end

function paused_steps(x)
    a = @process_step "first $x" x + 1
    b = @process_step "second" 2a
    @process_step "fails" error("boom $b")
end

# The stops of `f()` with the debug options `options`, as (variables, line)
function stops_of(f; options...)
    stops = []
    JuLeAna.STOP_HOOK[] = (mod, vars, file, line) -> push!(stops, (; mod, vars, file, line))
    try
        with_logger(NullLogger()) do
            try
                with(f, JuLeAna.DEBUG_CAPTURE => JuLeAna.debug_capture(:proc, (); options...))
            catch
            end
        end
    finally
        JuLeAna.STOP_HOOK[] = nothing
    end
    return stops
end

# The single failure that `f()` captures, also as the failures of the last `run_step` call
function capture_failure(f, item = nothing)
    capture = JuLeAna.debug_capture(:proc, ())
    with_logger(NullLogger()) do
        try
            with(f, JuLeAna.DEBUG_CAPTURE => capture, JuLeAna.CURRENT_ITEM => item)
        catch
        end
    end
    JuLeAna.LAST_FAILURES[] = capture.failures
    return only(capture.failures)
end

@testset "process_step" begin
    @testset "value and scope" begin
        function assigns(x)
            declared = 0
            value = @process_step "assign" begin
                declared = x + 1
                inner = 2x
                declared + inner
            end
            return value, declared, @isdefined(inner)
        end
        @test assigns(1) == (4, 2, false)

        function fails_after_assigning()
            declared = 0
            try
                @process_step "fails" begin
                    declared = 1
                    error("boom")
                end
            catch
            end
            return declared
        end
        @test (@test_logs (:error,) fails_after_assigning()) == 1
    end

    @testset "error and log" begin
        e_type = :e_cusp
        err = @test_logs (:error, "e_cusp simple calibration failed: ErrorException(\"no peaks\")") try
            @process_step "$e_type simple calibration" begin
                error("no peaks")
            end
        catch e
            e
        end
        @test err isa ProcessStepError
        @test err.name == "e_cusp simple calibration"
        @test err.item === nothing
        @test err.exception == ErrorException("no peaks")
        @test string(err) == "e_cusp simple calibration: ErrorException(\"no peaks\")"
        @test JuLeAna.root_exception(err) === err
        @test truncate_error(err) == "e_cusp simple calibration: ErrorException(\"no peaks\")"

        # the root exception of a wrapped failure is reported
        wrapped = @test_logs (:error, "spawned failed: ErrorException(\"inner\")") try
            @process_step "spawned" begin
                wait(Threads.@spawn error("inner"))
            end
        catch e
            e
        end
        @test wrapped.exception == ErrorException("inner")
    end

    @testset "nested steps log once" begin
        nested() = @process_step "outer" begin
            @process_step "middle" begin
                @process_step "inner" begin
                    throw(ArgumentError("bad window"))
                end
            end
        end
        err = @test_logs (:error, "inner failed: ArgumentError(\"bad window\")") try
            nested()
        catch e
            e
        end
        @test err.name == "inner"
        @test err.exception == ArgumentError("bad window")
    end

    @testset "detector of the item" begin
        row = (detector = DetectorId(:V00048B), usability = :on, channel = 1)
        err = @test_logs (:error, "fit failed for V00048B: ErrorException(\"x\")") try
            with(JuLeAna.CURRENT_ITEM => row) do
                @process_step "fit" error("x")
            end
        catch e
            e
        end
        @test err.item === row

        # through `parallel`, the failure reaches the log table as "<name>: <error>"
        DetLog = NamedTuple{(:Detector, :usability, :Status, :X, :Error)}
        result = with_logger(NullLogger()) do
            JuLeAna.parallel([row], DetLog) do r
                @process_step "fit" error("x")
            end
        end
        @test only(result).second.log.Error == "fit: ErrorException(\"x\")"

        fk = FileKey("l200-p03-r000-cal-20230311T235840Z")
        FkLog = NamedTuple{(:Filekey, :Status, :A, :B, :Error)}
        logger = Test.TestLogger()
        with_logger(logger) do
            JuLeAna.parallel(k -> (@process_step "load" error("missing file")), [fk], FkLog)
        end
        @test only(filter(r -> r.level == Logging.Error, logger.logs)).message == "load failed: ErrorException(\"missing file\")"
    end

    @testset "capture" begin
        module_for_locals = Module()
        capture = JuLeAna.debug_capture(:proc, (DataPeriod(3), DataRun(1)))
        failures = capture.failures
        row = (detector = DetectorId(:V00048B), usability = :on)
        err = with_logger(NullLogger()) do
            try
                with(() -> capture_nested(5), JuLeAna.DEBUG_CAPTURE => capture, JuLeAna.CURRENT_ITEM => row)
            catch e
                e
            end
        end
        @test err isa ProcessStepError
        # only the innermost step captures; the variables first assigned in it are not visible
        f = only(failures)
        @test propertynames(f) == (:mid, :outer, :x)
        @test (f.x, f.outer, f.mid) == (5, 5, 10)
        @test_throws "the failure of \"inner 5\" captured no variable `inner_new`; it captured mid, outer, x" f.inner_new
        info = JuLeAna.failure_info(f)
        @test info.name == "inner 5" && info.step == :proc && info.item === row && info.detector == DetectorId(:V00048B)
        @test info.exception == ErrorException("boom") && !isempty(info.backtrace)
        @test info.block isa Expr && info.file == @__FILE__
        @test JuLeAna.failure_variables(f) == Dict(:x => 5, :outer => 5, :mid => 10)
        @test sprint(show, f) == "Failure(\"inner 5\" for V00048B)"
        @test sprint(show, MIME"text/plain"(), f) ==
              "\"inner 5\" failed for V00048B in proc p03 r001 at $(info.file):$(info.line)\n" *
              "  error: ErrorException(\"boom\")\n  variables: mid, outer, x\n  code:\n    inner_new = 3x\n    error(\"boom\")"
        @test JuLeAna.define_locals(module_for_locals, f) == [:mid, :outer, :x]
        @test module_for_locals.mid == 10 && module_for_locals.x == 5
        @test occursin("2 failed `@process_step` captured", sprint(JuLeAna.print_failures, [f, f]))
        @test sprint(JuLeAna.print_failures, JuLeAna.Failure[]) == "run_step: no failed `@process_step` was captured\n"

        # without debug mode nothing is captured
        with_logger(NullLogger()) do
            try
                capture_nested(1)
            catch
            end
        end
        @test length(failures) == 1
    end

    @testset "rerun" begin
        f = capture_failure(() -> RerunTarget.mean_above([1, 2], 5))
        @test JuLeAna.failure_info(f).mod === RerunTarget
        # unchanged, it fails in the same way and replaces the failure
        @test_throws ErrorException("nothing above 5") with_logger(() -> JuLeAna.rerun(f), NullLogger())
        f2 = JuLeAna.failure()
        @test f2 !== f && only(JuLeAna.failures()) === f2 && JuLeAna.failure_info(f2).name == "mean above 5"
        @test f2.values == [1, 2]
        # an override fixes it
        @test JuLeAna.rerun(f2; values = [4, 6, 8]) == 7.0
        @test JuLeAna.rerun(f2; values = [1, 3], threshold = 0) == 2.0
        @test_throws "rerun: thresh is not a captured variable of \"mean above 5\"; the captured variables are threshold, values" JuLeAna.rerun(f2;
                                                                                                                                                thresh = 0)

        # a failed outer step with an inner one
        f = capture_failure(() -> rerun_nested(1))
        @test JuLeAna.failure_info(f).name == "outer" && propertynames(f) == (:x,)
        @test JuLeAna.rerun(f; x = 9) == 3.0

        # the item of the failure, and no parameters are written
        row = (detector = DetectorId(:V00048B), usability = :on)
        f = capture_failure(() -> rerun_context(true), row)
        @test JuLeAna.rerun(f; fail = false) == (false, row)

        f = capture_failure(rerun_continue)
        @test_throws "rerun: the block of \"loop step\" contains `continue`, which leaves the block" JuLeAna.rerun(f)
        @test JuLeAna.block_exit(:(return 1)) == "return"
        @test JuLeAna.block_exit(:(if a
                                       ;break;
                                   end)) == "break"
        @test JuLeAna.block_exit(:(@goto done)) == "@goto"
        @test JuLeAna.block_exit(:(for i in 1:2
                                       ;i == 1 && continue;
                                       break;
                                   end)) === nothing
        @test JuLeAna.block_exit(:(while true
                                       ;break;
                                   end)) === nothing
        @test JuLeAna.block_exit(:(g(x) = return x)) === nothing
        @test JuLeAna.block_exit(:(map(x -> return x, 1:2))) === nothing
        @test JuLeAna.block_exit(:(function g()
                                       ;return 1;
                                   end)) === nothing
    end

    @testset "on_error" begin
        # off by default
        @test_throws ProcessStepError with_logger(() -> hooked(false), NullLogger())
        @test HOOK_CALLS[] == 0
        err = with(JuLeAna.ERROR_PLOTS => true) do
            @test_logs (:error, "hooked failed: ErrorException(\"step\")") try
                hooked(false)
            catch e
                e
            end
        end
        @test HOOK_CALLS[] == 1 && err.exception == ErrorException("step")
        # a failing hook only warns, and the error of the step is thrown unchanged
        err = with(JuLeAna.ERROR_PLOTS => true) do
            @test_logs (:error, "hooked failed: ErrorException(\"step\")") (:warn,
                                                                            "the error plot of hooked failed: ErrorException(\"no plot\")") try
                hooked(true)
            catch e
                e
            end
        end
        @test HOOK_CALLS[] == 2 && err isa ProcessStepError && err.exception == ErrorException("step")
        # only the innermost failing step runs its hook
        with(() -> with_logger(() -> try
                                   hooked_outer()
                               catch
                               end, NullLogger()), JuLeAna.ERROR_PLOTS => true)
        @test HOOK_CALLS[] == 2
        @test_throws "@process_step: unknown option `plot = 1`, expected `on_error = hook`" macroexpand(@__MODULE__,
                                                                                                        :(@process_step "x" plot = 1 nothing))
    end

    @testset "pause and infiltrate" begin
        stops = stops_of(() -> paused_steps(1); pause = :all)
        @test [s.vars for s in stops] == [Dict(:x => 1, :step_value => 2), Dict(:x => 1, :a => 2, :step_value => 4)]
        @test all(s -> s.mod === @__MODULE__() && s.file == @__FILE__, stops)
        @test stops[2].line == stops[1].line + 1
        stops = stops_of(() -> paused_steps(1); pause = ["second"])
        @test only(stops).vars[:step_value] == 4
        @test isempty(stops_of(() -> paused_steps(1); pause = ["first 2"]))
        # at the failure, with the variables of the capture
        stops = stops_of(() -> paused_steps(1); infiltrate = true)
        @test only(stops).vars == Dict(:x => 1, :a => 2, :b => 4)
        # the stop at a failure logs the code of the step
        JuLeAna.STOP_HOOK[] = (args...) -> nothing
        try
            capture = JuLeAna.debug_capture(:proc, (); infiltrate = true)
            @test_logs (:error,) (:info, r"^Stopped at the failed fails\. The code of the step:\n```julia\nerror\(\"boom ") try
                with(() -> paused_steps(1), JuLeAna.DEBUG_CAPTURE => capture)
            catch
            end
        finally
            JuLeAna.STOP_HOOK[] = nothing
        end
        @test isempty(stops_of(() -> paused_steps(1)))
        # a pause logs where it stopped
        JuLeAna.STOP_HOOK[] = (args...) -> nothing
        try
            capture = JuLeAna.debug_capture(:proc, (); pause = ["second"])
            @test (@test_logs (:info, "Paused after second; its value is `step_value`. The code of the step:\n```julia\n4\n```") with(() -> (@process_step "second" 4),
                                                                                                                                      JuLeAna.DEBUG_CAPTURE =>
                                                                                                                                          capture)) ==
                  4
        finally
            JuLeAna.STOP_HOOK[] = nothing
        end
    end

    @testset "log location" begin
        logger = Test.TestLogger()
        line = @__LINE__() + 3
        with_logger(logger) do
            try
                @process_step "located" error("x")
            catch
            end
        end
        record = only(logger.logs)
        @test record.file == @__FILE__
        @test record.line == line
    end
end
