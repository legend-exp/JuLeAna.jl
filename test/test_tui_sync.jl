# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using JuLeAna: Sync
using Tachikoma: Tachikoma, KeyEvent, TaskEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text
using LegendDataManagement: DataPeriod
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")
include(joinpath(@__DIR__, "sync", "fixture.jl"))

# The sync page reaches the remote root through LocalHost; nothing contacts a host.
function sync_tui(; production = "")
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
    settings = Sync.SyncSettings(; host = "local", remote_root = make_remote(), production, local_root = mktempdir(),
                                 selection = joinpath(mktempdir(), "sel.yaml"), hosts_file = Sync.PACKAGED_HOSTS_FILE)
    return JuLeAna.JuLeAnaTUI(ctrl; sync_settings = settings, sync_host = alias -> Sync.LocalHost())
end

function sync_render(m, width = 120, height = 36)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end

function sync_settle!(m)
    done() = (Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue); m.sync.running == 0)
    return timedwait(done, 60; pollint = 0.02) == :ok
end

press!(m, keys...) = foreach(k -> Tachikoma.update!(m, KeyEvent(k)), keys)
shows(m, text) = find_text(sync_render(m), text) !== nothing

withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json"), "XDG_CONFIG_HOME" => mktempdir()) do
    @testset "Sync window" begin
        @testset "S opens the window on Setup only, Esc closes it or asks while a sync runs" begin
            m = sync_tui(; production = "test")
            press!(m, '2', 'S')
            @test !m.sync_open && isnothing(m.sync)
            press!(m, '1', 'S')
            @test m.sync_open && m.sync isa Sync.SyncPage && m.sync.running == 1 && sync_settle!(m) && shows(m, "Data sync")
            m.sync.modal_kind = :busy   # environment creation cannot be stopped
            press!(m, :escape)
            @test m.dialog === :sync_leave && !shows(m, "s: stop")
            press!(m, 'c')
            m.sync.modal_kind = :none
            press!(m, :escape)
            @test !m.sync_open
            press!(m, 'S')
            m.sync.modal_kind = :transfer
            press!(m, :escape)
            @test m.dialog === :sync_leave && shows(m, "b: close the window") && shows(m, "s: stop") && shows(m, "c: cancel")
            press!(m, 'c')
            @test isnothing(m.dialog) && m.sync_open && Sync.sync_stoppable(m.sync)
            press!(m, :escape, 'b')
            m.sync.step = Sync.StepProgress("copying", 2, 3, 45, 100, nothing, "")
            @test !m.sync_open && shows(m, "sync running") && shows(m, "[2/3] copying 45/100")
            @test_logs (:warn, r"a sync is running") press!(m, 's')
            press!(m, 'S', :escape, 's')
            @test m.sync_open && !Sync.sync_stoppable(m.sync) && Sync.sync_running(m.sync)
            m2 = sync_tui()
            m2.snap = (; state = :running)
            @test_logs (:warn, r"processing") press!(m2, 'S')
            @test !m2.sync_open && isnothing(m2.sync)
        end

        @testset "the quit dialog lists every pending reason" begin
            m = sync_tui(; production = "test")
            press!(m, 'S')
            @test sync_settle!(m)
            press!(m, :down, ' ', 'q')
            @test m.dialog === :quit && shows(m, "w: save the sync selection to") && shows(m, "q: quit now, discarding the unsaved")
            press!(m, 'w')
            @test m.quit && isfile(Sync.selection_path(m.sync.settings))
            m.sync.modal_kind = :transfer
            @test occursin("interrupting the sync transfer", JuLeAna.quit_message(m))
        end
    end
end
