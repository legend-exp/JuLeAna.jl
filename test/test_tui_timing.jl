# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Dates: DateTime
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TaskEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, key_release
using Test

# `InterfaceTiming` that reads the time from `now_ns[]`.
function manual_timing(now_ns; kwargs...)
    return JuLeAna.InterfaceTiming(; clock = () -> now_ns[], utc = () -> DateTime(2026, 1, 2, 3, 4, 5), kwargs...)
end

ms(x) = round(UInt64, x * 1e6)

@testset "Interface timing" begin
    @testset "window statistics" begin
        now_ns = Ref(ms(1000))
        t = manual_timing(now_ns; window_seconds = 10)
        # four frames at gaps of 16, 16 and 100 ms; views take 2, 4, 1 and 3 ms and show pages 1, 2, 1, 1
        starts = (0, 16, 32, 132)
        durations = (2, 4, 1, 3)
        pages = (1, 2, 1, 1)
        for (s, d, page) in zip(starts, durations, pages)
            now_ns[] = ms(1000 + s)
            JuLeAna.timing_view_begin!(t)
            now_ns[] = ms(1000 + s + d)
            @test isnothing(JuLeAna.timing_view_end!(t, nothing; page))
        end
        @test t.n_frames == 4 && t.n_gaps == 3
        @test t.view_thread == (Threads.threadid(), Threads.threadpool())
        now_ns[] = ms(1000 + 10_000)
        row = JuLeAna.timing_flush!(t, :running, nothing)
        fields = split(row, '\t')
        @test length(fields) == length(JuLeAna.TIMING_COLUMNS)
        col(name) = fields[findfirst(==(name), JuLeAna.TIMING_COLUMNS)]
        @test col("utc") == "2026-01-02T03:04:05"
        @test col("state") == "running"
        @test col("frames") == "4"
        @test parse(Float64, col("gap_p50_ms")) == 16.0
        @test parse(Float64, col("gap_max_ms")) == 100.0
        @test parse(Float64, col("gap_p95_ms")) ≈ 16 + 0.9 * 84
        @test parse(Float64, col("view_max_ms")) == 4.0
        @test parse(Float64, col("window_s")) == 10.0
        @test col("keys") == "0" && col("key_p50_ms") == "NA"
        @test col("update_max_ms") == "NA"
        @test col("view_thread") == "$(Threads.threadid()):$(Threads.threadpool())"
        @test col("view_max_page") == "2"
        @test col("page_views") == "1:3:2.0 2:1:4.0"
        # the next window starts empty and continues the frame gaps
        @test t.n_frames == 0 && all(iszero, t.page_frames) && t.slowest_view_page == 0
        now_ns[] = ms(1000 + 10_100)
        JuLeAna.timing_view_begin!(t)
        @test t.n_gaps == 1
    end

    @testset "updates and key latency" begin
        now_ns = Ref(ms(0))
        t = manual_timing(now_ns)
        function update(evt, duration)
            start = JuLeAna.timing_update_begin!(t, evt)
            now_ns[] += ms(duration)
            JuLeAna.timing_update_end!(t, start, evt)
        end
        update(KeyEvent('a'), 5)
        update(KeyEvent('b'), 7)
        update(KeyEvent('a', key_release), 1)
        update(MouseEvent(1, 1, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false), 2)
        update(TaskEvent(:refresh, nothing), 30)
        update(TaskEvent(:tick, nothing), 1)
        @test t.n_updates == 6 && t.n_pending == 2
        @test t.update_max == [ms(7), ms(2), ms(30), 0]
        @test t.slowest_update === :refresh
        # the view starts 10 ms after the last update and takes 4 ms
        now_ns[] += ms(10)
        JuLeAna.timing_view_begin!(t)
        now_ns[] += ms(4)
        JuLeAna.timing_view_end!(t, nothing)
        @test t.n_pending == 0 && t.n_keys == 2
        # the keys arrived 60 and 55 ms before the end of the view
        @test sort(t.key_latencies[1:2]) == [ms(55), ms(60)]
        row = split(JuLeAna.timing_flush!(t, :ready, nothing), '\t')
        col(name) = row[findfirst(==(name), JuLeAna.TIMING_COLUMNS)]
        @test col("keys") == "2"
        @test col("update_task_max_ms") == "30.0"
        @test col("update_key_max_ms") == "7.0"
        @test col("slowest_update") == "refresh"
        # a `view` without a page
        @test col("view_max_page") == "NA" && col("page_views") == "NA"
    end

    @testset "buffers beyond capacity are counted" begin
        now_ns = Ref(ms(0))
        t = manual_timing(now_ns; capacity = 3)
        for i in 1:10
            now_ns[] += ms(1)
            JuLeAna.timing_view_begin!(t)
            JuLeAna.timing_view_end!(t, nothing)
        end
        @test t.n_frames == 10
        @test count(!=(0), t.view_times) <= 3
        row = split(JuLeAna.timing_flush!(t, :ready, nothing), '\t')
        @test row[3] == "10"
    end

    @testset "garbage collection in the window" begin
        now_ns = Ref(ms(0))
        t = manual_timing(now_ns)
        GC.gc()
        row = split(JuLeAna.timing_flush!(t, :ready, nothing), '\t')
        col(name) = row[findfirst(==(name), JuLeAna.TIMING_COLUMNS)]
        @test parse(Int, col("gc_count")) >= 1
        @test parse(Float64, col("gc_time_ms")) > 0
        @test parse(Float64, col("gc_max_pause_ms")) > 0
    end

    @testset "timing file" begin
        now_ns = Ref(ms(0))
        t = manual_timing(now_ns; window_seconds = 1)
        # without a log folder nothing is written, and the window still restarts
        for snap in (nothing, (; state = :loading, log_path = nothing), (; state = :loading, log_path = ""))
            now_ns[] += ms(1500)
            JuLeAna.timing_view_begin!(t)
            row = JuLeAna.timing_view_end!(t, snap)
            @test row isa String
            @test t.n_frames == 0
        end
        dir = mktempdir()
        @test isempty(readdir(dir))
        for i in 1:2
            now_ns[] += ms(1500)
            JuLeAna.timing_view_begin!(t)
            @test JuLeAna.timing_view_end!(t, (; state = :running, log_path = dir)) isa String
        end
        path = joinpath(dir, "interface_timing.tsv")
        @test timedwait(() -> isfile(path) && countlines(path) == 3, 30) === :ok
        lines = readlines(path)
        @test lines[1] == join(JuLeAna.TIMING_COLUMNS, '\t')
        @test all(l -> length(split(l, '\t')) == length(JuLeAna.TIMING_COLUMNS), lines)
        @test split(lines[2], '\t')[2] == "running"
        @test count(==(lines[1]), lines) == 1
    end

    @testset "validation" begin
        @test_throws "window_seconds must be positive" JuLeAna.InterfaceTiming(; window_seconds = 0)
        @test_throws "capacity must be positive" JuLeAna.InterfaceTiming(; capacity = 0)
        @test_throws "pages must be positive" JuLeAna.InterfaceTiming(; pages = 0)
    end
