# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    SyncApp(page::SyncPage)

The model of `juleana-sync`: one [`SyncPage`](@ref) on the whole screen, its task queue, and the quit
dialog. The page returns `false` for `q` and Ctrl-C; the app asks about a running transfer first, then
about unsaved marks, and otherwise quits.
"""
mutable struct SyncApp <: Model
    const page::SyncPage
    const queue::TaskQueue
    quit::Bool
    dialog::Union{Nothing,Modal}
    dialog_kind::Symbol
    timer::Any
end

SyncApp(page::SyncPage) = SyncApp(page, page.tasks, false, nothing, :none, nothing)

should_quit(app::SyncApp) = app.quit
task_queue(app::SyncApp) = app.queue

function view(app::SyncApp, f::Frame)
    render_sync(app.page, f.area, f.buffer)
    app.dialog === nothing || render(app.dialog, f.area, f.buffer)
    return nothing
end

function request_quit!(app::SyncApp)
    page = app.page
    if sync_busy(page)
        app.dialog = Modal(title = "Transfer running",
                           message = "Quitting now interrupts the transfer.\nStaged files are kept and the next run resumes from them.",
                           confirm_label = "Quit now", cancel_label = "Keep running", selected = :cancel)
        app.dialog_kind = :busy
    elseif sync_dirty(page)
        app.dialog = Modal(title = "Unsaved selection", message = "Save the selection to\n$(page.options.out)\nbefore leaving?",
                           confirm_label = "Save and quit", cancel_label = "Quit without saving", selected = :confirm)
        app.dialog_kind = :unsaved
    else
        app.quit = true
    end
    return app
end

function update!(app::SyncApp, e::KeyEvent)
    if app.dialog !== nothing
        answer = handle_key!(app.dialog, e)
        answer in (false, :none) && return app
        kind = app.dialog_kind
        app.dialog = nothing
        app.dialog_kind = :none
        if kind == :unsaved
            answer == :confirm && save!(app.page)
            app.quit = true
        elseif kind == :busy && answer == :confirm
            app.quit = true
        end
        return app
    end
    sync_key!(app.page, e) && return app
    (e.key == :ctrl_c || (e.key == :char && e.char == 'q')) && request_quit!(app)
    return app
end

function update!(app::SyncApp, e::MouseEvent)
    app.dialog === nothing && sync_mouse!(app.page, e)
    return app
end

function update!(app::SyncApp, e::TaskEvent)
    startswith(String(e.id), "sync:") && (sync_task!(app.page, e); return app)
    e.id === :tick && return app
    return error("unexpected background result :$(e.id) in juleana-sync")
end

# The tick makes the screen redraw while a step without a known size runs.
function start!(app::SyncApp)
    app.timer = Tachikoma.spawn_timer!(app.queue, :tick, 0.5; repeat = true)
    return app
end

function stop!(app::SyncApp)
    app.timer === nothing || Tachikoma.cancel!(app.timer)
    app.timer = nothing
    return app
end

init!(app::SyncApp, ::Tachikoma.Terminal) = (start!(app); sync_start!(app.page); nothing)
cleanup!(app::SyncApp) = (stop!(app); nothing)

"""
    run_tui(options::Options, host::RemoteHost)::Int

Open the screen for `options` and return the exit code once it closes. It starts on the production
picker when `options` names no production.
"""
function run_tui(options::Options, host::RemoteHost)
    queue = TaskQueue()
    page = if isempty(options.production)
        SyncPage(host, options; queue)
    else
        SyncPage(host, Production(host, options.production, options.remote_root, options.local_root; mount_root = options.mount_root),
                 options; queue)
    end
    run_themed(SyncApp(page))
    return 0
end

# The screen uses the theme of juleana: two calls read the saved name; the previous theme is restored afterwards.
function run_themed(model)
    previous = Tachikoma.theme()
    Tachikoma.set_theme!(tui_theme(load_theme_name()))
    try
        app(model)
    finally
        Tachikoma.set_theme!(previous)
    end
    return nothing
end
