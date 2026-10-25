# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text
using LegendDataManagement: DataPeriod, DataRun
using Dates: DateTime
using Logging: Logging
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

# Render the whole interface `m` into a `width` x `height` test backend.
function render_model(m, width = 120, height = 30)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end

# Messages of no step.
const NO_MESSAGES = (; key = nothing, messages = JuLeAna.StepMessage[])

# Render the Progress page of `page` into a `width` x `height` test backend.
function render_page(page, prog, busy, width = 120, height = 30; msgs = NO_MESSAGES)
    tb = TestBackend(width, height)
    JuLeAna.render_progress(page, prog, busy, msgs, Rect(1, 1, width, height), tb.buf)
    return tb
end

page_text(tb, height = 30) = join((row_text(tb, r) for r in 1:height), "\n")

@testset "Progress page" begin
    p3, r1, r2 = DataPeriod(3), DataRun(1), DataRun(2)
    done_key, run_key, wait_key, part_key = (p3, r1, :run_a), (p3, r1, :run_b), (p3, r2, :run_a), (p3, nothing, :p_part)

    # one finished step, one running step with a failed item and workers 2 and 3, two waiting steps
    function running_store()
        store = ProgressStore()
        JuLeAna.reset_progress!(store, [done_key, run_key, wait_key, part_key])
        JuLeAna.set_step_state!(store, done_key, :running)
        JuLeAna.set_step_state!(store, done_key, :done)
        JuLeAna.set_step_state!(store, run_key, :running)
        id = JuLeAna.items_queued!(store, run_key, 10)
        JuLeAna.item_started!(store, run_key, id, 1, "fk0")
        JuLeAna.item_started!(store, run_key, id + 1, 1, "fk1")
        JuLeAna.item_finished!(store, run_key, id, :done)
        JuLeAna.item_finished!(store, run_key, id + 1, :failed)
        JuLeAna.item_started!(store, run_key, id + 2, 2, "fk2")
        JuLeAna.item_started!(store, run_key, id + 3, 3, "fk3")
        sleep(0.05)
        return store
    end

    @testset "bar_segments" begin
        @test JuLeAna.bar_segments([3, 1, 0, 6], 20) == [6, 2, 0, 12]
        @test JuLeAna.bar_segments([0, 0, 0], 20) == [0, 0, 0]
        for counts in ([1, 1, 1, 1], [1, 0, 0, 2], [7, 3, 5, 11], [1, 100]), width in (1, 7, 10, 20)

            segments = JuLeAna.bar_segments(counts, width)
            @test sum(segments) == width && all(>=(0), segments)
        end
        # cumulative rounding keeps the order: the boundary after each segment is its rounded share
        @test cumsum(JuLeAna.bar_segments([1, 1, 1], 10)) == round.(Int, 10 .* [1, 2, 3] ./ 3)
    end

    @testset "no run yet" begin
        for prog in (nothing, progress(ProgressStore()))
            page = JuLeAna.ProgressPage()
            text = page_text(render_page(page, prog, JuLeAna.BusyItem[]))
            @test occursin("No processing run yet.", text)
            @test occursin("Busy workers (0)", text) && occursin("none", text)
            # keys on an empty page do not fail
            @test JuLeAna.progress_key!(page, KeyEvent(:down), prog)
        end
    end

    @testset "running run" begin
        store = running_store()
        prog, busy = progress(store), busy_workers(store)
        page = JuLeAna.ProgressPage()
        tb = render_page(page, prog, busy)
        text = page_text(tb)
        @test occursin("%  1/4 steps done", text)
        @test occursin("running 1", text) && occursin("waiting 2", text) && occursin("done 1", text)
        @test occursin("Steps (following)", text)
        # the running group is unfolded, the finished one is not
        @test occursin("▾ p03-r001", text) && occursin("▸ p03-r002", text)
        @test occursin("run_b", text) && occursin("✓ run_a", text) && !occursin("○", text) && !occursin("p_part", text)
        @test occursin("1/10", text)
        @test occursin("w 2,3", text)
        @test occursin("/min", text) && occursin("ETA", text)
        @test occursin("1 failed", text)
        # busy workers
        @test occursin("Busy workers (2)", text)
        @test find_text(tb, "w 2") !== nothing && occursin("fk2", text) && occursin("fk3", text)
        @test occursin("p03-r001 run_b", text)
        # the cursor follows the running step
        @test page.cursor == run_key
    end

    @testset "stopped run with not run items" begin
        store = running_store()
        JuLeAna.items_abandoned!(store, run_key)
        JuLeAna.finish_progress!(store, :stopped)
        prog, busy = progress(store), busy_workers(store)
        page = JuLeAna.ProgressPage()
        text = page_text(render_page(page, prog, busy))
        @test occursin("8 not run", text) && occursin("▒", text)
        @test occursin("stopped 3", text) && occursin("done 1", text)
        # group rows count stopped steps, step rows count items that were not run
        @test occursin("0/1 done, 1 stopped", text)
        @test occursin("abandoned", text)
        @test occursin("Busy workers (2)", text)
    end

    @testset "keys" begin
        store = running_store()
        prog = progress(store)
        page = JuLeAna.ProgressPage()
        render_page(page, prog, JuLeAna.BusyItem[])
        @test page.follow && page.cursor == run_key
        @test JuLeAna.progress_key!(page, KeyEvent(:down), prog)
        @test !page.follow && page.cursor != run_key
        text = page_text(render_page(page, prog, JuLeAna.BusyItem[]))
        @test occursin("Steps", text) && !occursin("following", text)
        @test JuLeAna.progress_key!(page, KeyEvent('f'), prog)
        @test page.follow
        render_page(page, prog, JuLeAna.BusyItem[])
        @test page.cursor == run_key

        # Left folds the group of the cursor row and moves the cursor to it; the choice outlives new reads
        @test JuLeAna.progress_key!(page, KeyEvent(:left), prog)
        @test !page.follow && page.cursor == (p3, r1) && page.expanded[(p3, r1)] === false
        prog2 = progress(store)
        text = page_text(render_page(page, prog2, JuLeAna.BusyItem[]))
        @test occursin("▸ p03-r001", text) && !occursin("run_b", text)
        # Enter on a group row unfolds and folds it
        @test JuLeAna.progress_key!(page, KeyEvent(:enter), prog2)
        @test occursin("▾ p03-r001", page_text(render_page(page, prog2, JuLeAna.BusyItem[])))
        @test JuLeAna.progress_key!(page, KeyEvent(:enter), prog2)
        @test occursin("▸ p03-r001", page_text(render_page(page, prog2, JuLeAna.BusyItem[])))
        @test JuLeAna.progress_key!(page, KeyEvent(:enter), prog2)
        @test occursin("▾ p03-r001", page_text(render_page(page, prog2, JuLeAna.BusyItem[])))
        @test JuLeAna.progress_key!(page, KeyEvent(:left), prog2)
        @test occursin("▸ p03-r001", page_text(render_page(page, prog2, JuLeAna.BusyItem[])))
        @test JuLeAna.progress_key!(page, KeyEvent(:right), prog2)
        @test occursin("▾ p03-r001", page_text(render_page(page, prog2, JuLeAna.BusyItem[])))

        # Home and End
        @test JuLeAna.progress_key!(page, KeyEvent(:home), prog2) && page.cursor == (p3, r1)
        @test JuLeAna.progress_key!(page, KeyEvent(:end_key), prog2)
        rows = JuLeAna.progress_rows(page, prog2)
        @test page.cursor == last(rows).key
        @test JuLeAna.progress_key!(page, KeyEvent(:pageup), prog2)

        # keys the page does not use, and key releases
        for evt in (KeyEvent('1'), KeyEvent('q'), KeyEvent(:escape), KeyEvent(:pageup, Tachikoma.key_release))
            @test !JuLeAna.progress_key!(page, evt, prog2)
        end
        @test !JuLeAna.progress_key!(page, KeyEvent(:down, Tachikoma.key_release), prog2)

        # mouse wheel
        page = JuLeAna.ProgressPage()
        render_page(page, prog, JuLeAna.BusyItem[])
        wheel(button, x = 5, y = 8) = MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false)
        @test JuLeAna.progress_mouse!(page, wheel(Tachikoma.mouse_scroll_up), prog)
        @test !page.follow
        @test !JuLeAna.progress_mouse!(page, wheel(Tachikoma.mouse_scroll_up, 5, 1), prog)

        # a left click on a row moves the cursor there; on a group row it also folds or unfolds
        page = JuLeAna.ProgressPage()
        render_page(page, prog, JuLeAna.BusyItem[])
        click(y) = MouseEvent(5, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false)
        rows = JuLeAna.progress_rows(page, prog)
        row_y(i) = page.list.y + i - page.top
        @test rows[2].step
        @test JuLeAna.progress_mouse!(page, click(row_y(2)), prog)
        @test page.cursor == rows[2].key && !page.follow
        @test !rows[1].step && rows[1].unfolded
        @test JuLeAna.progress_mouse!(page, click(row_y(1)), prog)
        @test page.cursor == rows[1].key && page.expanded[rows[1].key] == false
        @test !JuLeAna.progress_mouse!(page, click(1), prog)

        # a vanished cursor row falls back to the nearest row
        page.cursor = (p3, r2, :gone)
        page.index = 100
        @test JuLeAna.sync_cursor!(page, JuLeAna.progress_rows(page, prog)) == length(JuLeAna.progress_rows(page, prog))
    end

    @testset "scrolling follows the running step" begin
        keys = [(p3, DataRun(i), :step) for i in 1:30]
        store = ProgressStore()
        JuLeAna.reset_progress!(store, keys)
        for k in keys[1:25]
            JuLeAna.set_step_state!(store, k, :running)
            JuLeAna.set_step_state!(store, k, :done)
        end
        JuLeAna.set_step_state!(store, keys[26], :running)
        prog = progress(store)
        page = JuLeAna.ProgressPage()
        tb = render_page(page, prog, JuLeAna.BusyItem[], 120, 14)
        @test page.cursor == keys[26]
        @test find_text(tb, "step") !== nothing && occursin("p03-r026", page_text(tb, 14))
        @test page.top > 1
        # scrolling back up with the keys shows the first rows again
        for _ in 1:60
            JuLeAna.progress_key!(page, KeyEvent(:up), prog)
        end
        text = page_text(render_page(page, prog, JuLeAna.BusyItem[], 120, 14), 14)
        @test occursin("p03-r001", text) && !occursin("p03-r026", text)
        # following scrolls to the running step again
        JuLeAna.progress_key!(page, KeyEvent('f'), prog)
        @test occursin("p03-r026", page_text(render_page(page, prog, JuLeAna.BusyItem[], 120, 14), 14))
    end

    @testset "messages pane" begin
        # run_a is failed with three messages, one of them with a second line; run_b waits
        store = ProgressStore()
        JuLeAna.reset_progress!(store, [done_key, run_key])
        JuLeAna.set_step_state!(store, done_key, :running)
        t0 = DateTime(2026, 1, 2, 3, 4, 5)
        JuLeAna.step_message!(store, done_key, Logging.Info, "loading")
        JuLeAna.step_message!(store, done_key, Logging.Warn, "low statistics\n  channel = 7")
        JuLeAna.step_message!(store, done_key, Logging.Error, "fit failed")
        JuLeAna.set_step_state!(store, done_key, :failed; error = "BoundsError: bad index\nstacktrace line")
        prog = progress(store)
        msgs = (; key = done_key, messages = step_messages(store, done_key))
        none = JuLeAna.BusyItem[]
        render(page, msgs = msgs, h = 30) = page_text(render_page(page, prog, none, 120, h; msgs), h)
        row_y(page, key) = page.list.y + findfirst(r -> r.key == key, JuLeAna.progress_rows(page, prog)) - page.top

        page = JuLeAna.ProgressPage()
        text = render(page)
        @test isnothing(page.open) && !occursin("messages", text)
        @test page.cursor != done_key
        JuLeAna.sync_cursor!(page, JuLeAna.progress_rows(page, prog))
        # Enter on a step row opens the pane and turns following off; Enter again closes it
        page.cursor = done_key
        @test JuLeAna.progress_key!(page, KeyEvent(:enter), prog)
        @test page.open == done_key && !page.follow
        text = render(page)
        @test occursin("p03-r001 run_a: 3 messages", text)
        @test occursin("Info  loading", text) && occursin("Warn  low statistics", text) && occursin("Error fit failed", text)
        # continuation lines are indented under the level column
        @test occursin(" "^15 * "  channel = 7", text)
        # the error of a failed step comes first, before the first message
        lines = split(text, '\n')
        i_error = findfirst(l -> occursin("BoundsError: bad index", l), lines)
        @test !isnothing(i_error) && occursin("stacktrace line", lines[i_error + 1])
        @test i_error < findfirst(l -> occursin("loading", l), lines)
        # message lines start with a local time stamp
        @test occursin(r"\d\d:\d\d:\d\d Info  loading", text)
        @test JuLeAna.progress_key!(page, KeyEvent(:enter), prog)
        @test isnothing(page.open)
        @test !occursin("3 messages", render(page))
        # Escape closes the pane, and is not used without one
        JuLeAna.progress_key!(page, KeyEvent(:enter), prog)
        @test !isnothing(page.open)
        @test JuLeAna.progress_key!(page, KeyEvent(:escape), prog) && isnothing(page.open)
        @test !JuLeAna.progress_key!(page, KeyEvent(:escape), prog)

        # moving the cursor to another step row switches the pane; a group row keeps the step
        JuLeAna.progress_key!(page, KeyEvent(:enter), prog)
        @test JuLeAna.progress_key!(page, KeyEvent(:down), prog)
        @test page.cursor == run_key && page.open == run_key
        text = render(page, (; key = run_key, messages = JuLeAna.StepMessage[]))
        @test occursin("p03-r001 run_b: 0 messages", text) && occursin("No messages from this step.", text)
        # messages read for another step are not shown
        @test occursin("Reading messages", render(page, msgs))
        @test JuLeAna.progress_key!(page, KeyEvent(:home), prog)
        @test page.cursor == (p3, r1) && page.open == run_key
        # Enter on a group row folds it and keeps the pane
        @test JuLeAna.progress_key!(page, KeyEvent(:enter), prog)
        @test page.open == run_key && page.expanded[(p3, r1)] === false

        # a click on a step row opens the pane, a click on a group row folds
        page = JuLeAna.ProgressPage()
        render_page(page, prog, none)
        click(y) = MouseEvent(5, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false)
        @test JuLeAna.progress_mouse!(page, click(row_y(page, done_key)), prog)
        @test page.open == done_key && page.cursor == done_key && !page.follow
        @test JuLeAna.progress_mouse!(page, click(row_y(page, (p3, r1))), prog)
        @test page.open == done_key && page.expanded[(p3, r1)] === false

        # follow turns on again: the pane follows the cursor's step
        page = JuLeAna.ProgressPage()
        page.cursor, page.open = done_key, done_key
        JuLeAna.progress_key!(page, KeyEvent('f'), prog)
        @test page.follow
        render(page, msgs)
        @test page.open == done_key

        # a long message list: the newest messages are shown, PgUp scrolls, End goes back
        JuLeAna.reset_progress!(store, [done_key])
        JuLeAna.set_step_state!(store, done_key, :running)
        for i in 1:40
            JuLeAna.step_message!(store, done_key, Logging.Info, "message $i")
        end
        prog = progress(store)
        msgs = (; key = done_key, messages = step_messages(store, done_key))
        page = JuLeAna.ProgressPage()
        render_page(page, prog, none; msgs)
        page.cursor = done_key
        JuLeAna.progress_key!(page, KeyEvent(:enter), prog)
        text = render(page, msgs)
        @test occursin("40 messages", text) && occursin("message 40", text) && !occursin("message 1 ", text * " ")
        @test page.pane_follow && page.pane_lines == 40
        bottom_top = page.pane_top
        @test JuLeAna.progress_key!(page, KeyEvent(:pageup), prog)
        @test !page.pane_follow && page.cursor == done_key
        text = render(page, msgs)
        @test page.pane_top == bottom_top - page.pane_height && !occursin("message 40", text)
        @test JuLeAna.progress_key!(page, KeyEvent(:pagedown), prog)
        @test page.pane_follow && occursin("message 40", render(page, msgs))
        JuLeAna.progress_key!(page, KeyEvent(:pageup), prog)
        JuLeAna.progress_key!(page, KeyEvent(:end_key), prog)
        @test page.pane_follow && occursin("message 40", render(page, msgs))

        # no room for the pane: it is not drawn
        text = render(page, msgs, 12)
        @test !occursin("40 messages", text)
        @test render_page(page, prog, none, 20, 12; msgs) isa TestBackend
    end

    @testset "small areas" begin
        store = running_store()
        prog, busy = progress(store), busy_workers(store)
        for (w, h) in ((20, 5), (40, 8), (60, 12), (3, 3))
            @test render_page(JuLeAna.ProgressPage(), prog, busy, w, h) isa TestBackend
        end
    end

    @testset "through the model" begin
        store = running_store()
        root = mktempdir()
        l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
        args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        cfg = ProcessingConfig(; processors = Dict(:process_energy_calibration_cal => spec(:process_energy_calibration_cal, :run, 1)),
                               p_processors = Dict{Symbol,ProcessorSpec}())
        periods, run_status, partition_status = JuLeAna.setup_dependency_graph(l200, cfg, [DataPeriod(2)], nothing, run_steps(cfg),
                                                                               partition_steps(cfg))
        session = DataflowSession(; args, l200, config = cfg, periods, run_steps = run_steps(cfg), partition_steps = partition_steps(cfg),
                                  run_status, partition_status)
        m = JuLeAna.JuLeAnaTUI(DataflowController(session; processors = Dict{Symbol,Any}()))
        m.progress, m.busy = progress(store), busy_workers(store)
        Tachikoma.update!(m, KeyEvent('4'))
        @test m.page == 4
        text = page_text(render_model(m))
        @test occursin("Steps (following)", text) && occursin("Busy workers (2)", text)
        @test occursin("↑↓ PgUp PgDn move", text) && occursin("Enter on step messages", text)
        Tachikoma.update!(m, KeyEvent(:down))
        @test !m.progress_page.follow
        Tachikoma.update!(m, KeyEvent('f'))
        @test m.progress_page.follow
        wheel = MouseEvent(5, 13, Tachikoma.mouse_scroll_down, Tachikoma.mouse_press, false, false, false)
        Tachikoma.update!(m, wheel)
        @test !m.progress_page.follow
        Tachikoma.update!(m, KeyEvent('1'))
        @test m.page == 1
        Tachikoma.update!(m, KeyEvent('4'))
        Tachikoma.update!(m, KeyEvent('q'))
        @test m.quit

        # opening a step on the Progress page reads its messages in the background
        key = (DataPeriod(2), DataRun(6), :process_energy_calibration_cal)
        JuLeAna.reset_progress!(m.ctrl.progress, [key])
        JuLeAna.set_step_state!(m.ctrl.progress, key, :running)
        JuLeAna.step_message!(m.ctrl.progress, key, Logging.Warn, "low statistics")
        JuLeAna.set_step_state!(m.ctrl.progress, key, :failed; error = "fit failed")
        Tachikoma.update!(m, KeyEvent('4'))
        refresh_done() = (t = time() + 60; while m.refreshing && time() < t
                              Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
                              sleep(0.02)
                          end; !m.refreshing)
        @test refresh_done()
        JuLeAna.refresh!(m)
        @test refresh_done()
        render_model(m)
        @test m.progress_page.cursor == key
        @test isempty(m.step_msgs.messages) && isnothing(m.step_msgs.key)
        Tachikoma.update!(m, KeyEvent(:enter))
        @test m.progress_page.open == key
        @test refresh_done()
        t_end = time() + 60
        while m.step_msgs.key != key && time() < t_end
            Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
            sleep(0.02)
        end
        @test m.step_msgs.key == key && [e.text for e in m.step_msgs.messages] == ["low statistics"]
        text = page_text(render_model(m))
        @test occursin("1 message", text) && occursin("low statistics", text) && occursin("fit failed", text)
        @test occursin("Esc close", text) && !occursin("PgUp PgDn move", text)
        Tachikoma.update!(m, KeyEvent(:escape))
        @test isnothing(m.progress_page.open)
        Tachikoma.cleanup!(m)
    end
end # testset