end

# The interface must never touch the data config of the session.
withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json")) do
    @testset "Interface timing in the terminal interface" begin
        args = Dict{String,Any}("config" => "none")
        m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors = Dict{Symbol,Any}(), loader = _ -> error("no session")))
        @test m.timing isa JuLeAna.InterfaceTiming
        tb = TestBackend(100, 30)
        frame = Frame(tb.buf, Rect(1, 1, 100, 30), GraphicsRegion[], PixelSnapshot[])
        for _ in 1:3
            Tachikoma.view(m, frame)
        end
        @test m.timing.n_frames == 3 && m.timing.n_gaps == 2
        @test m.timing.page_frames[m.page] == 3
        @test m.timing.view_thread == (Threads.threadid(), Threads.threadpool())
        Tachikoma.update!(m, KeyEvent('?'))
        Tachikoma.update!(m, MouseEvent(1, 1, Tachikoma.mouse_left, Tachikoma.mouse_release, false, false, false))
        Tachikoma.update!(m, TaskEvent(:dataset, nothing))
        @test m.timing.n_updates == 3 && m.timing.n_pending == 1
        Tachikoma.view(m, frame)
        @test m.timing.n_pending == 0 && m.timing.n_keys == 1
        Tachikoma.cleanup!(m)
    end
end
