# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text, style_at
using LegendDataManagement: DataPeriod, DataRun
using Dates: DateTime, Hour
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

# Render the Reports page of `page` into a `width` x `height` test backend.
function render_reports_page(page, width = 120, height = 32)
    tb = TestBackend(width, height)
    JuLeAna.render_reports(page, Rect(1, 1, width, height), tb.buf)
    return tb
end

# Position `(x, y)` of the first occurrence of `text`, counted in characters.
function locate_text(tb, text)
    for y in 1:tb.height
        row = row_text(tb, y)
        pos = findfirst(text, row)
        isnothing(pos) || return (; x = length(row, 1, first(pos) - 1) + 1, y)
    end
    return nothing
end

reports_text(tb) = join((row_text(tb, r) for r in 1:tb.height), "\n")

# A row of `report_index`.
function index_row(process, period, run, state; level = :run, date = nothing, failures = Tuple{String,String}[])
    return (; process, level, category = :cal, period, run, path = "/jlrep/$process-$period-$run.md", state, date, n_entries = 0,
            n_failed = length(failures), n_warnings = 0, failures)
end

const INDEX_ROWS = [index_row(:process_energy_calibration_cal, "p03", "r001", :ok; date = DateTime(2026, 10, 3, 12, 0)),
                    index_row(:process_energy_calibration_cal, "p03", "r002", :failed; date = DateTime(2026, 10, 3, 12, 5),
                              failures = [("V02 (trap)", "fit failed"), ("V03 (cusp)", "fit failed")]),
                    index_row(:process_energy_calibration_cal, "p03", "r003", :missing),
                    index_row(:process_energy_calibration_cal, "p03", "r004", :failed; failures = [("V02 (trap)", "no peaks")]),
                    index_row(:process_dsp_cal, "p03", "r001", :ok),
                    index_row(:process_dsp_cal, "p03", "r002", :warning; date = DateTime(2026, 10, 2, 8, 30)),
                    index_row(:p_process_aoe_cut_cal, "p03", nothing, :failed; level = :partition, failures = [("V02 (1)", "no peaks")])]

function report_entry(period, run, state; path = "/jlrep/$period-$run.md", date = nothing)
    return (; period, run, path, state, date)
end

const OVERVIEW_ROWS = [(; name = "dsp_cal", level = :run, category = "cal", nreports = 1, counts = (; ok = 1, warning = 0, failed = 0),
                        last_date = nothing, latest_path = nothing, reports = [report_entry("p03", "r001", :ok)]),
                       (; name = "energy_calibration", level = :run, category = "cal", nreports = 2,
                        counts = (; ok = 1, warning = 0, failed = 1), last_date = nothing, latest_path = nothing,
                        reports = [report_entry("p03", "r001", :ok),
                                   report_entry("p03", "r002", :failed; date = DateTime(2026, 10, 3, 12, 5))])]

# A page that has read `rows` for `source`, as the interface does it.
function loaded_page(rows = INDEX_ROWS; source = :run)
    page = JuLeAna.ReportsPage()
    JuLeAna.reports_visit!(page, nothing)
    page.source = source
    request = only(JuLeAna.take_requests!(page))
    JuLeAna.reports_result!(page, (; request = merge(request, (; source)), value = rows, history = nothing))
    return page
end

press(page, key) = JuLeAna.reports_key!(page, KeyEvent(key))

