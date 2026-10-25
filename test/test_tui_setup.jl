# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TestBackend, Rect, find_text, row_text
using LegendDataManagement: DataPeriod, DataRun
using Logging: Logging
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

# Deliver the events of `m`'s task queue, as the app loop does, until `cond()` holds.
function setup_settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

# Wait until all commands are answered, then read the controller state anew.
function setup_refreshed!(m)
    setup_settle!(() -> m.pending == 0 && !m.refreshing, m) || return false
    JuLeAna.refresh!(m)
    return setup_settle!(() -> !m.refreshing, m)
end

function render_setup_page(m, width = 140, height = 30)
    return (tb = TestBackend(width, height); JuLeAna.render_setup(m.setup, m.snap, Rect(1, 1, width, height), tb.buf); tb)
end

press!(m, keys...) = foreach(k -> Tachikoma.update!(m, KeyEvent(k)), keys)

@testset "Setup page" begin
    @testset "tag colors" begin
        style(tag) = JuLeAna.setup_tag_style(tag)
        @test style("cal").fg == Tachikoma.tstyle(:primary).fg
        @test style("phy").fg == Tachikoma.tstyle(:secondary).fg
        @test style("rank 3").fg == Tachikoma.tstyle(:text_dim).fg
        @test isnothing(style("2 runs"))
    end

    root = mktempdir()
    l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
    p2, p3 = DataPeriod.((2, 3))
    r0, r6, r7 = DataRun.((0, 6, 7))
    all_runs = [[(p2, r) for r in DataRun.(0:7)]; [(p3, r) for r in DataRun.(0:5)]]
    args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
    cfg = ProcessingConfig(;
                           processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1),
                                             :process_dsp_cal => spec(:process_dsp_cal, :run, 2; enabled = false)),
                           p_processors = Dict(:p_process_aoe_cut_cal =>
                                                   spec(:p_process_aoe_cut_cal, :partition, 1; dependencies = [:process_dsp_cal])))
    function new_session()
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [p2, p3], nothing, run_steps(cfg),
                                                                               partition_steps(cfg))
        return DataflowSession(; args, l200, config = cfg, periods, run_steps = run_steps(cfg), partition_steps = partition_steps(cfg),
                               run_status, partition_status)
    end
    run_stub(cfg, l200, period, run; reprocess = false) = nothing
    part_stub(cfg, l200, period; reprocess = false, only_first_period = false) = false
    energy_stub(cfg, l200, period, run; reprocess = false, max_wvfs = 10, channels = Symbol[]) = nothing
    processors = Dict{Symbol,Any}(:process_energy_calibration_cal => energy_stub, :process_dsp_cal => run_stub,
                                  :p_process_aoe_cut_cal => part_stub)
    new_tui(session = new_session()) = JuLeAna.JuLeAnaTUI(DataflowController(session; processors, record_software = false,
                                                                             record_metadata = false))

    @testset "checklists follow the controller" begin
        m = new_tui()
        @test setup_refreshed!(m)
        page = m.setup
        @test JuLeAna.checked(page.periods) == all_runs
        @test JuLeAna.checked(page.run_procs) == [:process_energy_calibration_cal]
        @test JuLeAna.checked(page.part_procs) == [:p_process_aoe_cut_cal]
        @test [i.key for i in page.run_procs.groups[1].items] == [:process_energy_calibration_cal, :process_dsp_cal]
        dsp = page.run_procs.groups[1].items[2]
        @test dsp.tags == ["cal", "rank 02"]
        @test page.part_procs.groups[1].items[1].tags == ["cal", "rank 01"]

        tb = render_setup_page(m)
        for text in ("Periods / runs", "Run processors", "Partition processors", "Reprocess: config", "Processor log level: config",
                     "Processor plot level: config", "Check dependencies: yes", "Periods: 2 (p02, p03)", "Runs: 14", "Run steps: 1 × 14 runs",
                     "Partition steps: 1 × 2 periods")
            @test find_text(tb, text) !== nothing
        end
        # the keys are in the key row and the help panel, not in the options pane
        @test find_text(tb, "s: start") === nothing
        # the logo is drawn only where the options pane has room for it
        letters_bottom = strip(JuLeAna.LOGO_LETTERS[end])
        @test find_text(tb, letters_bottom) === nothing
        @test find_text(render_setup_page(m, 280, 50), letters_bottom) !== nothing

        # a change in the controller shows up in the checklists
        dispatch!(m.ctrl, SelectRuns(Dict(2 => [7])))
        @test setup_refreshed!(m)
        @test JuLeAna.checked(page.periods) == [(p2, r7)]
    end

    @testset "dataset info" begin
        m = new_tui()
        @test setup_refreshed!(m)
        @test setup_settle!(() -> m.setup.dataset isa AbstractDict, m)
        # the cursor is on the p02 group: the totals of the period
        tb = render_setup_page(m)
        for text in ("Dataset p02", "Start 2022-01-01 00:00 UTC", "8 runs", "32 keys", "22:13:20")
            @test find_text(tb, text) !== nothing
        end
        press!(m, fill(:down, 7)...)
        tb = render_setup_page(m)
        for text in ("Dataset p02-r006", "Start 2022-07-01 00:00 UTC", "4 keys", "02:46:40")
            @test find_text(tb, text) !== nothing
        end
        @test find_text(tb, "no analysis") === nothing

        page = JuLeAna.SetupPage()
        page.dataset = m.setup.dataset
        p16, p99 = DataPeriod.((16, 99))
        page.periods = JuLeAna.Checklist([JuLeAna.ChecklistGroup(p16, "p16",
                                                                 [JuLeAna.ChecklistItem((p16, r6), "r006"),
                                                                  JuLeAna.ChecklistItem((p16, DataRun(99)), "r099")]),
                                          JuLeAna.ChecklistGroup(p99, "p99", JuLeAna.ChecklistItem[])])
        text(page) = join(join(first.(spans)) for spans in JuLeAna.dataset_lines(page).lines)
        @test occursin("4 runs", text(page)) && occursin("0 analysis", text(page))
        page.periods.cursor = 2
        @test JuLeAna.dataset_lines(page).title == "Dataset p16-r006"
        @test occursin("no analysis", text(page)) && occursin("00:01:09", text(page))
        # a run or period that is not in the runinfo
        page.periods.cursor = 3
        @test occursin("not in the runinfo", text(page))
        page.periods.cursor = 4
        @test occursin("not in the runinfo", text(page))
        # every run and period has a box of the same height
        @test length(unique(length(JuLeAna.dataset_lines((page.periods.cursor = i; page)).lines) for i in 1:4)) == 1
        page.dataset = "no runinfo file"
        @test JuLeAna.dataset_lines(page).lines == [[("runinfo: no runinfo file", Tachikoma.tstyle(:error))]]
        page.dataset = nothing
        @test occursin("Reading the runinfo", text(page))
    end

    @testset "selections become controller commands" begin
        m = new_tui()
        @test setup_refreshed!(m)
        # rows: p02, r000 to r007, p03, r000 to r005
        press!(m, fill(:down, 8)..., ' ')
        @test setup_refreshed!(m)
        @test m.snap.runs == Dict(p2 => DataRun.(0:6))
        @test m.snap.periods == [p2, p3]
        press!(m, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.periods == [p2]
        @test isnothing(m.command_error)

        press!(m, :tab)
        @test m.setup.focus == 2 && m.setup.run_procs.focused && !m.setup.periods.focused
        press!(m, ' ')
        @test setup_refreshed!(m)
        @test isempty(m.snap.run_steps)
        press!(m, 'c')
        @test setup_refreshed!(m)
        @test m.snap.run_steps == [:process_energy_calibration_cal, :process_dsp_cal]
        press!(m, 'p')
        @test setup_refreshed!(m)
        @test isempty(m.snap.run_steps)

        # `d` adds the dependency of the partition step
        press!(m, :tab, 'n', 'd')
        @test setup_refreshed!(m)
        @test isempty(m.snap.partition_steps) && isempty(m.snap.run_steps)
        press!(m, 'a', 'd')
        @test setup_refreshed!(m)
        @test m.snap.partition_steps == [:p_process_aoe_cut_cal]
        @test m.snap.run_steps == [:process_dsp_cal]

        # options pane
        press!(m, :tab)
        @test m.setup.focus == 4 && !m.setup.part_procs.focused
        press!(m, ' ')
        @test setup_refreshed!(m)
        @test m.snap.reprocess === true
        press!(m, ' ')
        @test setup_refreshed!(m)
        @test m.snap.reprocess === false
        press!(m, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.processor_log_level == Logging.Debug
        press!(m, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.processor_plot_level === :debug
        press!(m, :down, :enter)
        @test setup_refreshed!(m)
        @test !m.snap.check_dependencies
        press!(m, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.analysis_runs_only == !cfg.analysis_runs_only
        # the run mode row is drawn and cycles between :local and :slurm
        @test find_text(render_setup_page(m), "Run mode") !== nothing
        other_runmode = cfg.runmode === :local ? :slurm : :local
        @test m.snap.runmode === cfg.runmode
        press!(m, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.runmode === other_runmode
        press!(m, ' ')
        @test setup_refreshed!(m)
        @test m.snap.runmode === cfg.runmode
        press!(m, :tab, :tab)
        @test m.setup.focus == 1 && m.setup.periods.focused
        press!(m, :backtab, :backtab)
        @test m.setup.focus == 4

        # start
        press!(m, 's')
        @test setup_refreshed!(m)
        wait(m.ctrl)
        @test setup_refreshed!(m)
        @test m.snap.outcome === :finished
    end

    @testset "action keys" begin
        page = JuLeAna.SetupPage()
        sent = ControllerCommand[]
        for (key, expected) in
            (('s', StartProcessing), ('x', StopProcessing), ('X', StopProcessing), ('r', ReloadConfig), ('g', ResetDependencyGraph),
             ('W', AddWorkers))
            @test JuLeAna.setup_key!(page, KeyEvent(key), nothing, cmd -> push!(sent, cmd))
            @test last(sent) isa expected
        end
        @test !sent[2].force && sent[3].force
        # keys the page does not use go to the interface
        @test !JuLeAna.setup_key!(page, KeyEvent('q'), nothing, cmd -> push!(sent, cmd))
        @test !JuLeAna.setup_key!(page, KeyEvent('2'), nothing, cmd -> push!(sent, cmd))
        @test length(sent) == 6
    end

    @testset "pending commands keep the local selection" begin
        m = new_tui()
        @test setup_refreshed!(m)
        snap = m.snap
        JuLeAna.set_checked!(m.setup.periods, [(p3, r0)])
        JuLeAna.sync_setup!(m.setup, snap; pending = true)
        @test JuLeAna.checked(m.setup.periods) == [(p3, r0)]
        JuLeAna.sync_setup!(m.setup, snap)
        @test JuLeAna.checked(m.setup.periods) == all_runs
    end

    @testset "a read older than an answered command is not shown" begin
        m = new_tui()
        @test setup_refreshed!(m)
        snap, prog, busy = m.snap, m.progress, m.busy
        JuLeAna.set_checked!(m.setup.periods, [(p3, r0)])
        # a command was answered after this read had started
        m.answered += 1
        m.refreshing = true
        Tachikoma.update!(m, Tachikoma.TaskEvent(:refresh, (m.answered - 1, snap, prog, busy, m.step_msgs)))
        @test JuLeAna.checked(m.setup.periods) == [(p3, r0)]
        # and the page reads again
        @test m.refreshing
        @test setup_settle!(() -> !m.refreshing, m)
        @test JuLeAna.checked(m.setup.periods) == all_runs
    end

    @testset "selected runs that are not on disk" begin
        session = new_session()
        session.runs = Dict(p2 => [r6, DataRun(9)])
        m = JuLeAna.JuLeAnaTUI(DataflowController(session; processors, record_software = false, record_metadata = false))
        @test setup_refreshed!(m)
        @test JuLeAna.checked(m.setup.periods) == [(p2, r6); all_runs[9:end]]
    end

    @testset "parse_kwarg_value" begin
        @test JuLeAna.parse_kwarg_value(" 12 ", 10) === 12
        @test JuLeAna.parse_kwarg_value("0.5", 1.0) === 0.5
        @test JuLeAna.parse_kwarg_value("3", 1.0) === 3.0
        @test JuLeAna.parse_kwarg_value("false", true) === false
        @test JuLeAna.parse_kwarg_value("some text", "old") == "some text"
        @test JuLeAna.parse_kwarg_value("V01, V02,", [:V00]) == [:V01, :V02]
        @test JuLeAna.parse_kwarg_value("", Symbol[]) == Symbol[]
        @test JuLeAna.parse_kwarg_value("[1, 2]", nothing) == [1, 2]
        @test JuLeAna.parse_kwarg_value("[:a, :b]", nothing) == [:a, :b]
        @test JuLeAna.parse_kwarg_value("\"x\"", nothing) == "x"
        @test JuLeAna.parse_kwarg_value(":x", nothing) === :x
        @test JuLeAna.parse_kwarg_value("[]", nothing) == []
        @test_throws "expected an integer, got `abc`" JuLeAna.parse_kwarg_value("abc", 3)
        @test_throws "expected true or false, got `1`" JuLeAna.parse_kwarg_value("1", true)
        @test_throws "expected a Julia literal" JuLeAna.parse_kwarg_value("rm(\"x\")", nothing)
        @test_throws "expected a Julia literal" JuLeAna.parse_kwarg_value("[1,", nothing)
        @test_throws "expected a Julia literal" JuLeAna.parse_kwarg_value("x", nothing)
    end

    @testset "kwargs editor" begin
        m = new_tui()
        @test setup_refreshed!(m)
        press!(m, :tab)
        # `e` on a processor opens its editor; the editor takes every key
        press!(m, 'e')
        @test m.setup.editor isa JuLeAna.KwargsEditor && m.setup.editor.step === :process_energy_calibration_cal
        text = join(row_text(render_setup_page(m), r) for r in 1:30)
        @test occursin("Settings of energy_calibration cal", text)
        @test occursin("channels", text) && occursin("max_wvfs", text)
        press!(m, 'q', '2')
        @test !m.quit && m.page == 1

        # the first rows are the log and the plot level; Enter sets the next level
        energy() = only(filter(p -> p.name === :process_energy_calibration_cal, m.snap.processors))
        @test occursin("  log level = info", join(row_text(render_setup_page(m), r) for r in 1:30))
        press!(m, :enter, :down, :enter)
        @test setup_refreshed!(m)
        @test energy().log_level == Logging.Debug && energy().plot_level === :debug && energy().overridden == [:log_level, :plot_level]
        text = join(row_text(render_setup_page(m), r) for r in 1:30)
        @test occursin("* log level = debug   (config: info)", text) && occursin("* plot level = debug   (config: info)", text)
        # `u` resets the level under the cursor
        press!(m, 'u')
        @test setup_refreshed!(m)
        @test energy().plot_level === :info && energy().overridden == [:log_level]
        press!(m, :up, 'u')
        @test setup_refreshed!(m)
        @test isempty(energy().overridden)

        # then the kwargs in alphabetical order: channels, max_wvfs (both accepted, not set)
        press!(m, :down, :down, :down, :enter)
        @test m.setup.editor.text == ""
        press!(m, '5', 'x', :backspace, :enter)
        @test setup_refreshed!(m)
        energy = only(filter(p -> p.name === :process_energy_calibration_cal, m.snap.processors))
        @test energy.kwargs[:max_wvfs] == 5 && energy.overridden == [:max_wvfs]
        @test occursin("* max_wvfs = 5   (config: not set)", join(row_text(render_setup_page(m), r) for r in 1:30))

        # a set value is edited in its own type
        JuLeAna.kwargs_key!(m.setup.editor, KeyEvent(:enter), m.snap, cmd -> nothing)
        @test m.setup.editor.text == "5"
        press!(m, :backspace, 'a', :enter)
        @test m.setup.editor.error == "expected an integer, got `a`"
        @test occursin("expected an integer", join(row_text(render_setup_page(m), r) for r in 1:30))
        press!(m, :escape)
        @test isnothing(m.setup.editor.text) && isnothing(m.setup.editor.error)

        # a kwarg that is not set takes a Julia literal
        press!(m, :up, :enter, 'V', '1', :enter)
        @test startswith(m.setup.editor.error, "expected a Julia literal")
        press!(m, :escape, :enter, '[', ':', 'V', '1', ',', ':', 'V', '2', ']', :enter)
        @test setup_refreshed!(m)
        energy = only(filter(p -> p.name === :process_energy_calibration_cal, m.snap.processors))
        @test energy.kwargs[:channels] == [:V1, :V2]

        press!(m, 'u')
        @test setup_refreshed!(m)
        energy = only(filter(p -> p.name === :process_energy_calibration_cal, m.snap.processors))
        @test energy.overridden == [:max_wvfs]
        press!(m, 'U')
        @test setup_refreshed!(m)
        @test isempty(only(filter(p -> p.name === :process_energy_calibration_cal, m.snap.processors)).overridden)
        press!(m, :escape)
        @test isnothing(m.setup.editor)
        @test isnothing(m.command_error)
    end

    @testset "write the config" begin
        config_file = joinpath(mktempdir(), "processing_config.yaml")
        cp(args["config"], config_file)
        production = mktempdir()
        written = joinpath(production, "setup", "config", "processing_config.yaml")
        session = new_session()
        session.args["config"] = config_file
        m = new_tui(session)
        @test setup_refreshed!(m)
        withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
            # any key but `y` cancels
            press!(m, 'w')
            @test m.setup.confirm === :write
            @test occursin("Write the current settings to", join(row_text(render_setup_page(m), r) for r in 1:30))
            press!(m, 'n')
            @test isnothing(m.setup.confirm)
            @test setup_refreshed!(m)
            @test !ispath(written)

            # the config folder of the data production is created and the session config file becomes the written one
            # the editor rows: log level, plot level, channels, max_wvfs
            press!(m, :tab, 'e', :down, :down, :down, :enter, '7', :enter, :escape, 'w', 'y')
            @test setup_refreshed!(m)
            @test isnothing(m.command_error)
            @test ProcessingConfig(written).processors[:process_energy_calibration_cal].kwargs[:max_wvfs] == 7
            @test m.snap.config_file == written
            @test !isfile(written * ".bak") && !isfile(config_file * ".bak")
            press!(m, 'w', 'y')
            @test setup_refreshed!(m)
            @test isfile(written * ".bak")
        end
    end

    @testset "mouse" begin
        m = new_tui()
        @test setup_refreshed!(m)
        press!(m, :tab)
        render_setup_page(m)
        # first row of the periods pane: the p02 group
        list = m.setup.periods.list
        Tachikoma.update!(m, MouseEvent(list.x + 2, list.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test m.setup.focus == 1 && m.setup.periods.focused
        @test setup_refreshed!(m)
        @test m.snap.periods == [p3]

        # a click on an option row focuses the options pane and cycles the option
        render_setup_page(m)
        options = m.setup.options
        @test m.snap.check_dependencies
        Tachikoma.update!(m, MouseEvent(options.x + 2, options.y + 3, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test m.setup.focus == 4 && m.setup.option == 4 && !m.setup.periods.focused
        @test setup_refreshed!(m)
        @test !m.snap.check_dependencies
        tb = render_setup_page(m)
        @test find_text(tb, "▶ Options") !== nothing && find_text(tb, "▶ Periods") === nothing
        # below the option rows the click only focuses the pane
        Tachikoma.update!(m, MouseEvent(options.x + 2, options.y + 6, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test setup_refreshed!(m)
        @test !m.snap.check_dependencies
    end

    @testset "production and dataset" begin
        parent = mktempdir()
        for name in ("prod-b", "prod-a", "no-config")
            mkpath(joinpath(parent, name))
            name == "no-config" || write(joinpath(parent, name, "config.json"), "{}")
        end
        withenv("LEGEND_DATA_CONFIG" => joinpath(parent, "prod-a", "config.json")) do
            @test_throws "no production root" JuLeAna.read_choices(DataflowController(Dict{String,Any}()), "")
            ctrl = DataflowController(Dict{String,Any}("config" => nothing); loader = nothing)
            @test JuLeAna.read_choices(ctrl, parent) == (; productions = ["prod-a", "prod-b"], datasets = ["default"])

            m = new_tui()
            @test setup_refreshed!(m)
            page = m.setup
            # the choices are read in the background for the loaded session
            @test setup_settle!(() -> page.choices isa NamedTuple && page.dataset isa AbstractDict, m)
            @test page.choices.productions == ["prod-a", "prod-b"] && "default" in page.choices.datasets
            tb = render_setup_page(m)
            for text in ("Production", "Root: ", "Production: prod-a", "Dataset: default", "Options", "Dataset p02")
                @test find_text(tb, text) !== nothing
            end
            # the Dataset pane is below the Production pane, which is below the Options pane
            rows = [find_text(tb, t).y for t in ("Options", "Production: prod-a", "Dataset p02")]
            @test issorted(rows) && allunique(rows)
            @test find_text(tb, "Dataset p02").x > m.setup.periods.list.x + m.setup.periods.list.width

            # Tab reaches the pane as the fifth stop, the last before the periods
            page.focus = 4
            press!(m, :tab)
            @test page.focus == 5 && !any(list -> list.focused, JuLeAna.setup_panes(page))
            @test find_text(render_setup_page(m), "▶ Production") !== nothing
            press!(m, :tab)
            @test page.focus == 1 && page.periods.focused

            # the production picker lists the productions next to the current one
            sent = ControllerCommand[]
            send = cmd -> push!(sent, cmd)
            key!(k) = JuLeAna.setup_key!(page, KeyEvent(k), m.snap, send)
            page.focus, page.source = 5, 2
            key!(:enter)
            @test page.picker.kind === :production && page.picker.items == ["prod-a", "prod-b"] && page.picker.cursor == 1
            tb = render_setup_page(m)
            @test find_text(tb, "Data production") !== nothing && find_text(tb, "▶ prod-a") !== nothing
            # choosing the current production sends nothing
            key!(:enter)
            @test isnothing(page.picker) && isempty(sent)
            key!(:enter)
            key!(:down)
            key!(:down)
            @test page.picker.cursor == 2
            key!(:escape)
            @test isnothing(page.picker) && isempty(sent)
            key!(:enter)
            key!(:down)
            key!(:enter)
            @test only(sent) isa SelectProduction && only(sent).path == joinpath(parent, "prod-b")
            empty!(sent)

            # the dataset line opens the picker of the datasets
            key!(:down)
            @test page.source == 3
            page.choices = (; productions = ["prod-a"], datasets = ["default", "valid", "zzz"])
            key!(' ')
            @test page.picker.kind === :dataset && page.picker.cursor == 1
            key!(:down)
            key!(:enter)
            @test only(sent) == SelectDataset(:valid)
            empty!(sent)

            # the pickers open only once the names are read; an error shows in the pane
            page.choices = nothing
            key!(:enter)
            @test isnothing(page.picker)
            page.choices = "disk error"
            @test find_text(render_setup_page(m), "disk error") !== nothing
            key!(:enter)
            @test isnothing(page.picker)

            # a click on a line opens its picker, a click on an item chooses it
            page.choices = (; productions = ["prod-a", "prod-b"], datasets = ["default", "valid"])
            render_setup_page(m)
            area = page.production_area
            click(x, y) = JuLeAna.setup_mouse!(page, MouseEvent(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false),
                                               m.snap, send)
            @test click(area.x + 2, area.y + 1)
            @test page.focus == 5 && page.source == 2 && page.picker.kind === :production
            render_setup_page(m)
            @test click(page.picker_area.x + 2, page.picker_area.y + 1)
            @test isnothing(page.picker) && only(sent).path == joinpath(parent, "prod-b")
            empty!(sent)
            @test click(area.x + 2, area.y + 2)
            @test page.source == 3 && page.picker.kind === :dataset
            @test click(1, 1) && !isnothing(page.picker)
            key!(:escape)
            @test isempty(sent)
        end
    end

    @testset "production listing" begin
        tree = realpath(mktempdir())
        touch_config(path, name = "config.json") = (mkpath(path); write(joinpath(path, name), "{}"))
        touch_config(joinpath(tree, "test"))
        touch_config(joinpath(tree, "jl-v1.0", "prodA"))
        touch_config(joinpath(tree, "jl-v1.0", "prodB"), "config.yaml")
        touch_config(joinpath(tree, "a", "b", "c", "d"))
        touch_config(joinpath(tree, "a", "b", "c", "d", "e"))
        touch_config(joinpath(tree, "a", "b", "c", "d", "e", "f"))
        touch_config(joinpath(tree, "a", "b", "c", "d", "e", "f", "g"))
        touch_config(joinpath(tree, "test", "generated", "inner"))
        touch_config(joinpath(tree, ".hidden"))
        mkpath(joinpath(tree, "empty"))
        symlink(joinpath(tree, "test"), joinpath(tree, "link"))
        # the folder at depth 4 is listed, deeper ones are not; a production is not searched
        @test JuLeAna.find_productions(tree) == ["a/b/c/d", "jl-v1.0/prodA", "jl-v1.0/prodB", "test"]
        @test JuLeAna.find_productions(joinpath(tree, "jl-v1.0")) == ["prodA", "prodB"]
        # the root itself counts
        @test JuLeAna.find_productions(joinpath(tree, "test")) == ["."]
        @test JuLeAna.find_productions(joinpath(tree, "missing")) == String[]
    end

    @testset "production root" begin
        tree = realpath(mktempdir())
        mkpath.(joinpath.(tree, ("alpha", "alpine", "beta", "prod")))
        write(joinpath(tree, "prod", "config.json"), "{}")
        withenv("LEGEND_DATA_CONFIG" => joinpath(tree, "prod", "config.json")) do
            page = JuLeAna.SetupPage()
            send = cmd -> error("no command expected")
            key!(k) = JuLeAna.setup_key!(page, KeyEvent(k), nothing, send)
            type!(text) = foreach(key!, text)
            @test JuLeAna.production_root(page) == tree
            page.focus = 5
            tb = TestBackend(140, 30)
            JuLeAna.render_setup(page, nothing, Rect(1, 1, 140, 30), tb.buf)
            @test find_text(tb, "Root: ") !== nothing
            @test find_text(tb, "Root: ").y < find_text(tb, "Production: ").y

            # Enter edits the root in place; every key goes to its text
            key!(:enter)
            @test page.root_edit == tree
            @test page.focus == 5
            type!("/al1q")
            @test page.root_edit == tree * "/al1q"
            key!(:backspace)
            key!(:backspace)
            @test page.root_edit == tree * "/al"
            JuLeAna.render_setup(page, nothing, Rect(1, 1, 140, 30), tb.buf)
            @test find_text(tb, "█") !== nothing

            # Tab extends to the common prefix and lists several candidates
            key!(:tab)
            @test page.root_edit == tree * "/alp"
            @test page.root_hint == ("alpha/  alpine/", false)
            key!('h')
            key!(:tab)
            @test page.root_edit == tree * "/alpha/" && page.root_hint == ("", false)
            for i in 1:9
                mkpath(joinpath(tree, "alpha", "d$i"))
            end
            key!(:tab)
            @test endswith(page.root_hint[1], "and 1 more") && count("/", page.root_hint[1]) == 8

            # Enter with a missing folder shows the error and keeps editing
            type!("nope")
            key!(:enter)
            @test page.root_edit == tree * "/alpha/dnope" && page.root_hint[2] && isnothing(page.root)
            JuLeAna.render_setup(page, nothing, Rect(1, 1, 140, 30), tb.buf)
            @test find_text(tb, "Not an existing absolute folder") !== nothing

            # Enter with an existing folder sets the root and re-reads the productions
            page.choices = (; productions = ["x"], datasets = ["default"])
            foreach(_ -> key!(:backspace), 1:5)
            key!(:enter)
            @test isnothing(page.root_edit) && page.root == tree * "/alpha" && isnothing(page.choices)
            @test JuLeAna.production_root(page) == tree * "/alpha"

            # a relative path is rejected, `~` is expanded, Escape cancels
            key!(:enter)
            foreach(_ -> key!(:backspace), 1:length(page.root_edit))
            type!("rel")
            key!(:enter)
            @test !isnothing(page.root_edit) && page.root == tree * "/alpha"
            foreach(_ -> key!(:backspace), 1:3)
            type!("~")
            key!(:enter)
            @test page.root == rstrip(homedir(), '/')
            key!(:enter)
            type!("zzz")
            key!(:escape)
            @test isnothing(page.root_edit) && page.root == rstrip(homedir(), '/')

            # the interface passes digits and q to the field instead of switching the page
            m = new_tui()
            @test setup_refreshed!(m)
            m.setup.focus, m.setup.source = 5, 1
            press!(m, :enter, '2', '3', 'q', '?')
            @test m.page == 1 && !m.quit && !m.help && endswith(m.setup.root_edit, "23q?")
            press!(m, :escape, '2')
            @test m.page == 2
        end
    end
end
