# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "juleana-sync app" begin
    h = LocalHost()
    term = Tachikoma.Terminal(; io = IOBuffer(), size = (rows = 24, cols = 80), external_size = true)
    picker_options() = Options("local", FIXTURE_ROOT, mktempdir(), nothing, "", "", nothing, false, false)

    function app_for(; dirty = false, out = joinpath(mktempdir(), "sel.yaml"))
        local_root = mktempdir()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        app = SyncApp(SyncPage(h, p, Options("local", FIXTURE_ROOT, local_root, nothing, "test", out, nothing, false, false)))
        dirty && (app.page.dirty = true)
        return app
    end

    @testset "the page leaves q, ?, T and digits to its host unless a field or a dialog waits for them" begin
        page = app_for().page
        for key in (KeyEvent('q'), KeyEvent(:ctrl_c), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
            @test !sync_key!(page, key)
        end
        # While a dialog waits for an answer the page takes every key but Ctrl-C.
        page.modal = Tachikoma.Modal(title = "Estimate", message = "", confirm_label = "Sync", cancel_label = "Close")
        page.modal_kind = :estimate
        for key in (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
            @test sync_key!(page, key)
        end
        @test !sync_key!(page, KeyEvent(:ctrl_c))
        page.modal, page.modal_kind = nothing, :none
        # While work runs nothing waits for an answer, so the host keys reach the host.
        for kind in (:checking, :estimating, :transfer, :busy), key in (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
            page.modal_kind = kind
            @test !sync_key!(page, key)
        end
        page.modal_kind = :none
        @test sync_key!(page, KeyEvent(:down)) && sync_key!(page, KeyEvent(' ')) && sync_dirty(page) && !sync_busy(page)
        page.modal_kind = :firstn   # the prompt owns the keyboard
        page.input = Tachikoma.TextInput(label = "N: ", text = "")
        @test sync_text_input(page) && sync_key!(page, KeyEvent('3')) && sync_key!(page, KeyEvent('q'))
    end

    @testset "T switches the theme, keeps it and says when it cannot be kept; the top row shows the name and version" begin
        previous = Tachikoma.theme()
        depot = mktempdir()
        pushfirst!(DEPOT_PATH, depot)
        try
            app = app_for()
            Tachikoma.set_theme!(Sync.tui_theme("night-owl"))
            @test_logs (:info, "Theme: juleana") update!(app, KeyEvent('T'))
            @test Tachikoma.theme().name == "juleana" && read(joinpath(depot, "prefs", "JuLeAna", "theme"), String) == "juleana" &&
                  app.page.status == ""
            rm(joinpath(depot, "prefs"); recursive = true)
            write(joinpath(depot, "prefs"), "")   # `prefs` is a file, so nothing can be saved below it: the theme still switches
            @test_logs (:warn, r"Could not save the theme") (:info, r"Theme: ") update!(app, KeyEvent('T'))
            @test Tachikoma.theme().name != "juleana" && occursin("could not save the theme", app.page.status)
        finally
            popfirst!(DEPOT_PATH)
            Tachikoma.set_theme!(previous)
        end
        app = app_for()
        app.page.panel_open = true
        tb = draw(app; width = 100, height = 30)
        row = rstrip(row_text(tb, 1))
        @test endswith(row, "JuLeAna v$(pkgversion(parentmodule(Sync)))") && textwidth(row) == 100 && occursin("Settings", row_text(tb, 2))
        @test find_text(draw(app; width = 10, height = 30), "JuLeAna") === nothing
    end

    @testset "q quits a clean app and asks about unsaved marks" begin
        for key in (KeyEvent('q'), KeyEvent(:ctrl_c))
            clean = app_for()
            update!(clean, key)
            @test should_quit(clean)
            dirty = app_for(; dirty = true)
            update!(dirty, key)
            @test !should_quit(dirty) && dirty.dialog_kind == :unsaved && find_text(draw(dirty), "Save the selection to") !== nothing
        end
        saved = app_for(; dirty = true)
        update!(saved, KeyEvent('q'))
        update!(saved, KeyEvent(:enter))   # the dialog opens on "Save and quit"
        @test should_quit(saved) && isfile(saved.page.options.out)
        # A failing save keeps the app open with its error in the page's dialog; the marks stay.
        blocked_app = app_for(; dirty = true, out = joinpath(touch(joinpath(mktempdir(), "file")), "sel.yaml"))
        update!(blocked_app, KeyEvent('q'))
        update!(blocked_app, KeyEvent(:enter))
        @test !should_quit(blocked_app) && blocked_app.dialog === nothing && blocked_app.page.modal_kind == :error && blocked_app.page.dirty
        discarded = app_for(; dirty = true)
        update!(discarded, KeyEvent('q'))
        update!(discarded, KeyEvent(:right))   # the second button is "Quit without saving"
        update!(discarded, KeyEvent(:enter))
        @test should_quit(discarded) && !isfile(discarded.page.options.out)
        kept = app_for(; dirty = true)
        update!(kept, KeyEvent('q'))
        update!(kept, KeyEvent(:escape))   # Escape keeps the app open and saves nothing
        @test !should_quit(kept) && kept.dialog === nothing && kept.dialog_kind == :none && kept.page.dirty &&
              !isfile(kept.page.options.out)

        # The dialog names the file that Save writes, also after the selection path was edited.
        named = app_for(; dirty = true)
        edited = joinpath(mktempdir(), "edited.yaml")
        change_setting!(named.page, :selection, edited)
        change_setting!(named.page, :jobs, "x")   # another field is invalid: the options stay as they were
        update!(named, KeyEvent('q'))
        @test named.dialog_kind == :unsaved && occursin(edited, named.dialog.message)
        update!(named, KeyEvent(:enter))
        @test isfile(edited)
    end

    @testset "a running transfer asks before quitting" begin
        app = app_for()
        app.page.modal_kind = :transfer
        update!(app, KeyEvent('q'))
        @test !should_quit(app) && app.dialog_kind == :busy
        update!(app, KeyEvent(:escape))
        update!(app, KeyEvent(:ctrl_c))
        @test !should_quit(app) && app.dialog_kind == :busy
        update!(app, KeyEvent(:escape))   # "Keep running" is the default
        @test app.dialog === nothing && !should_quit(app)
        update!(app, KeyEvent(:ctrl_c))
        update!(app, KeyEvent(:left))
        update!(app, KeyEvent(:enter))
        @test should_quit(app)
    end

    @testset "task events: sync ones reach the page, others and faults are an error dialog" begin
        app = app_for()
        app.page.running += 1   # a result needs a task that runs
        update!(app, TaskEvent(Symbol("sync:productions"), ["a", "b"]))
        @test app.page.productions == ["a", "b"] && app.page.running == 0
        update!(app, TaskEvent(:tick, nothing))
        @test_throws "unexpected background result :other" update!(app, TaskEvent(:other, nothing))
        @test !sync_task!(app.page, TaskEvent(:other, nothing)) && task_queue(app) === app.page.tasks
        app.page.running += 1
        @test sync_task!(app.page, TaskEvent(Symbol("sync:nothing_here"), nothing))
        @test app.page.modal_kind == :error && occursin("unexpected background result :nothing_here", app.page.modal.message)
        app.page.modal, app.page.modal_kind = nothing, :none
        # A result without a running task is a task id mix-up and is reported, never clamped.
        @test sync_task!(app.page, TaskEvent(Symbol("sync:productions"), String[]))
        @test app.page.modal_kind == :error && occursin("task id was mixed up", app.page.modal.message) && app.page.running == 0
        app.page.modal, app.page.modal_kind = nothing, :none

        @test Sync.shielded(() -> error("boom in a handler"), app.page, true)
        @test app.page.modal_kind == :error && occursin("boom in a handler", app.page.modal.message) && !should_quit(app)
        update!(app, KeyEvent(:enter))   # closes the dialog; the app still answers keys
        update!(app, KeyEvent('q'))
        @test should_quit(app)
        app.page.modal_kind = :transfer   # during a transfer the dialog stays and the fault is appended to the status line
        app.page.modal = Tachikoma.Modal(title = "Transferring", message = "starting…", confirm_label = "", cancel_label = "")
        app.page.status = "copying"
        @test Sync.shielded(() -> error("late fault"), app.page, true)
        @test app.page.modal_kind == :transfer && app.page.modal.title == "Transferring" && app.page.status == "copying; late fault"
        @test_throws InterruptException Sync.shielded(() -> throw(InterruptException()), app.page, true)
    end

    @testset "the app connects and lists on start, quits with q, and keeps its own work counter" begin
        app = SyncApp(SyncPage(h, picker_options()))
        init!(app, term)
        @test app.timer !== nothing && app.page.running == 1
        cleanup!(app)   # the tick timer keeps the queue active
        settle!(app)
        @test app.page.productions !== nothing && app.page.picker !== nothing && app.timer === nothing
        sync_start!(app.page)   # the listing starts once
        @test app.page.running == 0
        app.queue.active[] += 1   # another component's task on the shared queue
        update!(app, KeyEvent(:down))
        update!(app, KeyEvent(:enter))   # still opens the production
        @test app.page.running == 1
        app.queue.active[] -= 1
        settle!(app)
        update!(app, KeyEvent('q'))
        @test should_quit(app)
        picker = SyncApp(SyncPage(h, picker_options()))
        update!(picker, KeyEvent(:ctrl_c))
        @test should_quit(picker)

        settings = SyncSettings(; host = "local", remote_root = FIXTURE_ROOT, production = "test", local_root = mktempdir())
        connected = SyncApp(SyncPage(settings, TaskQueue(); host_factory = _ -> h))
        @test connected.timer === nothing
        Sync.start!(connected)
        @test connected.timer !== nothing
        sync_start!(connected.page)
        @test connected.page.running == 1
        Sync.stop!(connected)
        @test connected.timer === nothing
        settle!(connected)
        @test connected.page.running == 0 && connected.page.production.name == "test"
    end
end
