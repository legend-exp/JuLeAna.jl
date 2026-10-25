# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using Test
using JuLeAna
using Distributed: addprocs, remotecall_fetch, rmprocs, @everywhere
using Logging: Logging, with_logger

module LogTestModule
f() = @debug "debug from LogTestModule"
end

module LegendLogTest
f() = @debug "debug from LegendLogTest"
module Sub
f() = @debug "debug from LegendLogTest.Sub"
end
end

# Log records written by `f()` through a file-only `processing_logger`.
function logged_lines(f; log_level, debug_modules = "")
    log_file = tempname()
    withenv("JULIA_DEBUG" => debug_modules) do
        return with_logger(f, JuLeAna.processing_logger(; log_file, log_level, console_level = nothing))
    end
    return readlines(log_file)
end

@testset "logging" begin
    @testset "parse_log_level" begin
        @test JuLeAna.parse_log_level("debug") == Logging.Debug
        @test JuLeAna.parse_log_level("info") == Logging.Info
        @test JuLeAna.parse_log_level("warn") == Logging.Warn
        @test JuLeAna.parse_log_level("error") == Logging.Error
        @test_throws "key `config.log_level` must be one of" JuLeAna.parse_log_level("verbose")
    end

    @testset "record format" begin
        lines = logged_lines(; log_level = Logging.Info) do
            @info "first line\nsecond line" n = 3
            @warn "careful"
        end
        @test occursin(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z Info  \[Main\] first line$", lines[1])
        @test lines[2] == "    second line"
        @test lines[3] == "    n = 3"
        @test occursin(r"Warn  \[Main\] careful$", lines[4])
        @test startswith(lines[5], "    @ ") && occursin("test_logging.jl:", lines[5])
        @test length(lines) == 5

        lines = logged_lines(; log_level = Logging.Info) do
            try
                error("boom")
            catch e
                @error "failed" exception = (e, catch_backtrace())
            end
        end
        @test "    exception = boom" in lines
        @test any(startswith("        Stacktrace:"), lines)
    end

    @testset "levels" begin
        log_all() = (@debug "debug record"; @info "info record"; @warn "warn record"; @error "error record"; LogTestModule.f())
        messages(lines) = filter(l -> !startswith(l, "    "), lines)

        @test length(messages(logged_lines(log_all; log_level = Logging.Info))) == 3
        @test length(messages(logged_lines(log_all; log_level = Logging.Warn))) == 2
        @test length(messages(logged_lines(log_all; log_level = Logging.Error))) == 1
        # `debug` adds only the debug records of the modules in `JULIA_DEBUG`
        lines = logged_lines(log_all; log_level = Logging.Debug, debug_modules = "LogTestModule")
        @test length(messages(lines)) == 4
        @test any(contains("debug from LogTestModule"), lines)
        @test !any(contains("debug record"), lines)
        # other levels drop debug records even of the `JULIA_DEBUG` modules
        @test !any(contains("debug from LogTestModule"), logged_lines(log_all; log_level = Logging.Info, debug_modules = "LogTestModule"))
        @test !any(contains("info record"), logged_lines(log_all; log_level = Logging.Warn, debug_modules = "LogTestModule"))
    end

    @testset "processor log level" begin
        log_all() = (@info "info record"; LegendLogTest.f(); LegendLogTest.Sub.f(); LogTestModule.f())
        in_processor(level) = () -> JuLeAna.with(log_all, JuLeAna.PROCESSOR_LOG_LEVEL => level)
        has(lines, text) = any(contains(text), lines)

        # a processor at `debug` writes the debug records of the listed packages only
        lines = logged_lines(in_processor(Logging.Debug); log_level = Logging.Info)
        @test has(lines, "info record")
        @test has(lines, "debug from LegendLogTest") && has(lines, "debug from LegendLogTest.Sub")
        @test !has(lines, "debug from LogTestModule")
        # `JULIA_DEBUG` adds its modules
        @test has(logged_lines(in_processor(Logging.Debug); log_level = Logging.Info, debug_modules = "LogTestModule"),
                  "debug from LogTestModule")
        # the processor level replaces the process level
        lines = logged_lines(in_processor(Logging.Warn); log_level = Logging.Debug, debug_modules = "LogTestModule")
        @test isempty(lines)
        lines = logged_lines(in_processor(Logging.Info); log_level = Logging.Error, debug_modules = "LegendLogTest")
        @test has(lines, "info record") && !has(lines, "debug from")
        # outside of a processor, `debug` covers only the `JULIA_DEBUG` modules
        @test !has(logged_lines(log_all; log_level = Logging.Debug), "debug from")
        @test JuLeAna.debug_log_package(JuLeAna) && JuLeAna.debug_log_package(LegendLogTest.Sub)
        @test !JuLeAna.debug_log_package(Base) && !JuLeAna.debug_log_package(LogTestModule)

        # two processors at the same time keep their own levels
        log_file = tempname()
        with_logger(JuLeAna.processing_logger(; log_file, log_level = Logging.Info, console_level = nothing)) do
            @sync for (name, level) in (("chatty", Logging.Debug), ("quiet", Logging.Info))
                Threads.@spawn JuLeAna.with(JuLeAna.PROCESSOR_LOG_LEVEL => level) do
                    for _ in 1:20
                        @info "info of $name"
                        LegendLogTest.f()
                        yield()
                    end
                end
            end
        end
        lines = readlines(log_file)
        @test count(contains("info of chatty"), lines) == 20 && count(contains("info of quiet"), lines) == 20
        @test count(contains("debug from LegendLogTest"), lines) == 20
    end

    @testset "progress records" begin
        lines = logged_lines(; log_level = Logging.Debug) do
            id = JuLeAna.uuid4()
            @info JuLeAna.ProgressLogging.Progress(id, 0.5; name = "bar")
            @info "after the bar"
        end
        @test length(lines) == 1 && occursin("after the bar", only(lines))
    end

    @testset "exceptions without a backtrace" begin
        # as `@sync` reports a failed task: the cause is only inside the wrapper
        task = Threads.@spawn error("fit did not converge")
        err = try
            wait(task)
        catch e
            CompositeException([e])
        end
        text = join(logged_lines(; log_level = Logging.Info) do
                        @error "Processing failed" exception = err
                    end, "\n")
        @test occursin("fit did not converge", text)
        buf = JuLeAna.MessageBuffer()
        with_logger(() -> (@error "Processing failed" exception = err), buf)
        @test any(l -> occursin("fit did not converge", l), JuLeAna.message_lines(buf))
    end

    @testset "reports" begin
        # a report as the processors build and log it
        LDM = JuLeAna.LegendDataManagement
        report = LDM.lreport()
        LDM.lreport!(report, "# Main Log")
        LDM.lreport!(report, JuLeAna.StructArray(var"Processor Status" = [LDM.process_failed]))
        LDM.lreport!(report, "Date of processing: 2026-10-15T02:41:28Z")
        LDM.lreport!(report, "## Decay Time Extraction")
        LDM.lreport!(report, JuLeAna.StructArray(Detector = ["V$(lpad(i, 5, '0'))A" for i in 1:30], Error = fill("-", 30)))
        markdown = sprint(show, MIME"text/markdown"(), report)
        text = join(logged_lines(; log_level = Logging.Info) do
                        @info report
                    end, "\n")
        @test !occursin("NamedTuple", text)
        @test occursin("## Decay Time Extraction", text) && occursin("V00030A", text)
        @test count(==('\n'), text) >= count(==('\n'), markdown)

        buf = JuLeAna.MessageBuffer()
        with_logger(() -> (@info report), buf)
        line = only(JuLeAna.message_lines(buf))
        @test occursin("Decay Time Extraction: Failure, ", line) && occursin("lines, full text in head.log", line)
        # a short Markdown message is kept as it is
        @test JuLeAna.markdown_summary("# Title\nsome text") == "# Title\nsome text"
        @test JuLeAna.markdown_summary(join(["# Head"; ["row $i" for i in 1:25]], '\n')) == "Head: 26 lines, full text in head.log"
    end

    @testset "sinks" begin
        @test_throws "no log file and no console output" JuLeAna.processing_logger(; console_level = nothing)
        @test JuLeAna.process_log_file("logs") == joinpath("logs", "head.log")
    end

    @testset "worker log file" begin
        log_path = mktempdir()
        pid = only(addprocs(1; exeflags = "--project=$(Base.active_project())"))
        try
            @everywhere [pid] using JuLeAna
            remotecall_fetch(pid, log_path) do log_path
                JuLeAna.init_process(log_path, JuLeAna.parse_log_level("info"))
                @info "worker record"
                @debug "hidden worker record"
            end
            log_file = joinpath(log_path, "worker-$pid-$(gethostname()).log")
            @test remotecall_fetch(JuLeAna.process_log_file, pid, log_path) == log_file
            lines = readlines(log_file)
            @test any(contains("Info  [Main] worker record"), lines)
            @test !any(contains("hidden worker record"), lines)
            # only inside a SLURM job does the job's node-local shared memory hold tempdir()
            shm = mktempdir()
            tmp(job) = remotecall_fetch(pid, log_path, shm, job) do log_path, shm, job
                ENV["JOB_SHMTMPDIR"] = shm
                job ? (ENV["SLURM_JOB_ID"] = "1") : delete!(ENV, "SLURM_JOB_ID")
                JuLeAna.init_process(log_path, JuLeAna.parse_log_level("info"))
                tempdir()
            end
            @test tmp(false) != shm
            @test tmp(true) == shm
        finally
            rmprocs(pid)
        end
    end
end

@testset "@debug_progress" begin
    # the lines of a loop that skips its second item at the processor log level `level`
    function progress_output(level)
        seen = Int[]
        out = mktemp() do path, io
            redirect_stdout(io) do
                JuLeAna.with(JuLeAna.PROCESSOR_LOG_LEVEL => level) do
                    JuLeAna.@debug_progress "Filekey: fk" for x in [1, 2, 3]
                        x == 2 && continue
                        push!(seen, x)
                    end
                end
            end
            close(io)
            read(path, String)
        end
        return seen, out
    end
    seen, out = progress_output(Logging.Debug)
    @test seen == [1, 3]
    @test out == "[ Progress: Filekey: fk 1/3\n[ Progress: Filekey: fk 2/3\n" * "[ Progress: Filekey: fk 3/3\n[ Progress: Filekey: fk 3/3\n"
    @test all(l -> occursin(JuLeAna.PROGRESS_LINE, l), split(chomp(out), '\n'))
    for level in (Logging.Info, nothing)
        seen, out = progress_output(level)
        @test seen == [1, 3] && isempty(out)
    end
    @test_throws "@debug_progress: expected a loop" macroexpand(JuLeAna, :(JuLeAna.@debug_progress "x" while true
                                                                           end))
end