@testset "Reports page" begin
    @testset "strip_span_tags" begin
        text = """<span style="color:red">Failure</span> and <span class="a">x</span>, <b>kept</b>"""
        @test JuLeAna.strip_span_tags(text) == "Failure and x, <b>kept</b>"
        @test JuLeAna.strip_span_tags("no tags | a |") == "no tags | a |"
    end

    @testset "tables_as_code" begin
        text = "# Title\nDate: x\n\n| Detector | Status | Error |\n|:---|:---|:---|\n| V01 | Failure | no peaks |\n| V02 | Success | - |\nafter\n| A |\n|---|\n"
        @test JuLeAna.tables_as_code(text) ==
              join(["# Title", "Date: x", "", "```", "Detector  Status   Error", "────────  ───────  ────────",
                    "V01       Failure  no peaks", "V02       Success  -", "```", "after", "```", "A", "─", "```", ""], "\n")
        @test JuLeAna.tables_as_code("no table\n") == "no table\n"

        # HTML tags in the cells are removed
        html = "| Filekey | Status |\n|:---|:---|\n| k1 | <span style=\"color:red\">Failure</span> |\n"
        @test JuLeAna.tables_as_code(html) == "```\nFilekey  Status\n───────  ───────\nk1       Failure\n```\n"

        # a wide table is narrowed and its long cells wrap within their column
        detectors = join(("\"D$(lpad(i, 5, '0'))A\"" for i in 1:30), ", ")
        wide = "| Filekey | Status | Number of Detectors | Failed Detectors |\n|:---|:---|:---|:---|\n" *
               "| l200-p00-r000-cal-20250101T000000Z | <span style=\"color:red\">Failure</span> | 0/30 | [$detectors] |\n" *
               "| l200-p00-r000-cal-20250101T000100Z | <span style=\"color:green\">Success</span> | 30/30 | - |\n"
        lines = split(JuLeAna.tables_as_code(wide; width = 80), '\n')
        @test lines[1] == "```" && lines[end - 1] == "```"
        @test maximum(textwidth, lines) <= 80
        @test !any(occursin("<", l) for l in lines)
        # every detector survives the wrapping
        @test count("\"D", join(lines)) == 30
        @test count(l -> startswith(l, "l200-p00-r000"), lines) == 2
        # the long cell continues on the lines below the status
        failure = findfirst(l -> occursin("Failure", l), lines)
        @test occursin("\"D", lines[failure]) && occursin("\"D", lines[failure + 1])
        @test JuLeAna.wrap_cell("", 5) == [""]
        @test JuLeAna.wrap_cell("abcdefghij kl", 4) == ["abcd", "efgh", "ij", "kl"]
        # the default width fits a viewer of 100 columns
        @test maximum(textwidth, split(JuLeAna.tables_as_code(wide), '\n')) <= 100
    end

    @testset "groups, counts and colors" begin
        page = loaded_page()
        @test page.loaded && !page.reading && isnothing(page.error)
        @test [g.name for g in page.groups] == ["energy_calibration", "dsp", "aoe_cut"]
        @test page.groups[1].counts == (; ok = 1, warning = 0, failed = 2, missing = 1)
        tb = render_reports_page(page)
        @test find_text(tb, "Reports (current run)") !== nothing
        @test find_text(tb, "ok 1  warn 0  fail 2  miss 1") !== nothing
        @test find_text(tb, "ok 1  warn 1  fail 0  miss 0") !== nothing
        @test find_text(tb, "partition") !== nothing && find_text(tb, "run") !== nothing
        # the category follows the level, in the color of its tag on the Setup page
        @test find_text(tb, "run        cal  ok 1") !== nothing
        pos = locate_text(tb, "cal  ok")
        @test style_at(tb, pos.x, pos.y).fg == Tachikoma.tstyle(:primary).fg
        # the groups with failures are unfolded, the group without is not
        @test find_text(tb, "▾ energy_calibration") !== nothing
        @test find_text(tb, "▸ dsp") !== nothing
        @test find_text(tb, "▾ aoe_cut") !== nothing
        @test find_text(tb, "p03-r001") !== nothing && find_text(tb, "p03-r004") !== nothing
        @test find_text(tb, "p03-r002  ✗ failed   10-03 12:05Z") !== nothing
        @test find_text(tb, "– missing") !== nothing
        @test find_text(tb, "10-03 12:05Z") !== nothing
        for (word, color) in (("✗ failed", :error), ("✓ ok", :success), ("– missing", :text_dim))
            pos = locate_text(tb, word)
            @test style_at(tb, pos.x, pos.y).fg == Tachikoma.tstyle(color).fg
        end
        for (word, color) in (("ok 1", :success), ("warn 0", :warning), ("fail 2", :error), ("miss 1", :text_dim))
            pos = locate_text(tb, word)
            @test style_at(tb, pos.x, pos.y).fg == Tachikoma.tstyle(color).fg
        end
        # a partition-level report has the period as label
        pos = find_text(tb, "▾ aoe_cut")
        @test occursin(r"p03 +✗ failed", row_text(tb, pos.y + 1))
    end

    @testset "empty and pending states" begin
        page = JuLeAna.ReportsPage()
        @test find_text(render_reports_page(page), "Reading reports…") !== nothing
        @test find_text(render_reports_page(loaded_page(INDEX_ROWS[1:0])), "No processing run yet.") !== nothing
        @test find_text(render_reports_page(loaded_page(Any[]; source = :all)), "No reports.") !== nothing
        page = loaded_page()
        page.reading = true
        @test find_text(render_reports_page(page), "Reading reports…") !== nothing
        page = JuLeAna.ReportsPage()
        JuLeAna.reports_visit!(page, nothing)
        request = only(JuLeAna.take_requests!(page))
        JuLeAna.reports_result!(page, (; request, error = "report_index: no session is loaded"))
        tb = render_reports_page(page)
        @test find_text(tb, "report_index: no session is loaded") !== nothing && !page.reading
        @test style_at(tb, locate_text(tb, "report_index").x, locate_text(tb, "report_index").y).fg == Tachikoma.tstyle(:error).fg
    end

    @testset "cursor and fold keys" begin
        page = loaded_page()
        render_reports_page(page)
        rows() = JuLeAna.reports_rows(page)
        @test length(rows()) == 3 + 4 + 1
        @test press(page, :down) && page.cursor == ((("energy_calibration", :run, "cal")), "p03", "r001")
        @test press(page, :end_key) && page.index == length(rows())
        @test press(page, :home) && page.index == 1
        @test press(page, :pagedown) && page.index > 1
        @test press(page, :home)
        # Left folds the group of the cursor row and moves the cursor to the group row
        @test press(page, :down) && press(page, :left)
        @test page.index == 1 && length(rows()) == 4
        @test find_text(render_reports_page(page), "▸ energy_calibration") !== nothing
        @test press(page, :right) && length(rows()) == 8
        @test press(page, :enter) && length(rows()) == 4
        @test press(page, :enter) && length(rows()) == 8
        # the cursor stays on its group when the rows change
        page.cursor = rows()[end].key
        page.groups = page.groups[2:end]
        @test JuLeAna.sync_reports_cursor!(page, JuLeAna.reports_rows(page)) == length(JuLeAna.reports_rows(page))
        # keys that belong to the interface
        @test !press(page, '1') && !press(page, 'q') && !press(page, '?') && !press(page, :escape)
        @test !JuLeAna.reports_key!(page, KeyEvent(:down, Tachikoma.key_release))
    end

    @testset "source and reads" begin
        page = loaded_page()
        @test JuLeAna.take_requests!(page) == []
        @test press(page, 'a')
        @test page.source === :all && !page.loaded && page.reading
        request = only(JuLeAna.take_requests!(page))
        @test request.kind === :index && request.source === :all
        @test find_text(render_reports_page(page), "Reports (all on disk)") !== nothing
        # an answer to an older read is dropped
        JuLeAna.reports_result!(page,
                                (; request = merge(request, (; generation = request.generation - 1)), value = OVERVIEW_ROWS,
                                 history = nothing))
        @test !page.loaded && page.reading
        JuLeAna.reports_result!(page, (; request, value = OVERVIEW_ROWS, history = nothing))
        @test page.loaded && !page.reading
        @test [g.name for g in page.groups] == ["dsp", "energy_calibration"]
        tb = render_reports_page(page)
        @test find_text(tb, "ok 1  warn 0  fail 0") !== nothing && find_text(tb, "miss") === nothing
        # `r` reads again and keeps the source
        @test press(page, 'r')
        request = only(JuLeAna.take_requests!(page))
        @test request.kind === :index && request.source === :all
        @test page.loaded && page.reading
        @test find_text(render_reports_page(page), "Reading reports…") !== nothing
        # two reads queued before the interface takes them: only the latest remains
        press(page, 'r')
        press(page, 'r')
        @test length(JuLeAna.take_requests!(page)) == 1
        @test press(page, 'a')
        @test page.source === :run
        @test only(JuLeAna.take_requests!(page)).source === :run
    end

    @testset "failures of the processor under the cursor" begin
        page = loaded_page()
        tb = render_reports_page(page)
        @test find_text(tb, "Failures: energy_calibration") !== nothing
        @test find_text(tb, "V02  2 runs: p03-r002, p03-r004") !== nothing
        @test find_text(tb, "V03  1 run: p03-r002") !== nothing
        @test find_text(tb, "    fit failed") !== nothing && find_text(tb, "    no peaks") !== nothing
        pos = locate_text(tb, "fit failed")
        @test style_at(tb, pos.x, pos.y).fg == Tachikoma.tstyle(:error).fg
        # the group without failures
        page.cursor = (page.groups[2].key,)
        tb = render_reports_page(page)
        @test find_text(tb, "Failures: dsp") !== nothing && find_text(tb, "No failures.") !== nothing
        # a report row shows the failures of its processor; a partition-level processor counts periods
        page.cursor = (page.groups[3].key, "p03", nothing)
        tb = render_reports_page(page)
        @test find_text(tb, "Failures: aoe_cut") !== nothing && find_text(tb, "V02  1 period: p03") !== nothing
        # all reports on disk: the failures are read for the processor under the cursor
        page = loaded_page(OVERVIEW_ROWS; source = :all)
        group = page.groups[1]
        @test isempty(JuLeAna.take_requests!(page))
        @test find_text(render_reports_page(page), "No failures.") !== nothing
        @test press(page, :down) && press(page, :down) && press(page, :down)
        @test page.cursor == (page.groups[2].key,) || page.cursor[1] == page.groups[2].key
        request = only(JuLeAna.take_requests!(page))
        @test request.kind === :failures && request.group == page.groups[2].key
        @test request.reports == [("p03", "r002", "/jlrep/p03-r002.md")]
        @test find_text(render_reports_page(page), "Reading failures…") !== nothing
        # the request is not repeated while it is pending
        press(page, :up)
        press(page, :down)
        @test isempty(JuLeAna.take_requests!(page))
        rows = [(; process = request.group, period = "p03", run = "r002",
                 failures = [("V07 (trap)", "no peaks"), ("V07 (cusp)", "no peaks")])]
        JuLeAna.reports_result!(page, (; request, value = rows))
        tb = render_reports_page(page)
        @test find_text(tb, "V07  1 run: p03-r002") !== nothing && find_text(tb, "no peaks") !== nothing
        @test isempty(JuLeAna.take_requests!(page))
        # a failed read of the failures shows the message in place of the list
        page = loaded_page(OVERVIEW_ROWS; source = :all)
        press(page, :down)
        press(page, :down)
        press(page, :down)
        request = only(JuLeAna.take_requests!(page))
        JuLeAna.reports_result!(page, (; request, error = "unknown processor status"))
        @test find_text(render_reports_page(page), "unknown processor status") !== nothing
    end

    @testset "focus and scrolling of the failures" begin
        failures = [("V$(lpad(i, 2, '0')) (trap)", "error $i") for i in 1:30]
        page = loaded_page([index_row(:process_energy_calibration_cal, "p03", "r001", :failed; failures)])
        tb = render_reports_page(page, 120, 14)
        @test find_text(tb, "V01  1 run") !== nothing && find_text(tb, "V30") === nothing
        # the list has the focus: Tab moves it to the failures
        @test page.focus == 1 && press(page, :tab) && page.focus == 2
        @test press(page, :pagedown) && page.fail_top > 1
        @test press(page, :down)
        tb = render_reports_page(page, 120, 14)
        @test find_text(tb, "V01  1 run") === nothing
        @test page.index == 1
        @test press(page, :end_key)
        @test find_text(render_reports_page(page, 120, 14), "V30  1 run") !== nothing
        @test press(page, :home) && page.fail_top == 1
        @test press(page, :backtab) && page.focus == 1
        # Enter, Left and Right belong to the list
        press(page, :tab)
        @test !press(page, :enter)
        # the wheel scrolls the failures over their block, the cursor over the list
        press(page, :tab)
        tb = render_reports_page(page, 120, 14)
        wheel(x, y, button) = JuLeAna.reports_mouse!(page, MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false))
        @test wheel(100, 5, Tachikoma.mouse_scroll_down) && page.fail_top == 1 + JuLeAna.REPORT_WHEEL_LINES
        @test wheel(100, 5, Tachikoma.mouse_scroll_up) && page.fail_top == 1
        @test wheel(5, 5, Tachikoma.mouse_scroll_down) && page.index == 2
        # a click on a group row folds it
        @test wheel(5, 2, Tachikoma.mouse_left) && page.index == 1 && JuLeAna.reports_rows(page)[1].unfolded == false
        @test !wheel(100, 5, Tachikoma.mouse_left)
    end

    @testset "open report" begin
        page = loaded_page()
        render_reports_page(page)
        press(page, :down)
        path = INDEX_ROWS[1].path
        # Enter on a group row folds, on a report row opens
        @test press(page, :enter)
        request = only(JuLeAna.take_requests!(page))
        @test request == (; kind = :open, path)
        @test page.viewer_path == path && isnothing(page.viewer)
        tb = render_reports_page(page)
        @test find_text(tb, basename(path)) !== nothing && find_text(tb, "Reading report…") !== nothing
        @test find_text(tb, "Reports (current run)") === nothing
        # keys go to the viewer, `q` and `1` do not reach the interface
        @test press(page, '1') && press(page, 'a') && page.source === :run && isempty(JuLeAna.take_requests!(page))
        text = """
            # Main Log
            Time of processing: 2026-10-01T10:00:00

            | Detector | Status |
            |:---|:---|
            | V01 | <span style="color:red">Failure</span> |
            """ * "\n" * join(("line $i" for i in 1:60), "\n\n")
        JuLeAna.reports_result!(page, (; request, value = JuLeAna.report_viewer(path, text)))
        tb = render_reports_page(page, 100, 20)
        screen = reports_text(tb)
        @test find_text(tb, basename(path)) !== nothing
        # rendered with CommonMark: the heading marker and the HTML tags are gone
        @test find_text(tb, "Main Log") !== nothing && !occursin("# Main Log", screen)
        @test find_text(tb, "Failure") !== nothing && !occursin("<span", screen)
        @test find_text(tb, "line 1") !== nothing && find_text(tb, "line 60") === nothing
        @test press(page, :pagedown) && find_text(render_reports_page(page, 100, 20), "Main Log") === nothing
        @test press(page, :end_key) && find_text(render_reports_page(page, 100, 20), "line 60") !== nothing
        @test press(page, :home) && find_text(render_reports_page(page, 100, 20), "Main Log") !== nothing
        wheel = JuLeAna.reports_mouse!(page, MouseEvent(10, 10, Tachikoma.mouse_scroll_down, Tachikoma.mouse_press, false, false, false))
        @test wheel && find_text(render_reports_page(page, 100, 20), "Main Log") === nothing
        # `q` closes the viewer; afterwards `q` is not used
        @test press(page, 'q')
        @test isnothing(page.viewer_path) && isnothing(page.viewer)
        @test find_text(render_reports_page(page), "Reports (current run)") !== nothing
        @test !press(page, 'q')

        # Escape closes it, and an answer that arrives later is dropped
        press(page, :enter)
        request = only(JuLeAna.take_requests!(page))
        @test press(page, :escape) && isnothing(page.viewer_path)
        JuLeAna.reports_result!(page, (; request, value = JuLeAna.report_viewer(path, text)))
        @test isnothing(page.viewer)

        # a missing file and a failed read
        press(page, :enter)
        request = only(JuLeAna.take_requests!(page))
        JuLeAna.reports_result!(page, (; request, value = nothing))
        @test find_text(render_reports_page(page), "No report file: $path") !== nothing
        press(page, :escape)
        press(page, :enter)
        request = only(JuLeAna.take_requests!(page))
        JuLeAna.reports_result!(page, (; request, error = "permission denied"))
        @test find_text(render_reports_page(page), "permission denied") !== nothing
        # a closed viewer ignores mouse events
        press(page, :escape)
        @test !JuLeAna.reports_mouse!(page, MouseEvent(5, 3, Tachikoma.mouse_left, Tachikoma.mouse_release, false, false, false))
    end

    @testset "processing history entry" begin
        page = JuLeAna.ReportsPage()
        JuLeAna.reports_visit!(page, nothing)
        request = only(JuLeAna.take_requests!(page))
        path = joinpath(mktempdir(), "history.md")
        JuLeAna.reports_result!(page, (; request, value = OVERVIEW_ROWS, history = path))
        rows = JuLeAna.reports_rows(page)
        @test rows[1].key == (:history,) && rows[1].report && isnothing(rows[1].group)
        @test rows[2].group.name == "dsp"
        tb = render_reports_page(page)
        @test find_text(tb, "Processing history") !== nothing
        # the cursor starts on the history row; folding keys leave it alone
        @test page.cursor === nothing || page.cursor == (:history,)
        @test press(page, :left) && press(page, :right) && JuLeAna.cursor_group(page) === nothing
        @test find_text(render_reports_page(page), "Failures") !== nothing
        @test press(page, :enter)
        @test only(JuLeAna.take_requests!(page)) == (; kind = :open, path)
        @test page.viewer_path == path
        # no history file, no entry
        JuLeAna.close_viewer!(page)
        JuLeAna.reports_result!(page,
                                (; request = merge(request, (; generation = page.generation)), value = OVERVIEW_ROWS, history = nothing))
        @test isnothing(page.history) && !any(r -> r.key == (:history,), JuLeAna.reports_rows(page))
    end

    @testset "reading a report file" begin
        # an `:open` request does not use the controller
        ctrl = DataflowController(Dict{String,Any}("config" => nothing); loader = nothing, record_software = false, record_metadata = false)
        path = joinpath(mktempdir(), "report.md")
        write(path, "# Main Log\n\nbody")
        answer = JuLeAna.read_reports(ctrl, (; kind = :open, path))
        @test answer.value isa Tachikoma.MarkdownPane
        @test JuLeAna.read_reports(ctrl, (; kind = :open, path = path * ".missing")).value === nothing
        @test JuLeAna.read_history_page(ctrl, (; kind = :open, path)).value isa Tachikoma.MarkdownPane
    end

    @testset "reads follow the controller state" begin
        page = JuLeAna.ReportsPage()
        snap(; outcome = nothing, started = nothing, finished = nothing, state = :ready, periods = [2], run_steps = [:a]) = (; state,
                                                                                                                             outcome,
                                                                                                                             started,
                                                                                                                             finished,
                                                                                                                             periods,
                                                                                                                             runs = nothing,
                                                                                                                             run_steps,
                                                                                                                             partition_steps = Symbol[])
        JuLeAna.reports_visit!(page, nothing)
        @test length(JuLeAna.take_requests!(page)) == 1
        # visible with no change: no read
        JuLeAna.reports_visit!(page, nothing)
        @test isempty(JuLeAna.take_requests!(page))
        # the session loaded
        JuLeAna.reports_visit!(page, snap())
        @test length(JuLeAna.take_requests!(page)) == 1
        JuLeAna.reports_visit!(page, snap())
        @test isempty(JuLeAna.take_requests!(page))
        # a run started, then finished
        start = DateTime(2026, 10, 3)
        JuLeAna.reports_visit!(page, snap(; started = start))
        @test length(JuLeAna.take_requests!(page)) == 1
        JuLeAna.reports_visit!(page, snap(; outcome = :finished, started = start, finished = start + Hour(1)))
        @test length(JuLeAna.take_requests!(page)) == 1
        # another selection does not change the reports of the run
        JuLeAna.reports_visit!(page, snap(; outcome = :finished, started = start, finished = start + Hour(1), run_steps = [:a, :b]))
        @test isempty(JuLeAna.take_requests!(page))
        # while loading, the state of the session is not known
        JuLeAna.reports_visit!(page, snap(; state = :loading))
        @test length(JuLeAna.take_requests!(page)) == 1
    end

    @testset "through the interface" begin
        root = mktempdir()
        l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
        p2 = DataPeriod(2)
        runs = DataRun.([6, 7])
        args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                               p_processors = Dict{Symbol,ProcessorSpec}())
        function new_session()
            periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [p2], runs, run_steps(cfg),
                                                                                   partition_steps(cfg))
            return DataflowSession(; args, l200, config = cfg, periods, runs, run_steps = run_steps(cfg),
                                   partition_steps = partition_steps(cfg), run_status, partition_status)
        end
        processors = Dict{Symbol,Any}(:process_energy_calibration_cal => (cfg, l200, period, run; reprocess = false) -> nothing)
        report(run) = JuLeAna.report_path(l200, :process_energy_calibration_cal, :run, p2, DataRun(run), :cal)
        failed_text = "# Energy calibration\nDate of processing: 2026-10-03T12:00:00Z\n\n" * RUN_REPORT
        ok_text = "# Energy calibration\nDate of processing: 2026-10-01T09:30:00Z\n\n| Detector | Status | Filter Type | Error |\n|:---|:---|:---|:---|\n| V01 | Success | trap | - |\n"
        mkpath(dirname(report(6)))
        mkpath(dirname(report(7)))
        write(report(6), failed_text)

        function settle!(cond, m; timeout = 60)
            t_end = time() + timeout
            while time() < t_end
                Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
                cond() && return true
                sleep(0.02)
            end
            return false
        end
        function render_model(m, width = 120, height = 32)
            tb = TestBackend(width, height)
            Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
            return tb
        end

        m = JuLeAna.JuLeAnaTUI(DataflowController(new_session(); processors, record_software = false, record_metadata = false))
        page = m.reports_page
        # a processing run whose steps the page lists with `a`
        dispatch!(m.ctrl, StartProcessing())
        wait(m.ctrl)
        JuLeAna.refresh!(m)
        @test settle!(() -> !m.refreshing && !isnothing(m.snap), m)
        # the page reads nothing before it is visible, then starts with all reports on disk
        @test !page.visited && !page.reading
        Tachikoma.update!(m, KeyEvent('6'))
        @test m.page == 6 && page.reading && page.source === :all
        @test find_text(render_model(m), "Reading reports…") !== nothing
        @test settle!(() -> page.loaded && !page.reading, m)
        @test find_text(render_model(m), "Reports (all on disk)") !== nothing
        Tachikoma.update!(m, KeyEvent('a'))
        @test settle!(() -> page.loaded && !page.reading && page.source === :run, m)
        tb = render_model(m)
        @test find_text(tb, "Reports (current run)") !== nothing && find_text(tb, "▾ energy_calibration") !== nothing
        @test find_text(tb, "p02-r006  ✗ failed   10-03 12:00Z") !== nothing && find_text(tb, "p02-r007  – missing") !== nothing
        @test find_text(tb, "ok 0  warn 0  fail 1  miss 1") !== nothing
        # the processing run wrote the history, the first row; the cursor starts on it
        @test find_text(tb, "Processing history") !== nothing && page.cursor == (:history,)
        Tachikoma.update!(m, KeyEvent(:down))
        tb = render_model(m)
        @test find_text(tb, "V02  1 run: p02-r006") !== nothing && find_text(tb, "fit failed") !== nothing
        keys_row = row_text(tb, 31)
        @test occursin("↑↓ move  Enter open  a all/run  r reload  Tab pane", keys_row)
        @test occursin("1-8 page  q quit", keys_row)

        # `r` reads the reports again
        write(report(7), ok_text)
        Tachikoma.update!(m, KeyEvent('r'))
        @test page.reading
        @test settle!(() -> !page.reading, m)
        tb = render_model(m)
        @test find_text(tb, "p02-r007  ✓ ok       10-01 09:30Z") !== nothing && find_text(tb, "miss 0") !== nothing

        # all reports on disk
        Tachikoma.update!(m, KeyEvent('a'))
        @test settle!(() -> page.loaded && !page.reading, m)
        tb = render_model(m)
        @test find_text(tb, "Reports (all on disk)") !== nothing && find_text(tb, "miss") === nothing
        # the failures of the processor are read in the background
        Tachikoma.update!(m, KeyEvent(:down))
        @test settle!(() -> haskey(page.summaries, page.groups[1].key), m)
        @test find_text(render_model(m), "V02  1 run: p02-r006") !== nothing
        Tachikoma.update!(m, KeyEvent('a'))
        @test settle!(() -> page.loaded && !page.reading && page.source === :run, m)

        # open a report; `q` closes it and does not quit
        Tachikoma.update!(m, KeyEvent(:down))
        Tachikoma.update!(m, KeyEvent(:down))
        Tachikoma.update!(m, KeyEvent(:enter))
        @test page.viewer_path == report(6)
        @test settle!(() -> !isnothing(page.viewer), m)
        tb = render_model(m)
        @test find_text(tb, basename(report(6))) !== nothing && find_text(tb, "Energy calibration") !== nothing
        @test find_text(tb, "# Energy calibration") === nothing && find_text(tb, "<span") === nothing
        keys_row = row_text(tb, 31)
        @test occursin("↑↓ PgUp PgDn scroll  Esc close", keys_row) && !occursin("quit", keys_row)
        Tachikoma.update!(m, KeyEvent('q'))
        @test !Tachikoma.should_quit(m) && isnothing(page.viewer_path)
        Tachikoma.update!(m, KeyEvent(:enter))
        Tachikoma.update!(m, KeyEvent(:escape))
        @test !Tachikoma.should_quit(m) && isnothing(page.viewer_path)
        # the help panel lists the keys of the page
        Tachikoma.update!(m, KeyEvent('?'))
        @test find_text(render_model(m), "Reports page") !== nothing
        Tachikoma.update!(m, KeyEvent(:escape))
        # other pages do not read, and `q` quits
        Tachikoma.update!(m, KeyEvent('1'))
        @test m.page == 1
        Tachikoma.update!(m, KeyEvent('6'))
        Tachikoma.update!(m, KeyEvent('q'))
        @test Tachikoma.should_quit(m)
        Tachikoma.cleanup!(m)

        # no session loaded yet: the message of the failed read
        idle = JuLeAna.JuLeAnaTUI(DataflowController(args; processors, loader = _ -> new_session(), record_software = false,
                                                     record_metadata = false))
        Tachikoma.update!(idle, KeyEvent('6'))
        @test settle!(() -> !idle.reports_page.reading, idle)
        @test find_text(render_model(idle), "report_overview: no session") !== nothing
        Tachikoma.cleanup!(idle)
    end
end
