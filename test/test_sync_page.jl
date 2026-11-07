# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "tree screen" begin
    h = LocalHost()
    click(x, y) = MouseEvent(x, y, mouse_left, mouse_press, false, false, false)
    wheel(x, y, button) = MouseEvent(x, y, button, mouse_press, false, false, false)
    row_pos(m, k) = (m.tree.last_area.x + 2, m.tree.last_area.y + k - 1 - m.tree.offset)
    keys!(m, ks...) = foreach(k -> update!(m, KeyEvent(k)), ks)

    function model(; mount_root = nothing, out = joinpath(mktempdir(), "test.yaml"), root = FIXTURE_ROOT, name = "test")
        local_root = mktempdir()
        p = Production(h, name, root, local_root; mount_root)
        return SyncPage(h, p, Options("local", root, local_root, mount_root, name, out, nothing, false, false))
    end
    # A page without a production, as it starts when the production is picked in the window.
    options() = Options("local", FIXTURE_ROOT, mktempdir(), nothing, "", "", nothing, false, false)
    tier!(m) = (keys!(m, :down, :down, :down, :down); current_node(m))   # root, config.json, metadata, par, tier
    function open!(m, label)
        for _ in 1:40
            current_node(m).label == label && break
            update!(m, KeyEvent(:down))
        end
        @test current_node(m).label == label
        update!(m, KeyEvent(:enter))
        settle!(m)
    end
    # A copy of the fixture that the test may damage, with the listing of tier delivered.
    function damaged_model()
        root = joinpath(mktempdir(), "remote")
        cp(joinpath(SYNC_FIXTURES, "remote"), root)
        write(joinpath(root, "test", "config.json"),
              replace(read(joinpath(root, "test", "config.json.in"), String), "@REMOTE_ROOT@" => root))
        m = model(; root)
        tier = tier!(m)
        update!(m, KeyEvent(:enter))
        timedwait(() -> isready(m.tasks.channel), 30.0) == :ok || error("no listing within 30 s")
        rm(joinpath(tier.remote_path, "jlhit"); recursive = true)
        deliver_next!(m)
        return m, tier
    end

    @testset "the initial render shows the production, its sections and the status line" begin
        tb = draw(model())
        @test find_text(tb, "Production: test") !== nothing && find_text(tb, "config.json") !== nothing &&
              find_text(tb, "tier/jlhit") !== nothing
        @test find_text(tb, "legend-metadata") === nothing && find_text(tb, "Details") !== nothing &&
              find_text(tb, "space copy") !== nothing
        @test occursin("selected: 0 B copy (0 files), 0 links", row_text(tb, 30)) && occursin("unsaved", row_text(tb, 30))
        local_root = mktempdir()
        nested = Production(h, "temp/jl-dev", FIXTURE_ROOT, local_root)
        opts = Options("local", FIXTURE_ROOT, local_root, nothing, "temp/jl-dev", joinpath(mktempdir(), "sel.yaml"), nothing, false, false)
        @test find_text(draw(SyncPage(h, nested, opts); width = 160), "overlays: config_fixture.json, temp/config_site.yaml") !== nothing
    end

    @testset "enter lists a section in the background and the sizes follow the listing" begin
        m = model()
        tier = tier!(m)
        @test tier.label == "tier"
        update!(m, KeyEvent(:enter))
        @test occursin("listing", row_text(draw(m), 30))
        deliver_next!(m)   # the listing
        @test [c.label for c in tier.children] == ["jlevt", "jlhit"] && all(c -> c.size === nothing, tier.children)
        tb = draw(m)
        row = row_text(tb, find_text(tb, "] jlevt").y)
        @test occursin("…", row) && !occursin(" K", row)
        keys!(m, :down, ' ')
        @test occursin("selected: 0 B?", row_text(draw(m), 30))   # a size is still missing
        deliver_next!(m)   # the sizes
        @test [c.size for c in tier.children] == [4096 + 8192, 2048 + 1024 + 18]
        tb = draw(m)
        @test occursin(format_bytes(4096 + 8192), row_text(tb, find_text(tb, "] jlevt").y)) && !occursin("?", row_text(tb, 30))
        @test occursin("selected: $(format_bytes(4096 + 8192)) copy", row_text(tb, 30))
        keys!(m, :up, :enter)   # enter again collapses without listing again
        @test find_text(draw(m), "jlevt") === nothing
        update!(m, KeyEvent(:enter))
        @test find_text(draw(m), "jlevt") !== nothing
    end

    @testset "a failing listing or sizing opens an error and leaves an open dialog alone" begin
        m, tier = damaged_model()
        deliver_next!(m)
        @test m.modal_kind == :error && occursin("not a directory", m.modal.message) && all(c -> c.size === nothing, tier.children)

        m, _ = damaged_model()
        open_message!(m, "Working", "a dialog the user is reading")
        deliver_next!(m)
        @test m.modal_kind == :message && m.modal.message == "a dialog the user is reading"
        @test occursin("sizes of tier: ", m.status) && occursin("not a directory", m.status)

        m = model()
        push!(m.pending, "some/other/listing/in-flight")   # a listing that is still in flight when this one fails
        bad = tier!(m)
        bad.remote_path = joinpath(FIXTURE_ROOT, "no-such-directory")
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test m.modal_kind == :error && find_text(draw(m), "Error") !== nothing
        @test bad.remote_path ∉ m.pending && "some/other/listing/in-flight" in m.pending
        update!(m, KeyEvent(:escape))
        @test m.modal_kind == :none
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:nonsense"), 1))
        @test m.modal_kind == :error && occursin("unexpected background result :nonsense", m.modal.message)
    end

    @testset "space and l mark rows, an inherited mode is excluded, link mode needs a mount root" begin
        m = model()
        keys!(m, :down, ' ')
        tb = draw(m)
        @test current_node(m).mode == :copy && m.dirty && find_text(tb, "[x] config.json") !== nothing &&
              find_text(tb, "[-] Production: test") !== nothing
        @test occursin(format_bytes(filesize(joinpath(FIXTURE_ROOT, "test", "config.json"))), row_text(tb, 30)) &&
              occursin("(1 files)", row_text(tb, 30))
        update!(m, KeyEvent(' '))
        @test current_node(m).mode == :none && occursin("selected: 0 B", row_text(draw(m), 30))
        update!(m, KeyEvent('l'))
        @test current_node(m).mode == :none && occursin("mount", row_text(draw(m), 30))
        mounted = model(; mount_root = "/Volumes/cslg4")
        keys!(mounted, :down, 'l')
        @test current_node(mounted).mode == :link && find_text(draw(mounted), "[~] config.json") !== nothing

        m = model()
        tier!(m)
        keys!(m, ' ', :enter)
        settle!(m)
        keys!(m, :down, ' ')   # jlevt inherits the copy of tier
        tb = draw(m)
        @test find_text(tb, "[ ] jlevt") !== nothing && find_text(tb, "[x] jlhit") !== nothing && find_text(tb, "[-] tier ") !== nothing
    end

    @testset "n selects the first N filekeys" begin
        m = model()
        for label in ("tier", "jlevt", "phy", "p18")
            open!(m, label)
        end
        keys!(m, :down, :down, :enter)   # the detectors row, then r000
        settle!(m)
        run_node = current_node(m)
        @test run_node.label == "r000"
        update!(m, KeyEvent('n'))
        @test m.modal_kind == :firstn && find_text(draw(m), "First N filekeys") !== nothing
        keys!(m, 'x', :enter)
        @test m.modal_kind == :firstn && occursin("positive number", m.status)   # the prompt stays open
        keys!(m, :backspace, '1', :enter)
        @test m.modal_kind == :none && [c.mode for c in filekey_groups(run_node)] == [:copy, :none]
        keys!(m, 'n', '2', :escape)
        @test m.modal_kind == :none && [c.mode for c in filekey_groups(run_node)] == [:copy, :none]
    end

    @testset "s saves, e estimates, t transfers and reports" begin
        out = joinpath(mktempdir(), "sync", "test.yaml")
        m = model(; out)
        keys!(m, :down, ' ', 's')
        @test !m.dirty && isfile(out) && occursin("saved: test.yaml", row_text(draw(m), 30))
        @test joinpath("test", "legend-metadata") in load_selection(out, m.production).copy

        update!(m, KeyEvent('e'))
        @test occursin("estimating", row_text(draw(m), 30))
        settle!(m)
        @test m.modal_kind == :estimate && m.estimate isa Estimate && m.estimate.files == 3   # config.json, the overlay and the metadata README
        @test find_text(draw(m), "Estimate") !== nothing && find_text(draw(m), "Sync") !== nothing
        update!(m, KeyEvent(:escape))
        @test m.modal_kind == :none && !isdir(joinpath(m.production.local_root, "test", "legend-metadata"))

        update!(m, KeyEvent('t'))
        settle!(m)
        @test m.modal_kind == :estimate && m.modal.selected == :confirm
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :transfer
        update!(m, KeyEvent(:escape))
        @test m.modal_kind == :transfer && m.modal !== nothing   # the transfer dialog cannot be dismissed
        settle!(m)
        @test m.modal_kind == :message && occursin("transferred", m.modal.message) && occursin("LEGEND_DATA_CONFIG=", m.modal.message)
        @test m.step === nothing && isfile(joinpath(m.production.local_root, "test", "config_local.yaml"))
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :none && current_node(m).local_state == :present
    end

    @testset "detector rows of a run: x marks, the other marking keys explain themselves" begin
        mount_root = mktempdir()
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir(); mount_root)
        m = SyncPage(h, p,
                     Options("local", EXTRACT_ROOT, p.local_root, mount_root, "xprod", joinpath(mktempdir(), "x.yaml"), nothing, false,
                             false))
        for label in ("tier", "jldsp", "cal", "p18", "r000")
            open!(m, label)
        end
        run = current_node(m)
        @test first(run.children).kind == :detectors && occursin("detectors", row_text(draw(m), find_text(draw(m), "] r000").y + 1))
        rows!(first(run.children), ("B00000C", 400, []), ("V01234A", 800, []), ("aux", 1200, []))
        rebuild_tree!(m)
        @test find_text(draw(m; width = 120), "B00000C") !== nothing
        keys!(m, :down, :enter, :enter)   # the rows are there: Enter folds and unfolds them, lists nothing and checks no environment
        @test m.modal_kind == :none && m.tasks.active[] == 0 && find_text(draw(m; width = 120), "B00000C") !== nothing
        for key in (' ', 'l', 'n')
            m.status = ""
            update!(m, KeyEvent(key))
            @test occursin(key == 'n' ? "n applies to run directories" : "use x on detector rows", m.status) &&
                  current_node(m).mode == :none
        end
        keys!(m, :down, 'x')
        tb = draw(m; width = 120)
        @test current_node(m).mode == :extract && find_text(tb, "[e] B00000C") !== nothing && find_text(tb, "HDF5 group") !== nothing
        @test occursin("~800 B extract (2 files)", row_text(tb, 30)) && find_text(tb, "[-] detectors") !== nothing
        update!(m, KeyEvent('x'))
        @test current_node(m).mode == :none
        set_mode!(run, :copy)   # a run transferred whole cannot be extracted from
        m.status = ""
        update!(m, KeyEvent('x'))
        @test occursin("already transferred whole", m.status) && current_node(m).mode == :none
        set_mode!(run, :none)
        keys!(m, :home, 'x')
        @test occursin("x extracts a detector", m.status)
    end

    @testset "per-detector files are listed without the helper environment and transferred" begin
        function perdet(mount_root)
            p = Production(h, "dprod", PERDET_ROOT, mktempdir(); mount_root)
            helper = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())
            opts = Options("local", PERDET_ROOT, p.local_root, mount_root, "dprod", joinpath(mktempdir(), "x.yaml"), nothing, false, false,
                           0, helper)
            m = SyncPage(h, p, opts)
            for label in ("tier", "jlqcs", "cal", "p16")
                open!(m, label)
            end
            return m
        end
        m = perdet("/")
        @test [c.kind for c in current_node(m).children] == [:detectors, :dir, :dir]
        update!(m, KeyEvent(:down))
        @test find_text(draw(m; width = 120), "enter lists the detector files of every run in p16") !== nothing
        update!(m, KeyEvent(:enter))
        @test startswith(m.status, "listing") && m.modal_kind == :none
        settle!(m)
        tb = draw(m)
        @test m.environment === nothing && m.modal === nothing && occursin(format_bytes(400), row_text(tb, find_text(tb, "B00000C").y))
        update!(m, KeyEvent(:down))
        b = current_node(m)
        update!(m, KeyEvent(' '))
        tb = draw(m)
        @test b.mode == :copy && find_text(tb, "[x] B00000C") !== nothing && find_text(tb, "held by r000, r001") !== nothing
        @test occursin("400 B copy (2 files)", row_text(tb, 30))
        update!(m, KeyEvent('l'))
        @test b.mode == :link && occursin("2 links", row_text(draw(m), 30))
        update!(m, KeyEvent('x'))
        @test occursin("hold one detector each", m.status) && b.mode == :link
        keys!(m, 'l', ' ', :down, ' ', 't')   # B00000C and V01234A are copied
        settle!(m)
        @test m.modal_kind == :estimate && m.estimate.files == 5 && occursin("not in run: V01234A in", m.modal.message)
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test m.modal_kind == :message && occursin("not in run, left out: V01234A in", m.modal.message)
        local_period = joinpath(m.production.local_root, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
        @test length(readdir(joinpath(local_period, "r000"))) == 2 && length(readdir(joinpath(local_period, "r001"))) == 1
        nomount = perdet(nothing)
        keys!(nomount, :down, :enter)
        settle!(nomount)
        keys!(nomount, :down, 'l')
        @test occursin("needs a mount root", nomount.status)
    end

    @testset "the production picker lists, opens, reports errors and retries" begin
        m = sync_start!(SyncPage(h, options()))
        @test find_text(draw(m), "working…") !== nothing && !m.picking
        settle!(m)
        tb = draw(m)
        @test m.picking && find_text(tb, "Productions on local") !== nothing && find_text(tb, "temp/jl-dev") !== nothing &&
              find_text(tb, "working…") === nothing
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test find_text(draw(m), "Production: temp/jl-dev") !== nothing && m.options.production == "temp/jl-dev" &&
              m.production.name == "temp/jl-dev"
        @test m.options.out == joinpath(default_selection_dir(), m.options.host, "temp-jl-dev.yaml")
        m.settings.selection = joinpath(mktempdir(), "sel.yaml")
        update!(m, KeyEvent('s'))
        @test load_selection(m.settings.selection, m.production).production == "temp/jl-dev"

        m = sync_start!(SyncPage(h, options()))
        settle!(m)
        keys!(m, :down, :enter)
        settle!(m)
        @test m.production.name == "test"

        failed = sync_start!(SyncPage(h,
                                      Options("local", joinpath(FIXTURE_ROOT, "nosuch"), mktempdir(), nothing, "", "", nothing, false,
                                              false)))
        settle!(failed)
        @test failed.modal_kind == :error && find_text(draw(failed), "not a directory") !== nothing
        update!(failed, KeyEvent(:escape))   # the page asks to connect again, and opening the picker retries
        @test failed.modal === nothing && failed.root === nothing &&
              find_text(draw(failed), "Connect (c) lists the productions") !== nothing
        failed.options = options()
        open_picker!(failed)
        @test find_text(draw(failed), "working…") !== nothing
        settle!(failed)
        @test find_text(draw(failed), "temp/jl-dev") !== nothing
    end

    @testset "the mouse scrolls, selects and opens rows, and a dialog swallows clicks" begin
        m = model()
        draw(m; height = 8)
        area = m.tree.last_area
        @test tree_visible_count(m.tree) > area.height && m.tree.offset == 0
        update!(m, wheel(area.x, area.y, mouse_scroll_down))
        @test m.tree.offset == 1 && m.tree.selected >= 2   # the selection stays in the window
        update!(m, wheel(area.x, area.y, mouse_scroll_up))
        update!(m, wheel(area.x + 200, area.y, mouse_scroll_down))   # outside the tree
        @test m.tree.offset == 0

        m = model()
        draw(m)
        update!(m, click(row_pos(m, 5)...))
        @test current_node(m).label == "tier" && m.tree.selected == 5 && find_text(draw(m), "jlevt") === nothing
        update!(m, click(row_pos(m, 5)...))   # a second click acts like enter
        @test occursin("listing", row_text(draw(m), 30))
        settle!(m)
        @test find_text(draw(m), "jlevt") !== nothing
        update!(m, click(row_pos(m, 5)...))
        @test find_text(draw(m), "jlevt") === nothing

        before = (m.tree.selected, m.tree.offset)
        update!(m, click(area.x + 200, area.y))
        update!(m, MouseEvent(row_pos(m, 3)..., mouse_right, mouse_press, false, false, false))
        update!(m, MouseEvent(row_pos(m, 3)..., mouse_left, mouse_release, false, false, false))
        update!(m, MouseEvent(row_pos(m, 3)..., mouse_left, mouse_drag, false, false, false))
        update!(m, click(area.x + 2, area.y + 25))   # below the rows
        @test (m.tree.selected, m.tree.offset) == before && isempty(m.pending)
        update!(m, click(row_pos(m, 3)...))
        @test m.tree.selected == 3   # so the ignored events above are not vacuous
        open_message!(m, "Working", "a dialog the user is reading")
        update!(m, click(row_pos(m, 4)...))
        update!(m, click(row_pos(m, 4)...))
        @test m.modal !== nothing && m.tree.selected == 3 && isempty(m.pending)
        m.modal, m.modal_kind = nothing, :busy
        update!(m, click(row_pos(m, 4)...))
        @test m.tree.selected == 3

        picker = sync_start!(SyncPage(h, options()))
        settle!(picker)
        draw(picker)
        pick = picker.picker.last_area
        update!(picker, click(pick.x + 1, pick.y + 1))
        update!(picker, click(pick.x + 200, pick.y + 1))
        @test picker.picker.selected == 2 && picker.picking
        picker.running += 1   # a click is ignored while a background task is active
        update!(picker, click(pick.x + 1, pick.y + 2))
        @test picker.picker.selected == 2
        picker.running -= 1
        update!(picker, click(pick.x + 1, pick.y + 1))
        settle!(picker)
        @test picker.production.name == picker.productions[2] && find_text(draw(picker), "Production: $(picker.productions[2])") !== nothing
    end
end

@testset "settings panel" begin
    h = LocalHost()
    click(x, y) = MouseEvent(x, y, mouse_left, mouse_press, false, false, false)
    rect_of(m, name) = Dict(m.panel_rects)[name]
    click_on!(m, name) = (r = rect_of(m, name); sync_mouse!(m, click(r.x + 1, r.y)))
    type!(m, text) = foreach(c -> sync_key!(m, KeyEvent(c)), text)
    function to_field!(m, field)
        for _ in 1:(length(PANEL_ITEMS) + 1)
            m.focus == :panel && PANEL_ITEMS[m.cursor] == field && return m
            sync_key!(m, KeyEvent(:tab))
        end
        error("Tab never reached $field")
    end
    # Replace the value of `field` and commit it.
    function edit!(m, field, text)
        to_field!(m, field)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, text)
        return sync_key!(m, KeyEvent(:enter))
    end
    function model(; out = joinpath(mktempdir(), "test.yaml"))
        local_root = mktempdir()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        m = SyncPage(h, p, Options("local", FIXTURE_ROOT, local_root, nothing, "test", out, nothing, false, false))
        m.panel_open = true
        return m
    end

    @testset "the panel shows every field with its value and the buttons, in two columns when wide" begin
        tb = draw(model(); width = 120, height = 30)
        for text in ("Settings", "Host", "local", "Remote root", "Production", "test", "Local root", "Mount root", "(none)", "Staging",
                     "(host default)", "Jobs",
                     "Selection", "Save selection", "Estimate", "Transfer")
            @test find_text(tb, text) !== nothing
        end
        @test find_text(tb, "Host").y == find_text(tb, "Remote root").y && occursin("unsaved", row_text(tb, 30))
        narrow = draw(model(); width = 80, height = 40)
        @test find_text(narrow, "Host").y != find_text(narrow, "Remote root").y
        m = model()
        # 6 panel rows + 2 border rows + 6 body rows + the progress row = 15: one row less collapses the panel to a summary line.
        @test find_text(draw(m; height = 14), "▸ local") !== nothing && find_text(draw(m; height = 14), "Settings") === nothing
        @test find_text(draw(m; height = 15), "Settings") !== nothing
        sync_key!(m, KeyEvent('p'))
        @test !m.panel_open && find_text(draw(m; height = 30), "▸ local") !== nothing
        sync_mouse!(m, click(m.summary_rect.x + 1, m.summary_rect.y))
        @test m.panel_open && find_text(draw(m; height = 30), "Settings") !== nothing
    end

    @testset "Tab visits every field and button, then the tree; Enter edits, Escape cancels" begin
        m = model()
        draw(m)
        visited = Symbol[]
        for _ in PANEL_ITEMS
            sync_key!(m, KeyEvent(:tab))
            push!(visited, PANEL_ITEMS[m.cursor])
        end
        @test Tuple(visited) == PANEL_ITEMS && m.focus == :panel
        sync_key!(m, KeyEvent(:tab))
        @test m.focus == :tree
        sync_key!(m, KeyEvent(:backtab))
        @test m.focus == :panel && PANEL_ITEMS[m.cursor] == last(PANEL_ITEMS)
        sync_key!(m, KeyEvent(:escape))
        @test m.focus == :tree
        sync_key!(m, KeyEvent(:tab))   # tree keys do nothing while the panel has the focus
        before = current_node(m)
        sync_key!(m, KeyEvent(:down))
        sync_key!(m, KeyEvent(' '))
        @test current_node(m) === before && m.cursor == 2 && !sync_dirty(m)

        m = model()
        draw(m)
        edit!(m, :jobs, "7")
        @test m.edit === nothing && m.settings.jobs == "7" && m.options.jobs == 7
        sync_key!(m, KeyEvent(:enter))
        type!(m, "9")
        @test find_text(draw(m), "79▏") !== nothing
        sync_key!(m, KeyEvent(:escape))
        @test m.edit === nothing && m.settings.jobs == "7"
        out = joinpath(mktempdir(), "other.yaml")
        edit!(m, :selection, out)   # the explicit path replaces the default and is what s saves to
        sync_key!(m, KeyEvent('s'))
        @test isfile(out)
        sync_key!(m, KeyEvent(:enter))
        type!(m, "x"^200 * "tail.yaml")
        @test find_text(draw(m), "tail.yaml▏") !== nothing   # a long edit keeps the cursor visible
    end

    @testset "an invalid value is shown with its reason and blocks the actions" begin
        m = model()
        draw(m)
        edit!(m, :jobs, "x")
        @test m.errors[:jobs] == "Jobs must be an integer >= 0, got x"
        tb = draw(m)
        r = rect_of(m, :jobs)
        @test find_text(tb, "Jobs must be an integer >= 0, got x") !== nothing && style_at(tb, r.x + 12, r.y) == Tachikoma.tstyle(:error)
        sync_key!(m, KeyEvent('e'))
        @test m.modal_kind == :none && occursin("Jobs must be an integer", m.status)
        sync_key!(m, KeyEvent('t'))
        @test m.modal_kind == :none
        edit!(m, :jobs, "2")
        @test isempty(m.errors)
        sync_key!(m, KeyEvent('e'))
        @test m.modal_kind == :estimating
        settle!(m)
        m2 = model()
        m2.settings.local_root = joinpath(tempdir(), "no-such-dir-sync")   # parse_options accepts it, the panel does not
        revalidate!(m2)
        @test occursin("is not an existing directory", m2.errors[:local_root])
    end

    @testset "a field in edit takes every key, otherwise the host keys fall through" begin
        m = model()
        for key in (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'), KeyEvent(:ctrl_c))
            @test !sync_key!(m, key)
        end
        to_field!(m, :host)
        @test !sync_key!(m, KeyEvent('q'))   # panel focus, not editing
        sync_key!(m, KeyEvent(:enter))
        text = m.edit.text
        for key in (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
            @test sync_key!(m, key)
        end
        @test m.edit.text == text * "q?T3" && sync_text_input(m)
        sync_key!(m, KeyEvent(:escape))
        @test !sync_text_input(m)
    end

    @testset "the mouse starts an edit and presses the buttons, but not under a dialog" begin
        out = joinpath(mktempdir(), "test.yaml")
        m = model(; out)
        draw(m)
        click_on!(m, :jobs)
        @test m.edit !== nothing && m.edit.field == :jobs && m.focus == :panel
        sync_key!(m, KeyEvent(:escape))
        click_on!(m, :save)
        @test isfile(out)
        click_on!(m, :estimate)
        @test m.modal_kind == :estimating
        settle!(m)
        focus = m.focus
        @test !click_on!(m, :jobs) && m.edit === nothing && m.focus == focus
    end

    @testset "the Production field opens the picker and choosing asks before dropping unsaved marks" begin
        m = model()
        draw(m)
        to_field!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        @test m.picking && find_text(draw(m), "Productions on local") !== nothing
        sync_key!(m, KeyEvent(:escape))
        @test !m.picking && m.settings.production == "test"
        sync_key!(m, KeyEvent(:enter))   # the productions are known now: the list opens at once
        @test m.picking
        sync_key!(m, KeyEvent(:enter))
        @test m.running == 1   # one background task opens it
        settle!(m)
        @test !m.picking && m.production.name == m.productions[1] && m.settings.production == m.productions[1]

        m = model()
        draw(m)
        sync_key!(m, KeyEvent(' '))
        @test sync_dirty(m)
        to_field!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        sync_key!(m, KeyEvent(:enter))
        @test m.modal_kind == :discard && m.running == 0 && occursin("Discard the marks on test", m.modal.message)
        sync_key!(m, KeyEvent(:enter))   # the dialog opens on Keep
        @test m.modal_kind == :none && sync_dirty(m)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:left))
        sync_key!(m, KeyEvent(:enter))   # Discard
        @test m.running == 1
        settle!(m)
        @test !m.picking && m.production.name == m.productions[1]

        # An invalid setting or a failed open leaves the page as it was.
        m = model()
        draw(m)
        to_field!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)   # the productions are known
        sync_key!(m, KeyEvent(:escape))
        edit!(m, :jobs, "x")
        production, root, opts = m.production, m.root, m.options
        open_picker!(m)
        sync_key!(m, KeyEvent(:enter))
        @test !m.picking && m.running == 0 && occursin("Jobs must be an integer", m.status)
        change_setting!(m, :jobs, "0")
        m.options = Options("local", joinpath(FIXTURE_ROOT, "nosuch"), m.options.local_root, nothing, "test", m.options.out, nothing, false,
                            false)
        failing = m.options
        open_picker!(m)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        @test m.modal_kind == :error && m.production === production && m.root === root && m.options === failing &&
              m.settings.production == "test"
    end
