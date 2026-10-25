# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using JuLeAna: AddWorkers, CancelAllocation, CancelAll, PostponeIdleCancel, EditStartScript, SetRunmodeSettings
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Rect, find_text, row_text, style_at
using LegendDataManagement: DataPeriod, DataRun
using Dates: DateTime, Minute, Second
using Logging: with_logger
using Test

# Render the Workers page of `page` into a `width` x `height` test backend.
function render_workers_page(page, snap = nothing, busy = JuLeAna.BusyItem[], messages = JuLeAna.MessageBuffer(); width = 120,
                             height = 24, at = DateTime(2026, 10, 15, 12, 0, 0))
    tb = TestBackend(width, height)
    JuLeAna.render_workers(page, snap, busy, messages, Rect(1, 1, width, height), tb.buf; at)
    return tb
end

workers_screen(tb) = join((row_text(tb, r) for r in 1:tb.height), "\n")

@testset "Workers page" begin
    t0 = DateTime(2026, 10, 15, 11, 47, 56)
    allocation(id, state; backend = :local, job_name = nothing, job_ids = String[], exit_code = nothing, finished = nothing, output = String[]) = (;
                                                                                                                                                   id,
                                                                                                                                                   backend,
                                                                                                                                                   job_name,
                                                                                                                                                   started = t0,
                                                                                                                                                   finished,
                                                                                                                                                   state,
                                                                                                                                                   exit_code,
                                                                                                                                                   job_ids,
                                                                                                                                                   output)
    allocations = [allocation(1, :running; backend = :slurm, job_name = "julia-42-1", job_ids = ["4711", "4712"],
                              output = ["starting workers", "srun: job 4711 queued"]),
                   allocation(2, :cancelled; finished = t0 + Minute(3), exit_code = 143, output = ["cancelled output"]),
                   allocation(3, :failed; finished = t0 + Minute(1), exit_code = 3, output = ["boom"]),
                   allocation(4, :ended; finished = t0 + Minute(2), exit_code = 0)]
    script = (; path = "/prod/config/startjlworkers.sh", text = "#!/bin/bash\nsrun julia\n")
    slurm = (; queue = "JOBID PARTITION NAME\n4711 debug julia-42-1\n", idle = "PARTITION AVAIL NODES\ndebug* up 3\n")
    overview(; slurm = nothing, script = script) = (; allocations, script,
                                                    workers = [(; pid = 2, host = "cslg4"), (; pid = 3, host = nothing)], slurm)
    snap = (; nworkers = 2, idle_deadline = DateTime(2026, 10, 15, 12, 4, 12))
    busy = [JuLeAna.BusyItem((2, "item", DataPeriod(2), DataRun(6), :process_dsp_cal, t0, false))]

    # a page that has read `ov`
    function loaded_page(ov = overview())
        page = JuLeAna.WorkersPage()
        JuLeAna.workers_visit!(page)
        (request,) = JuLeAna.take_requests!(page)
        JuLeAna.workers_result!(page, (; request, value = ov))
        return page
    end
    # keys applied to `page`, the commands sent
    function press!(page, keys...)
        sent = Any[]
        used = [JuLeAna.workers_key!(page, k, cmd -> push!(sent, cmd)) for k in keys]
        return sent, used
    end

    @testset "reading the overview" begin
        page = JuLeAna.WorkersPage()
        @test find_text(render_workers_page(page), "Reading the allocations…") !== nothing
        JuLeAna.workers_visit!(page; at = 100.0)
        JuLeAna.workers_visit!(page; at = 101.0)
        requests = JuLeAna.take_requests!(page)
        @test length(requests) == 1 && requests[1].kind === :overview && isempty(JuLeAna.take_requests!(page))
        # no new read while one is under way, even when the overview is stale
        JuLeAna.workers_stale!(page)
        JuLeAna.workers_visit!(page; at = 102.0)
        @test isempty(JuLeAna.take_requests!(page))
        JuLeAna.workers_result!(page, (; request = requests[1], value = overview()))
        @test !page.reading && page.overview == overview()
        # the stale mark queues a read at once, the age of the last read after five seconds
        JuLeAna.workers_visit!(page; at = 102.5)
        @test length(JuLeAna.take_requests!(page)) == 1
        JuLeAna.workers_result!(page, (; request = requests[1], value = overview()))
        JuLeAna.workers_visit!(page; at = 105.0)
        @test isempty(JuLeAna.take_requests!(page))
        JuLeAna.workers_visit!(page; at = 107.6)
        @test length(JuLeAna.take_requests!(page)) == 1
        # a failed read keeps the shown overview and shows the message
        JuLeAna.workers_result!(page, (; request = requests[1], error = "squeue failed"))
        @test page.overview == overview() && find_text(render_workers_page(page, snap), "squeue failed") !== nothing
        JuLeAna.workers_result!(page, (; request = requests[1], value = overview()))
        @test isnothing(page.error)
    end

    @testset "allocations" begin
        page = loaded_page()
        at = t0 + Minute(12) + Second(4)
        tb = render_workers_page(page, snap; at)
        text = workers_screen(tb)
        @test occursin("Allocations", text) && occursin("▶  1 slurm", text)
        @test occursin("julia-42-1 (4711,4712)", text) && occursin("00:12:04", text)
        @test occursin("ended after 00:03:00", text) && occursin("exit 3", text) && !occursin("exit 0", text)
        for (word, color) in (("running", :success), ("cancelled", :warning), ("failed", :error), ("ended    ", :text_dim))
            hit = find_text(tb, word)
            @test hit !== nothing && style_at(tb, hit.x, hit.y).fg == Tachikoma.tstyle(color).fg
        end
        # the output of the selected allocation, the newest line at the bottom
        @test occursin("Output of allocation 1", text)
        first_line, last_line = find_text(tb, "starting workers"), find_text(tb, "srun: job 4711 queued")
        @test first_line !== nothing && last_line !== nothing && last_line.y == first_line.y + 1
        @test find_text(tb, "boom") === nothing
        # moving the selection changes the output pane
        sent, used = press!(page, KeyEvent(:down), KeyEvent(:down))
        @test isempty(sent) && all(used)
        text = workers_screen(render_workers_page(page, snap))
        @test occursin("Output of allocation 3", text) && occursin("boom", text) && !occursin("starting workers", text)
        press!(page, KeyEvent(:down), KeyEvent(:down))
        @test JuLeAna.workers_selected_allocation(page).id == 4
        @test find_text(render_workers_page(page, snap), "No output.") !== nothing
        # an overview with other allocations keeps the selection on its allocation
        JuLeAna.workers_result!(page, (; request = (; kind = :overview), value = (; overview()..., allocations = allocations[2:end])))
        @test JuLeAna.workers_selected_allocation(page).id == 4
        @test find_text(render_workers_page(loaded_page((; overview()..., allocations = [])), snap), "No allocations") !== nothing
    end

    @testset "information line" begin
        page = loaded_page()
        text = row_text(render_workers_page(page, snap, busy), 1)
        @test occursin("workers 2, 1 busy", text) && occursin("idle cancel in 04:12", text)
        text = row_text(render_workers_page(page, (; nworkers = 0, idle_deadline = nothing)), 1)
        @test occursin("workers 0", text) && occursin("no idle cancel", text)
        # a deadline in the past counts down to zero
        @test occursin("idle cancel in 00:00",
                       row_text(render_workers_page(page, (; nworkers = 1, idle_deadline = DateTime(2026, 10, 15, 11))), 1))
    end

    @testset "workers and their output" begin
        page = loaded_page()
        tb = render_workers_page(page, snap, busy)
        text = workers_screen(tb)
        @test occursin("Workers", text) &&
              occursin("cslg4", text) &&
              occursin("busy dsp p02-r006  item  00:12:04", text) &&
              occursin("idle", text)
        hit = find_text(tb, "busy dsp")
        @test style_at(tb, hit.x, hit.y).fg == Tachikoma.tstyle(:accent).fg
        # the host of a new worker is not known yet
        @test occursin("3 …", text)
        abandoned = [JuLeAna.BusyItem((3, "item", DataPeriod(2), nothing, :p_process_energy_cal, t0, true))]
        @test occursin("busy energy p02  item  00:12:04 (abandoned)",
                       workers_screen(render_workers_page(page, snap, abandoned; width = 160)))
        # the lines relayed from the selected worker, without the prefix
        buf = JuLeAna.MessageBuffer()
        JuLeAna.append_output!(buf, :stdout,
                               "      From worker 2:\thello\n      From worker 3:\tother\n      From worker 2:\tWarning: careful\nhead line\n")
        tb = render_workers_page(page, snap, busy, buf)
        text = workers_screen(tb)
        @test occursin("Output of worker 2", text) && occursin("hello", text) && occursin("Warning: careful", text)
        @test !occursin("other", text) && !occursin("From worker", text) && !occursin("head line", text)
        hit = find_text(tb, "Warning: careful")
        @test style_at(tb, hit.x, hit.y).fg == Tachikoma.tstyle(:warning).fg
        # the second pane takes the arrow keys after Tab
        press!(page, KeyEvent(:tab), KeyEvent(:down))
        @test JuLeAna.workers_selected_worker(page).pid == 3 && JuLeAna.workers_selected_allocation(page).id == 1
        text = workers_screen(render_workers_page(page, snap, busy, buf))
        @test occursin("Output of worker 3", text) && occursin("other", text) && !occursin("hello", text)
        press!(page, KeyEvent(:tab))
        @test page.focus == 1
        # of the progress lines, only the newest one of each description is shown
        buf = JuLeAna.MessageBuffer()
        JuLeAna.append_output!(buf, :stdout,
                               "      From worker 3:\t[ Progress: Filekey: a 1/2\n" *
                               "      From worker 3:\tbetween\n" *
                               "      From worker 3:\t[ Progress: Filekey: b 1/1\n" *
                               "      From worker 3:\t[ Progress: Filekey: a 2/2\n")
        @test [e.text for e in JuLeAna.worker_output(buf, 3)] == ["between", "[ Progress: Filekey: b 1/1", "[ Progress: Filekey: a 2/2"]
        # a description that starts like another one is a progress bar of its own
        JuLeAna.append_output!(buf, :stdout, "      From worker 3:\t[ Progress: Filekey: a b 1/3\n")
        @test count(e -> startswith(e.text, "[ Progress: Filekey: a"), JuLeAna.worker_output(buf, 3)) == 2
        # the output of many workers pushes out neither the lines of another worker nor the other lines
        buf = JuLeAna.MessageBuffer(10; worker_capacity = 5)
        with_logger(() -> (@info "head message"), buf)
        JuLeAna.append_output!(buf, :stdout, "      From worker 3:\t[ Progress: Filekey: a 7/60\n")
        for pid in 4:20, i in 1:50
            JuLeAna.append_output!(buf, :stdout,
                                   "      From worker $pid:\t[ Progress: Filekey: f$pid $i/50\n      From worker $pid:\tline $i\n")
        end
        @test only(JuLeAna.worker_output(buf, 3)).text == "[ Progress: Filekey: a 7/60"
        @test occursin("head message", only(JuLeAna.message_lines(buf)))
        # each worker keeps its last `worker_capacity` lines, the progress line among them
        @test [e.text for e in JuLeAna.worker_output(buf, 20)] ==
              ["line 47", "line 48", "line 49", "[ Progress: Filekey: f20 50/50", "line 50"]
        @test isempty(JuLeAna.worker_output(buf, 99))
        # warnings and errors of a worker also go to the other lines and raise the alert
        JuLeAna.append_output!(buf, :stdout, "      From worker 5:\t┌ Error: fit failed\n")
        @test JuLeAna.message_lines(buf)[end] == "      From worker 5:\t┌ Error: fit failed"
        @test JuLeAna.worker_output(buf, 5)[end].text == "┌ Error: fit failed" && buf.alert.text == "fit failed"
        @test_throws "worker_capacity must be positive" JuLeAna.MessageBuffer(; worker_capacity = 0)
    end

    @testset "scrolling the output" begin
        lines = ["line $i" for i in 1:60]
        page = loaded_page((; overview()..., allocations = [allocation(1, :running; output = lines)]))
        text = workers_screen(render_workers_page(page, snap; height = 24))
        @test occursin("line 60", text) && !occursin("line 1\n", text)
        press!(page, KeyEvent(:pageup))
        text = workers_screen(render_workers_page(page, snap; height = 24))
        newest = 60 - page.alloc_out.height
        @test occursin("scrolled up", text) &&
              !occursin("line 60", text) &&
              occursin("line $newest", text) &&
              !occursin("line $(newest + 1)", text)
        press!(page, KeyEvent(:end_key))
        @test occursin("line 60", workers_screen(render_workers_page(page, snap; height = 24)))
        # many pages up stop at the first line
        for _ in 1:20
            press!(page, KeyEvent(:pageup))
        end
        text = workers_screen(render_workers_page(page, snap; height = 24))
        @test occursin("line 1\n", text * "\n") || occursin("line 1 ", text)
        @test page.alloc_back == 60 - page.alloc_out.height
        # the wheel scrolls the pane under the pointer
        press!(page, KeyEvent(:end_key))
        render_workers_page(page, snap; height = 24)
        wheel(x, y, button) = Tachikoma.MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false)
        out = page.alloc_out
        @test JuLeAna.workers_mouse!(page, wheel(out.x, out.y, Tachikoma.mouse_scroll_up)) && page.alloc_back == JuLeAna.WORKERS_WHEEL_LINES
        @test JuLeAna.workers_mouse!(page, wheel(out.x, out.y, Tachikoma.mouse_scroll_down)) && page.alloc_back == 0
        @test !JuLeAna.workers_mouse!(page, wheel(1, 1, Tachikoma.mouse_scroll_up))
    end

    @testset "wheel over the worker list and the worker output" begin
        wheel(x, y, button) = Tachikoma.MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false)
        many = [(; pid, host = "viper") for pid in 2:41]
        page = loaded_page((; overview()..., workers = many))
        press!(page, KeyEvent(:tab))
        render_workers_page(page, snap)
        # the wheel scrolls the list and keeps the selection
        list = page.worker_list
        @test JuLeAna.workers_mouse!(page, wheel(list.x, list.y, Tachikoma.mouse_scroll_down))
        @test page.worker_top == 1 + JuLeAna.WORKERS_WHEEL_LINES && JuLeAna.workers_selected_worker(page).pid == 2
        text = workers_screen(render_workers_page(page, snap))
        @test page.worker_top == 1 + JuLeAna.WORKERS_WHEEL_LINES && occursin("Output of worker 2", text)
        @test !occursin(r"▶ +2 ", text)
        # moving the selection with a key scrolls the list back to it
        press!(page, KeyEvent(:down))
        render_workers_page(page, snap)
        @test JuLeAna.workers_selected_worker(page).pid == 3 && page.worker_top == 2
        # the wheel over the allocations scrolls their list
        alist = page.alloc_list
        @test JuLeAna.workers_mouse!(page, wheel(alist.x, alist.y, Tachikoma.mouse_scroll_down)) && page.alloc_top > 1

        # scrolled-up output stays on its lines while new lines arrive
        buf = JuLeAna.MessageBuffer()
        JuLeAna.append_output!(buf, :stdout, join(("      From worker 3:\tline $i\n" for i in 1:60)))
        render_workers_page(page, snap, busy, buf)
        out = page.worker_out
        @test JuLeAna.workers_mouse!(page, wheel(out.x, out.y, Tachikoma.mouse_scroll_up))
        before = workers_screen(render_workers_page(page, snap, busy, buf))
        @test occursin("scrolled up $(JuLeAna.WORKERS_WHEEL_LINES)", before) && !occursin("line 60", before)
        JuLeAna.append_output!(buf, :stdout, join(("      From worker 3:\tnew $i\n" for i in 1:5)))
        after = workers_screen(render_workers_page(page, snap, busy, buf))
        @test page.worker_back == JuLeAna.WORKERS_WHEEL_LINES + 5 && !occursin("new", after)
        visible(text) = [m.match for m in eachmatch(r"line \d+", text)]
        @test visible(after) == visible(before)
        # End follows the newest line again
        press!(page, KeyEvent(:end_key))
        @test occursin("new 5", workers_screen(render_workers_page(page, snap, busy, buf)))
    end

    @testset "mouse selection" begin
        page = loaded_page()
        render_workers_page(page, snap, busy)
        click(x, y) = Tachikoma.MouseEvent(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false)
        list = page.alloc_list
        @test JuLeAna.workers_mouse!(page, click(list.x + 3, list.y + 1))
        @test JuLeAna.workers_selected_allocation(page).id == 2 && page.focus == 1
        @test !JuLeAna.workers_mouse!(page, click(list.x + 3, list.y + 10))
        list = page.worker_list
        @test JuLeAna.workers_mouse!(page, click(list.x + 3, list.y + 1))
        @test JuLeAna.workers_selected_worker(page).pid == 3 && page.focus == 2
    end

    @testset "SLURM pane" begin
        page = loaded_page()
        text = workers_screen(render_workers_page(page, snap))
        @test !occursin("SLURM", text)
        sent, used = press!(page, KeyEvent('s'))
        @test isempty(sent) && used == [false] && page.tab === :workers
        page = loaded_page(overview(; slurm))
        @test occursin("[Workers] │ SLURM", workers_screen(render_workers_page(page, snap)))
        sent, used = press!(page, KeyEvent('s'))
        @test used == [true] && isempty(sent)
        tb = render_workers_page(page, snap)
        text = workers_screen(tb)
        @test occursin("Workers │ [SLURM]", text) && occursin("4711 debug julia-42-1", text) && occursin("debug* up 3", text)
        @test !occursin("Output of worker", text) && occursin("Output of allocation 1", text)
        # the queue comes above the idle nodes
        @test find_text(tb, "4711 debug").y < find_text(tb, "debug* up 3").y
        press!(page, KeyEvent('s'))
        @test occursin("[Workers] │ SLURM", workers_screen(render_workers_page(page, snap)))
        # the pane falls back to the workers when the overview has no SLURM output
        press!(page, KeyEvent('s'))
        JuLeAna.workers_result!(page, (; request = (; kind = :overview), value = overview()))
        @test occursin("Output of worker", workers_screen(render_workers_page(page, snap)))
    end

    @testset "commands" begin
        page = loaded_page()
        sent, used = press!(page, KeyEvent('a'), KeyEvent('p'))
        @test all(used) && sent[1] isa AddWorkers && sent[2] isa PostponeIdleCancel
        # cancel of the selected allocation, asked first
        sent, used = press!(page, KeyEvent('c'))
        @test isempty(sent) && used == [true] && page.confirm === :cancel
        text = workers_screen(render_workers_page(page, snap))
        @test occursin("Cancel allocation 1?", text) && occursin("Items running on these workers fail.", text)
        sent, used = press!(page, KeyEvent('y'))
        @test used == [true] && length(sent) == 1 && sent[1] isa CancelAllocation && sent[1].id == 1 && isnothing(page.confirm)
        # any other key cancels the question, and is not used otherwise
        sent, used = press!(page, KeyEvent('c'), KeyEvent('n'))
        @test isempty(sent) && used == [true, true] && isnothing(page.confirm)
        sent, used = press!(page, KeyEvent('c'), KeyEvent(:escape), KeyEvent('y'))
        @test isempty(sent) && used == [true, true, false]
        # cancel of all
        sent, used = press!(page, KeyEvent('C'))
        @test isempty(sent) && page.confirm === :all
        @test occursin("Cancel all running allocations?", workers_screen(render_workers_page(page, snap)))
        sent, _ = press!(page, KeyEvent('y'))
        @test length(sent) == 1 && sent[1] isa CancelAll
        sent, _ = press!(page, KeyEvent('C'), KeyEvent('q'))
        @test isempty(sent)
        # a key release does not answer the question
        press!(page, KeyEvent('C'))
        sent, used = press!(page, KeyEvent('y', Tachikoma.key_release))
        @test isempty(sent) && used == [true] && page.confirm === :all
        press!(page, KeyEvent('n'))
        # only a running allocation can be cancelled
        press!(page, KeyEvent(:down))
        @test JuLeAna.workers_selected_allocation(page).state === :cancelled
        sent, used = press!(page, KeyEvent('c'))
        @test isempty(sent) && used == [false] && isnothing(page.confirm)
        # keys the page does not use
        sent, used = press!(page, KeyEvent('q'), KeyEvent('5'), KeyEvent('x'))
        @test isempty(sent) && used == [false, false, false]
        # the first read is not in yet: the commands that need no overview work, `c` waits for it
        fresh = JuLeAna.WorkersPage()
        sent, used = press!(fresh, KeyEvent('a'), KeyEvent('c'), KeyEvent('p'))
        @test used == [true, false, true] && length(sent) == 2
        # `r` marks the overview as stale
        page.read_at = 5.0
        press!(page, KeyEvent('r'))
        @test page.read_at == -Inf
    end

    @testset "start script editor" begin
        page = loaded_page()
        sent, used = press!(page, KeyEvent('e'))
        @test used == [true] && !isnothing(page.editor)
        tb = render_workers_page(page, snap)
        text = workers_screen(tb)
        @test occursin("Start script", text) &&
              occursin("#!/bin/bash", text) &&
              occursin("srun julia", text) &&
              !occursin("Allocations", text)
        # every key edits, including the keys of other pages; Ctrl-O saves the text
        sent, used = press!(page, KeyEvent('q'), KeyEvent('3'), KeyEvent(:ctrl, 'o'))
        @test used == [true, true, true] && isnothing(page.editor)
        @test length(sent) == 1 && sent[1] isa EditStartScript && sent[1].text == "q3#!/bin/bash\nsrun julia\n"
        # Escape closes without saving
        press!(page, KeyEvent('e'))
        sent, used = press!(page, KeyEvent('x'), KeyEvent(:escape))
        @test isempty(sent) && isnothing(page.editor)
        # the editor is not a script the page writes: key releases are swallowed, the mouse is ignored
        press!(page, KeyEvent('e'))
        sent, used = press!(page, KeyEvent('y', Tachikoma.key_release))
        @test used == [true] && isempty(sent) && !isnothing(page.editor)
        @test !JuLeAna.workers_mouse!(page, Tachikoma.MouseEvent(5, 5, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        press!(page, KeyEvent(:escape))
        # a script that could not be generated: the message replaces the editor
        page = loaded_page(overview(; script = "start_script!: no processing config is set"))
        sent, used = press!(page, KeyEvent('e'))
        @test used == [true] && isnothing(page.editor)
        @test occursin("no processing config is set", workers_screen(render_workers_page(page, snap)))
        sent, used = press!(page, KeyEvent('x'))
        @test used == [true] && isempty(sent) && isnothing(page.notice)
        # before the first read there is no script either
        fresh = JuLeAna.WorkersPage()
        press!(fresh, KeyEvent('e'))
        @test occursin("has not been read yet", workers_screen(render_workers_page(fresh, snap)))
    end

    @testset "SLURM options" begin
        flags = ["--time=01:00:00", "--mem-bind=local", "--nodes=1", "--mem=480GB"]
        @test JuLeAna.slurm_option(flags, "time") == "01:00:00" && isnothing(JuLeAna.slurm_option(flags, "partition"))
        # `--mem-bind` is not `--mem`
        @test JuLeAna.slurm_option(["--mem-bind=local"], "mem") === nothing
        @test JuLeAna.set_slurm_option(flags, "mem", "30GB") == ["--time=01:00:00", "--mem-bind=local", "--nodes=1", "--mem=30GB"]
        @test JuLeAna.set_slurm_option(flags, "partition", "interactive")[end] == "--partition=interactive"
        @test JuLeAna.set_slurm_option(flags, "nodes", "") == ["--time=01:00:00", "--mem-bind=local", "--mem=480GB"]
        @test JuLeAna.set_slurm_option(flags, "partition", "") == flags
        @test_throws "time limit: expected minutes, hh:mm:ss or d-hh:mm:ss, got `1h`" JuLeAna.set_slurm_option(flags, "time", "1h")
        @test_throws "nodes: expected a positive integer, got `0`" JuLeAna.set_slurm_option(flags, "nodes", "0")
        @test_throws "the flag `-N4` sets nodes" JuLeAna.set_slurm_option(["-N4"], "nodes", "2")
        @test_throws "the flag `--nodes` sets nodes" JuLeAna.set_slurm_option(["--nodes", "4"], "nodes", "2")
        @test JuLeAna.set_slurm_option(flags, "time", "2-00:00:00")[1] == "--time=2-00:00:00"
    end

    @testset "SLURM form" begin
        settings = (; local_n = 4, local_julia_settings = String[], slurm_flags = ["--time=01:00:00", "--cpu-bind=cores", "--nodes=1"],
                    slurm_julia_settings = String[])
        fsnap = (; snap..., runmode_settings = settings)
        page = loaded_page()
        sent = Any[]
        press(keys...) = [JuLeAna.workers_key!(page, k isa Char ? KeyEvent(k) : KeyEvent(k), cmd -> push!(sent, cmd); snap = fsnap)
                          for k in keys]
        # without the run mode settings the form does not open
        @test !JuLeAna.workers_key!(page, KeyEvent('o'), cmd -> push!(sent, cmd); snap = (; snap..., runmode_settings = nothing))
        @test press('o') == [true] && page.form isa JuLeAna.SlurmForm
        @test !JuLeAna.workers_mouse!(page, Tachikoma.MouseEvent(5, 5, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        tb = render_workers_page(page, fsnap)
        @test find_text(tb, "SLURM settings (this session)") !== nothing
        @test find_text(tb, "not set") !== nothing && find_text(tb, "01:00:00") !== nothing
        @test find_text(tb, "other flags: --cpu-bind=cores") !== nothing
        # every key goes to the form, also the page keys
        press(:down, :enter, 'a')
        @test isempty(sent) && page.form.text == "01:00:00a"
        press(:enter)
        @test isempty(sent) && occursin("time limit: expected", page.form.error)
        @test find_text(render_workers_page(page, fsnap), "time limit: expected") !== nothing
        press(:backspace, :backspace, :backspace, :backspace, :backspace, :backspace, :backspace, :backspace, :backspace, '9', '0', :enter)
        @test only(sent) isa SetRunmodeSettings && only(sent).slurm_flags == ["--time=90", "--cpu-bind=cores", "--nodes=1"]
        @test isnothing(page.form.text) && isnothing(page.form.error)
        # an empty value removes the option, Escape drops a typed text and then closes the form
        empty!(sent)
        press(:down, :enter, :backspace, :enter)
        @test only(sent).slurm_flags == ["--time=01:00:00", "--cpu-bind=cores"]
        press(:enter, '7', :escape)
        @test length(sent) == 1 && isnothing(page.form.text)
        press(:escape)
        @test isnothing(page.form)
    end

    @testset "small areas" begin
        page = loaded_page()
        @test render_workers_page(page, snap; width = 10, height = 4) isa TestBackend
        @test render_workers_page(page, snap; width = 40, height = 8) isa TestBackend
    end
end
