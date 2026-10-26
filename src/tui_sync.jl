# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# The Sync page of `m`, created on first use from the settings the interface was given, or the user's configuration.
# Reading the configuration and building the page (which validates the settings and reads the hosts file) happen in one
# guarded block: a malformed file gives a page with default settings and its error in the page's dialog on the first
# visit; it never ends the interface.
function sync_page!(m::JuLeAnaTUI)
    isnothing(m.sync) || return m.sync
    problem = nothing
    page = try
        SyncPage(isnothing(m.sync_settings) ? user_settings() : m.sync_settings, m.queue; host_factory = m.sync_host)
    catch err
        err isa InterruptException && rethrow()
        problem = err
        SyncPage(SyncSettings(), m.queue; host_factory = m.sync_host)
    end
    m.sync = page
    isnothing(problem) || shielded(() -> throw(problem), page, nothing)
    return page
end

"""
    offline_sync_settings()::SyncSettings

Settings that cannot contact a host or read a user file: an empty Local root blocks Connect, so a page built from them
only draws. The precompile workload and every test that walks over all pages use them.
"""
offline_sync_settings() = SyncSettings(; host = "offline", remote_root = "/offline", local_root = "", hosts_file = PACKAGED_HOSTS_FILE)

# Draw the Sync page. A fault in it is drawn as one error line naming the exception, so the interface keeps running; an
# interrupt is rethrown.
function draw_sync!(m::JuLeAnaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    try
        render_sync(sync_page!(m), area, buf)
    catch err
        err isa InterruptException && rethrow()
        text = "The Sync page failed to draw: " * first(split(sprint(showerror, err), '\n'))
        Tachikoma.set_string!(buf, area.x, area.y, text, Tachikoma.tstyle(:error); max_x = Tachikoma.right(area))
    end
    return nothing
end

# The hint pairs of the Sync page and whether it takes text; a fault gives no hints.
function sync_bar(m::JuLeAnaTUI)
    try
        page = sync_page!(m)
        return (sync_hints(page), sync_text_input(page))
    catch err
        err isa InterruptException && rethrow()
        return ((), false)
    end
end

# Switch to page `n`. The first visit of the Sync tab creates its page and connects.
function show_page!(m::JuLeAnaTUI, n::Integer)
    m.page = n
    if n == SYNC_PAGE
        created = isnothing(m.sync)
        page = sync_page!(m)
        created && shielded(() -> sync_start!(page), page, nothing)
    end
    return nothing
end
