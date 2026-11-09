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
    write(joinpath(dest, "test", "config.json"), replace(read(joinpath(dest, "test", "config.json.in"), String), "@REMOTE_ROOT@" => dest))
    return dest
end

# The sync page reaches the fixture through LocalHost; nothing contacts a host.
function sync_tui(; settings = nothing)
    l200 = legend_test_data(legend_test_setup(mktempdir(), TEST_DIRS))
    cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                           p_processors = Dict{Symbol,ProcessorSpec}())
    periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [DataPeriod(2)], nothing, run_steps(cfg),
                                                                           partition_steps(cfg))
    session = DataflowSession(; args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml")), l200,
                              config = cfg, periods, run_steps = run_steps(cfg), partition_steps = partition_steps(cfg), run_status,
                              partition_status)
    processors = Dict{Symbol,Any}(:process_energy_calibration_cal => (cfg, l200, period, run; reprocess = false) -> nothing)
    ctrl = DataflowController(session; processors, record_software = false, record_metadata = false)
    return JuLeAna.JuLeAnaTUI(ctrl; sync_settings = settings, sync_host = alias -> Sync.LocalHost())
end

function sync_settings(; production = "", local_root = mktempdir(), selection = joinpath(mktempdir(), "sel.yaml"))
    return Sync.SyncSettings(; host = "local", remote_root = sync_fixture_root(), production, local_root, selection,
                             hosts_file = Sync.PACKAGED_HOSTS_FILE)
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

press!(m, keys...) = foreach(k -> Tachikoma.update!(m, KeyEvent(k)), keys)

# The window opened on a page that has connected to the production `test`.
function sync_window(; settings = sync_settings(; production = "test"))
    m = sync_tui(; settings)
    press!(m, 'S')
    @test sync_settle!(() -> m.sync.running == 0, m)
    return m
end

