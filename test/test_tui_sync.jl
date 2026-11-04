# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using JuLeAna: Sync
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TaskEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text,
                 mouse_left, mouse_press
using Dates: now, UTC
using LegendDataManagement: DataPeriod
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

# A copy of the sync fixture whose config.json names the copy, so the production can be read through LocalHost.
function sync_fixture_root()
    dest = joinpath(mktempdir(), "remote")
    cp(joinpath(@__DIR__, "sync", "fixtures", "remote"), dest)
    template = read(joinpath(dest, "test", "config.json.in"), String)
    write(joinpath(dest, "test", "config.json"), replace(template, "@REMOTE_ROOT@" => dest))
    rm(joinpath(dest, "test", "config.json.in"))
    return dest
end

# The sync page reaches the fixture through LocalHost; nothing contacts a host.
function sync_tui(; settings = nothing, width = 120)
    root = mktempdir()
    l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
    cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                           p_processors = Dict{Symbol,ProcessorSpec}())
    periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [DataPeriod(2)], nothing, run_steps(cfg),
                                                                           partition_steps(cfg))
    session = DataflowSession(; args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml")),
                              l200, config = cfg, periods, run_steps = run_steps(cfg), partition_steps = partition_steps(cfg),
                              run_status, partition_status)
    processors = Dict{Symbol,Any}(:process_energy_calibration_cal => (cfg, l200, period, run; reprocess = false) -> nothing)
    ctrl = DataflowController(session; processors, record_software = false, record_metadata = false)
    return JuLeAna.JuLeAnaTUI(ctrl; sync_settings = settings, sync_host = alias -> Sync.LocalHost())
end

function sync_settings(; production = "", local_root = mktempdir())
    return Sync.SyncSettings(; host = "local", remote_root = sync_fixture_root(), production, local_root,
                             selection = joinpath(mktempdir(), "sel.yaml"), hosts_file = Sync.PACKAGED_HOSTS_FILE)
end

function sync_render(m, width = 120, height = 36)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end

function sync_settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

