# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using JuLeAna: Sync
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TaskEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text,
                 mouse_left, mouse_press
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
    @testset "Sync tab" begin
        @testset "tab 8 exists and the page is created on the first visit" begin
            m = sync_tui(; settings = sync_settings())
            @test last(JuLeAna.TUI_PAGES) == "Sync" && JuLeAna.SYNC_PAGE == 8
            tb = sync_render(m)
            @test find_text(tb, "8 Sync") !== nothing
            @test isnothing(m.sync)
            Tachikoma.update!(m, KeyEvent('8'))
            @test m.page == 8 && m.sync isa Sync.SyncPage && m.sync.running == 1     # the connection starts
            @test sync_settle!(() -> m.sync.running == 0, m)
            tb = sync_render(m)
            @test find_text(tb, "Settings") !== nothing && find_text(tb, "Productions on local") !== nothing
            # Visiting again does not connect again.
            Tachikoma.update!(m, KeyEvent('1'))
            Tachikoma.update!(m, KeyEvent('8'))
            @test m.sync.running == 0
            # A click on the tab does the same as the digit.
            m2 = sync_tui(; settings = sync_settings())
            sync_render(m2)
            r = m2.tabs._tab_rects[8]
            Tachikoma.update!(m2, MouseEvent(r.x + 2, r.y, mouse_left, mouse_press, false, false, false))
            @test m2.page == 8 && m2.sync isa Sync.SyncPage
        end

        @testset "an interface that never visits the tab never creates the page" begin
            m = sync_tui(; settings = sync_settings())
            for key in ('2', '3', '1')
                Tachikoma.update!(m, KeyEvent(key))
            end
            Tachikoma.update!(m, TaskEvent(:tick, nothing))
            @test isnothing(m.sync)
        end

        @testset "the keys of main are not shadowed" begin
            m = sync_tui(; settings = sync_settings())
            Tachikoma.update!(m, KeyEvent('8'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            Tachikoma.update!(m, KeyEvent(:escape))                  # closes the picker, which the Sync page opened
            Tachikoma.update!(m, KeyEvent('3'))
            @test m.page == 3
            Tachikoma.update!(m, KeyEvent('8'))
            Tachikoma.update!(m, KeyEvent('?'))
            @test m.help && find_text(sync_render(m), "Sync page") !== nothing
            Tachikoma.update!(m, KeyEvent(:escape))
            @test !m.help
            # A field in edit takes digits and q as text.
            Tachikoma.update!(m, KeyEvent(:tab))
            Tachikoma.update!(m, KeyEvent(:enter))
            Tachikoma.update!(m, KeyEvent('3'))
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.page == 8 && !m.quit && endswith(m.sync.edit.text, "3q")
            Tachikoma.update!(m, KeyEvent(:escape))
            @test isnothing(m.sync.edit)
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.quit && isnothing(m.dialog)
        end

        @testset "sync: task events reach the page, others still reach main" begin
            m = sync_tui(; settings = sync_settings())
            Tachikoma.update!(m, KeyEvent('8'))
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
            Tachikoma.update!(m, KeyEvent('8'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.picker = Tachikoma.SelectableList(["a"])
            m.sync.productions = nothing
            m.sync.picking = true                                     # a corrupt state: choosing from the list fails on it
            Tachikoma.update!(m, KeyEvent(:enter))
            @test m.page == 8 && !m.quit && m.sync.modal_kind == :error
            @test find_text(sync_render(m), "Error") !== nothing
            Tachikoma.update!(m, KeyEvent(:enter))
            Tachikoma.update!(m, KeyEvent('3'))                       # the dialog is closed: main's keys work again
            @test m.page == 3
        end

        @testset "a fault while drawing is shown as one line and the interface keeps running" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('8'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.picker = Tachikoma.SelectableList(["a"])
            m.sync.productions = nothing
            m.sync.picking = true                                     # render_picker needs the list of productions
            tb = sync_render(m)
            @test find_text(tb, "The Sync page failed to draw") !== nothing && find_text(tb, "8 Sync") !== nothing
            @test !m.quit
            m.sync.picking = false
            @test find_text(sync_render(m), "Settings") !== nothing   # the page draws again once the state is sound
        end

        @testset "a malformed configuration file is shown on the first visit, not fatal" begin
            xdg = mktempdir()
            mkpath(joinpath(xdg, "juleana", "sync"))
            write(joinpath(xdg, "juleana", "sync", "settings.yaml"), "local_root: [unclosed\n")
            withenv("XDG_CONFIG_HOME" => xdg) do
                m = sync_tui()                                        # no settings given: the first visit reads the directory
                Tachikoma.update!(m, KeyEvent('8'))
                @test m.page == 8 && m.sync isa Sync.SyncPage && m.sync.modal_kind == :error && !m.quit
                @test m.sync.running == 0                             # nothing connected
            end
            # A malformed hosts.yaml fails while the page is built (it validates the settings): same result.
            xdg2 = mktempdir()
            mkpath(joinpath(xdg2, "juleana", "sync"))
            write(joinpath(xdg2, "juleana", "sync", "hosts.yaml"), "alpha: [unclosed\n")
            write(joinpath(xdg2, "juleana", "sync", "settings.yaml"), "local_root: $(mktempdir())\n")
            withenv("XDG_CONFIG_HOME" => xdg2) do
                m = sync_tui()
                Tachikoma.update!(m, KeyEvent('8'))
                @test m.page == 8 && m.sync isa Sync.SyncPage && m.sync.modal_kind == :error && !m.quit
                Tachikoma.update!(m, KeyEvent(:enter))
                Tachikoma.update!(m, KeyEvent('3'))
                @test m.page == 3
            end
        end

        @testset "Setup's production is offered when it can be matched" begin
            mirror = mktempdir()
            settings(; production = "") = sync_settings(; production, local_root = mirror)
            # Setup works on <mirror>/test: below the local root, and "test" is a production on the host.
            mkpath(joinpath(mirror, "test"))
            withenv("LEGEND_DATA_CONFIG" => joinpath(mirror, "test", "config.json")) do
                m = sync_tui(; settings = settings())
                Tachikoma.update!(m, KeyEvent('8'))
                @test m.sync.settings.production == "test" && m.sync.suggested
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.production !== nothing && m.sync.production.name == "test" && !m.sync.picking
                # Choosing another production on the Sync tab leaves Setup alone: its state, the pending commands and
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
                Tachikoma.update!(m, KeyEvent('8'))
                @test sync_settle!(() -> m.sync.running == 0, m)
                @test m.sync.settings.production == "" && occursin("nope is not a production on local", m.sync.status) && m.sync.picking
            end
            # Setup's production lies elsewhere: the field starts empty.
            withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "prod", "config.json")) do
                m = sync_tui(; settings = settings())
                Tachikoma.update!(m, KeyEvent('8'))
                @test m.sync.settings.production == "" && !m.sync.suggested
            end
            # No production in Setup at all.
            withenv("LEGEND_DATA_CONFIG" => nothing) do
                m = sync_tui(; settings = settings())
                Tachikoma.update!(m, KeyEvent('8'))
                @test m.sync.settings.production == ""
            end
            # A production named in the given settings is kept: only an empty field is filled.
            withenv("LEGEND_DATA_CONFIG" => joinpath(mirror, "test", "config.json")) do
                m = sync_tui(; settings = settings(; production = "temp/jl-dev"))
                Tachikoma.update!(m, KeyEvent('8'))
                @test m.sync.settings.production == "temp/jl-dev" && !m.sync.suggested
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
            Tachikoma.update!(m, KeyEvent('8'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.quit && isnothing(m.dialog)                              # nothing pending

            # Unsaved marks.
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('8'))
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
            Tachikoma.update!(m, KeyEvent('8'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            m.sync.modal_kind = :transfer
            Tachikoma.update!(m, KeyEvent('q'))                       # the page takes every key but Ctrl-C while a transfer runs
            @test isnothing(m.dialog) && !m.quit
            Tachikoma.update!(m, KeyEvent(:ctrl_c))
            @test m.dialog === :quit && find_text(sync_render(m), "q: quit now, interrupting the sync transfer") !== nothing
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.quit
        end

        @testset "processing and unsaved marks: w saves and the dialog stays" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('8'))
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
        end

        @testset "hints and help" begin
            m = sync_tui(; settings = sync_settings(; production = "test"))
            Tachikoma.update!(m, KeyEvent('8'))
            @test sync_settle!(() -> m.sync.running == 0, m)
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Space copy", keys_row) && occursin("1-8 page  q quit", keys_row)
            Tachikoma.update!(m, KeyEvent(:tab))
            Tachikoma.update!(m, KeyEvent(:enter))
            keys_row = row_text(sync_render(m, 150, 40), 39)
            @test occursin("Esc cancel", keys_row) && !occursin("quit", keys_row)        # text input: no global hints
        end
    end
end