# Neither the user's configuration nor a real production is touched: both variables are temporary for the whole file.
withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json"), "XDG_CONFIG_HOME" => mktempdir()) do
    @testset "Sync window" begin
        @testset "S opens the window on Setup only, and the page is created on the first opening" begin
            m = sync_tui(; settings = sync_settings())
            @test length(JuLeAna.TUI_PAGES) == 7 && !("Sync" in JuLeAna.TUI_PAGES) && find_text(sync_render(m), "Sync") === nothing
            press!(m, '2', '3', '1')
            Tachikoma.update!(m, TaskEvent(:tick, nothing))
            @test isnothing(m.sync) && !m.sync_open
            press!(m, '2', 'S')
            @test !m.sync_open && isnothing(m.sync)
            press!(m, '1', '/', 'S')   # in the filter of Setup, S is text
            @test !m.sync_open && isnothing(m.sync)
        end

        @testset "the window takes the keys and the mouse and leaves q, ? and T to the interface" begin
            m = sync_tui(; settings = sync_settings())
            press!(m, 'S')
            @test m.sync_open && m.page == 1 && m.sync isa Sync.SyncPage && m.sync.running == 1   # the connection starts
            @test sync_settle!(() -> m.sync.running == 0, m)
            tb = sync_render(m)
            @test find_text(tb, "Data sync") !== nothing && find_text(tb, "Settings") !== nothing &&
                  find_text(tb, "Productions on local") !== nothing
            @test find_text(tb, "1 Setup") !== nothing   # the tab bar stays
            press!(m, :escape)   # Esc closes the list first, then the window; opening again does not connect again
            @test m.sync_open && !m.sync.picking
            press!(m, :escape)
            @test !m.sync_open && find_text(sync_render(m), "Data sync") === nothing
            press!(m, 'S')
            @test m.sync_open && m.sync.running == 0
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Space copy", keys_row) && occursin("Esc close", keys_row) && occursin("q quit", keys_row) &&
                  !occursin("page", keys_row)

            press!(m, '3')
            @test m.page == 1 && m.sync_open   # a digit opens no page
            r = m.tabs._tab_rects[3]
            click(x, y) = MouseEvent(x, y, mouse_left, mouse_press, false, false, false)
            Tachikoma.update!(m, click(r.x + 2, r.y))
            @test m.page == 1 && m.sync_open   # neither does a tab
            host = Dict(m.sync.panel_rects)[:host]
            Tachikoma.update!(m, click(host.x + 1, host.y))   # the page gets the click
            @test m.sync.focus == :panel && !isnothing(m.sync.edit)
            press!(m, :escape, :escape)
            @test m.sync.focus == :tree && m.sync_open

            press!(m, '?')
            help = sync_render(m)
            @test m.help && find_text(help, "Sync window") !== nothing && find_text(help, "Setup page") === nothing &&
                  find_text(help, "open a page") === nothing
            press!(m, :escape)
            @test !m.help && m.sync_open   # Esc closes the help, not the window
            previous, depot = Tachikoma.theme(), mktempdir()
            pushfirst!(DEPOT_PATH, depot)
            try
                Tachikoma.set_theme!(JuLeAna.tui_theme("night-owl"))
                @test_logs (:info, "Theme: juleana") Tachikoma.update!(m, KeyEvent('T'))
                @test Tachikoma.theme().name == "juleana"
            finally
                popfirst!(DEPOT_PATH)
                Tachikoma.set_theme!(previous)
            end

            # A field in edit takes digits and q as text, and its hints are the editing ones; Esc steps back through the edit and the panel.
            press!(m, :tab, :enter, '3', 'q')
            @test m.sync_open && !m.quit && endswith(m.sync.edit.text, "3q")
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Esc cancel", keys_row) && !occursin("quit", keys_row)
            press!(m, :escape)
            @test isnothing(m.sync.edit) && m.sync.focus == :panel && m.sync_open
            press!(m, :escape)
            @test m.sync.focus == :tree && m.sync_open
            press!(m, :escape)
            @test !m.sync_open
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("S sync", keys_row) && occursin("1-7 page", keys_row)   # Setup lists the key that opens the window

            # The page gets no click and no key once the window is closed.
            Tachikoma.update!(m, click(host.x + 1, host.y))
            @test m.sync.focus == :tree
            press!(m, '3')
            @test m.page == 3
            press!(m, '1', 'S', 'q')
            @test m.quit && isnothing(m.dialog)
        end

        @testset "Esc asks while a sync runs: background, stop or stay" begin
            m = sync_window()
            m.sync.modal_kind = :transfer
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Esc background or stop", keys_row) && !occursin("Space copy", keys_row)
            press!(m, :escape)
            @test m.dialog === :sync_leave
            tb = sync_render(m)
            @test find_text(tb, "b: close the window") !== nothing && find_text(tb, "s: stop") !== nothing &&
                  find_text(tb, "c: cancel") !== nothing
            press!(m, 'x')   # other keys do nothing; c and Esc stay in the window
            @test m.dialog === :sync_leave
            press!(m, 'c')
            @test isnothing(m.dialog) && m.sync_open && Sync.sync_stoppable(m.sync)
            press!(m, :escape, :escape)
            @test isnothing(m.dialog) && m.sync_open
            press!(m, :escape, 'b')   # b closes the window and the work goes on; S shows it again
            @test isnothing(m.dialog) && !m.sync_open && m.sync.modal_kind == :transfer && Sync.sync_stoppable(m.sync)
            @test find_text(sync_render(m), "sync running") !== nothing
            press!(m, 'S', :escape, 's')   # s stops it; once it stops, only the background is left to offer
            @test isnothing(m.dialog) && m.sync_open && !Sync.sync_stoppable(m.sync) && Sync.sync_running(m.sync)
            press!(m, :escape)
            @test find_text(sync_render(m), "s: stop") === nothing
            press!(m, 's')
            @test m.dialog === :sync_leave

            # Environment creation reports no progress: it can go to the background, not be stopped.
            m2 = sync_window()
            m2.sync.modal_kind = :busy
            keys_row = row_text(sync_render(m2, 150, 40), 39)
            @test occursin("Esc background", keys_row) && !occursin("or stop", keys_row)
            press!(m2, :escape)
            @test find_text(sync_render(m2), "s: stop") === nothing
            press!(m2, 's')
            @test m2.dialog === :sync_leave && m2.sync.modal_kind == :busy
            press!(m2, 'b')
            @test !m2.sync_open && m2.sync.modal_kind == :busy

            # The question closes itself when the sync ends while it is open.
            m3 = sync_window()
            m3.sync.modal_kind = :transfer
            press!(m3, :escape)
            m3.sync.running += 1
            Tachikoma.update!(m3, TaskEvent(Symbol("sync:transfer"), ErrorException("boom")))
            @test isnothing(m3.dialog) && m3.sync_open && m3.sync.modal_kind == :error && find_text(sync_render(m3), "boom") !== nothing
        end

        @testset "the status panel shows a running sync and what waits in the closed window" begin
            m = sync_window()
            press!(m, :escape)
            @test !m.sync_open && find_text(sync_render(m), "No processing run in this session.") !== nothing
            m.sync.modal_kind = :transfer
            m.sync.step = Sync.StepProgress("copying", 2, 3, 45, 100, nothing, "")
            tb = sync_render(m)
            @test find_text(tb, "[2/3] copying 45/100") !== nothing && find_text(tb, "No processing run") === nothing &&
                  find_text(tb, "sync running") !== nothing
            # A run in progress keeps the bar.
            m.snap = (; state = :running, outcome = nothing, nworkers = 0, idle_deadline = nothing, last_error = nothing,
                      started = now(UTC), finished = nothing)
            m.progress = (; fraction = 0.5)
            panel = TestBackend(120, 4)
            JuLeAna.render_status(m, Rect(1, 1, 120, 4), panel.buf)
            @test find_text(panel, "50%") !== nothing && find_text(panel, "copying") === nothing
            m.snap, m.progress = nothing, nothing

            m.sync.running += 1   # a failure waits in the closed window, the panel says so, and S shows it
            Tachikoma.update!(m, TaskEvent(Symbol("sync:transfer"), ErrorException("boom")))
            tb = sync_render(m)
            @test find_text(tb, "sync: Error, S on Setup shows it") !== nothing && find_text(tb, "sync running") === nothing
            @test find_text(tb, "No processing run in this session.") !== nothing
            press!(m, 'S')
            @test find_text(sync_render(m), "boom") !== nothing && find_text(sync_render(m), "S on Setup shows it") === nothing
            press!(m, :enter, :escape)
            @test !m.sync_open && find_text(sync_render(m), "S on Setup shows it") === nothing
            m.sync.running += 1   # so does a question
            m.sync.modal_kind = :estimating
            Tachikoma.update!(m, TaskEvent(Symbol("sync:estimate"), (Sync.Estimate(0, 0, 0, true), false, nothing, nothing)))
            @test find_text(sync_render(m), "sync: Estimate, S on Setup shows it") !== nothing

            # Processing and a sync do not run together.
            for kind in (:checking, :estimating, :transfer, :busy)
                m.sync.modal_kind = kind
                @test_logs (:warn, r"a sync is running") press!(m, 's')
                @test m.pending == 0 && !isready(m.commands)
            end
            m.sync.modal_kind = :estimate   # a dialog that waits for an answer holds nothing up: the command is sent
            close(m.commands)   # a closed channel keeps it from running
            @test_throws InvalidStateException press!(m, 's')
            @test m.pending == 1
            for state in (:running, :stopping)
                m2 = sync_tui(; settings = sync_settings())
                m2.snap = (; state)
                @test_logs (:warn, r"processing") press!(m2, 'S')
                @test !m2.sync_open && isnothing(m2.sync)
            end
        end

        @testset "the quit dialog lists every pending reason" begin
            # Mark the section "tier" (root, config.json, metadata, par, tier: four rows down); the mandatory copies are not marks.
            mark_tier!(m) = (press!(m, :down, :down, :down, :down, ' '); @test Sync.sync_dirty(m.sync))
            m = sync_window()
            mark_tier!(m)
            @test JuLeAna.sync_pending(m)
            press!(m, 'q')
            @test m.dialog === :quit && !m.quit
            text = sync_render(m)
            @test find_text(text, "w: save the sync selection to") !== nothing &&
                  find_text(text, "q: quit now, discarding the unsaved sync selection") !== nothing
            @test find_text(text, "s: stop after the running items") === nothing
            press!(m, 's')   # s does nothing without a run
            @test m.dialog === :quit
            press!(m, 'c')
            @test isnothing(m.dialog) && !m.quit && Sync.sync_dirty(m.sync)
            press!(m, 'q', 'w')
            @test m.quit && isfile(Sync.selection_path(m.sync.settings)) && !Sync.sync_dirty(m.sync)

            m = sync_window()
            m.sync.modal_kind = :transfer
            press!(m, 'q')
            @test m.dialog === :quit &&
                  find_text(sync_render(m), "q: quit now, interrupting the sync transfer or environment creation") !== nothing
            press!(m, 'q')
            @test m.quit

            # With a run in progress the dialog also offers to stop it; w saves and the dialog stays.
            m = sync_window()
            mark_tier!(m)
            m.snap = (; state = :running)   # the quit logic reads only the state
            message = JuLeAna.quit_message(m)
            @test occursin("s: stop after the running items, then quit", message) && occursin("w: save the sync selection to", message)
            @test occursin("q: quit now, ending the run and its workers, discarding the unsaved sync selection", message)
            @test occursin("c: cancel, keep processing", message)
            m.dialog = :quit
            press!(m, 'w')
            @test m.dialog === :quit && !m.quit && !Sync.sync_dirty(m.sync) && !occursin("w: save", JuLeAna.quit_message(m))
            m.sync.dirty, m.sync.modal_kind = true, :transfer   # the s line names the sync work that the quit loses
            message = JuLeAna.quit_message(m)
            @test occursin("s: stop after the running items, then quit, interrupting the sync transfer or environment creation, discarding the unsaved sync selection\n",
                           message)
            m.sync.dirty, m.sync.modal_kind = false, :none
            @test occursin("s: stop after the running items, then quit\n", JuLeAna.quit_message(m)) &&
                  !occursin("sync", JuLeAna.quit_message(m))
            m.snap = nothing
            @test JuLeAna.quit_message(m) == "q: quit now\nc: cancel"

            blocker = joinpath(mktempdir(), "file")   # a failing save shows the error and keeps the dialog
            write(blocker, "x")
            m = sync_window(; settings = sync_settings(; production = "test", selection = joinpath(blocker, "sel.yaml")))
            mark_tier!(m)
            press!(m, 'q', 'w')
            @test m.dialog === :quit && !m.quit && Sync.sync_dirty(m.sync) && m.sync.modal_kind == :error
        end

        @testset "a fault in the page is shown in its dialog and the interface keeps running" begin
            m = sync_window()
            m.sync.picker = Tachikoma.SelectableList(["a"])   # a corrupt state: choosing from the list fails on it
            m.sync.productions = nothing
            m.sync.picking = true
            press!(m, :enter)
            @test m.sync_open && !m.quit && m.sync.modal_kind == :error && find_text(sync_render(m), "Error") !== nothing
            press!(m, :enter)
            tb = sync_render(m)   # drawing the corrupt state shows one line and keeps the tab bar
            @test find_text(tb, "The Sync page failed to draw") !== nothing && find_text(tb, "1 Setup") !== nothing && !m.quit
            m.sync.picking = false
            @test find_text(sync_render(m), "Settings") !== nothing
            press!(m, :escape)
            @test !m.sync_open
        end

        @testset "a malformed configuration file is shown on the first opening, not fatal" begin
            for (name, text) in (("settings.yaml", "local_root: [unclosed\n"), ("hosts.yaml", "alpha: [unclosed\n"))
                xdg = mktempdir()
                mkpath(joinpath(xdg, "juleana", "sync"))
                write(joinpath(xdg, "juleana", "sync", name), text)
                name == "hosts.yaml" && write(joinpath(xdg, "juleana", "sync", "settings.yaml"), "local_root: $(mktempdir())\n")
                withenv("XDG_CONFIG_HOME" => xdg) do
                    m = sync_tui()   # no settings given: the first opening reads the directory
                    press!(m, 'S')
                    @test m.sync_open && m.sync isa Sync.SyncPage && m.sync.modal_kind == :error && !m.quit && m.sync.running == 0
                    press!(m, :enter, :escape)
                    @test !m.sync_open
                end
            end
        end

        @testset "Setup's production is offered when it can be matched and picking another leaves Setup alone" begin
            mirror = mktempdir()
            mkpath(joinpath(mirror, "test"))
            withenv("LEGEND_DATA_CONFIG" => joinpath(mirror, "test", "config.json")) do
                m = sync_tui(; settings = sync_settings(; local_root = mirror))
                press!(m, 'S')
                @test m.sync.settings.production == "test" && m.sync.suggested
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.production !== nothing && m.sync.production.name == "test" && !m.sync.picking
                setup_state() = (JuLeAna.current_production(), ENV["LEGEND_DATA_CONFIG"], m.pending, m.answered, m.page, m.setup.root,
                                 m.snap)
                before = setup_state()
                press!(m, :tab, :tab, :tab, :enter)   # the Production field; the productions are known: the list opens
                @test m.sync.picking
                press!(m, :enter)   # the first row, temp/jl-dev
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.production.name == "temp/jl-dev" && m.sync.settings.production == "temp/jl-dev" && setup_state() == before
            end
            mkpath(joinpath(mirror, "nope"))
            withenv("LEGEND_DATA_CONFIG" => joinpath(mirror, "nope", "config.json")) do   # a name that is no production on the host is dropped
                m = sync_tui(; settings = sync_settings(; local_root = mirror))
                press!(m, 'S')
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.settings.production == "" && occursin("nope is not a production on local", m.sync.status) && m.sync.picking
            end
        end
    end
end
