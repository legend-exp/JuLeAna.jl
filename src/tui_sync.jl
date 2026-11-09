# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# The Sync screen of `m`, created on first use from the settings the interface was given, or the user's configuration.
# Reading the configuration and building the page (which validates the settings and reads the hosts file) happen in one
# guarded block: a malformed file gives a page with default settings and its error in the page's dialog at the first
# opening; it never ends the interface.
function sync_page!(m::JuLeAnaTUI)
    isnothing(m.sync) || return m.sync
    problem = nothing
    page = try
        settings = isnothing(m.sync_settings) ? user_settings() : m.sync_settings
        initial = isempty(settings.production) ? sync_initial_production(settings) : nothing
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

# The production Setup works on, as a candidate name for the Sync screen: its folder relative to the local root (a mirror)
# or to the remote root of a host.
function sync_initial_production(settings::SyncSettings)
    current = current_production()
    isnothing(current) && return nothing
    roots = [normdir(expanduser(settings.local_root)); host_remote_roots(settings.hosts_file)]
    return preselect_production(joinpath(current[2], current[1]), roots)
end

# Whether leaving would lose sync work: unsaved marks, or a running transfer or environment creation.
sync_pending(m::JuLeAnaTUI) = !isnothing(m.sync) && (sync_dirty(m.sync) || sync_busy(m.sync))

# The text of the quit dialog: one line per key that applies. The `s` and `q` lines name the sync work they lose.
function quit_message(m::JuLeAnaTUI)
    dirty = !isnothing(m.sync) && sync_dirty(m.sync)
    busy = !isnothing(m.sync) && sync_busy(m.sync)
    lines = String[]
    sync_effects = String[]
    busy && push!(sync_effects, "interrupting the sync transfer or environment creation")
    dirty && push!(sync_effects, "discarding the unsaved sync selection")
    processing(m) && push!(lines, join(["s: stop after the running items, then quit"; sync_effects], ", "))
    dirty && push!(lines, "w: save the sync selection to $(selection_path(m.sync.settings)), then quit")
    effects = processing(m) ? ["ending the run and its workers"; sync_effects] : sync_effects
    push!(lines, join(["q: quit now"; effects], ", "))
    push!(lines, processing(m) ? "c: cancel, keep processing" : "c: cancel")
    return join(lines, "\n")
end

"""
    offline_sync_settings()::SyncSettings

Settings that cannot contact a host or read a user file: an empty Local root blocks Connect, so a page built from them
only draws. The precompile workload and every test that walks over all pages use them.
"""
offline_sync_settings() = SyncSettings(; host = "offline", remote_root = "/offline", local_root = "", hosts_file = PACKAGED_HOSTS_FILE)

# Draw the window of the Sync screen. A fault in the screen is drawn as one error line naming the exception, so the interface
# keeps running; an interrupt is rethrown.
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

# The hint pairs of the Sync window and whether it takes text; a fault gives no hints. While work runs the screen takes no key
# of its own, so its hints do not apply.
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

# Open the Sync window, unless processing runs. The first opening creates the screen and connects.
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

# A key in the open Sync window; returns whether it is used. Escape closes the window when the screen has nothing left to close
# and asks while it runs work; the screen's own uses of Escape come first. `sync_key!` leaves the keys of the interface to it.
function sync_window_key!(m::JuLeAnaTUI, evt::Tachikoma.KeyEvent)
    page = sync_page!(m)
    if evt.key == :escape
        sync_running(page) && (m.dialog = :sync_leave; return true)
        sync_at_rest(page) && (m.sync_open = false; return true)
    end
    return sync_key!(page, evt)
end

# The text of the question of Escape while the Sync window runs work: one line per key that applies.
function sync_leave_message(m::JuLeAnaTUI)
    lines = ["b: close the window, keep it running in the background"]
    sync_stoppable(m.sync) && push!(lines, "s: stop it; files already staged are kept and the next run resumes from them")
    push!(lines, "c: cancel, stay in the window")
    return join(lines, "\n")
end
