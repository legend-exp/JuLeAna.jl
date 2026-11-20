# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# A malformed settings file gives a page with default settings and its error in the dialog; it never ends the interface.
function sync_page!(m::JuLeAnaTUI)
    isnothing(m.sync) || return m.sync
    problem = nothing
    page = try
        settings = isnothing(m.sync_settings) ? user_settings() : m.sync_settings
        initial = nothing
        current = isempty(settings.production) ? current_production() : nothing
        isnothing(current) || (initial = preselect_production(joinpath(current[2], current[1]),
                                                              [normdir(expanduser(settings.local_root)); host_remote_roots(settings.hosts_file)]))
        isnothing(initial) || (settings.production = initial)
        SyncPage(settings, m.queue; host_factory = m.sync_host, suggested = !isnothing(initial))
    catch err
        err isa InterruptException && rethrow()
        problem = err
        SyncPage(SyncSettings(), m.queue; host_factory = m.sync_host)
    end
    m.sync = page
    isnothing(problem) || shielded(() -> throw(problem), page, nothing)
    return page
end

sync_pending(m::JuLeAnaTUI) = !isnothing(m.sync) && (sync_dirty(m.sync) || sync_busy(m.sync))

function quit_message(m::JuLeAnaTUI)
    dirty = !isnothing(m.sync) && sync_dirty(m.sync)
    effects = String[]
    !isnothing(m.sync) && sync_busy(m.sync) && push!(effects, "interrupting the sync transfer or environment creation")
    dirty && push!(effects, "discarding the unsaved sync selection")
    lines = String[]
    processing(m) && push!(lines, join(["s: stop after the running items, then quit"; effects], ", "))
    dirty && push!(lines, "w: save the sync selection to $(selection_path(m.sync.settings)), then quit")
    push!(lines, join(["q: quit now"; processing(m) ? ["ending the run and its workers"] : String[]; effects], ", "))
    push!(lines, processing(m) ? "c: cancel, keep processing" : "c: cancel")
    return join(lines, "\n")
end

offline_sync_settings() = SyncSettings(; host = "offline", remote_root = "/offline", local_root = "", hosts_file = PACKAGED_HOSTS_FILE)

# A fault in the screen is drawn as one error line, so the interface keeps running.
function draw_sync!(m::JuLeAnaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    inner = Tachikoma.render(pane_block("Data sync", true), area, buf)
    try
        render_sync(sync_page!(m), inner, buf)
    catch err
        err isa InterruptException && rethrow()
        text = "The Sync page failed to draw: " * first(split(sprint(showerror, err), '\n'))
        Tachikoma.set_string!(buf, inner.x, inner.y, text, Tachikoma.tstyle(:error); max_x = Tachikoma.right(inner))
    end
    return nothing
end

function sync_bar(m::JuLeAnaTUI)
    try
        page = sync_page!(m)
        sync_running(page) && return ((("Esc", sync_stoppable(page) ? "background or stop" : "background"),), false)
        return ((sync_hints(page)..., (sync_at_rest(page) ? (("Esc", "close"),) : ())...), sync_text_input(page))
    catch err
        err isa InterruptException && rethrow()
        return ((), false)
    end
end

function open_sync!(m::JuLeAnaTUI)
    if processing(m)
        @warn "The Sync window did not open: processing runs. Stop it first or start another juleana-sync"
        return nothing
    end
    created = isnothing(m.sync)
    page = sync_page!(m)
    m.sync_open = true
    created && shielded(() -> sync_start!(page), page, nothing)
    return nothing
end

function sync_window_key!(m::JuLeAnaTUI, evt::Tachikoma.KeyEvent)
    page = sync_page!(m)
    if evt.key == :escape
        sync_running(page) && (m.dialog = :sync_leave; return true)
        sync_at_rest(page) && (m.sync_open = false; return true)
    end
    return sync_key!(page, evt)
end

function sync_leave_message(m::JuLeAnaTUI)
    stop = sync_stoppable(m.sync) ? "\ns: stop it; files already staged are kept and the next run resumes from them" : ""
    return "b: close the window, keep it running in the background" * stop * "\nc: cancel, stay in the window"
end
