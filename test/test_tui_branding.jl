# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text, style_at
using Logging: Logging, with_logger
using LegendDataManagement: DataPeriod
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

function branding_render(m, width = 120, height = 36)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end

# Column of the first occurrence of `text` in row `row`.
function branding_column(tb, row, text)
    line = row_text(tb, row)
    return textwidth(line[1:prevind(line, first(findfirst(text, line)))]) + 1
end

branding_text(tb, height = 36) = join((row_text(tb, r) for r in 1:height), "\n")

function branding_settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

# Read the controller state anew and wait for the result.
function branding_refreshed!(m)
    branding_settle!(() -> !m.refreshing, m) || return false
    JuLeAna.refresh!(m)
    return branding_settle!(() -> !m.refreshing, m)
end

# The Workers page generates the worker start script in the production config folder:
# keep it in a temporary one.
withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json")) do
    @testset "Branding" begin
        @testset "logo" begin
            @test JuLeAna.logo_size(JuLeAna.TEXT_LOGO) == (102, 22)
            @test JuLeAna.logo_size(JuLeAna.LOGO_LETTERS) == (73, 8)
            @test JuLeAna.logo_size(["ab", "abcd", ""]) == (4, 3)
            @test JuLeAna.logo_size([[("ab", :red), ("cd", :green)], [("e", :outline)]]) == (4, 2)
            @test JuLeAna.logo_size(String[]) == (0, 0)
            colors = Set(name for row in JuLeAna.TEXT_LOGO for (_, name) in row)
            @test colors == Set([:outline, :red, :green, :purple])
            text = Tachikoma.theme().text
            red, green, purple = JuLeAna.TITLE_COLORS
            @test JuLeAna.logo_color(:outline) == text && JuLeAna.logo_color(:red) == red
            @test JuLeAna.logo_color(:green) == green && JuLeAna.logo_color(:purple) == purple
            @test_throws "unknown color" JuLeAna.logo_color(:blue)
        end

        @testset "fitting logo" begin
            @test JuLeAna.fitting_logo(102, 22) === JuLeAna.TEXT_LOGO
            @test JuLeAna.fitting_logo(200, 40) === JuLeAna.TEXT_LOGO
            @test JuLeAna.fitting_logo(101, 22) === JuLeAna.LOGO_LETTERS
            @test JuLeAna.fitting_logo(102, 21) === JuLeAna.LOGO_LETTERS
            @test JuLeAna.fitting_logo(73, 8) === JuLeAna.LOGO_LETTERS
            @test isnothing(JuLeAna.fitting_logo(72, 30)) && isnothing(JuLeAna.fitting_logo(200, 7))
        end

        @testset "render logo" begin
            rows = [[("a", :outline), (" ", :outline), ("b", :red)], "  c", [("d", :green), ("ef", :purple)]]
            tb = TestBackend(10, 6)
            JuLeAna.render_logo(rows, 2, 2, tb.buf)
            text = Tachikoma.theme().text
            red, green, purple = JuLeAna.TITLE_COLORS
            @test rstrip(row_text(tb, 2)) == " a b"
            @test rstrip(row_text(tb, 3)) == "   c"
            @test rstrip(row_text(tb, 4)) == " def"
            @test style_at(tb, 2, 2).fg == text && style_at(tb, 4, 2).fg == red
            @test style_at(tb, 4, 3).fg == text
            @test style_at(tb, 2, 4).fg == green && style_at(tb, 3, 4).fg == purple && style_at(tb, 4, 4).fg == purple
            # spaces are transparent
            tb = TestBackend(10, 6)
            Tachikoma.set_string!(tb.buf, 1, 2, "xxxxxx", Tachikoma.Style())
            JuLeAna.render_logo(rows, 2, 2, tb.buf)
            @test rstrip(row_text(tb, 2)) == "xaxbxx"
            # clipping at `max_x` and `max_y`
            tb = TestBackend(10, 6)
            JuLeAna.render_logo(rows, 2, 2, tb.buf; max_x = 3, max_y = 3)
            @test rstrip(row_text(tb, 2)) == " a" && isempty(strip(row_text(tb, 3))) && isempty(strip(row_text(tb, 4)))
            # parts outside of the buffer are dropped
            tb = TestBackend(5, 3)
            JuLeAna.render_logo(JuLeAna.TEXT_LOGO, -30, -5, tb.buf)
            @test any(r -> !isempty(strip(row_text(tb, r))), 1:3)
            tb = TestBackend(110, 24)
            JuLeAna.render_logo(JuLeAna.TEXT_LOGO, 5, 1, tb.buf)
            @test find_text(tb, strip(JuLeAna.TEXT_LOGO[1][1][1])) == (; x = 5 + 34, y = 1)
            @test style_at(tb, 5 + 41, 2).fg == red
        end

        root = mktempdir()
        l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
        args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                               p_processors = Dict{Symbol,ProcessorSpec}())
        function new_session(parsed_args = args)
            periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [DataPeriod(2)], nothing, run_steps(cfg),
                                                                                   partition_steps(cfg))
            return DataflowSession(; args = parsed_args, l200, config = cfg, periods, run_steps = run_steps(cfg),
                                   partition_steps = partition_steps(cfg), run_status, partition_status)
        end
        quick_step(cfg, l200, period, run; reprocess = false) = nothing
        processors = Dict{Symbol,Any}(:process_energy_calibration_cal => quick_step)
        docs_url = "https://legend-exp.github.io/JuLeAna.jl/stable/"

        @testset "startup screen" begin
            function slow_loader(parsed_args)
                sleep(0.3)
                return new_session(parsed_args)
            end
            m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = slow_loader); splash_seconds = 5.0)
            # not started: the page is shown
            @test !m.splash && find_text(branding_render(m), "Periods / runs") !== nothing
            JuLeAna.start!(m)
            tb = branding_render(m)
            @test find_text(tb, "Loading the session…") !== nothing
            @test find_text(tb, docs_url) !== nothing
            @test find_text(tb, JuLeAna.juleana_version()) !== nothing
            @test find_text(tb, "Periods / runs") === nothing
            # frame, tabs and key row stay
            @test find_text(tb, "JuLeAna") !== nothing && find_text(tb, "1 Setup") !== nothing && find_text(tb, "q quit") !== nothing
            # the link carries the hyperlink
            link = find_text(tb, docs_url)
            @test style_at(tb, link.x, link.y).hyperlink == docs_url
            # the full logo is drawn
            @test find_text(tb, strip(JuLeAna.TEXT_LOGO[1][1][1])) !== nothing
            @test branding_settle!(() -> !isnothing(m.snap) && m.snap.state === :ready, m)
            # loaded, but the minimum time has not passed
            @test find_text(branding_render(m), "Session loaded") !== nothing
            m.started_at -= 5.0
            tb = branding_render(m)
            @test find_text(tb, docs_url) === nothing && find_text(tb, "Periods / runs") !== nothing
            Tachikoma.update!(m, Tachikoma.TaskEvent(:tick, nothing))
            @test !m.splash
            Tachikoma.cleanup!(m)
        end

        @testset "a key ends the startup screen and is not passed on" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = new_session); splash_seconds = 60.0)
            JuLeAna.start!(m)
            @test branding_settle!(() -> !isnothing(m.snap) && m.snap.state === :ready, m)
            @test JuLeAna.splash_active(m)
            Tachikoma.update!(m, KeyEvent('3'))
            @test m.page == 1 && !m.splash && !JuLeAna.splash_active(m)
            Tachikoma.update!(m, KeyEvent('3'))
            @test m.page == 3
            # a quit key ends the screen without quitting
            m2 = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = new_session); splash_seconds = 60.0)
            JuLeAna.start!(m2)
            Tachikoma.update!(m2, KeyEvent('q'))
            @test !m2.quit && !m2.splash
            Tachikoma.cleanup!(m)
            Tachikoma.cleanup!(m2)
        end

        @testset "a failed load ends the startup screen" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = _ -> error("no data config")); splash_seconds = 0.2)
            with_logger(Logging.NullLogger()) do
                JuLeAna.start!(m)
                @test branding_settle!(() -> !isnothing(m.snap) && !isnothing(m.snap.last_error), m)
                @test find_text(branding_render(m), "Loading the session failed") !== nothing || !JuLeAna.splash_active(m)
                sleep(0.25)
                @test !JuLeAna.splash_active(m)
            end
            Tachikoma.cleanup!(m)
        end

        @testset "startup screen sizes" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = new_session); splash_seconds = 60.0)
            m.splash, m.started_at = true, time()
            full_top = strip(JuLeAna.TEXT_LOGO[1][1][1])
            letters_bottom = strip(JuLeAna.LOGO_LETTERS[end])
            body_name(tb, h) = [r for r in 5:h if occursin("JuLeAna", replace(row_text(tb, r), docs_url => ""))]
            # the full logo, the letters, the name as text
            tb = branding_render(m, 120, 36)
            @test find_text(tb, full_top) !== nothing && find_text(tb, letters_bottom) !== nothing && isempty(body_name(tb, 36))
            tb = branding_render(m, 120, 30)
            @test find_text(tb, full_top) === nothing && find_text(tb, letters_bottom) !== nothing && isempty(body_name(tb, 30))
            tb = branding_render(m, 90, 36)
            @test find_text(tb, full_top) === nothing && find_text(tb, letters_bottom) !== nothing
            tb = branding_render(m, 70, 26)
            @test find_text(tb, letters_bottom) === nothing && find_text(tb, full_top) === nothing
            rows = body_name(tb, 26)
            @test length(rows) == 1
            x = branding_column(tb, only(rows), "JuLeAna")
            red, green, purple = JuLeAna.TITLE_COLORS
            @test [style_at(tb, x + i, only(rows)).fg for i in (0, 2, 4)] == [red, green, purple]
            @test all(i -> style_at(tb, x + i, only(rows)).bold, 0:6)
            @test find_text(tb, docs_url) !== nothing
            tb = branding_render(m, 120, 14)
            @test find_text(tb, letters_bottom) === nothing && length(body_name(tb, 14)) == 1
            text_only = branding_render(m, 70, 14)
            @test find_text(text_only, docs_url) !== nothing
            Tachikoma.cleanup!(m)
        end

        @testset "corner logo" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors))
            version = JuLeAna.juleana_version()
            red, green, purple = JuLeAna.TITLE_COLORS
            dim = Tachikoma.tstyle(:text_dim).fg
            text = Tachikoma.tstyle(:text).fg
            config = "/data/l200/jl-v9.9.9/config.json"
            withenv("LEGEND_DATA_CONFIG" => config) do
                wide = branding_render(m, 120, 36)
                @test endswith(rstrip(row_text(wide, 2), '│'), "JuLeAna " * version)
                @test endswith(row_text(wide, 3), "jl-v9.9.9  /data/l200│")
                # the name in the logo colors, bold; the version dim
                x = branding_column(wide, 2, "JuLeAna " * version)
                @test [style_at(wide, x + i, 2).fg for i in (0, 1, 2, 3, 4, 6)] == [red, red, green, green, purple, purple]
                @test all(i -> style_at(wide, x + i, 2).bold, 0:6)
                @test style_at(wide, x + 8, 2).fg == dim
                # the production name and the dimmer root
                y = branding_column(wide, 3, "jl-v9.9.9")
                @test style_at(wide, y, 3).fg == text && style_at(wide, y + 11, 3).fg == dim
                # the tab bar's bottom line is not touched
                @test count(==('─'), row_text(wide, 4)) > 100
                # the root is clipped from the left
                clipped = branding_render(m, 114, 36)
                @test endswith(row_text(clipped, 3), "jl-v9.9.9  …/l200│") &&
                      endswith(rstrip(row_text(clipped, 2), '│'), "JuLeAna " * version)
                # the bar is truncated: no logo beside it, and all tabs are shown at 120 columns
                truncated = branding_render(m, 90, 36)
                @test length(m.tabs._tab_rects) < length(JuLeAna.TUI_PAGES)
                @test !any(y -> occursin(version, row_text(truncated, y)) || occursin("jl-v9.9.9", row_text(truncated, y)), 1:4)
                branding_render(m, 120, 36)
                @test length(m.tabs._tab_rects) == length(JuLeAna.TUI_PAGES)
                # no room right of the tabs: nothing in the rows of the tab bar (the Setup page
                # shows the production in its Production pane)
                narrow = branding_render(m, 100, 36)
                @test !any(y -> occursin(version, row_text(narrow, y)) || occursin("jl-v9.9.9", row_text(narrow, y)), 1:4)
                @test find_text(narrow, "7 History") !== nothing
            end
            # a root that is longer than the free space
            long_root = "/" * join(("dir$i" for i in 1:30), "/")
            withenv("LEGEND_DATA_CONFIG" => long_root * "/jl-v1/config.json") do
                tb = branding_render(m, 120, 36)
                @test occursin(r"jl-v1  …[^│]*dir30│$", row_text(tb, 3))
            end
            # the last of several config files names the production, the ones before are overrides
            withenv("LEGEND_DATA_CONFIG" => "/c/d/site.yaml:/a/b/jl-v1/config.json") do
                tb = branding_render(m, 120, 36)
                @test endswith(row_text(tb, 3), "jl-v1  /a/b│") && find_text(tb, "site") === nothing
            end
            withenv("LEGEND_DATA_CONFIG" => nothing) do
                tb = branding_render(m, 120, 36)
                @test endswith(row_text(tb, 3), "no data production│")
                @test endswith(rstrip(row_text(tb, 2), '│'), "JuLeAna " * version)
            end
            Tachikoma.cleanup!(m)
        end

        @testset "Setup page logo" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors))
            @test branding_refreshed!(m)
            full_top = strip(JuLeAna.TEXT_LOGO[1][1][1])
            letters_bottom = strip(JuLeAna.LOGO_LETTERS[end])
            # the Options pane is too narrow for the logo on common screens
            for (w, h) in ((120, 36), (220, 50))
                tb = branding_render(m, w, h)
                @test find_text(tb, letters_bottom) === nothing && find_text(tb, "Runs: ") !== nothing
            end
            # a wide pane takes the letters, which end on the last row inside the pane
            tb = branding_render(m, 260, 50)
            @test find_text(tb, full_top) === nothing
            pos = find_text(tb, letters_bottom)
            @test !isnothing(pos) && occursin('╯', row_text(tb, pos.y + 1)) && find_text(tb, "Runs: ") !== nothing
            # a wider and taller one the full logo
            tb = branding_render(m, 360, 55)
            @test find_text(tb, full_top) !== nothing
            # without height for the letters, no logo
            tb = branding_render(m, 260, 20)
            @test find_text(tb, letters_bottom) === nothing
            Tachikoma.cleanup!(m)
        end

        @testset "key help" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors))
            @test branding_refreshed!(m)
            Tachikoma.update!(m, KeyEvent('?'))
            @test m.help
            tb = branding_render(m)
            for text in ("Keys", "start workers", "start processing", "Ctrl-G", "Setup page", "All pages", docs_url)
                @test find_text(tb, text) !== nothing
            end
            @test find_text(tb, "follow the running step") === nothing
            link = find_text(tb, docs_url)
            @test style_at(tb, link.x, link.y).hyperlink == docs_url
            @test find_text(tb, "Ctrl-T  Ctrl-S") !== nothing
            # on a low screen the key list is cut, the link and the closing hint stay
            low = branding_render(m, 120, 14)
            @test find_text(low, docs_url) !== nothing && find_text(low, "Esc, ? or q closes") !== nothing
            # other keys do nothing while it is open; `q` closes it without quitting
            Tachikoma.update!(m, KeyEvent('3'))
            @test m.page == 1 && m.help
            Tachikoma.update!(m, KeyEvent('q'))
            @test !m.help && !m.quit
            for key in (KeyEvent(:escape), KeyEvent('?'))
                Tachikoma.update!(m, KeyEvent('?'))
                Tachikoma.update!(m, key)
                @test !m.help
            end
            @test find_text(branding_render(m), "start workers") === nothing

            # the Progress page lists its own keys
            Tachikoma.update!(m, KeyEvent('4'))
            Tachikoma.update!(m, KeyEvent('?'))
            tb = branding_render(m)
            @test find_text(tb, "follow the running step") !== nothing && find_text(tb, "start workers") === nothing
            Tachikoma.update!(m, KeyEvent('?'))
            @test !m.help

            # the Log page lists its own keys
            Tachikoma.update!(m, KeyEvent('5'))
            Tachikoma.update!(m, KeyEvent('?'))
            tb = branding_render(m)
            @test find_text(tb, "Log page") !== nothing &&
                  find_text(tb, "cycle the level") !== nothing &&
                  find_text(tb, "follow the running step") === nothing
            Tachikoma.update!(m, KeyEvent('?'))
            @test !m.help

            # a small screen clips the panel
            Tachikoma.update!(m, KeyEvent('1'))
            Tachikoma.update!(m, KeyEvent('?'))
            @test find_text(branding_render(m, 40, 12), "Keys") !== nothing
            Tachikoma.update!(m, KeyEvent(:escape))

            # the filter and the kwargs editor receive `?` as text
            Tachikoma.update!(m, KeyEvent('/'))
            Tachikoma.update!(m, KeyEvent('?'))
            @test !m.help && m.setup.periods.filter == "?"
            Tachikoma.update!(m, KeyEvent(:escape))
            Tachikoma.update!(m, KeyEvent(:tab))
            Tachikoma.update!(m, KeyEvent('e'))
            @test !isnothing(m.setup.editor)
            Tachikoma.update!(m, KeyEvent('?'))
            @test !m.help
            Tachikoma.cleanup!(m)
        end

        @testset "key row lists the help key" begin
            m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors))
            Tachikoma.update!(m, KeyEvent('3'))
            @test occursin("? help", row_text(branding_render(m, 120, 36), 35))
            Tachikoma.cleanup!(m)
        end
    end # testset
end # withenv
