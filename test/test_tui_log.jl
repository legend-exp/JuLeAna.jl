# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text, style_at
using Logging: Logging, with_logger
using LegendDataManagement: DataPeriod
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

# Render the Log page of `page` into a `width` x `height` test backend.
function render_log_page(page, entries, width = 120, height = 30; kwargs...)
    tb = TestBackend(width, height)
    JuLeAna.render_log(page, entries, Rect(1, 1, width, height), tb.buf; kwargs...)
    return tb
end

log_text(tb, height = 30) = join((row_text(tb, r) for r in 1:height), "\n")

# A buffer with an info message, a multi-line warning, an error and an output line.
function sample_buffer(capacity = 1000)
    buf = JuLeAna.MessageBuffer(capacity)
    with_logger(buf) do
        @info "loading the session"
        @warn "careful with this" detail = "first\nsecond"
        @error "fit failed" period = 3
    end
    JuLeAna.append_output!(buf, :stdout, "from worker 2: done\n")
    return buf
end

press(page, entries, key) = JuLeAna.log_key!(page, KeyEvent(key), entries)

@testset "Log page" begin
    entries = JuLeAna.message_entries(sample_buffer())
    # an info line, a warning with two keyword lines, an error with one, an output line
    @test [e.level for e in entries] == [Logging.Info, Logging.Warn, Logging.Warn, Logging.Warn, Logging.Error, Logging.Error, Logging.Info]
    @test length(unique(e.record for e in entries)) == 4

    @testset "level filter keeps the lines of a record" begin
        page = JuLeAna.LogPage()
        @test length(JuLeAna.shown_entries(page, entries)) == length(entries)
        warn_rows = findall(e -> e.level == Logging.Warn, entries)
        @test length(warn_rows) == 3
        press(page, entries, 'l')
        @test page.min_level == Logging.Warn
        shown = JuLeAna.shown_entries(page, entries)
        @test [entries[i].level for i in shown] == [e.level for e in entries if e.level >= Logging.Warn]
        @test warn_rows ⊆ shown
        press(page, entries, 'l')
        @test page.min_level == Logging.Error
        @test all(i -> entries[i].level == Logging.Error, JuLeAna.shown_entries(page, entries))
        press(page, entries, 'l')
        @test page.min_level == Logging.Info
    end

    @testset "text filter is case-insensitive and record-wise" begin
        page = JuLeAna.LogPage()
        page.filter = "SECOND"
        shown = JuLeAna.shown_entries(page, entries)
        # a match in a continuation line keeps the whole record
        @test shown == findall(e -> e.level == Logging.Warn, entries)
        page.filter = "FIT failed"
        @test [entries[i].level for i in JuLeAna.shown_entries(page, entries)] == [e.level for e in entries if e.level == Logging.Error]
        page.filter = "no such text"
        @test isempty(JuLeAna.shown_entries(page, entries))
        page.filter = "worker"
        page.min_level = Logging.Warn
        @test isempty(JuLeAna.shown_entries(page, entries))
    end

    @testset "empty and filtered views" begin
        page = JuLeAna.LogPage()
        @test find_text(render_log_page(page, entries[1:0]), "No messages yet.") !== nothing
        tb = render_log_page(page, entries)
        text = log_text(tb)
        @test occursin("loading the session", text) && occursin("fit failed", text) && occursin("(following)", text)
        @test occursin("$(length(entries)) of $(length(entries)) lines", text)
        @test !occursin("older lines", text)
        page.filter = "zzz"
        @test occursin("0 of $(length(entries)) lines", log_text(render_log_page(page, entries)))
    end

    @testset "colors by level and highlighted matches" begin
        page = JuLeAna.LogPage()
        page.filter = "FIT"
        tb = render_log_page(page, entries)
        hit = find_text(tb, "fit failed")
        @test hit !== nothing
        @test style_at(tb, hit.x, hit.y).fg == Tachikoma.theme().accent
        @test style_at(tb, hit.x + 4, hit.y).fg == Tachikoma.theme().error
        page.filter = ""
        tb = render_log_page(page, entries)
        warn = find_text(tb, "careful with this")
        @test style_at(tb, warn.x, warn.y).fg == Tachikoma.theme().warning
        info = find_text(tb, "loading the session")
        @test style_at(tb, info.x, info.y).fg == Tachikoma.theme().text
        # the time stamp is dimmed
        @test style_at(tb, info.x - 15, info.y).fg == Tachikoma.theme().text_dim
    end

    @testset "following and scrolling" begin
        buf = JuLeAna.MessageBuffer()
        with_logger(buf) do
            for i in 1:60
                @info "message $i"
            end
        end
        page = JuLeAna.LogPage()
        entries = JuLeAna.message_entries(buf)
        tb = render_log_page(page, entries)
        @test find_text(tb, "message 60") !== nothing && find_text(tb, "message 1 ") === nothing
        with_logger(() -> @info("message 61"), buf)
        entries = JuLeAna.message_entries(buf)
        @test find_text(render_log_page(page, entries), "message 61") !== nothing

        @test press(page, entries, :up) && !page.follow
        tb = render_log_page(page, entries)
        @test find_text(tb, "message 61") === nothing && find_text(tb, "message 60") !== nothing
        @test occursin("lines", log_text(tb)) && !occursin("(following)", log_text(tb))
        # new messages do not move the view
        top = page.top
        with_logger(() -> @info("message 62"), buf)
        render_log_page(page, JuLeAna.message_entries(buf))
        @test page.top == top
        @test press(page, entries, :home) && page.top == 1 && !page.follow
        @test find_text(render_log_page(page, entries), "message 1") !== nothing
        @test press(page, entries, :pagedown) && page.top == 1 + page.height
        @test press(page, entries, :pageup) && page.top == 1
        @test press(page, entries, :end_key) && page.follow
        @test find_text(render_log_page(page, entries), "message 61") !== nothing
        @test press(page, entries, :pagedown) && !page.follow
        @test press(page, entries, 'f') && page.follow
        @test press(page, entries, :down) && !page.follow

        # the wheel scrolls while the pointer is inside the block
        page = JuLeAna.LogPage()
        render_log_page(page, entries)
        wheel(button, x = 5, y = 8) = MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false)
        @test JuLeAna.log_mouse!(page, wheel(Tachikoma.mouse_scroll_up), entries) && !page.follow
        @test page.top == last(JuLeAna.shown_entries(page, entries)) - page.height + 1 - 3
        @test !JuLeAna.log_mouse!(page, wheel(Tachikoma.mouse_scroll_up, 500, 8), entries)
        @test !JuLeAna.log_mouse!(page, MouseEvent(5, 8, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false), entries)
    end

    @testset "editing the filter" begin
        page = JuLeAna.LogPage()
        @test press(page, entries, '/') && page.editing
        for key in ('q', '5', '?', 'f', 'l', 'W')
            @test press(page, entries, key)
        end
        @test page.filter == "q5?flW" && page.min_level == Logging.Info && page.editing
        @test occursin("filter: q5?flW▏", log_text(render_log_page(page, entries)))
        @test press(page, entries, :backspace) && page.filter == "q5?fl"
        @test press(page, entries, :up) && page.editing
        @test press(page, entries, :enter) && !page.editing && page.filter == "q5?fl"
        @test occursin("filter: q5?fl", log_text(render_log_page(page, entries)))
        @test press(page, entries, '/') && press(page, entries, :escape)
        @test !page.editing && isempty(page.filter)
        # keys not used outside editing
        for key in ('1', '6', 'q', '?', :tab, :escape)
            @test !press(page, entries, key)
        end
        @test !JuLeAna.log_key!(page, KeyEvent(:up, Tachikoma.key_release), entries)
    end

    @testset "full buffer points to the log file" begin
        buf = sample_buffer(4)
        entries = JuLeAna.message_entries(buf)
        @test length(entries) == 4
        page = JuLeAna.LogPage()
        text = log_text(render_log_page(page, entries; capacity = 4))
        @test occursin("older lines in head.log", text)
        text = log_text(render_log_page(page, entries; capacity = 4, log_path = "/some/dir"))
        @test occursin("older lines in " * joinpath("/some/dir", "head.log"), text)
        @test !occursin("older lines", log_text(render_log_page(page, entries; capacity = 5)))
    end

    @testset "small areas" begin
        page = JuLeAna.LogPage()
        for (w, h) in ((2, 2), (5, 3), (20, 4))
            tb = render_log_page(page, entries, w, h)
            @test tb isa TestBackend
        end
    end

    @testset "in the interface" begin
        root = mktempdir()
        l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
        args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                               p_processors = Dict{Symbol,ProcessorSpec}())
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [DataPeriod(2)], nothing, run_steps(cfg),
                                                                               partition_steps(cfg))
        session = DataflowSession(; args, l200, config = cfg, periods, run_steps = run_steps(cfg), partition_steps = partition_steps(cfg),
                                  run_status, partition_status)
        buf = sample_buffer()
        render_model(m, w = 120, h = 30) = (tb = TestBackend(w, h);
                                            Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, w, h), GraphicsRegion[], PixelSnapshot[])); tb)
        m = JuLeAna.JuLeAnaTUI(DataflowController(session; processors = Dict{Symbol,Any}()), buf)
        Tachikoma.update!(m, KeyEvent('5'))
        @test m.page == 5
        text = log_text(render_model(m))
        @test occursin("fit failed", text) && occursin("l level", text) && occursin("1-7 page", text)
        Tachikoma.update!(m, KeyEvent('l'))
        text = log_text(render_model(m))
        @test m.log_page.min_level == Logging.Warn && occursin("(warnings)", text) && !occursin("loading the session", text)
        wheel = MouseEvent(5, 10, Tachikoma.mouse_scroll_down, Tachikoma.mouse_press, false, false, false)
        Tachikoma.update!(m, wheel)
        @test !m.log_page.follow
        # typing a filter captures the keys that switch pages and quit
        Tachikoma.update!(m, KeyEvent('/'))
        for key in ('q', '1', '?')
            Tachikoma.update!(m, KeyEvent(key))
        end
        @test m.page == 5 && !m.quit && !m.help && m.log_page.filter == "q1?"
        Tachikoma.update!(m, KeyEvent(:escape))
        Tachikoma.update!(m, KeyEvent('?'))
        @test m.help
        Tachikoma.update!(m, KeyEvent('?'))
        Tachikoma.update!(m, KeyEvent('1'))
        @test m.page == 1
        Tachikoma.update!(m, KeyEvent('5'))
        Tachikoma.update!(m, KeyEvent('q'))
        @test m.quit
        Tachikoma.cleanup!(m)
    end
end # testset