end

@testset "connection and selection files" begin
    h = LocalHost()
    # A page without a connection, as juleana-sync and juleana build it.
    function fresh(; production = "", host_factory = alias -> h, root = FIXTURE_ROOT, local_root = mktempdir())
        settings = SyncSettings(; host = "local", remote_root = root, production, local_root, selection = joinpath(mktempdir(), "sel.yaml"))
        return SyncPage(settings, TaskQueue(); host_factory)
    end
    function started(; kwargs...)
        m = fresh(; kwargs...)
        sync_start!(m)
        settle!(m)
        return m
    end
    last_row(m) = row_text(draw(m; height = 30), 30)

    @testset "a page without a connection or a production refuses the actions politely" begin
        m = fresh()
        tb = draw(m; width = 120, height = 30)
        @test find_text(tb, "Settings") !== nothing && occursin("Connect (c) lists the productions", row_text(tb, 30))
        for key in (' ', 'l', 'n', 'x', 's', 'e', 't', 'o')
            m.status = ""
            @test sync_key!(m, KeyEvent(key)) && occursin("Connect first", m.status) && m.modal_kind == :none
        end
        while PANEL_ITEMS[m.cursor] != :production || m.focus != :panel
            sync_key!(m, KeyEvent(:tab))
        end
        sync_key!(m, KeyEvent(:enter))   # no connection yet: Enter connects
        @test m.running == 1 && m.connecting
        sync_key!(m, KeyEvent(:enter))   # busy: the status says so and nothing else starts
        @test m.running == 1 && occursin("busy:", m.status)
        settle!(m)
        @test !m.connecting && m.picking

        listed = SyncPage(h, Options("local", FIXTURE_ROOT, mktempdir(), nothing, "", "", nothing, false, false))   # the productions are being listed
        tb = draw(listed; width = 120, height = 30)
        @test listed.root === nothing && find_text(tb, "No production is open") !== nothing &&
              occursin("Connect (c) lists the productions", row_text(tb, 30))
        for key in (' ', 'l', 'n', 'x', 's', 'e', 't')
            listed.status = ""
            @test sync_key!(listed, KeyEvent(key)) && occursin("Open a production first", listed.status)
        end
    end

    @testset "sync_start! connects once the settings are valid and reports each failure" begin
        m = fresh()
        sync_start!(m)
        @test m.running == 1
        settle!(m)
        @test m.host === h && m.options.remote_root == FIXTURE_ROOT && m.picking && m.root === nothing && "test" in m.productions
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        @test m.root !== nothing && m.production.name == m.productions[1] && m.settings.production == m.productions[1]
        m2 = started(; production = "test")
        @test !m2.picking && m2.production.name == "test" && !sync_dirty(m2)

        m3 = started(; host_factory = _ -> error("unknown host x"))
        @test m3.modal_kind == :error && occursin("checking host local: ", m3.modal.message) &&
              occursin("unknown host x", m3.modal.message) && m3.host === nothing
        m4 = started(; root = joinpath(FIXTURE_ROOT, "nosuch"))
        @test m4.modal_kind == :error && occursin("listing productions on local: ", m4.modal.message)
        bad = SyncPage(SyncSettings(; host = "x", remote_root = "/x", local_root = joinpath(tempdir(), "no-such-sync-dir")), TaskQueue())
        sync_start!(bad)
        @test bad.running == 0 && occursin("is not an existing directory", bad.status)
        no_root = SyncPage(SyncSettings(; host = "x", remote_root = "/x", local_root = ""), TaskQueue())
        sync_start!(no_root)
        @test no_root.running == 0 && no_root.status == "Local root must be set" && blocked(no_root)
        empty = started(; root = mktempdir())
        @test empty.productions == String[] && !empty.picking && occursin("no productions found", empty.status)
        open_picker!(empty)
        @test empty.running == 0 && occursin("no productions found", empty.status)

        missing = started(; production = "nope")
        @test missing.modal_kind == :error && occursin("production nope is not on", missing.modal.message) && missing.root === nothing
        suggested = fresh(; production = "nope")
        suggested.suggested = true   # a production suggested from elsewhere is dropped and the picker opens
        sync_start!(suggested)
        settle!(suggested)
        @test suggested.modal_kind == :none && suggested.settings.production == "" && occursin("nope", suggested.status) &&
              suggested.picking
    end

    @testset "changing the host or remote root reconnects and drops the productions of the old one" begin
        m = fresh()
        sync_start!(m)
        settle!(m)
        old = copy(m.productions)
        sync_key!(m, KeyEvent(:escape))
        draw(m)
        change_setting!(m, :remote_root, EXTRACT_ROOT)
        @test m.connecting && m.productions === nothing && m.picker === nothing && !m.picking
        settle!(m)
        tb = draw(m)
        @test m.productions == ["xprod"] != old && m.picking && find_text(tb, "xprod") !== nothing &&
              find_text(tb, "temp/jl-dev") === nothing

        m2 = started(; production = "test")
        change_setting!(m2, :host, "local2")
        @test m2.productions === nothing && !m2.picking && m2.connecting
        settle!(m2)
        @test m2.settings.host == "local2" && m2.production.name == "test"

        m3 = started(; production = "test")
        set_mode!(m3.root.children[findfirst(c -> c.label == "tier", m3.root.children)], :copy)
        m3.dirty = true
        root = m3.root
        change_setting!(m3, :host, "local2")
        @test m3.modal_kind == :discard && occursin("Discard the marks on test?", m3.modal.message) && m3.settings.host == "local" &&
              m3.productions !== nothing
        sync_key!(m3, KeyEvent(:escape))   # Keep
        @test m3.modal_kind == :none && m3.settings.host == "local" && m3.root === root && sync_dirty(m3)
        change_setting!(m3, :host, "local2")
        sync_key!(m3, KeyEvent(:left))
        sync_key!(m3, KeyEvent(:enter))   # Discard
        settle!(m3)
        @test m3.settings.host == "local2" && m3.root !== root && !sync_dirty(m3) && m3.production.name == "test"
    end

    @testset "Connect, Load, Estimate and Transfer are refused while another task runs" begin
        m = started(; production = "test")
        push!(m.active, "sizes:/x")   # background sizes do not block Connect
        m.running += 1
        m.status = ""
        @test !Sync.busy!(m) && m.status == ""
        m.environment = EnvironmentStatus("julia", "/project", true, String[])
        connect!(m)
        @test m.connecting && !occursin("busy", m.status)
        settle!(m)
        @test m.environment === nothing   # a new connection forgets the helper environment
        pop!(m.active)
        m.running -= 1

        tier = m.root.children[findfirst(c -> c.label == "tier", m.root.children)]
        set_mode!(tier, :copy)
        m.dirty = true
        start_load!(m, save!(m))
        sync_key!(m, KeyEvent('e'))
        @test m.modal_kind == :none && m.estimated === nothing && m.running == 1 && occursin("busy:", m.status)
        sync_key!(m, KeyEvent('t'))
        @test m.modal_kind == :none && m.estimated === nothing
        settle!(m)
        tier = m.root.children[findfirst(c -> c.label == "tier", m.root.children)]
        target = Sync.to_local(m.production, tier.remote_path)
        sync_key!(m, KeyEvent('t'))
        settle!(m)
        @test m.modal_kind == :estimate && m.estimated !== nothing && !ispath(target)
        m.root = production_tree(m.host, m.production)   # the transfer still moves what was estimated
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        @test m.modal_kind == :message && ispath(target) && m.estimated === nothing
        @test_throws "no estimated selection" start_transfer!(m)
    end

    @testset "Save and Load bring the marks back, refuse a selection of another production or host, and keep the tree on failure" begin
        m = started(; production = "test")
        set_mode!(m.root.children[findfirst(c -> c.label == "tier", m.root.children)], :copy)
        sync_key!(m, KeyEvent('s'))
        saved = Selection(m.production, "local", m.root)
        @test isfile(selection_path(m.settings)) && !sync_dirty(m)
        other = fresh(; production = "test", local_root = m.settings.local_root)
        other.settings.selection = selection_path(m.settings)
        sync_start!(other)
        settle!(other)
        draw(other)
        sync_key!(other, KeyEvent('o'))
        @test other.running == 1
        settle!(other)
        @test Selection(other.production, "local", other.root).copy == saved.copy && !sync_dirty(other) &&
              other.saved == selection_path(other.settings)

        m.dirty = true
        root, marks, collapsed = m.root, saved.copy, copy(m.collapsed)
        stale = Selection("local", "test", FIXTURE_ROOT, m.production.local_root, nothing,
                          ["test/config.json", "test/legend-metadata", "test/no-such-dir"],
                          String[], now())
        save_selection(selection_path(m.settings), stale)
        draw(m)
        sync_key!(m, KeyEvent('o'))
        @test m.modal_kind == :discard && occursin("Replace the marks on test", m.modal.message)
        sync_key!(m, KeyEvent(:left))
        sync_key!(m, KeyEvent(:enter))   # the dialog opens on "Keep"; left selects "Replace"
        settle!(m)
        @test m.modal_kind == :error && occursin("test/no-such-dir", m.modal.message) && occursin("listing directories", m.modal.message)
        @test m.root === root && Selection(m.production, "local", m.root).copy == marks && m.collapsed == collapsed && m.dirty &&
              m.step === nothing
        wrong_production = Selection("local", "other", FIXTURE_ROOT, m.production.local_root, nothing, String[], String[], now())
        wrong_host = Selection("viper", "test", FIXTURE_ROOT, m.production.local_root, nothing, String[], String[], now())
        for (selection, message) in
            ((wrong_production, "is for production other"), (wrong_host, "saved for host viper, but the current host is local"))
            save_selection(selection_path(m.settings), selection)
            sync_key!(m, KeyEvent(:enter))
            sync_key!(m, KeyEvent('o'))
            sync_key!(m, KeyEvent(:left))
            sync_key!(m, KeyEvent(:enter))
            settle!(m)
            @test occursin(message, m.modal.message) && m.root === root
        end
        m.settings.host = "edited-after-connect"   # a saved selection records the host of the tree
        @test load_selection(save!(m), m.production).host == "local"
    end

    @testset "the progress line shows each step kind and an error names its step" begin
        m = started(; production = "test")
        step(p) = update!(m, TaskEvent(Symbol("sync:step"), p))
        step(StepProgress("listing detector files", 1, 3, 2, 8, nothing, ""))
        @test occursin("[1/3] listing detector files 2/8", last_row(m)) && occursin('█', last_row(m))
        step(StepProgress("copying", 2, 3, 45, 100, 3 * 1024 * 1024, "3.2MB/s  ETA 0:00:10"))
        @test all(occursin(s, last_row(m)) for s in ("[2/3] copying 45/100", "3.0 M", "3.2MB/s  ETA 0:00:10"))
        step(StepProgress("checking files to copy", 3, 3, 0, nothing, nothing, ""))
        m.step_started = time() - 75
        @test occursin("[3/3] checking files to copy", last_row(m)) && occursin("1:15", last_row(m))
        step(StepProgress("extracting on the host", 1, 3, 1, 4, 2048, ""))
        @test m.step_started > time() - 5   # a new step restarts the clock
        m.modal = Tachikoma.Modal(title = "Transferring", message = "starting…", confirm_label = "", cancel_label = "")
        m.modal_kind = :transfer
        @test occursin("[1/3] extracting on the host 1/4", last_row(m))   # the dialog leaves the progress row visible
        m.modal, m.modal_kind = nothing, :none
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:estimate"), (Estimate(0, 0, 0, true), false, nothing, nothing)))
        @test m.step === nothing && m.modal_kind == :estimate
        update!(m, KeyEvent(:escape))
        @test occursin("selected:", last_row(m))   # the dialog covered the last row

        step(StepProgress("copying", 2, 3, 1, 100, nothing, ""))
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:transfer"), ErrorException("rsync died")))
        @test occursin("rsync died", m.modal.message) && occursin("in step \"copying\", 2 of 3", m.modal.message)
        m.modal, m.modal_kind = nothing, :none

        # An error while a transfer or environment dialog is open goes to the status line; the owner's result replaces the dialog.
        for kind in (:transfer, :busy)
            m.modal_kind = kind
            m.modal = Tachikoma.Modal(title = "Working", message = "…", confirm_label = "", cancel_label = "")
            m.status = ""
            push!(m.pending, "/x")
            m.running += 1
            update!(m, TaskEvent(Symbol("sync:listing:/x"), ErrorException("listing failed")))
            @test m.modal_kind == kind && m.modal.title == "Working" && sync_busy(m) && occursin("listing failed", m.status) &&
                  "/x" ∉ m.pending
        end
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:bootstrap"), ErrorException("pkg failed")))
        @test m.modal_kind == :error && occursin("pkg failed", m.modal.message)
    end

    @testset "a stop ends a running transfer and its rsync, and the next run is not stopped" begin
        m = started(; production = "test")
        sync_key!(m, KeyEvent('t'))
        settle!(m)
        @test m.modal_kind == :estimate
        pidfile = joinpath(mktempdir(), "pid")
        script = """
            #!/bin/sh
            if [ "\$1" = "--version" ]; then echo "rsync  version 3.4.1  protocol version 32"; exit 0; fi
            echo \$\$ > $pidfile
            while :; do printf '  1,000  50%%  1.00MB/s  0:00:01\\r'; sleep 0.05; done
            """
        with_rsync(script) do
            sync_key!(m, KeyEvent(:enter))
            @test sync_running(m) && sync_stoppable(m)
            t_end = time() + 30
            while (m.step === nothing || m.step.total === nothing) && time() < t_end
                drain_tasks!(e -> update!(m, e), m.tasks)
                sleep(0.01)
            end
            @test m.step.step == "copying"
            sync_stop!(m)
            @test sync_running(m) && !sync_stoppable(m) && occursin("stopping", last_row(m))
            settle!(m)
        end
        @test !sync_running(m) && m.modal === nothing && m.modal_kind == :none && m.step === nothing
        @test occursin("stopped", m.status) && occursin("resumes", m.status)
        @test !success(pipeline(`kill -0 $(parse(Int, strip(read(pidfile, String))))`; stderr = devnull))
        sync_key!(m, KeyEvent('t'))
        settle!(m)
        @test m.modal_kind == :estimate
    end

    @testset "a stop ends an estimate even when it finishes first, and a real failure after a stop is reported" begin
        m = started(; production = "test")
        sync_key!(m, KeyEvent('e'))
        @test sync_running(m) && sync_stoppable(m)
        sync_stop!(m)
        settle!(m)
        @test !sync_running(m) && m.modal === nothing && m.modal_kind == :none && m.estimated === nothing &&
              occursin("estimate stopped", m.status)

        m.modal_kind = :estimating
        m.stop[] = true
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:estimate"), ErrorException("the host went away")))
        @test m.modal_kind == :error && occursin("the host went away", m.modal.message)
        m.modal, m.modal_kind = nothing, :transfer
        sync_stop!(m)   # a transfer that ends before the stop can act reports its result
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:transfer"), TransferResult(0, 0, 0, 0, String[], "", "")))
        @test m.modal_kind == :message && m.modal.title == "Transfer complete" && m.status == ""
        for kind in (:busy, :checking)   # work without progress readings cannot be stopped
            m.modal_kind = kind
            @test sync_running(m) && !sync_stoppable(m)
        end
        for kind in (:none, :estimate, :message, :error, :firstn)
            m.modal_kind = kind
            @test !sync_running(m) && !sync_stoppable(m)
        end
    end

    @testset "the environment is checked before an extraction and created only after the user agrees" begin
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        env = joinpath(mktempdir(), "env")
        stub = write_stub_julia(joinpath(mktempdir(), "stub-julia"))
        helper = HelperConfig(; julia = stub, julia_project = env, staging = joinpath(mktempdir(), "stage"))
        m = SyncPage(h, p,
                     Options("local", EXTRACT_ROOT, p.local_root, nothing, "xprod", joinpath(mktempdir(), "x.yaml"), nothing, false, false,
                             0, helper))
        for label in ("tier", "jldsp", "cal", "p18", "r000")
            while current_node(m).label != label
                update!(m, KeyEvent(:down))
            end
            update!(m, KeyEvent(:enter))
            settle!(m)
        end
        update!(m, KeyEvent(:down))   # the detectors row
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :checking
        pending = m.continuation
        for key in (KeyEvent('e'), KeyEvent('q'), KeyEvent('n'), KeyEvent(:enter), KeyEvent(:escape))
            update!(m, key)   # no key reaches the page while the environment is checked
        end
        @test m.modal_kind == :checking && m.modal === nothing && m.continuation === pending && pending !== nothing
        settle!(m)
        @test m.modal_kind == :bootstrap && occursin("Pkg.add", m.modal.message)
        update!(m, KeyEvent(:escape))   # declined: nothing is created and nothing continues
        @test m.modal_kind == :none && m.continuation === nothing && !isdir(env)

        continued = Ref(false)
        with_environment!(m, () -> continued[] = true)
        settle!(m)
        @test m.modal_kind == :bootstrap && m.modal.selected == :confirm
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :busy
        update!(m, KeyEvent(:escape))   # no key reaches the busy dialog
        @test m.modal_kind == :busy
        settle!(m)
        @test continued[] && m.modal === nothing && environment_ready(m.environment) && isfile(joinpath(env, "Project.toml"))
    end

    @testset "the buttons fit the panel at 80 columns and wrap on narrower screens" begin
        for width in (120, 80, 60)
            m = fresh(; production = "test")
            tb = draw(m; width, height = 40)
            rects = [r for (name, r) in m.panel_rects if name in PANEL_BUTTONS]
            @test all(label -> find_text(tb, "[ $label ]") !== nothing, values(Sync.BUTTON_LABELS)) && length(rects) == 5
            @test !any(a.y == b.y && a.x < b.x + b.width && b.x < a.x + a.width for (i, a) in pairs(rects), (j, b) in pairs(rects) if i < j)
            @test all(r -> Tachikoma.right(r) <= width - 1, rects) && (length(unique(r.y for r in rects)) == 1) == (width >= 80)
            r = Dict(m.panel_rects)[:connect]
            sync_mouse!(m, MouseEvent(r.x + 1, r.y, mouse_left, mouse_press, false, false, false))
            @test m.running == 1 && m.connecting
            settle!(m)
            @test m.production.name == "test"
        end
    end
end
