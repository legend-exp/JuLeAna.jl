# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using Tachikoma: TestBackend, Frame, Rect, KeyEvent, TaskEvent, GraphicsRegion, PixelSnapshot, reset!, row_text, find_text, drain_tasks!
import Tachikoma: Tachikoma, view, update!, should_quit
using JuLeAna.Sync: SyncApp, SETTINGS_FIELDS, sync_key!, sync_start!, sync_text_input, sync_running, sync_stop!

update!(m::SyncPage, e::KeyEvent) = (sync_key!(m, e); m)
update!(m::SyncPage, e::TaskEvent) = (Sync.sync_task!(m, e) || error("not a sync event: $(e.id)"); m)
view(m::SyncPage, f::Frame) = Sync.render_sync(m, f.area, f.buffer)

function draw(m; width = 100, height = 30)
    tb = TestBackend(width, height)
    reset!(tb.buf)
    view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end

# Delivers the background results as the app loop does, until no task runs and no event waits.
function settle!(m)
    done() = (drain_tasks!(e -> update!(m, e), m.tasks); m.tasks.active[] == 0 && !isready(m.tasks.channel))
    return timedwait(done, 30; pollint = 0.01) == :ok || error("the background tasks did not finish within 30 s")
end

@testset "screen and juleana-sync" begin
    h = LocalHost()
    keys!(m, ks...) = foreach(k -> update!(m, KeyEvent(k)), ks)
    function page()
        local_root = mktempdir()
        m = SyncPage(h, Production(h, "test", REMOTE, local_root),
                     Options("local", REMOTE, local_root, nothing, "test", joinpath(mktempdir(), "sel.yaml"), nothing, false, false))
        m.panel_open = true
        return m
    end

    @testset "host keys, quit dialogs and theme" begin
        host_keys = (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
        m = page()
        keys!(m, :tab, :enter)   # the first field is in edit
        @test all(k -> sync_key!(m, k), host_keys) && sync_text_input(m)
        keys!(m, :escape)
        m.modal_kind = :transfer
        @test all(k -> !sync_key!(m, k), host_keys)

        saved = SyncApp(page())
        saved.page.dirty = true
        update!(saved, KeyEvent('q'))
        @test !should_quit(saved) && find_text(draw(saved), "Save the selection to") !== nothing
        update!(saved, KeyEvent(:enter))   # opens on "Save and quit"
        @test should_quit(saved) && isfile(saved.page.options.out)
        busy = SyncApp(page())
        busy.page.modal_kind = :transfer
        keys!(busy, 'q', :escape, :ctrl_c, :left, :enter)
        @test should_quit(busy)

        previous, depot = Tachikoma.theme(), mktempdir()
        pushfirst!(DEPOT_PATH, depot)
        try
            Tachikoma.set_theme!(Sync.tui_theme("night-owl"))
            @test_logs (:info, "Theme: juleana") update!(SyncApp(page()), KeyEvent('T'))
            @test Tachikoma.theme().name == "juleana" && read(joinpath(depot, "prefs", "JuLeAna", "theme"), String) == "juleana"
        finally
            popfirst!(DEPOT_PATH)
            Tachikoma.set_theme!(previous)
        end
        row = rstrip(row_text(draw(SyncApp(page())), 1))
        @test endswith(row, "JuLeAna v$(pkgversion(parentmodule(Sync)))") && textwidth(row) == 100
    end

    @testset "picker, settings, estimate, then the transfer, which cannot be dismissed" begin
        m = sync_start!(SyncPage(h, Options("local", REMOTE, mktempdir(), nothing, "", "", nothing, false, false)))
        settle!(m)
        @test m.picking && find_text(draw(m), "Productions on local") !== nothing
        keys!(m, :enter)
        settle!(m)
        @test !m.picking && m.production.name == "test" && find_text(draw(m), "Production: test") !== nothing
        m.panel_open = true
        draw(m)
        m.focus, m.cursor = :panel, findfirst(==(:jobs), SETTINGS_FIELDS)
        keys!(m, :enter, :backspace, 'x', :enter)
        @test m.errors[:jobs] == "Jobs must be an integer >= 0, got x" && find_text(draw(m), "got x") !== nothing
        keys!(m, 'e')
        @test m.modal_kind == :none && occursin("Jobs must be an integer", m.status)
        keys!(m, :enter, :backspace, '2', :enter)
        @test isempty(m.errors) && m.options.jobs == 2
        keys!(m, :escape, :down, ' ', 'e')
        settle!(m)
        @test m.modal_kind == :estimate && m.estimate.files == 2
        keys!(m, :escape, 't')
        settle!(m)
        keys!(m, :enter, :escape)
        @test m.modal_kind == :transfer
        settle!(m)
        @test m.modal_kind == :message && isfile(joinpath(m.production.local_root, "test", "config_local.yaml"))
    end

    @testset "the progress line shows under the transfer dialog; a stop ends the transfer and its rsync" begin
        m = page()
        keys!(m, 't')
        settle!(m)
        pidfile = joinpath(mktempdir(), "pid")
        script = "#!/bin/sh\n[ \"\$1\" = --version ] && { echo 'rsync  version 3.4.1  protocol version 32'; exit 0; }\necho \$\$ > $pidfile\n" *
                 "while :; do printf '  1,000  50%%  1.00MB/s  0:00:01\\r'; sleep 0.05; done\n"
        bin = mktempdir()   # a stand-in `rsync` first on the PATH
        write(joinpath(bin, "rsync"), script)
        chmod(joinpath(bin, "rsync"), 0o755)
        withenv("PATH" => bin * ":" * ENV["PATH"]) do
            keys!(m, :enter)
            t_end = time() + 30
            while (m.step === nothing || m.step.total === nothing) && time() < t_end
                drain_tasks!(e -> update!(m, e), m.tasks)
                sleep(0.01)
            end
            @test m.modal_kind == :transfer && occursin(r"\[\d+/\d+\]", row_text(draw(m), 30))
            sync_stop!(m)
            settle!(m)
        end
        @test !sync_running(m) && m.modal === nothing && occursin("stopped", m.status)
        @test !success(pipeline(`kill -0 $(parse(Int, strip(read(pidfile, String))))`; stderr = devnull))
    end
end
