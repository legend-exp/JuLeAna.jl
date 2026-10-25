# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Compile the terminal interface when the package is precompiled, so that its first frame
# and the first keys, mouse events and task results of a session appear without compiling
# the drawing and event code: draw the startup screen, every page and the key help of an
# interface without a session, then draw every page of an interface with made-up session
# data while key, mouse and task events go through `Tachikoma.update!`, and run the interface
# loop of `run_tui` without a terminal. Nothing reads data or writes files, and no task
# outlives the workload: the command channel is closed, so no event may send a command, and
# the pages are marked as read and the state read as under way, so that no event queues a
# background read.
@setup_workload begin
    # the interface logs on its first frame; nothing is printed while precompiling
    @compile_workload Logging.with_logger(Logging.NullLogger()) do
        ctrl = DataflowController(Dict{String,Any}("config" => nothing); loader = nothing)
        m = JuLeAnaTUI(ctrl; splash_seconds = 0.0)
        # ends the task that runs the commands of the interface
        close(m.commands)
        m.snap = snapshot(ctrl)
        tb = Tachikoma.TestBackend(140, 40)
        frame() = Tachikoma.view(m,
                                 Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 40), Tachikoma.GraphicsRegion[],
                                                 Tachikoma.PixelSnapshot[]))
        m.splash = true
        frame()
        m.splash = false
        # pages are set directly: key events would start the background reads of the pages
        for page in eachindex(TUI_PAGES)
            m.page = page
            frame()
        end
        m.help = true
        frame()
        m.help = false

        # made-up session: periods with runs, processors, a running run with items, messages
        t0 = now(UTC)
        p2, p3, r0 = DataPeriod(2), DataPeriod(3), DataRun(0)
        runs2 = DataRun.(6:8)
        processor(name, level, category, rank, deps; enabled = true, kwargs = Dict{Symbol,Any}()) = (; name, level, category, rank, enabled,
                                                                                                     selected = enabled,
                                                                                                     dependencies = deps, kwargs,
                                                                                                     config_kwargs = copy(kwargs),
                                                                                                     accepted = [:max_wvfs, :channels],
                                                                                                     overridden = Symbol[],
                                                                                                     log_level = Logging.Info,
                                                                                                     plot_level = :info,
                                                                                                     config_log_level = Logging.Info,
                                                                                                     config_plot_level = :info)
        processors = [processor(:process_dsp_cal, :run, :cal, 1, Symbol[]),
                      processor(:process_energy_calibration_cal, :run, :cal, 2, [:process_dsp_cal];
                                kwargs = Dict{Symbol,Any}(:max_wvfs => 10)),
                      processor(:process_hit_phy, :run, :phy, 3, [:process_dsp_cal]; enabled = false),
                      processor(:p_process_aoe_cut_cal, :partition, :cal, 1, [:process_energy_calibration_cal])]
        # an empty log folder: the interface timing writes no file when its window ends
        snap = convert(ControllerSnapshot,
                       (; state = :running, outcome = nothing, last_error = nothing, started = t0 - Second(90), finished = nothing,
                        config_file = "config/processing_config.yaml", log_path = "", dataset = "default", available_periods = [p2, p3],
                        available_runs = Dict(p2 => runs2, p3 => [r0]), periods = [p2, p3], runs = nothing,
                        run_steps = [:process_dsp_cal, :process_energy_calibration_cal], partition_steps = [:p_process_aoe_cut_cal],
                        processors, reprocess = nothing, processor_log_level = nothing, processor_plot_level = nothing,
                        analysis_runs_only = true, runmode = :local,
                        runmode_settings = (; local_n = 2, local_julia_settings = String[], slurm_flags = ["--nodes=1"],
                                            slurm_julia_settings = String[]), check_dependencies = true, nworkers = 2, allocations = [],
                        idle_deadline = t0 + Second(900)))

        done_key, run_key, wait_key, part_key = (p2, runs2[1], :process_dsp_cal), (p2, runs2[1], :process_energy_calibration_cal),
                                                (p2, runs2[2], :process_dsp_cal), (p2, nothing, :p_process_aoe_cut_cal)
        failed_key = (p3, r0, :process_dsp_cal)
        store = ProgressStore()
        reset_progress!(store, [done_key, run_key, wait_key, part_key, failed_key])
        set_step_state!(store, done_key, :running)
        set_step_state!(store, done_key, :done)
        set_step_state!(store, failed_key, :running)
        set_step_state!(store, failed_key, :failed; error = "boom")
        set_step_state!(store, run_key, :running)
        id = items_queued!(store, run_key, 10)
        item_started!(store, run_key, id, 1, "fk0")
        item_started!(store, run_key, id + 1, 1, "fk1")
        item_finished!(store, run_key, id, :done)
        item_finished!(store, run_key, id + 1, :failed)
        item_started!(store, run_key, id + 2, 2, "fk2")
        for (level, text) in ((Logging.Info, "Processing fk0"), (Logging.Warn, "Fit did not converge\n  channel = V02"),
                              (Logging.Error, "Processing fk1 failed"))
            step_message!(store, run_key, level, text)
        end
        Logging.with_logger(m.messages) do
            @info "Loaded session" periods = 2
            @warn "Fit did not converge" channel = "V02"
            @error "Processing failed" exception = (ErrorException("boom"), [])
            @debug "dropped"
        end
        append_output!(m.messages, :stdout, "output line\nWarning: from a worker\n")
        m.snap = snap
        m.progress, m.busy = progress(store), busy_workers(store)
        sync_setup!(m.setup, snap)
        m.setup.dataset_requested = true
        m.setup.choices_key = (current_production(), false, production_root(m.setup))

        # page data, delivered as the background reads answer
        index_row(process, period, run, state; level = :run) = (; process, level, category = :cal, period, run,
                                                                path = "/jlrep/$process-$period-$run.md", state, date = t0, n_entries = 0,
                                                                n_failed = 0, n_warnings = 0, failures = Tuple{String,String}[])
        rows = [index_row(:process_dsp_cal, "p02", "r006", :ok), index_row(:process_dsp_cal, "p02", "r007", :failed),
                index_row(:process_energy_calibration_cal, "p02", "r006", :warning),
                index_row(:p_process_aoe_cut_cal, "p02", nothing, :missing; level = :partition)]
        step(process, level, period, run, outcome) = (; process, level, category = :cal, period, run, outcome, started = t0, finished = t0,
                                                      done = 0, failed = 0, notrun = 0)
        grid = history_grid([(; name = p.name, p.level, p.category) for p in processors], [p2 => runs2, p3 => [r0]],
                            [(; name = "dsp_cal", level = :run, category = "cal",
                              reports = [(; period = "p02", run = "r006", path = "/jlrep/dsp.md", state = :ok, date = t0),
                                         (; period = "p02", run = "r007", path = "/jlrep/dsp7.md", state = :failed, date = t0)])],
                            [(; started = t0, finished = t0, user = "u", host = "h", outcome = :failed, log_path = "/log/a",
                              steps = [step(:process_dsp_cal, :run, p2, runs2[2], :failed), step(:process_dsp_cal, :run, p3, r0, :stopped),
                                       step(:p_process_aoe_cut_cal, :partition, p3, nothing, :cancelled)])])
        allocation(id, state, backend; output = String[]) = (; id, backend, job_name = "julia-$id", started = t0, finished = nothing, state,
                                                             exit_code = nothing, job_ids = ["4711"], output)
        overview = convert(WorkersOverview,
                           (;
                            allocations = [allocation(1, :running, :slurm; output = ["starting workers"]), allocation(2, :failed, :local)],
                            script = (; path = "/prod/config/startjlworkers.sh", text = "#!/bin/bash\nsrun julia\n"),
                            workers = [(; pid = 2, host = "cslg4"), (; pid = 3, host = nothing)],
                            slurm = (; queue = "JOBID NAME\n4711 julia-1\n", idle = "debug up\n")))
        report_text = "# Report\n\n## Summary\n\n| detector | status |\n|---|---|\n| V00 | ok |\n| V01 | failed |\n\n```\nfit failed\n```\n"
        m.reports_page.source = :run

        # An event is delivered as the interface loop does, followed by a frame. The pages stay
        # marked as read and the state read stays under way, so that no event starts a background task.
        deliver!(evt) = begin
            Tachikoma.update!(m, evt)
            m.refreshing = true
            m.workers_page.read_at = Inf
            frame()
            return nothing
        end
        m.page = 6
        reports_visit!(m.reports_page, snap)
        deliver!(Tachikoma.TaskEvent(:reports, (; request = only(take_requests!(m.reports_page)), value = rows, history = nothing)))
        m.page = 7
        history_visit!(m.history_page, snap)
        deliver!(Tachikoma.TaskEvent(:history, (; request = only(take_requests!(m.history_page)), value = grid)))
        m.page = 3
        m.workers_page.read_at = -Inf
        workers_visit!(m.workers_page)
        deliver!(Tachikoma.TaskEvent(:workers, (; request = only(take_requests!(m.workers_page)), value = overview)))
        m.page = 1
        deliver!(Tachikoma.TaskEvent(:tick, nothing))
        deliver!(Tachikoma.TaskEvent(:refresh,
                                     (0, snap, m.progress, m.busy, StepMessages((; key = nothing, messages = StepMessage[])), String[])))
        deliver!(Tachikoma.TaskEvent(:dataset,
                                     Dict((p2, runs2[1]) =>
                                              [(; category = :cal, nkeys = 3, livetime = 100.0, start = t0, analysis = true),
                                               (; category = :phy, nkeys = 1, livetime = NaN, start = nothing, analysis = false)])))
        deliver!(Tachikoma.TaskEvent(:dataset, "no runinfo"))

        press(keys...) = foreach(k -> deliver!(Tachikoma.KeyEvent(k)), keys)
        mouse(x, y, button, action) = deliver!(Tachikoma.MouseEvent(x, y, button, action, false, false, false))
        # Keys that send controller commands go straight to the page with a sender that drops them.
        drop = Returns(nothing)
        navigation = (:down, :down, :up, :pagedown, :pageup, :end_key, :home, :left, :right, :tab, :backtab, :down)
        for p in eachindex(TUI_PAGES)
            m.page = p
            press(navigation...)
            deliver!(Tachikoma.KeyEvent(:down, Tachikoma.key_release))
            deliver!(Tachikoma.KeyEvent('j', Tachikoma.key_release))
            press('j', 'k')
            m.help = true
            press('?')
            m.help = false
        end

        # Setup: filter, kwargs editor, write confirmation, options pane
        m.page = 1
        press('/', 'a', 'b', :backspace, :enter, '/', 'x', :escape, :tab, :down, 'e', :down, :down, :down, :enter, '1', :backspace, :escape,
              :escape, :tab, 'w', 'n', :tab, :down, :up, :tab)
        # Enter on a level row of the editor sends a command
        kwargs_key!(KwargsEditor(:process_dsp_cal), Tachikoma.KeyEvent(:enter), snap, drop)
        setup_key!(m.setup, Tachikoma.KeyEvent(' '), snap, drop)
        setup_key!(m.setup, Tachikoma.KeyEvent(:enter), snap, drop)
        for k in ('c', 'p', 'd', 's', 'x', 'X', 'r', 'g', 'W')
            setup_key!(m.setup, Tachikoma.KeyEvent(k), snap, drop)
        end
        m.setup.focus = 4
        setup_key!(m.setup, Tachikoma.KeyEvent(:enter), snap, drop)
        deliver!(Tachikoma.TaskEvent(:choices,
                                     (m.setup.choices_key, (; productions = ["prod-a", "prod-b"], datasets = ["default", "valid"]))))
        m.setup.focus = 5
        press(:enter, '1', :backspace, :tab, :escape, :down, :up, :down, :enter, :down, :escape)
        m.setup.source = 3
        press(:enter, :down)
        frame()
        setup_key!(m.setup, Tachikoma.KeyEvent(:enter), snap, drop)
        deliver!(Tachikoma.TaskEvent(:choices, (m.setup.choices_key, "no data production")))
        frame()
        m.setup.source = 1
        m.setup.focus = 1
        press(:tab, :tab, :tab)
        frame()

        # Graph
        m.page = 2
        press('h', 'h', 'v', 'v', :down, :down)
        graph_key!(m.graph_page, Tachikoma.KeyEvent(' '), snap, drop)
        graph_key!(m.graph_page, Tachikoma.KeyEvent('d'), snap, drop)
        frame()

        # Workers: SLURM text, cancel questions, start script editor
        m.page = 3
        press('s', :down, 's', :tab, :down, :pageup, :pagedown, :end_key, :tab, 'c', 'n', 'C', 'n', 'e', 'x', :backspace, :down, :escape)
        workers_key!(m.workers_page, Tachikoma.KeyEvent('a'), drop)
        workers_key!(m.workers_page, Tachikoma.KeyEvent('p'), drop)

        # Progress: fold, open a step with its messages, scroll them
        m.page = 4
        press(:home, :enter, :enter, :down, :down, :down, :down, :enter)
        deliver!(Tachikoma.TaskEvent(:refresh,
                                     (0, snap, m.progress, m.busy,
                                      StepMessages((; key = m.progress_page.open, messages = step_messages(store, run_key))), String[])))
        press(:down, :pagedown, :pageup, :end_key, 'f', :up, :escape, 'f', :right, :left)
        m.progress_page.open = run_key
        deliver!(Tachikoma.TaskEvent(:refresh,
                                     (0, snap, m.progress, m.busy,
                                      StepMessages((; key = run_key, messages = step_messages(store, run_key))), String[])))
        press(:down, :pagedown, :pageup, :end_key, 'f', :up, :escape)

        # Log: level, filter, follow
        m.page = 5
        press('l', 'l', 'l', 'l', '/', 'e', 'r', :backspace, :enter, :up, :pageup, :home, 'f', :end_key, '/', 'f', :escape)

        # Reports: groups, failures pane, report viewer
        m.page = 6
        press(:home, :enter, :enter, :down, :right, :left, :tab, :down, :up, :tab)
        path = "/jlrep/process_dsp_cal-p02-r006.md"
        open_report!(m.reports_page, path)
        deliver!(Tachikoma.TaskEvent(:reports,
                                     (; request = only(take_requests!(m.reports_page)), value = report_viewer(path, report_text))))
        press(:down, :pagedown, :pageup, :end_key, :home, 'x')
        deliver!(Tachikoma.KeyEvent(:down, Tachikoma.key_release))
        press('q')

        # History: cursor, report viewer
        m.page = 7
        press(:right, :right, :down, :down, :left, :up, :end_key, :home, :pagedown, :pageup, 'x')
        open_report!(m.history_page, path)
        deliver!(Tachikoma.TaskEvent(:history,
                                     (; request = only(take_requests!(m.history_page)), value = report_viewer(path, report_text))))
        press(:down, :pagedown, :pageup, :end_key, :home)
        press(:escape)

        # Mouse: clicks on the tabs, then wheel, clicks and movement over the content of each page
        for x in 3:6:70
            mouse(x, 3, Tachikoma.mouse_left, Tachikoma.mouse_press)
            mouse(x, 3, Tachikoma.mouse_left, Tachikoma.mouse_release)
        end
        for p in eachindex(TUI_PAGES), x in (12, 50, 100), y in (8, 16, 26)
            m.page = p
            mouse(x, y, Tachikoma.mouse_scroll_down, Tachikoma.mouse_press)
            mouse(x, y, Tachikoma.mouse_scroll_up, Tachikoma.mouse_press)
            mouse(x, y, Tachikoma.mouse_none, Tachikoma.mouse_move)
            mouse(x, y, Tachikoma.mouse_left, Tachikoma.mouse_release)
            mouse(x, y, Tachikoma.mouse_right, Tachikoma.mouse_press)
            if p == 1
                setup_mouse!(m.setup, Tachikoma.MouseEvent(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false), snap,
                             drop)
            else
                mouse(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press)
            end
        end
        # the viewers of the Reports and History pages get the wheel
        for (page, tag) in ((m.reports_page, :reports), (m.history_page, :history))
            m.page = tag === :reports ? 6 : 7
            open_report!(page, path)
            deliver!(Tachikoma.TaskEvent(tag, (; request = only(take_requests!(page)), value = report_viewer(path, report_text))))
            for y in (8, 20)
                mouse(70, y, Tachikoma.mouse_scroll_down, Tachikoma.mouse_press)
                mouse(70, y, Tachikoma.mouse_scroll_up, Tachikoma.mouse_press)
                mouse(139, y, Tachikoma.mouse_left, Tachikoma.mouse_press)
                mouse(139, y, Tachikoma.mouse_left, Tachikoma.mouse_release)
            end
            press(:escape)
        end

        # Quit dialog, key help and the main keys
        m.page = 2
        press('q')
        mouse(70, 20, Tachikoma.mouse_left, Tachikoma.mouse_press)
        press('x', 'c')
        deliver!(Tachikoma.KeyEvent(:ctrl_c))
        press(:escape)
        press('?')
        mouse(70, 20, Tachikoma.mouse_left, Tachikoma.mouse_press)
        press(:escape)
        for p in eachindex(TUI_PAGES)
            press(Char('0' + p))
        end

        # New-production form: editing, rows, phases of the creation
        m.page = 1
        press('N')
        press('a', 'b', :backspace, :enter, 'c', :down, :up, :tab, :tab, :tab, :tab, ' ', :down, ' ', :tab, :backtab, :down, :down)
        deliver!(Tachikoma.KeyEvent('a', Tachikoma.key_release))
        for k in ('n', 'd')
            deliver!(Tachikoma.KeyEvent(:ctrl, k))
        end
        press(:delete)
        m.production.cursor = 1
        press(:enter)
        m.production.phase = :creating
        deliver!(Tachikoma.TaskEvent(:refresh,
                                     (0, snap, m.progress, m.busy, StepMessages((; key = nothing, messages = StepMessage[])), ["creating"])))
        press('a')
        m.production.phase = :done
        frame()
        press('a')
        press('N', :escape)

        # answers to commands
        m.page = 1
        m.pending = 2
        deliver!(Tachikoma.TaskEvent(:command, nothing))
        deliver!(Tachikoma.TaskEvent(:command, ErrorException("rejected")))
        m.workers_page.read_at = Inf
        m.page = 3
        deliver!(Tachikoma.TaskEvent(:tick, nothing))
        m.quit = false

        # The interface loop of `run_tui` on a new interface, without a terminal: frames go to a buffer, keys
        # come from a stream and the size is fixed. Escape is not scripted because the key reader drops it in
        # the first second. Ctrl-C ends the loop after a timer tick; the last timer ends it if the key is lost.
        let m = JuLeAnaTUI(DataflowController(Dict{String,Any}("config" => nothing); loader = nothing), MessageBuffer();
                           splash_seconds = 0.0)
            input = Base.BufferStream()
            write(input, "ab\e[A\e[B\e[C\e[D\t\e[Z\e[<0;10;3M\e[<0;10;3m\e[<64;60;20M")
            timers = [Timer(_ -> write(input, "\x03"), 0.7), Timer(_ -> (m.quit = true), 5)]
            try
                run_app(m, m.messages; theme = NIGHT_OWL_THEME, io = IOBuffer(), input, tty_size = (rows = 40, cols = 140))
            finally
                foreach(close, timers)
                close(input)
            end
            # the cancelled tick timer of the interface ends its last sleep
            timedwait(() -> m.queue.active[] == 0, 5; pollint = 0.05)
        end
        return nothing
    end
end
