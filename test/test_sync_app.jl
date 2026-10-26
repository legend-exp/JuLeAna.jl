# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "app.jl" begin
    h = LocalHost()
    term = Tachikoma.Terminal(; io = IOBuffer(), size = (rows = 24, cols = 80), external_size = true)

    function app_for(; dirty = false, out = joinpath(mktempdir(), "sel.yaml"))
        local_root = mktempdir()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test", out, nothing, false, false)
        app = SyncApp(SyncPage(h, p, options))
        dirty && (app.page.dirty = true)
        return app
    end

    @testset "the page leaves the host keys to its host" begin
        page = app_for().page
        for key in (KeyEvent('q'), KeyEvent(:ctrl_c), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
            @test !sync_key!(page, key)
        end
        # While a dialog is open the page takes every key but Ctrl-C.
        page.modal_kind = :estimating
        for key in (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
            @test sync_key!(page, key)
        end
        @test !sync_key!(page, KeyEvent(:ctrl_c))
        page.modal_kind = :none
        @test sync_key!(page, KeyEvent(:down))
        @test sync_key!(page, KeyEvent(' '))
        @test sync_dirty(page) && !sync_busy(page)
        page.modal_kind = :firstn      # the prompt owns the keyboard
        page.input = Tachikoma.TextInput(label = "N: ", text = "")
        @test sync_text_input(page) && sync_key!(page, KeyEvent('3')) && sync_key!(page, KeyEvent('q'))
    end

    @testset "q quits a clean app and asks about unsaved marks" begin
        app = app_for()
        update!(app, KeyEvent('q'))
        @test should_quit(app)
        clean = app_for()
        update!(clean, KeyEvent(:ctrl_c))
        @test should_quit(clean)

        for key in (KeyEvent('q'), KeyEvent(:ctrl_c))
            dirty = app_for(; dirty = true)
            update!(dirty, key)
            @test !should_quit(dirty) && dirty.dialog_kind == :unsaved
            @test find_text(draw(dirty), "Save the selection to") !== nothing
        end
        saved = app_for(; dirty = true)
        update!(saved, KeyEvent('q'))
        update!(saved, KeyEvent(:enter))                 # the dialog opens on "Save and quit"
        @test should_quit(saved) && isfile(saved.page.options.out)
        # A failing save keeps the app open with its error in the page's dialog; the marks stay.
        blocked = app_for(; dirty = true, out = joinpath(touch(joinpath(mktempdir(), "file")), "sel.yaml"))
        update!(blocked, KeyEvent('q'))
        update!(blocked, KeyEvent(:enter))
        @test !should_quit(blocked) && blocked.dialog === nothing && blocked.page.modal_kind == :error && blocked.page.dirty
        discarded = app_for(; dirty = true)
        update!(discarded, KeyEvent('q'))
        update!(discarded, KeyEvent(:escape))            # Escape is "Quit without saving"
        @test should_quit(discarded) && !isfile(discarded.page.options.out)
    end

    @testset "a running transfer asks before quitting" begin
        app = app_for()
        app.page.modal_kind = :transfer
        update!(app, KeyEvent('q'))                      # the page takes every key but Ctrl-C while the transfer dialog is up
        @test !should_quit(app) && app.dialog === nothing
        update!(app, KeyEvent(:ctrl_c))
        @test !should_quit(app) && app.dialog_kind == :busy
        update!(app, KeyEvent(:escape))                  # "Keep running" is the default
        @test app.dialog === nothing && !should_quit(app)
        update!(app, KeyEvent(:ctrl_c))
        update!(app, KeyEvent(:left))
        update!(app, KeyEvent(:enter))
        @test should_quit(app)
    end

    @testset "task events: sync ones reach the page, others are an error" begin
        app = app_for()
        app.page.running += 1                            # a result needs a task that runs
        update!(app, TaskEvent(Symbol("sync:productions"), ["a", "b"]))
        @test app.page.productions == ["a", "b"] && app.page.running == 0
        update!(app, TaskEvent(:tick, nothing))
        @test_throws "unexpected background result :other" update!(app, TaskEvent(:other, nothing))
        @test !sync_task!(app.page, TaskEvent(:other, nothing))
        # A fault in the page is shown in its dialog; nothing is thrown.
        app.page.running += 1
        @test sync_task!(app.page, TaskEvent(Symbol("sync:nothing_here"), nothing))
        @test app.page.modal_kind == :error && occursin("unexpected background result :nothing_here", app.page.modal.message)
        app.page.modal = nothing
        app.page.modal_kind = :none
        # A result without a running task is a task id mix-up and is reported, never clamped.
        @test sync_task!(app.page, TaskEvent(Symbol("sync:productions"), String[]))
        @test app.page.modal_kind == :error && occursin("task id was mixed up", app.page.modal.message) && app.page.running == 0
        app.page.modal = nothing
        app.page.modal_kind = :none
        @test task_queue(app) === app.page.tasks
    end

    @testset "the picker app starts listing and quits with q" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        app = SyncApp(SyncPage(h, options))
        init!(app, term)
        @test app.timer !== nothing && app.page.running == 1
        cleanup!(app)          # the tick timer keeps the queue active
        settle!(app)
        @test app.page.productions !== nothing && app.page.picker !== nothing
        update!(app, KeyEvent('q'))
        @test should_quit(app)
        picker = SyncApp(SyncPage(h, options))
        update!(picker, KeyEvent(:ctrl_c))
        @test should_quit(picker)
    end

    @testset "init! starts the listing once" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        page = SyncPage(h, options)
        @test page.running == 0 && page.tasks.active[] == 0
        app = SyncApp(page)
        init!(app, term)
        sync_start!(page)
        @test page.running == 1
        cleanup!(app)
        settle!(app)
        @test page.running == 0 && page.productions !== nothing
        sync_start!(page)
        @test page.running == 0
        @test app.timer === nothing
    end

    @testset "an exception in a handler opens the error dialog and the app keeps running" begin
        app = app_for()
        @test Sync.shielded(() -> error("boom in a handler"), app.page, true)
        @test app.page.modal_kind == :error && occursin("boom in a handler", app.page.modal.message) && !should_quit(app)
        update!(app, KeyEvent(:enter))                    # closes the dialog; the app still answers keys
        @test app.page.modal_kind == :none
        update!(app, KeyEvent('q'))
        @test should_quit(app)
        # During a transfer the dialog stays and the fault is appended to the status line.
        app.page.modal_kind = :transfer
        app.page.modal = Tachikoma.Modal(title = "Transferring", message = "starting…", confirm_label = "", cancel_label = "")
        app.page.status = "copying"
        @test Sync.shielded(() -> error("late fault"), app.page, true)
        @test app.page.modal_kind == :transfer && app.page.modal.title == "Transferring" && app.page.status == "copying; late fault"
        app.page.modal = nothing
        app.page.modal_kind = :none
        @test_throws InterruptException Sync.shielded(() -> throw(InterruptException()), app.page, true)
    end

    @testset "the page's own work counter is independent of the queue" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        app = SyncApp(SyncPage(h, options))
        sync_start!(app.page)
        settle!(app)
        app.queue.active[] += 1                           # another component's task on the shared queue
        update!(app, KeyEvent(:down))
        update!(app, KeyEvent(:enter))                    # still opens the production
        @test app.page.running == 1
        app.queue.active[] -= 1
    end
end
