# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text, style_at
using Logging: Logging, with_logger
using LegendDataManagement: DataPeriod, DataRun, FileKey, ProcessStatus
using ProgressLogging: ProgressLogging
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

const TuiLog = NamedTuple{(:Filekey, :Status, :Error)}

# Render `m` into a `width` x `height` test backend.
function render_tui(m, width = 100, height = 30)
    tb = TestBackend(width, height)
    frame = Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[])
    Tachikoma.view(m, frame)
    return tb
end

screen_text(tb, height = 30) = join((row_text(tb, r) for r in 1:height), "\n")

# Deliver the events of `m`'s task queue, as the app loop does, until `cond()` holds.
function settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

# Read the controller state anew, after any read already under way, and wait for the result.
function refreshed!(m)
    settle!(() -> !m.refreshing, m) || return false
    JuLeAna.refresh!(m)
    return settle!(() -> !m.refreshing, m)
end

# The Workers page generates the worker start script in the production config folder:
# keep it in a temporary one.
withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json")) do
    @testset "TUI" begin
        root = mktempdir()
        l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
        p2 = DataPeriod(2)
        args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                               p_processors = Dict{Symbol,ProcessorSpec}())
        function new_session(parsed_args = args)
            periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [p2], nothing, run_steps(cfg),
                                                                                   partition_steps(cfg))
            return DataflowSession(; args = parsed_args, l200, config = cfg, periods, run_steps = run_steps(cfg),
                                   partition_steps = partition_steps(cfg), run_status, partition_status)
        end
        quick_step(cfg, l200, period, run; reprocess = false) = nothing
        processors = Dict{Symbol,Any}(:process_energy_calibration_cal => quick_step)

        @testset "render before the first read" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = new_session, record_software = false,
                                                      record_metadata = false))
            @test m.page == 1 && !Tachikoma.should_quit(m)
            tb = render_tui(m)
            for name in JuLeAna.TUI_PAGES
                @test find_text(tb, name) !== nothing
            end
            @test find_text(tb, "Loading the session") !== nothing
            @test find_text(tb, "W workers") !== nothing
            @test find_text(tb, "STARTING") !== nothing
            Tachikoma.update!(m, KeyEvent('3'))
            @test find_text(render_tui(m), "Allocations") !== nothing
        end

        @testset "frame, tabs, status and key rows" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false))
            tb = render_tui(m, 120, 32)
            @test find_text(tb, "JuLeAna").y == 1 && find_text(tb, "LEGEND-200").y == 1
            # the letters of the title have the colors of the logo; the frame's corner and edge precede them
            @test [style_at(tb, 4 + i, 1).fg for i in 0:6] == [JuLeAna.TITLE_COLORS[mod1(i, 3)] for i in 1:7]
            @test find_text(tb, "1 Setup") !== nothing &&
                  find_text(tb, "4 Progress") !== nothing &&
                  find_text(tb, "5 Log") !== nothing &&
                  find_text(tb, "6 Reports") !== nothing
            @test find_text(tb, "STARTING") !== nothing
            @test refreshed!(m)
            tb = render_tui(m, 120, 32)
            @test find_text(tb, "READY") !== nothing && find_text(tb, "workers 0") !== nothing
            keys_row = row_text(tb, 31)
            @test occursin("W workers", keys_row) && occursin("q quit", keys_row)
            Tachikoma.update!(m, KeyEvent('4'))
            @test occursin("f follow", row_text(render_tui(m, 120, 32), 31))
            Tachikoma.update!(m, KeyEvent('3'))
            keys_row = row_text(render_tui(m, 120, 32), 31)
            @test occursin("a add", keys_row) && occursin("1-8 page  q quit", keys_row) && !occursin("follow", keys_row)
            # a narrow screen cuts the key row at the frame
            @test !occursin("quit", row_text(render_tui(m, 12, 32), 31))
        end

        @testset "spinner" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false))
            @test refreshed!(m)
            spinner = join(Tachikoma.SPINNER_BRAILLE)
            has_spinner(m) = any(c -> c in spinner, screen_text(render_tui(m, 120, 32)))
            Tachikoma.update!(m, Tachikoma.TaskEvent(:tick, nothing))
            @test m.ticks == 1 && !has_spinner(m)
            m.snap = merge(m.snap, (; state = :running))
            @test has_spinner(m)
            first_frame = screen_text(render_tui(m, 120, 32))
            Tachikoma.update!(m, Tachikoma.TaskEvent(:tick, nothing))
            @test screen_text(render_tui(m, 120, 32)) != first_frame
            m.snap = merge(m.snap, (; state = :stopping))
            @test has_spinner(m)
            m.snap = merge(m.snap, (; state = :ready))
            @test !has_spinner(m)
            Tachikoma.cleanup!(m)
        end

        @testset "theme" begin
            @test JuLeAna.JULEANA_THEME isa Tachikoma.Theme
            before = Tachikoma.theme()
            @test JuLeAna.with_theme(() -> Tachikoma.theme(), JuLeAna.JULEANA_THEME) === JuLeAna.JULEANA_THEME
            @test Tachikoma.theme() === before
            @test_throws "boom" JuLeAna.with_theme(() -> error("boom"), JuLeAna.JULEANA_THEME)
            @test Tachikoma.theme() === before

            @test first(JuLeAna.TUI_THEMES) === JuLeAna.NIGHT_OWL_THEME
            @test allunique(t.name for t in JuLeAna.TUI_THEMES)
            @test JuLeAna.tui_theme("juleana") === JuLeAna.JULEANA_THEME
            @test_throws "unknown theme `nope`; the themes are night-owl, juleana" JuLeAna.tui_theme("nope")
            pref = joinpath(mktempdir(), "prefs", "theme")
            @test JuLeAna.load_theme_name(pref) == "night-owl"
            # `T` moves on to the next theme and saves it
            JuLeAna.with_theme(JuLeAna.NIGHT_OWL_THEME) do
                @test JuLeAna.next_theme!(pref) === JuLeAna.JULEANA_THEME
                @test Tachikoma.theme() === JuLeAna.JULEANA_THEME
            end
            @test JuLeAna.load_theme_name(pref) == "juleana"
            JuLeAna.with_theme(last(JuLeAna.TUI_THEMES)) do
                @test JuLeAna.next_theme!(pref) === JuLeAna.NIGHT_OWL_THEME
            end
            write(pref, "gone")
            @test (@test_logs (:warn, r"saved theme `gone`") JuLeAna.load_theme_name(pref)) == "night-owl"
            @test JuLeAna.parse_commandline(["-c", "x.yaml", "--theme", "juleana"])["theme"] == "juleana"
            @test isnothing(JuLeAna.parse_commandline(["-c", "x.yaml"])["theme"])
        end

        @testset "page switching" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false))
            Tachikoma.update!(m, KeyEvent('6'))
            @test m.page == 6
            Tachikoma.update!(m, KeyEvent('9'))
            @test m.page == 6
            Tachikoma.update!(m, KeyEvent('7'))
            @test m.page == 7
            tb = render_tui(m)
            @test count(r -> occursin("History", row_text(tb, r)), 1:30) >= 2 && find_text(tb, "7 History") !== nothing
            @test find_text(tb, "r reload") !== nothing
            Tachikoma.update!(m, KeyEvent('6'))
            # Tab moves between the panes of a page, not between pages
            Tachikoma.update!(m, KeyEvent(:tab))
            @test m.page == 6
            tb = render_tui(m)
            @test count(r -> occursin("Reports", row_text(tb, r)), 1:30) == 2
            for (key, name) in (('3', "Workers"),)
                Tachikoma.update!(m, KeyEvent(key))
                @test m.page == parse(Int, key)
                tb = render_tui(m)
                @test count(r -> occursin(name, row_text(tb, r)), 1:30) == 2
                @test find_text(tb, "Allocations") !== nothing
            end
            Tachikoma.update!(m, KeyEvent('2'))
            @test m.page == 2 && find_text(render_tui(m), "Loading the session…") !== nothing
            Tachikoma.update!(m, KeyEvent('5'))
            @test m.page == 5 && find_text(render_tui(m), "No messages yet.") !== nothing
            Tachikoma.update!(m, KeyEvent('1'))
            @test m.page == 1
            @test !m.quit
            # a click on a tab opens its page
            tb = render_tui(m)
            y = findfirst(r -> occursin("Progress", row_text(tb, r)), 1:30)
            row = row_text(tb, y)
            # `findfirst` gives a byte index and the row holds box characters
            x = length(row, 1, findfirst("Progress", row).start - 1) + 1
            Tachikoma.update!(m, Tachikoma.MouseEvent(x + 1, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
            @test m.page == 4
            @test find_text(render_tui(m), "No processing run yet.") !== nothing
            tb = render_tui(m)
            y = findfirst(r -> occursin("Log", row_text(tb, r)), 1:30)
            row = row_text(tb, y)
            x = length(row, 1, findfirst("Log", row).start - 1) + 1
            Tachikoma.update!(m, Tachikoma.MouseEvent(x + 1, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
            @test m.page == 5
        end

        @testset "Workers page" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false))
            page = m.workers_page
            @test refreshed!(m)
            # the page reads the overview in the background when it opens
            Tachikoma.update!(m, KeyEvent('3'))
            @test page.reading
            @test settle!(() -> !isnothing(page.overview), m)
            tb = render_tui(m, 120, 30)
            @test find_text(tb, "No allocations") !== nothing && find_text(tb, "No workers.") !== nothing
            @test find_text(tb, "workers 0") !== nothing
            # the start script is generated in the production config folder of the environment
            (; path) = page.overview.script
            @test startswith(path, dirname(ENV["LEGEND_DATA_CONFIG"])) && isfile(path)
            # a tick reads again once the last read is five seconds old
            @test settle!(() -> !page.reading, m)
            before = page.read_at
            Tachikoma.update!(m, Tachikoma.TaskEvent(:tick, nothing))
            @test !page.reading && page.read_at == before
            page.read_at = time() - 6
            Tachikoma.update!(m, Tachikoma.TaskEvent(:tick, nothing))
            @test page.reading
            @test settle!(() -> !page.reading, m)
            # an answered command asks for a new read
            Tachikoma.update!(m, KeyEvent('p'))
            @test m.pending == 1
            @test settle!(() -> m.pending == 0 && m.answered == 1, m)
            @test settle!(() -> page.reading || page.read_at > before, m)
            @test settle!(() -> !page.reading, m)
            # the page does not read while it is not shown
            Tachikoma.update!(m, KeyEvent('1'))
            page.read_at = time() - 6
            Tachikoma.update!(m, Tachikoma.TaskEvent(:tick, nothing))
            @test !page.reading
            # the editor takes the keys of other pages, and the quit key
            Tachikoma.update!(m, KeyEvent('3'))
            Tachikoma.update!(m, KeyEvent('e'))
            @test !isnothing(page.editor)
            keys_row = row_text(render_tui(m, 120, 30), 29)
            @test occursin("Ctrl-O save", keys_row) && !occursin("quit", keys_row)
            Tachikoma.update!(m, KeyEvent('q'))
            @test !m.quit && m.page == 3
            Tachikoma.update!(m, KeyEvent(:escape))
            @test isnothing(page.editor)
            # the key help lists the keys of the page
            Tachikoma.update!(m, KeyEvent('?'))
            @test find_text(render_tui(m, 120, 40), "Workers page") !== nothing
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.cleanup!(m)
        end

        @testset "start! loads the session in the background" begin
            loaded = Threads.Atomic{Bool}(false)
            function slow_loader(parsed_args)
                sleep(0.5)
                loaded[] = true
                return new_session(parsed_args)
            end
            ctrl = DataflowController(args; processors, loader = slow_loader, record_software = false, record_metadata = false)
            # without the startup screen, which covers the status panel
            m = JuLeAna.JuLeAnaTUI(ctrl; splash_seconds = 0.0)
            t0 = time()
            JuLeAna.start!(m)
            # start! returns before the session is loaded
            @test time() - t0 < 0.4 && !loaded[]
            @test settle!(() -> !isnothing(m.snap) && m.snap.state === :ready, m)
            @test loaded[]
            tb = render_tui(m)
            @test find_text(tb, "READY") !== nothing
            @test find_text(tb, "workers 0") !== nothing
            Tachikoma.cleanup!(m)
            @test m.timer.cancelled[]
            # the app calls `start!` through Tachikoma's `init!`
            @test which(Tachikoma.init!, Tuple{JuLeAna.JuLeAnaTUI,Tachikoma.Terminal}).module === JuLeAna
        end

        @testset "a failed load stays visible" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = _ -> error("no data config"), record_software = false,
                                                      record_metadata = false); splash_seconds = 0.0)
            with_logger(Logging.NullLogger()) do
                JuLeAna.start!(m)
                @test settle!(() -> !isnothing(m.snap) && m.snap.state === :idle && !isnothing(m.snap.last_error), m)
            end
            Tachikoma.cleanup!(m)
            @test find_text(render_tui(m, 120), "no data config") !== nothing
        end

        @testset "commands and their errors" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false))
            JuLeAna.send_command!(m, StopProcessing())
            @test settle!(() -> !isnothing(m.command_error), m)
            @test occursin("StopProcessing is not possible while the controller is :ready", m.command_error)
            @test settle!(() -> !m.refreshing, m)
            @test find_text(render_tui(m, 120), "StopProcessing is not possible") !== nothing
            # a successful command clears the error
            JuLeAna.send_command!(m, StartProcessing())
            @test settle!(() -> isnothing(m.command_error), m)
            wait(m.ctrl)
            @test refreshed!(m)
            @test m.snap.outcome === :finished
            text = screen_text(render_tui(m, 120))
            @test occursin("last run: finished", text) && occursin("100%", text)
        end

        @testset "quit" begin
            for key in (KeyEvent('q'), KeyEvent(:ctrl, 'c'), KeyEvent(:ctrl_c))
                m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false))
                @test refreshed!(m)
                Tachikoma.update!(m, key)
                @test Tachikoma.should_quit(m) && isnothing(m.dialog)
            end
        end

        @testset "quit while processing" begin
            started = Threads.Atomic{Int}(0)
            filekeys = [FileKey("l200-p02-r006-cal-20230101T00000$(i)Z") for i in 1:4]
            slow_step(cfg, l200, period, run; reprocess = false) = parallel(filekeys, TuiLog) do fk
                Threads.atomic_add!(started, 1)
                sleep(0.5)
                (processed = true, log = TuiLog((fk, ProcessStatus(1), "")))
            end
            ctrl = DataflowController(new_session(); processors = Dict{Symbol,Any}(:process_energy_calibration_cal => slow_step),
                                      record_software = false, record_metadata = false)
            dispatch!(ctrl, SelectRuns([6]))
            m = JuLeAna.JuLeAnaTUI(ctrl)
            dispatch!(ctrl, StartProcessing())
            @test timedwait(() -> started[] >= 1, 60) === :ok
            @test refreshed!(m) && m.snap.state === :running

            Tachikoma.update!(m, KeyEvent('q'))
            @test m.dialog === :quit && !m.quit
            @test find_text(render_tui(m), "s: stop after the running items, then quit") !== nothing
            # page keys do nothing while the dialog is open
            Tachikoma.update!(m, KeyEvent(:tab))
            @test m.page == 1
            Tachikoma.update!(m, KeyEvent('c'))
            @test isnothing(m.dialog) && !m.quit
            Tachikoma.update!(m, KeyEvent(:ctrl_c))
            @test m.dialog === :quit
            Tachikoma.update!(m, KeyEvent(:escape))
            @test isnothing(m.dialog)

            Tachikoma.update!(m, KeyEvent('q'))
            Tachikoma.update!(m, KeyEvent('s'))
            @test isnothing(m.dialog) && !m.quit
            # quits once the run has stopped
            @test settle!(() -> (JuLeAna.refresh!(m); m.quit), m)
            @test snapshot(ctrl).outcome === :stopped

            # `q` in the dialog quits at once
            m2 = JuLeAna.JuLeAnaTUI(ctrl)
            m2.snap = merge(snapshot(ctrl), (; state = :running))
            Tachikoma.update!(m2, KeyEvent('q'))
            Tachikoma.update!(m2, KeyEvent('q'))
            @test m2.quit
        end

        @testset "MessageBuffer" begin
            buf = JuLeAna.MessageBuffer(3)
            with_logger(buf) do
                @debug "dropped"
                @info "first\nsecond line"
                @info ProgressLogging.Progress(JuLeAna.uuid4(), 0.5; name = "bar")
            end
            lines = JuLeAna.message_lines(buf)
            @test length(lines) == 2
            @test occursin(r"^\d\d:\d\d:\d\d Info  first$", lines[1]) && strip(lines[2]) == "second line"
            @test isnothing(buf.alert)
            with_logger(() -> (@warn "careful" n = 1), buf)
            lines = JuLeAna.message_lines(buf)
            # the capacity keeps the newest lines
            @test length(lines) == 3 && occursin("Warn  careful", lines[2]) && strip(lines[3]) == "n = 1"
            @test buf.alert.level == Logging.Warn && buf.alert.text == "careful"
            # the lines of a record share its number and level
            entries = JuLeAna.message_entries(buf)
            @test [e.level for e in entries] == [Logging.Info, Logging.Warn, Logging.Warn]
            @test entries[1].record < entries[2].record == entries[3].record
            @test JuLeAna.message_lines(buf) == [e.text for e in entries]
            push!(entries, entries[1])
            @test length(JuLeAna.message_entries(buf)) == 3

            JuLeAna.append_output!(buf, :stdout, "      From worker 2:\tpartial")
            @test !any(contains("partial"), JuLeAna.message_lines(buf))
            JuLeAna.append_output!(buf, :stdout, " line\n      From worker 2:\t┌ Error: fit failed\n")
            lines = JuLeAna.message_lines(buf)
            # a worker's line goes to its own lines, its error also to the other lines
            @test [e.text for e in JuLeAna.worker_output(buf, 2)] == ["partial line", "┌ Error: fit failed"]
            @test !any(contains("partial"), lines) && lines[end] == "      From worker 2:\t┌ Error: fit failed"
            @test buf.alert.level == Logging.Error && buf.alert.text == "fit failed"
            @test_throws "capacity must be positive" JuLeAna.MessageBuffer(0)

            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false), buf)
            @test find_text(render_tui(m), "fit failed") !== nothing
            # each output line is a record; only lines with `Warning:` or `Error:` leave `Info`
            JuLeAna.append_output!(buf, :stderr, "plain\n┌ Warning: careful\n")
            entries = JuLeAna.message_entries(buf)
            @test [e.level for e in entries] == [Logging.Error, Logging.Info, Logging.Warn]
            @test allunique(e.record for e in entries)
        end
    end # testset
end # withenv