# Neither the user's configuration nor a real production is touched: both variables are temporary for the whole file.
withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json"), "XDG_CONFIG_HOME" => mktempdir()) do
    @testset "Sync window" begin
        @testset "S on Setup opens the window and the page is created on the first opening" begin
            m = sync_tui(; settings = sync_settings())
            @test length(JuLeAna.TUI_PAGES) == 7 && !("Sync" in JuLeAna.TUI_PAGES)
            @test find_text(sync_render(m), "Sync") === nothing
            @test isnothing(m.sync) && !m.sync_open
            Tachikoma.update!(m, KeyEvent('S'))
            @test m.sync_open && m.page == 1 && m.sync isa Sync.SyncPage && m.sync.running == 1     # the connection starts
            @test sync_settle!(() -> m.sync.running == 0, m)
            tb = sync_render(m)
            @test find_text(tb, "Data sync") !== nothing && find_text(tb, "Settings") !== nothing &&
                  find_text(tb, "Productions on local") !== nothing
            @test find_text(tb, "1 Setup") !== nothing                            # the tab bar stays
            # Esc closes the list first, then the window; opening again does not connect again.
            Tachikoma.update!(m, KeyEvent(:escape))
            @test m.sync_open && !m.sync.picking
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.sync_open && find_text(sync_render(m), "Data sync") === nothing
            Tachikoma.update!(m, KeyEvent('S'))
            @test m.sync_open && m.sync.running == 0
        end

        @testset "S is only a key of the Setup page and not text in its filter" begin
            m = sync_tui(; settings = sync_settings())
            Tachikoma.update!(m, KeyEvent('2'))
            Tachikoma.update!(m, KeyEvent('S'))
            @test !m.sync_open && isnothing(m.sync)
            Tachikoma.update!(m, KeyEvent('1'))
            Tachikoma.update!(m, KeyEvent('/'))
            Tachikoma.update!(m, KeyEvent('S'))
            @test !m.sync_open && isnothing(m.sync)
        end

        @testset "an interface that never opens the window never creates the page" begin
            m = sync_tui(; settings = sync_settings())
            for key in ('2', '3', '1')
                Tachikoma.update!(m, KeyEvent(key))
            end
            Tachikoma.update!(m, TaskEvent(:tick, nothing))
            @test isnothing(m.sync)
        end

        @testset "the window takes the keys and the mouse and leaves q, ? and T to the interface" begin
            m = sync_tui(; settings = sync_settings())
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            Tachikoma.update!(m, KeyEvent(:escape))                  # closes the picker, which the page opened
            sync_render(m)
            Tachikoma.update!(m, KeyEvent('3'))
            @test m.page == 1 && m.sync_open                         # a digit opens no page
            r = m.tabs._tab_rects[3]
            click(x, y) = MouseEvent(x, y, mouse_left, mouse_press, false, false, false)
            Tachikoma.update!(m, click(r.x + 2, r.y))
            @test m.page == 1 && m.sync_open                         # neither does a tab
            host = Dict(m.sync.panel_rects)[:host]
            Tachikoma.update!(m, click(host.x + 1, host.y))          # the page gets the click
            @test m.sync.focus == :panel && !isnothing(m.sync.edit)
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.update!(m, KeyEvent(:escape))
            @test m.sync.focus == :tree && m.sync_open

            Tachikoma.update!(m, KeyEvent('?'))
            help = sync_render(m)
            @test m.help && find_text(help, "Sync window") !== nothing && find_text(help, "Setup page") === nothing
            @test find_text(help, "open a page") === nothing
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.help && m.sync_open                             # Esc closes the help, not the window

            previous = Tachikoma.theme()
            depot = mktempdir()
            pushfirst!(DEPOT_PATH, depot)
            try
                Tachikoma.set_theme!(JuLeAna.tui_theme("night-owl"))
                @test_logs (:info, "Theme: juleana") Tachikoma.update!(m, KeyEvent('T'))
                @test Tachikoma.theme().name == "juleana"
            finally
                popfirst!(DEPOT_PATH)
                Tachikoma.set_theme!(previous)
            end

            # A field in edit takes digits and q as text; Esc steps back through the edit and the panel.
            Tachikoma.update!(m, KeyEvent(:tab))
            Tachikoma.update!(m, KeyEvent(:enter))
            Tachikoma.update!(m, KeyEvent('3'))
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.sync_open && !m.quit && endswith(m.sync.edit.text, "3q")
            Tachikoma.update!(m, KeyEvent(:escape))
            @test isnothing(m.sync.edit) && m.sync.focus == :panel && m.sync_open
            Tachikoma.update!(m, KeyEvent(:escape))
            @test m.sync.focus == :tree && m.sync_open
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.sync_open

            # The page gets no click and no key once the window is closed.
            Tachikoma.update!(m, click(host.x + 1, host.y))
            @test m.sync.focus == :tree
            Tachikoma.update!(m, KeyEvent('3'))
            @test m.page == 3
            Tachikoma.update!(m, KeyEvent('1'))
            Tachikoma.update!(m, KeyEvent('S'))
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.quit && isnothing(m.dialog)
        end

        @testset "Esc asks while a sync runs: background, stop or stay" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.modal_kind = :transfer
            Tachikoma.update!(m, KeyEvent(:escape))
            @test m.dialog === :sync_leave
            tb = sync_render(m)
            @test find_text(tb, "b: close the window") !== nothing && find_text(tb, "s: stop") !== nothing &&
                  find_text(tb, "c: cancel") !== nothing
            # Other keys do nothing; c and Esc stay in the window.
            Tachikoma.update!(m, KeyEvent('x'))
            @test m.dialog === :sync_leave
            Tachikoma.update!(m, KeyEvent('c'))
            @test isnothing(m.dialog) && m.sync_open && Sync.sync_stoppable(m.sync)
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.update!(m, KeyEvent(:escape))
            @test isnothing(m.dialog) && m.sync_open && Sync.sync_stoppable(m.sync)
            # b closes the window and the work goes on; S shows it again.
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.update!(m, KeyEvent('b'))
            @test isnothing(m.dialog) && !m.sync_open && m.sync.modal_kind == :transfer && Sync.sync_stoppable(m.sync)
            @test find_text(sync_render(m), "sync running") !== nothing
            Tachikoma.update!(m, KeyEvent('S'))
            @test m.sync_open
            # s stops it; once it stops, there is nothing left to offer but the background.
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.update!(m, KeyEvent('s'))
            @test isnothing(m.dialog) && m.sync_open && !Sync.sync_stoppable(m.sync) && Sync.sync_running(m.sync)
            Tachikoma.update!(m, KeyEvent(:escape))
            @test find_text(sync_render(m), "s: stop") === nothing
            Tachikoma.update!(m, KeyEvent('s'))
            @test m.dialog === :sync_leave
            Tachikoma.update!(m, KeyEvent('c'))

            # Environment creation reports no progress: it can go to the background, not be stopped.
            m2 = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m2, KeyEvent('S'))
            @test sync_settle!(() -> m2.sync.running == 0, m2)
            m2.sync.modal_kind = :busy
            Tachikoma.update!(m2, KeyEvent(:escape))
            @test find_text(sync_render(m2), "s: stop") === nothing
            Tachikoma.update!(m2, KeyEvent('s'))
            @test m2.dialog === :sync_leave && m2.sync.modal_kind == :busy
            Tachikoma.update!(m2, KeyEvent('b'))
            @test !m2.sync_open && m2.sync.modal_kind == :busy
        end

        @testset "the question closes itself when the sync ends while it is open" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.modal_kind = :transfer
            Tachikoma.update!(m, KeyEvent(:escape))
            @test m.dialog === :sync_leave
            m.sync.running += 1
            Tachikoma.update!(m, TaskEvent(Symbol("sync:transfer"), ErrorException("boom")))
            @test isnothing(m.dialog) && m.sync_open && m.sync.modal_kind == :error
            @test find_text(sync_render(m), "boom") !== nothing
        end

        @testset "the status panel shows a running sync and what waits in the closed window" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            @test find_text(sync_render(m), "No processing run in this session.") !== nothing
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.sync_open

            # The bar follows the steps and goes back to the run once they end.
            m.sync.modal_kind = :transfer
            m.sync.step = Sync.StepProgress("copying", 2, 3, 45, 100, nothing, "")
            tb = sync_render(m)
            @test find_text(tb, "[2/3] copying 45/100") !== nothing && find_text(tb, "No processing run") === nothing
            @test find_text(tb, "sync running") !== nothing
            # A run in progress keeps the bar.
            snap = (; state = :running, outcome = nothing, nworkers = 0, idle_deadline = nothing, last_error = nothing,
                    started = now(UTC), finished = nothing)
            m.snap, m.progress = snap, (; fraction = 0.5)
            panel = TestBackend(120, 4)
            JuLeAna.render_status(m, Rect(1, 1, 120, 4), panel.buf)
            @test find_text(panel, "50%") !== nothing && find_text(panel, "copying") === nothing
            m.snap, m.progress = nothing, nothing

            # A failure waits in the closed window, the panel says so, and S shows it.
            m.sync.running += 1
            Tachikoma.update!(m, TaskEvent(Symbol("sync:transfer"), ErrorException("boom")))
            tb = sync_render(m)
            @test find_text(tb, "sync: Error, S on Setup shows it") !== nothing && find_text(tb, "sync running") === nothing
            @test find_text(tb, "No processing run in this session.") !== nothing
            Tachikoma.update!(m, KeyEvent('S'))
            tb = sync_render(m)
            @test find_text(tb, "boom") !== nothing && find_text(tb, "S on Setup shows it") === nothing
            Tachikoma.update!(m, KeyEvent(:enter))
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.sync_open && find_text(sync_render(m), "S on Setup shows it") === nothing

            # So does a question.
            m.sync.running += 1
            m.sync.modal_kind = :estimating
            Tachikoma.update!(m, TaskEvent(Symbol("sync:estimate"), (Sync.Estimate(0, 0, 0, true), false, nothing, nothing)))
            @test find_text(sync_render(m), "sync: Estimate, S on Setup shows it") !== nothing
        end

        @testset "processing and a sync do not run together" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.sync_open
            for kind in (:checking, :estimating, :transfer, :busy)
                m.sync.modal_kind = kind
                @test_logs (:warn, r"a sync is running") Tachikoma.update!(m, KeyEvent('s'))
                @test m.pending == 0 && !isready(m.commands)
            end
            # A dialog that waits for an answer holds nothing up: the command is sent. The closed channel keeps it from running.
            m.sync.modal_kind = :estimate
            close(m.commands)
            @test_throws InvalidStateException Tachikoma.update!(m, KeyEvent('s'))
            @test m.pending == 1

            for state in (:running, :stopping)
                m2 = sync_tui(; settings = sync_settings())
                m2.snap = (; state)                                  # the checks read only the state
                @test_logs (:warn, r"processing") Tachikoma.update!(m2, KeyEvent('S'))
                @test !m2.sync_open && isnothing(m2.sync)
            end
        end

        @testset "sync: task events reach the page, others still reach main" begin
            m = sync_tui(; settings = sync_settings())
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.running += 1                                       # a result needs a task that runs
            Tachikoma.update!(m, TaskEvent(Symbol("sync:productions"), ["a", "b"]))
            @test m.sync.productions == ["a", "b"]
            ticks = m.ticks
            Tachikoma.update!(m, TaskEvent(:tick, nothing))
            @test m.ticks == ticks + 1
            # An unknown sync: id is a fault of the page: it opens the page's dialog and the interface keeps running.
            m.sync.running += 1
            Tachikoma.update!(m, TaskEvent(Symbol("sync:nothing_here"), nothing))
            @test m.sync.modal_kind == :error && occursin("unexpected background result :nothing_here", m.sync.modal.message) && !m.quit
            Tachikoma.update!(m, KeyEvent(:enter))
            @test m.sync.modal_kind == :none
        end

        @testset "an exception in a handler shows the dialog and the interface keeps running" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.picker = Tachikoma.SelectableList(["a"])
            m.sync.productions = nothing
            m.sync.picking = true                                     # a corrupt state: choosing from the list fails on it
            Tachikoma.update!(m, KeyEvent(:enter))
            @test m.sync_open && !m.quit && m.sync.modal_kind == :error
            @test find_text(sync_render(m), "Error") !== nothing
            Tachikoma.update!(m, KeyEvent(:enter))
            m.sync.picking = false
            Tachikoma.update!(m, KeyEvent(:escape))                   # the dialog is closed: the window closes
            @test !m.sync_open
        end

        @testset "a fault while drawing is shown as one line and the interface keeps running" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.picker = Tachikoma.SelectableList(["a"])
            m.sync.productions = nothing
            m.sync.picking = true                                     # render_picker needs the list of productions
            tb = sync_render(m)
            @test find_text(tb, "The Sync page failed to draw") !== nothing && find_text(tb, "1 Setup") !== nothing
            @test !m.quit
            m.sync.picking = false
            @test find_text(sync_render(m), "Settings") !== nothing   # the page draws again once the state is sound
        end

        @testset "a malformed configuration file is shown on the first opening, not fatal" begin
            xdg = mktempdir()
            mkpath(joinpath(xdg, "juleana", "sync"))
            write(joinpath(xdg, "juleana", "sync", "settings.yaml"), "local_root: [unclosed\n")
            withenv("XDG_CONFIG_HOME" => xdg) do
                m = sync_tui()                                        # no settings given: the first opening reads the directory
                Tachikoma.update!(m, KeyEvent('S'))
                @test m.sync_open && m.sync isa Sync.SyncPage && m.sync.modal_kind == :error && !m.quit
                @test m.sync.running == 0                             # nothing connected
            end
            # A malformed hosts.yaml fails while the page is built (it validates the settings): same result.
            xdg2 = mktempdir()
            mkpath(joinpath(xdg2, "juleana", "sync"))
            write(joinpath(xdg2, "juleana", "sync", "hosts.yaml"), "alpha: [unclosed\n")
            write(joinpath(xdg2, "juleana", "sync", "settings.yaml"), "local_root: $(mktempdir())\n")
            withenv("XDG_CONFIG_HOME" => xdg2) do
                m = sync_tui()
                Tachikoma.update!(m, KeyEvent('S'))
                @test m.sync_open && m.sync isa Sync.SyncPage && m.sync.modal_kind == :error && !m.quit
                Tachikoma.update!(m, KeyEvent(:enter))
                Tachikoma.update!(m, KeyEvent(:escape))
                @test !m.sync_open
            end
        end

        @testset "Setup's production is offered when it can be matched" begin
            mirror = mktempdir()
            settings(; production = "") = sync_settings(; production, local_root = mirror)
            # Setup works on <mirror>/test: below the local root, and "test" is a production on the host.
            mkpath(joinpath(mirror, "test"))
            withenv("LEGEND_DATA_CONFIG" => joinpath(mirror, "test", "config.json")) do
                m = sync_tui(; settings = settings())
                Tachikoma.update!(m, KeyEvent('S'))
                @test m.sync.settings.production == "test" && m.sync.suggested
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.production !== nothing && m.sync.production.name == "test" && !m.sync.picking
                # Choosing another production in the window leaves Setup alone: its state, the pending commands and
                # the environment of the process are the same afterwards.
                setup_state() = (JuLeAna.current_production(), ENV["LEGEND_DATA_CONFIG"], m.pending, m.answered, m.page, m.setup.root,
                                 m.snap)
                before = setup_state()
                draw_page = m.page
                Tachikoma.update!(m, KeyEvent(:tab))
                Tachikoma.update!(m, KeyEvent(:tab))
                Tachikoma.update!(m, KeyEvent(:tab))   # Production
                Tachikoma.update!(m, KeyEvent(:enter))                  # the productions are known: the list opens
                @test m.sync.picking
                Tachikoma.update!(m, KeyEvent(:enter))                  # the first row, temp/jl-dev
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.production.name == "temp/jl-dev" && m.sync.settings.production == "temp/jl-dev"
                @test setup_state() == before && m.page == draw_page
            end
            # A name that is not a production on the host is dropped and the picker opens.
            mkpath(joinpath(mirror, "nope"))
            withenv("LEGEND_DATA_CONFIG" => joinpath(mirror, "nope", "config.json")) do
                m = sync_tui(; settings = settings())
                Tachikoma.update!(m, KeyEvent('S'))
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.settings.production == "" && occursin("nope is not a production on local", m.sync.status) && m.sync.picking
            end
            # Setup's production lies elsewhere: the field starts empty.
            withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "prod", "config.json")) do
                m = sync_tui(; settings = settings())
                Tachikoma.update!(m, KeyEvent('S'))
                @test m.sync.settings.production == "" && !m.sync.suggested
            end
            # No production in Setup at all.
            withenv("LEGEND_DATA_CONFIG" => nothing) do
                m = sync_tui(; settings = settings())
                Tachikoma.update!(m, KeyEvent('S'))
                @test m.sync.settings.production == ""
            end
            # A production named in the given settings is kept: only an empty field is filled.
            withenv("LEGEND_DATA_CONFIG" => joinpath(mirror, "test", "config.json")) do
                m = sync_tui(; settings = settings(; production = "temp/jl-dev"))
                Tachikoma.update!(m, KeyEvent('S'))
                @test m.sync.settings.production == "temp/jl-dev" && !m.sync.suggested
            end
        end

        @testset "Setup's production below the remote root of a host in hosts.yaml" begin
            remote = sync_fixture_root()
            hosts = joinpath(mktempdir(), "hosts.yaml")
            write(hosts, "other:\n  remote_root: /nowhere/else\nlocal:\n  remote_root: $remote\n")
            settings = Sync.SyncSettings(; host = "local", remote_root = remote, local_root = mktempdir(), hosts_file = hosts,
                                         selection = joinpath(mktempdir(), "sel.yaml"))
            withenv("LEGEND_DATA_CONFIG" => joinpath(remote, "test", "config.json")) do
                m = sync_tui(; settings)
                Tachikoma.update!(m, KeyEvent('S'))
                @test m.sync.settings.production == "test" && m.sync.suggested
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.production !== nothing && m.sync.production.name == "test"
            end
        end

        # Mark the section "tier" (root, config.json, metadata, par, tier: four rows down); the mandatory copies are not marked.
        function mark_tier!(m)
            for _ in 1:4
                Tachikoma.update!(m, KeyEvent(:down))
            end
            @test Sync.current_node(m.sync).label == "tier"
            Tachikoma.update!(m, KeyEvent(' '))
            @test Sync.sync_dirty(m.sync)
        end

        @testset "the quit dialog lists every pending reason" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.quit && isnothing(m.dialog)                              # nothing pending

            # Unsaved marks.
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            mark_tier!(m)
            @test Sync.sync_dirty(m.sync) && JuLeAna.sync_pending(m)
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.dialog === :quit && !m.quit
            text = sync_render(m)
            @test find_text(text, "w: save the sync selection to") !== nothing
            @test find_text(text, "q: quit now, discarding the unsaved sync selection") !== nothing
            @test find_text(text, "s: stop after the running items") === nothing
            Tachikoma.update!(m, KeyEvent('s'))                              # s does nothing without a run
            @test m.dialog === :quit
            Tachikoma.update!(m, KeyEvent('c'))
            @test isnothing(m.dialog) && !m.quit && Sync.sync_dirty(m.sync)
            Tachikoma.update!(m, KeyEvent('q'))
            Tachikoma.update!(m, KeyEvent('w'))
            @test m.quit && isfile(Sync.selection_path(m.sync.settings)) && !Sync.sync_dirty(m.sync)

            # A running transfer.
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.modal_kind = :transfer
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.dialog === :quit &&
                  find_text(sync_render(m), "q: quit now, interrupting the sync transfer or environment creation") !== nothing
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.quit
        end

        @testset "processing and unsaved marks: w saves and the dialog stays" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            mark_tier!(m)
            @test Sync.sync_dirty(m.sync)
            m.snap = (; state = :running)                                     # the quit logic reads only the state
            message = JuLeAna.quit_message(m)
            @test occursin("s: stop after the running items, then quit", message) && occursin("w: save the sync selection to", message)
            @test occursin("q: quit now, ending the run and its workers, discarding the unsaved sync selection", message)
            @test occursin("c: cancel, keep processing", message)
            m.dialog = :quit
            Tachikoma.update!(m, KeyEvent('w'))
            @test m.dialog === :quit && !m.quit && !Sync.sync_dirty(m.sync)
            @test !occursin("w: save", JuLeAna.quit_message(m))
            # The s line names the sync work that the quit loses; a transfer is named next to the marks.
            m.sync.dirty = true
            m.sync.modal_kind = :transfer
            message = JuLeAna.quit_message(m)
            @test occursin("s: stop after the running items, then quit, interrupting the sync transfer or environment creation, discarding the unsaved sync selection\n",
                           message)
            @test occursin("q: quit now, ending the run and its workers, interrupting the sync transfer or environment creation, discarding the unsaved sync selection",
                           message)
            m.sync.modal_kind = :none
            m.sync.dirty = false
            message = JuLeAna.quit_message(m)
            @test occursin("s: stop after the running items, then quit\n", message) && !occursin("sync", message)
            m.snap = nothing
            @test JuLeAna.quit_message(m) == "q: quit now\nc: cancel"
        end

        @testset "a failing save in the quit dialog shows the error and keeps the dialog" begin
            blocker = joinpath(mktempdir(), "file")
            write(blocker, "x")
            settings = sync_settings(; production = "test")
            settings.selection = joinpath(blocker, "sel.yaml")               # a file is not a directory
            m = sync_tui(; settings)
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            mark_tier!(m)
            Tachikoma.update!(m, KeyEvent('q'))
            Tachikoma.update!(m, KeyEvent('w'))
            @test m.dialog === :quit && !m.quit && Sync.sync_dirty(m.sync) && m.sync.modal_kind == :error
        end

        @testset "hints and help" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('S'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Space copy", keys_row) && occursin("Esc close", keys_row) && occursin("q quit", keys_row)
            @test !occursin("page", keys_row)                                            # the digits open no page here
            m.sync.modal_kind = :transfer
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Esc background or stop", keys_row) && !occursin("Space copy", keys_row)
            m.sync.modal_kind = :busy                                                    # reports no progress: no stop
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Esc background", keys_row) && !occursin("or stop", keys_row)
            m.sync.modal_kind = :none
            Tachikoma.update!(m, KeyEvent(:tab))
            Tachikoma.update!(m, KeyEvent(:enter))
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Esc cancel", keys_row) && !occursin("quit", keys_row)        # text input: no global hints
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.sync_open
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("S sync", keys_row) && occursin("1-7 page", keys_row)         # Setup lists the key that opens it
        end
    end
end
