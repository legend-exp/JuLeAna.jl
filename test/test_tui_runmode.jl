# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Rect, find_text
using LegendDataManagement: DataPeriod, readlprops
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

@testset "Run mode settings" begin
    root = mktempdir()
    l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
    p2, p3 = DataPeriod.((2, 3))
    shipped_config = joinpath(dirname(@__DIR__), "config", "processing_config.yaml")
    cfg = ProcessingConfig(; processors = Dict(:process_dsp_cal => spec(:process_dsp_cal, :run, 1)),
                           p_processors = Dict(:p_process_aoe_cut_cal => spec(:p_process_aoe_cut_cal, :partition, 1)), local_n = 3,
                           local_julia_settings = ["--threads=2"], slurm_flags = ["--nodes=1", "--mem=8GB"],
                           slurm_julia_settings = String[])
    function new_session()
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [p2, p3], nothing, run_steps(cfg),
                                                                               partition_steps(cfg))
        return DataflowSession(; args = Dict{String,Any}("config" => shipped_config), l200, config = cfg, periods,
                               run_steps = run_steps(cfg), partition_steps = partition_steps(cfg), run_status, partition_status)
    end
    new_ctrl() = DataflowController(new_session())

    @testset "command" begin
        @test_throws "local_n must be positive" SetRunmodeSettings(; local_n = 0)
        @test_throws MethodError SetRunmodeSettings(; slurm_flags = [1])
        @test isnothing(SetRunmodeSettings().local_n)

        ctrl = new_ctrl()
        snap = snapshot(ctrl)
        @test snap.runmode_settings == (; local_n = 3, local_julia_settings = ["--threads=2"], slurm_flags = ["--nodes=1", "--mem=8GB"],
                                        slurm_julia_settings = String[])
        dispatch!(ctrl, SetRunmodeSettings(; local_n = 5, slurm_flags = ["--nodes=4"]))
        eff = JuLeAna.effective_config(ctrl)
        # settings that are `nothing` keep their value
        @test eff.local_n == 5 && eff.slurm_flags == ["--nodes=4"]
        @test eff.local_julia_settings == ["--threads=2"] && isempty(eff.slurm_julia_settings)
        # the session config is unchanged and the workers get the new config
        @test ctrl.session.config.local_n == 3
        @test ctrl.workers.config.local_n == 5 && ctrl.workers.config.slurm_flags == ["--nodes=4"]
        dispatch!(ctrl, SetRunmodeSettings(; local_julia_settings = String[]))
        @test snapshot(ctrl).runmode_settings ==
              (; local_n = 5, local_julia_settings = String[], slurm_flags = ["--nodes=4"], slurm_julia_settings = String[])
        # the settings stay when the run mode changes
        dispatch!(ctrl, SetRunmode(:slurm))
        @test ctrl.workers.config.runmode === :slurm && ctrl.workers.config.slurm_flags == ["--nodes=4"]

        # during a processing run, the settings apply to the next allocations
        ctrl.state = :running
        dispatch!(ctrl, SetRunmodeSettings(; slurm_flags = ["--nodes=2"]))
        @test ctrl.workers.config.slurm_flags == ["--nodes=2"]
        ctrl.state = :ready

        idle = DataflowController(Dict{String,Any}())
        @test isnothing(snapshot(idle).runmode_settings)
        @test_throws "SetRunmodeSettings is not possible while the controller is :idle" dispatch!(idle, SetRunmodeSettings(; local_n = 2))
    end

    @testset "WriteConfig" begin
        ctrl = new_ctrl()
        dispatch!(ctrl,
                  SetRunmodeSettings(; local_n = 7, local_julia_settings = ["--threads=4"], slurm_flags = ["--nodes=4", "--time=02:00:00"],
                                     slurm_julia_settings = ["--heap-size-hint=4G"]))
        written = joinpath(root, "runmode_config.yaml")
        withenv(() -> dispatch!(ctrl, WriteConfig(written)), "LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json"))
        settings = readlprops(written).config.runmode_settings
        @test settings.local.n == 7 && settings.local.julia_settings == ["--threads=4"]
        @test settings.slurm.flags == ["--nodes=4", "--time=02:00:00"] && settings.slurm.julia_settings == ["--heap-size-hint=4G"]
        @test occursin("--nodes=4", read(written, String))
        written_cfg = ProcessingConfig(written)
        @test written_cfg.local_n == 7 && written_cfg.slurm_flags == ["--nodes=4", "--time=02:00:00"]
    end

    @testset "editor" begin
        ctrl = new_ctrl()
        m = JuLeAna.JuLeAnaTUI(ctrl)
        settle(cond) = (t_end = time() + 60; while time() < t_end
                            Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
                            cond() && return true
                            sleep(0.02)
                        end; false)
        function refreshed()
            settle(() -> m.pending == 0 && !m.refreshing) || return false
            JuLeAna.refresh!(m)
            return settle(() -> !m.refreshing)
        end
        press(keys...) = foreach(k -> Tachikoma.update!(m, KeyEvent(k)), keys)
        typed(text) = foreach(c -> Tachikoma.update!(m, KeyEvent(c)), text)
        render() = (tb = TestBackend(140, 30); JuLeAna.render_setup(m.setup, m.snap, Rect(1, 1, 140, 30), tb.buf); tb)
        settings() = m.snap.runmode_settings
        @test refreshed()

        # `e` outside the Options pane opens the kwargs editor, on other option rows nothing
        press(:tab, :tab, :tab)
        @test m.setup.focus == 4
        press('e')
        @test isnothing(m.setup.editor)
        press(:down, :down, :down, :down)
        press('e')
        @test isnothing(m.setup.editor)
        press(:down)
        @test JuLeAna.SETUP_OPTIONS[m.setup.option][1] === :runmode
        press('e')
        @test m.setup.editor isa JuLeAna.RunmodeEditor
        tb = render()
        for text in ("Run mode settings", "local", "slurm", "workers (n) = 3", "--threads=2", "--nodes=1", "--mem=8GB", "(none)")
            @test find_text(tb, text) !== nothing
        end
        # the editor takes every key
        press('q', '2')
        @test !m.quit && m.page == 1

        # rows: local_n, local julia_settings + 1 entry, slurm flags + 2 entries, slurm julia_settings
        press(:enter)
        @test m.setup.editor.text == "3"
        press(:backspace, 'x', :enter)
        @test m.setup.editor.text == "x" && occursin("positive integer", m.setup.editor.error)
        @test find_text(render(), "positive integer") !== nothing
        press(:backspace, '0', :enter)
        @test m.setup.editor.text == "0" && occursin("positive integer", m.setup.editor.error)
        press(:backspace, '6', :enter)
        @test isnothing(m.setup.editor.text) && isnothing(m.setup.editor.error)
        @test refreshed()
        @test settings().local_n == 6 && JuLeAna.effective_config(ctrl).local_n == 6

        # change an entry
        press(:down, :down)
        @test m.setup.editor.cursor == 3
        press(:enter)
        @test m.setup.editor.text == "--threads=2"
        press(:backspace)
        typed("8")
        press(:enter)
        @test refreshed()
        @test settings().local_julia_settings == ["--threads=8"]

        # an empty entry is rejected, Escape drops the text and leaves the editor open
        press(:enter)
        foreach(_ -> press(:backspace), 1:11)
        press(:enter)
        @test occursin("must not be empty", m.setup.editor.error)
        press(:escape)
        @test isnothing(m.setup.editor.text) && isnothing(m.setup.editor.error) && m.setup.editor isa JuLeAna.RunmodeEditor
        @test settings().local_julia_settings == ["--threads=8"]

        # add an entry with `a` and with Enter on the heading of the slurm julia_settings list
        press(:down, :down)
        @test m.setup.editor.cursor == 5
        press('a')
        @test m.setup.editor.text == "" && m.setup.editor.adding
        typed("--time=01:00:00 ")
        press(:enter)
        @test refreshed()
        @test settings().slurm_flags == ["--nodes=1", "--mem=8GB", "--time=01:00:00"]
        press(:down, :down, :down)
        @test m.setup.editor.cursor == 8
        press(:enter)
        @test m.setup.editor.adding
        typed("-O1")
        press(:enter)
        @test refreshed()
        @test settings().slurm_julia_settings == ["-O1"]

        # delete an entry; the heading row cannot be deleted
        press(:up, :up, 'd')
        @test refreshed()
        @test settings().slurm_flags == ["--nodes=1", "--time=01:00:00"]
        press(:up, :up)
        @test m.setup.editor.cursor == 4
        press('d')
        @test refreshed()
        @test settings().slurm_flags == ["--nodes=1", "--time=01:00:00"]

        # Escape closes the editor
        press(:escape)
        @test isnothing(m.setup.editor)
        @test JuLeAna.effective_config(ctrl).slurm_flags == ["--nodes=1", "--time=01:00:00"]
        @test ctrl.workers.config.slurm_flags == ["--nodes=1", "--time=01:00:00"]
    end
end
