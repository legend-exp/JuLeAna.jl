# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Rect, find_text, row_text
using LegendDataManagement: DataPeriod, DataRun
using Dates: DateTime
using Test

# Render the History page of `page` into a `width` x `height` test backend.
function render_history_page(page, width = 100, height = 20)
    tb = TestBackend(width, height)
    JuLeAna.render_history(page, Rect(1, 1, width, height), tb.buf)
    return tb
end

history_text(tb) = join((row_text(tb, r) for r in 1:tb.height), "\n")
detail_text(page) = join(first.(JuLeAna.history_detail(page)))

@testset "History page" begin
    p2, p3 = DataPeriod(2), DataPeriod(3)
    runs2 = DataRun.(6:15)
    r0 = DataRun(0)
    t(h) = DateTime(2026, 10, 15, h)
    processors = [(; name = :process_dsp_cal, level = :run, category = :cal), (; name = :process_hit_cal, level = :run, category = :cal),
                  (; name = :p_process_energy_cal, level = :partition, category = :cal)]
    report(period, run, state, date) = (; period, run, path = "/rep/$period-$(something(run, "")).md", state, date)
    overview = [(; name = "dsp_cal", level = :run, category = "cal",
                 reports = [report("p02", "r006", :ok, t(10)), report("p02", "r007", :warning, t(10)),
                            report("p02", "r008", :failed, t(10))]),
                (; name = "energy", level = :partition, category = "cal", reports = [report("p02", nothing, :ok, t(10))])]
    step(process, level, period, run, outcome, started, finished) = (; process, level, category = :cal, period, run, outcome, started,
                                                                     finished, done = 0, failed = 0, notrun = 0)
    history = [(; started = t(11), finished = t(13), user = "u", host = "h", outcome = :failed, log_path = "/log/a",
                steps = [step(:process_dsp_cal, :run, p2, DataRun(6), :failed, t(11), t(12)),
                         step(:process_dsp_cal, :run, p2, DataRun(9), :stopped, t(11), t(12)),
                         step(:process_dsp_cal, :run, p3, r0, :cancelled, nothing, nothing),
                         step(:p_process_energy_cal, :partition, p3, nothing, :failed, t(11), t(12))])]
    grid = JuLeAna.history_grid(processors, [p2 => runs2, p3 => [r0]], overview, history)

    # controller snapshot with the given selection; everything is selected by default
    snapshot(; state = :ready, started = nothing, periods = [p2, p3], runs = nothing) = (; state, outcome = nothing, started,
                                                                                         finished = nothing, periods, runs,
                                                                                         available_periods = [p2, p3],
                                                                                         available_runs = Dict(p2 => runs2, p3 => [r0]))

    # a page that has read `grid`
    function loaded_page(snap = snapshot())
        page = JuLeAna.HistoryPage()
        JuLeAna.history_visit!(page, snap)
        (request,) = JuLeAna.take_requests!(page)
        JuLeAna.history_result!(page, (; request, value = grid))
        return page
    end

    @testset "reading the grid" begin
        page = JuLeAna.HistoryPage()
        @test find_text(render_history_page(page), "No session loaded.") !== nothing
        JuLeAna.history_visit!(page, nothing)
        JuLeAna.history_visit!(page, snapshot(state = :loading))
        @test isempty(JuLeAna.take_requests!(page))
        ready = snapshot()
        JuLeAna.history_visit!(page, ready)
        JuLeAna.history_visit!(page, ready)
        requests = JuLeAna.take_requests!(page)
        @test length(requests) == 1 && requests[1].kind === :grid
        @test find_text(render_history_page(page), "Reading history…") !== nothing
        # a stale answer is dropped, the current one is taken
        JuLeAna.history_result!(page, (; request = (; kind = :grid, generation = requests[1].generation - 1), value = grid))
        @test isnothing(page.grid)
        JuLeAna.history_result!(page, (; request = requests[1], value = grid))
        @test page.grid === grid && !page.reading
        # a new processing run triggers a new read; an older answer to the first read is dropped
        JuLeAna.history_visit!(page, snapshot(state = :running, started = t(14)))
        JuLeAna.history_result!(page, (; request = requests[1], value = (; periods = [], rows = [])))
        @test page.grid === grid
        (request,) = JuLeAna.take_requests!(page)
        JuLeAna.history_result!(page, (; request, error = "boom"))
        @test find_text(render_history_page(page), "boom") !== nothing
        JuLeAna.history_visit!(page, nothing)
        JuLeAna.history_result!(page, (; request, value = grid))
        @test isnothing(page.grid) && isnothing(page.error)
        # `r` reads again
        page = loaded_page()
        @test JuLeAna.history_key!(page, KeyEvent('r'))
        @test only(JuLeAna.take_requests!(page)).kind === :grid
        @test !JuLeAna.history_key!(page, KeyEvent('x')) && !JuLeAna.history_key!(page, KeyEvent('7'))
    end

    @testset "selected and all runs" begin
        run_labels(page) = [string(page.grid.periods[c.p].period, "-", c.run) for c in page.columns]
        # the default shows the selected runs only
        page = loaded_page(snapshot(periods = [p2], runs = Dict(p2 => DataRun.([7, 9]))))
        @test !page.all_runs && run_labels(page) == ["p02-r007", "p02-r009"]
        text = history_text(render_history_page(page))
        @test occursin("History, selected runs", text) && !occursin("p03", text)
        @test detail_text(page) == "dsp cal  p02-r007  warning  2026-10-15 10:00 UTC  report"
        # a partition-level cell spans only the shown runs of its period
        page.row = 3
        @test detail_text(page) == "energy cal  p02  ok  2026-10-15 10:00 UTC  report"
        @test occursin("[  ✓  ]", history_text(render_history_page(page)))
        # `a` shows all runs and periods, without a new read
        @test JuLeAna.history_key!(page, KeyEvent('a'))
        @test page.all_runs && length(page.columns) == 11 && isempty(JuLeAna.take_requests!(page))
        text = history_text(render_history_page(page))
        @test occursin("History, all runs", text) && occursin("p03", text)
        @test page.row == 3
        @test JuLeAna.history_key!(page, KeyEvent('a'))
        @test !page.all_runs && length(page.columns) == 2
        # a changed selection updates the shown columns in the selected mode, without a new read
        JuLeAna.history_visit!(page, snapshot(periods = [p3]))
        @test run_labels(page) == ["p03-r000"] && isempty(JuLeAna.take_requests!(page))
        JuLeAna.history_visit!(page, snapshot(periods = [p2, p3], runs = Dict(p2 => [DataRun(6)])))
        @test run_labels(page) == ["p02-r006", "p03-r000"]
        # runs given as a vector apply to every selected period
        JuLeAna.history_visit!(page, snapshot(runs = DataRun.([6, 0])))
        @test run_labels(page) == ["p02-r006", "p03-r000"]
        # all runs ignore the selection
        JuLeAna.history_key!(page, KeyEvent('a'))
        JuLeAna.history_visit!(page, snapshot(periods = [p3]))
        @test length(page.columns) == 11
        # an empty selection shows no columns
        JuLeAna.history_key!(page, KeyEvent('a'))
        JuLeAna.history_visit!(page, snapshot(periods = DataPeriod[]))
        @test isempty(page.columns)
        @test find_text(render_history_page(page), "No processors or runs.") !== nothing
        # a grid that arrives later takes the mode and selection of the page
        page = JuLeAna.HistoryPage()
        JuLeAna.history_key!(page, KeyEvent('a'))
        @test page.all_runs
        JuLeAna.history_visit!(page, snapshot(periods = [p3]))
        (request,) = JuLeAna.take_requests!(page)
        JuLeAna.history_result!(page, (; request, value = grid))
        @test length(page.columns) == 11
    end

    @testset "cursor and details" begin
        page = loaded_page()
        @test length(page.columns) == 11
        @test detail_text(page) == "dsp cal  p02-r006  failed  2026-10-15 12:00 UTC  history, log folder /log/a"
        JuLeAna.history_key!(page, KeyEvent(:right))
        @test detail_text(page) == "dsp cal  p02-r007  warning  2026-10-15 10:00 UTC  report"
        JuLeAna.history_key!(page, KeyEvent(:left))
        JuLeAna.history_key!(page, KeyEvent(:left))
        @test page.col == 1
        JuLeAna.history_key!(page, KeyEvent(:up))
        @test page.row == 1
        JuLeAna.history_key!(page, KeyEvent(:down))
        @test detail_text(page) == "hit cal  p02-r006  never processed"
        # on a partition row, the arrows move by period
        JuLeAna.history_key!(page, KeyEvent(:down))
        @test detail_text(page) == "energy cal  p02  ok  2026-10-15 10:00 UTC  report"
        JuLeAna.history_key!(page, KeyEvent(:right))
        @test page.col == 11 && detail_text(page) == "energy cal  p03  failed  2026-10-15 12:00 UTC  history, log folder /log/a"
        JuLeAna.history_key!(page, KeyEvent(:right))
        @test page.col == 11
        JuLeAna.history_key!(page, KeyEvent(:left))
        @test page.col == 1
        JuLeAna.history_key!(page, KeyEvent(:down))
        @test page.row == 3
        JuLeAna.history_key!(page, KeyEvent(:end_key))
        @test page.col == 11
        JuLeAna.history_key!(page, KeyEvent(:up))
        JuLeAna.history_key!(page, KeyEvent(:up))
        @test detail_text(page) == "dsp cal  p03-r000  cancelled  2026-10-15 13:00 UTC  history, log folder /log/a"
        JuLeAna.history_key!(page, KeyEvent(:home))
        @test page.col == 1
        render_history_page(page)
        JuLeAna.history_key!(page, KeyEvent(:pagedown))
        @test page.row == 3
        JuLeAna.history_key!(page, KeyEvent(:pageup))
        @test page.row == 1
    end

    @testset "opening reports" begin
        page = loaded_page()
        # a history cell does nothing
        JuLeAna.history_key!(page, KeyEvent(:enter))
        @test isempty(JuLeAna.take_requests!(page)) && isnothing(page.viewer_path)
        # a never processed cell does nothing
        page.row = 2
        JuLeAna.history_key!(page, KeyEvent(:enter))
        @test isempty(JuLeAna.take_requests!(page))
        page.row, page.col = 1, 2
        JuLeAna.history_key!(page, KeyEvent(:enter))
        @test JuLeAna.take_requests!(page) == [(; kind = :open, path = "/rep/p02-r007.md")]
        @test page.viewer_path == "/rep/p02-r007.md"
        @test find_text(render_history_page(page), "Reading report…") !== nothing
        # an answer for another report is dropped
        JuLeAna.history_result!(page,
                                (; request = (; kind = :open, path = "/rep/other.md"),
                                 value = JuLeAna.report_viewer("/rep/other.md", "# Other")))
        @test isnothing(page.viewer)
        JuLeAna.history_result!(page,
                                (; request = (; kind = :open, path = page.viewer_path),
                                 value = JuLeAna.report_viewer(page.viewer_path, "# Report\n\nbody")))
        @test page.viewer isa Tachikoma.MarkdownPane
        @test find_text(render_history_page(page), "p02-r007.md") !== nothing
        # the viewer takes the keys; Escape closes it
        @test JuLeAna.history_key!(page, KeyEvent(:down)) && page.row == 1
        @test JuLeAna.history_key!(page, KeyEvent('x'))
        @test JuLeAna.history_key!(page, KeyEvent(:escape)) && isnothing(page.viewer_path)
        JuLeAna.history_key!(page, KeyEvent(:enter))
        JuLeAna.take_requests!(page)
        JuLeAna.history_result!(page, (; request = (; kind = :open, path = page.viewer_path), value = nothing))
        @test find_text(render_history_page(page), "No report file: /rep/p02-r007.md") !== nothing
        JuLeAna.history_key!(page, KeyEvent('q'))
        @test isnothing(page.viewer_path)
    end

    @testset "rendering" begin
        page = loaded_page()
        text = history_text(render_history_page(page))
        @test occursin("dsp cal", text) && occursin("hit cal", text) && occursin("p energy cal", text)
        @test occursin("p02", text) && occursin("p03", text)
        @test occursin("✓", text) && occursin("!", text) && occursin("✗", text) && occursin("–", text)
        @test occursin("■", text) && occursin("[", text) && occursin("[■]", text) && occursin("history:", text)
        @test occursin("dsp cal  p02-r006  failed", text)
        @test find_text(render_history_page(page, 100, 20), "History") !== nothing
        # a history cell looks different from a report cell of the same state
        tb = render_history_page(page)
        # the icon of run 6 in the first row is the middle character of its cell
        @test collect(row_text(tb, page.cells.y))[page.cells.x + 1] == '■'
        @test Tachikoma.style_at(tb, page.cells.x + 1, page.cells.y).fg == Tachikoma.tstyle(JuLeAna.HISTORY_COLORS.failed).fg
        @test Tachikoma.style_at(tb, page.cells.x + 5, page.cells.y).fg == Tachikoma.tstyle(JuLeAna.REPORT_COLORS.warning).fg
    end

    @testset "scrolling" begin
        page = loaded_page()
        # room for the names and six run columns
        width = 40
        render_history_page(page, width, 12)
        @test page.left == 1
        JuLeAna.history_key!(page, KeyEvent(:end_key))
        tb = render_history_page(page, width, 12)
        @test page.left > 1
        text = history_text(tb)
        # the cursor column is shown with its run number, the names stay
        @test occursin("dsp cal", text) && occursin("p03", text)
        offsets = page.offsets
        @test offsets[page.col] - offsets[page.left] + JuLeAna.HISTORY_CELL_WIDTH <= page.cells.width
        JuLeAna.history_key!(page, KeyEvent(:home))
        render_history_page(page, width, 12)
        @test page.left == 1
        # rows scroll too
        render_history_page(page, width, 8)
        page.row = 3
        render_history_page(page, width, 8)
        @test page.top <= 3 <= page.top + page.height - 1
        # a tiny area draws nothing and does not throw
        render_history_page(page, 2, 2)
        render_history_page(page, 30, 4)
    end

    @testset "mouse" begin
        page = loaded_page()
        render_history_page(page)
        press(x, y, button = Tachikoma.mouse_left) = Tachikoma.MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false)
        cells = page.cells
        # third run column of the second row
        @test JuLeAna.history_mouse!(page, press(cells.x + 2 * 4 + 1, cells.y + 1))
        @test (page.row, page.col) == (2, 3)
        # the gap between two cells is no cell
        @test !JuLeAna.history_mouse!(page, press(cells.x + 3, cells.y))
        @test (page.row, page.col) == (2, 3)
        @test JuLeAna.history_mouse!(page, press(cells.x, cells.y, Tachikoma.mouse_scroll_down))
        @test page.row == 3
        @test JuLeAna.history_mouse!(page, press(cells.x, cells.y, Tachikoma.mouse_scroll_up))
        @test page.row == 2
        # the viewer gets the events while a report is open
        page.row, page.col = 1, 2
        JuLeAna.history_key!(page, KeyEvent(:enter))
        @test !JuLeAna.history_mouse!(page, press(1, 1))
    end
end
