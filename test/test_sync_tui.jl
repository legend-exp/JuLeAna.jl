# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "tui.jl" begin
    h = LocalHost()

    function model(; mount_root = nothing, out = joinpath(mktempdir(), "test.yaml"),
                   root = FIXTURE_ROOT)
        local_root = mktempdir()
        p = Production(h, "test", root, local_root; mount_root)
        options = Options("local", root, local_root, mount_root, "test",
                          out, nothing, false, false)
        SyncPage(h, p, options)
    end

    @testset "initial render" begin
        m = model()
        tb = draw(m)
        @test find_text(tb, "Production: test") !== nothing
        @test find_text(tb, "config.json") !== nothing
        @test find_text(tb, "legend-metadata") === nothing   # sections show their key
        @test find_text(tb, "metadata") !== nothing
        @test find_text(tb, "tier/jlhit") !== nothing
        @test occursin("selected: 0 B copy (0 files), 0 links", row_text(tb, 30))
        @test find_text(tb, "Details") !== nothing
        @test find_text(tb, "space copy") !== nothing
        @test occursin("unsaved", row_text(tb, 30))
    end

    @testset "enter lists a section in the background" begin
        m = model()
        # Move onto the "tier" section: root, config.json, metadata, par, tier.
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        @test current_node(m).label == "tier"
        update!(m, KeyEvent(:enter))
        @test occursin("listing", row_text(draw(m), 30))
        deliver_next!(m)                  # the listing
        deliver_next!(m)                  # the sizes of the listed directories
        tb = draw(m)
        @test find_text(tb, "jlevt") !== nothing
        @test find_text(tb, "jlhit") !== nothing
        @test occursin(format_bytes(4096 + 8192), row_text(tb, find_text(tb, "jlevt").y))

        # Enter again collapses without listing again.
        update!(m, KeyEvent(:enter))
        @test find_text(draw(m), "jlevt") === nothing
        update!(m, KeyEvent(:enter))
        @test find_text(draw(m), "jlevt") !== nothing
    end

    @testset "sizes follow the listing" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))   # tier
        end
        tier = current_node(m)
        update!(m, KeyEvent(:enter))
        deliver_next!(m)                  # the listing
        @test tier.children !== nothing
        @test [c.label for c in tier.children] == ["jlevt", "jlhit"]
        @test all(c -> c.size === nothing, tier.children)
        tb = draw(m)
        row = row_text(tb, find_text(tb, "] jlevt").y)
        @test occursin("…", row) && !occursin(" K", row)

        update!(m, KeyEvent(:down))       # jlevt
        update!(m, KeyEvent(' '))
        @test occursin("selected: 0 B?", row_text(draw(m), 30))   # a size is still missing

        deliver_next!(m)                  # the sizes
        @test [c.size for c in tier.children] == [4096 + 8192, 2048 + 1024 + 18]
        tb = draw(m)
        @test occursin(format_bytes(4096 + 8192), row_text(tb, find_text(tb, "] jlevt").y))
        @test occursin("selected: $(format_bytes(4096 + 8192)) copy", row_text(tb, 30))
        @test !occursin("?", row_text(tb, 30))
    end

    @testset "a child opens while sizes are pending" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        tier = current_node(m)
        update!(m, KeyEvent(:enter))
        deliver_next!(m)                  # the listing
        update!(m, KeyEvent(:down))       # jlevt
        jlevt = current_node(m)
        @test jlevt.size === nothing      # the sizes have not been delivered
        update!(m, KeyEvent(:enter))
        @test jlevt.remote_path in m.pending
        # Two events follow, the sizes and the listing of jlevt, in either order.
        deliver_next!(m)
        deliver_next!(m)
        @test isempty(m.pending)
        @test [c.label for c in jlevt.children] == ["phy"]
        @test [c.size for c in tier.children] == [4096 + 8192, 2048 + 1024 + 18]
    end

    @testset "a failing sizing is reported" begin
        root = joinpath(mktempdir(), "remote")
        cp(joinpath(SYNC_FIXTURES, "remote"), root)
        write(joinpath(root, "test", "config.json"),
              replace(read(joinpath(root, "test", "config.json.in"), String), "@REMOTE_ROOT@" => root))
        m = model(; root)
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        tier = current_node(m)
        update!(m, KeyEvent(:enter))
        # The listing is in the channel, and the sizing starts only once it is delivered.
        timedwait(() -> isready(m.tasks.channel), 30.0) == :ok || error("no listing within 30 s")
        rm(joinpath(tier.remote_path, "jlhit"); recursive = true)
        deliver_next!(m)
        deliver_next!(m)
        @test m.modal_kind == :error
        @test occursin("not a directory", m.modal.message)
        @test all(c -> c.size === nothing, tier.children)
    end

    @testset "a failing sizing leaves an open dialog alone" begin
        root = joinpath(mktempdir(), "remote")
        cp(joinpath(SYNC_FIXTURES, "remote"), root)
        write(joinpath(root, "test", "config.json"),
              replace(read(joinpath(root, "test", "config.json.in"), String), "@REMOTE_ROOT@" => root))
        m = model(; root)
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        tier = current_node(m)
        update!(m, KeyEvent(:enter))
        timedwait(() -> isready(m.tasks.channel), 30.0) == :ok || error("no listing within 30 s")
        rm(joinpath(tier.remote_path, "jlhit"); recursive = true)
        deliver_next!(m)
        open_message!(m, "Working", "a dialog the user is reading")
        @test m.modal_kind == :message
        deliver_next!(m)
        @test m.modal_kind == :message
        @test m.modal.message == "a dialog the user is reading"
        @test occursin("sizes of tier: ", m.status) && occursin("not a directory", m.status)
    end

    @testset "space toggles copy and updates the total" begin
        m = model()
        update!(m, KeyEvent(:down))
        node = current_node(m)
        @test node.label == "config.json"
        update!(m, KeyEvent(' '))
        @test node.mode == :copy
        tb = draw(m)
        @test find_text(tb, "[x] config.json") !== nothing
        @test occursin(format_bytes(filesize(joinpath(FIXTURE_ROOT, "test", "config.json"))),
                       row_text(tb, 30))
        @test occursin("(1 files)", row_text(tb, 30))
        # The production row above it shows the partial marker.
        @test find_text(tb, "[-] Production: test") !== nothing

        update!(m, KeyEvent(' '))
        @test node.mode == :none
        @test occursin("selected: 0 B", row_text(draw(m), 30))
    end

    @testset "link mode needs a mount root" begin
        m = model()
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent('l'))
        @test current_node(m).mode == :none
        @test occursin("mount", row_text(draw(m), 30))

        mounted = model(; mount_root = "/Volumes/cslg4")
        update!(mounted, KeyEvent(:down))
        update!(mounted, KeyEvent('l'))
        @test current_node(mounted).mode == :link
        @test find_text(draw(mounted), "[~] config.json") !== nothing
    end

    @testset "s saves the selection" begin
        out = joinpath(mktempdir(), "sync", "test.yaml")
        m = model(; out)
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(' '))
        @test m.dirty
        update!(m, KeyEvent('s'))
        @test !m.dirty
        @test isfile(out)
        # The right span names the selection file. A path outside the default
        # selection directory is shown by its basename, so the bar fits.
        @test occursin("saved: test.yaml", row_text(draw(m), 30))
        back = load_selection(out, m.production)
        @test joinpath("test", "config.json") in back.copy
        @test joinpath("test", "legend-metadata") in back.copy
    end

    @testset "e shows the exact estimate" begin
        m = model()
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(' '))          # config.json
        update!(m, KeyEvent('e'))
        @test occursin("estimating", row_text(draw(m), 30))
        settle!(m)
        @test m.modal_kind == :estimate
        @test m.estimate isa Estimate
        tb = draw(m)
        @test find_text(tb, "Estimate") !== nothing
        @test find_text(tb, "Sync") !== nothing
        # config.json, the overlay and the always-copied legend-metadata README.
        @test m.estimate.files == 3

        # Escape closes it and changes nothing on disk.
        update!(m, KeyEvent(:escape))
        @test m.modal_kind == :none
        @test !isdir(joinpath(m.production.local_root, "test", "legend-metadata"))
    end

    @testset "t transfers and reports" begin
        m = model()
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(' '))
        update!(m, KeyEvent('t'))
        settle!(m)
        @test m.modal_kind == :estimate
        @test m.modal.selected == :confirm

        update!(m, KeyEvent(:enter))       # confirm
        @test m.modal_kind == :transfer
        settle!(m)
        @test m.modal_kind == :message
        @test occursin("transferred", m.modal.message)
        @test occursin("LEGEND_DATA_CONFIG=", m.modal.message)
        @test isfile(joinpath(m.production.local_root, "test", "config.json"))
        @test isfile(joinpath(m.production.local_root, "test", "config_local.yaml"))
        @test m.progress === nothing
        # Local state is refreshed, so the details pane no longer says missing.
        update!(m, KeyEvent(:enter))       # close the summary
        @test m.modal_kind == :none
        @test current_node(m).local_state == :present
    end

    @testset "escape does not dismiss the transfer modal" begin
        m = model()
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(' '))
        update!(m, KeyEvent('t'))
        settle!(m)
        update!(m, KeyEvent(:enter))       # confirm: starts the transfer
        @test m.modal_kind == :transfer

        update!(m, KeyEvent(:escape))
        @test m.modal_kind == :transfer
        @test m.modal !== nothing

        settle!(m)
        @test m.modal_kind == :message
        @test occursin("transferred", m.modal.message)
    end

    @testset "a progress reading drives the gauge" begin
        m = model()
        m.progress = Progress(4096, 0.5, "1.2MB/s", "0:00:03")
        row = row_text(draw(m), 30)
        @test occursin("4.0 K", row)
        @test occursin("ETA 0:00:03", row)
        @test occursin('█', row)
    end

    @testset "an error opens a modal and the tool stays usable" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        # Offline failure: no test may reach cslg4.
        current_node(m).remote_path = joinpath(FIXTURE_ROOT, "no-such-directory")
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test m.modal_kind == :error
        @test find_text(draw(m), "Error") !== nothing
        # The listing is no longer in flight, so the node can be expanded again.
        @test isempty(m.pending)
        update!(m, KeyEvent(:escape))
        @test m.modal_kind == :none
        update!(m, KeyEvent(:up))
        @test current_node(m) !== nothing
    end

    @testset "a failing listing only clears its own pending marker" begin
        m = model()
        # A second, unrelated listing that is still in flight when this one fails.
        push!(m.pending, "some/other/listing/in-flight")

        for _ in 1:4
            update!(m, KeyEvent(:down))   # tier
        end
        bad = current_node(m)
        # Offline failure: no test may reach cslg4.
        bad.remote_path = joinpath(FIXTURE_ROOT, "no-such-directory")

        request_expand!(m, bad)
        @test bad.remote_path in m.pending
        settle!(m)

        @test bad.remote_path ∉ m.pending
        @test "some/other/listing/in-flight" in m.pending
        @test m.modal_kind == :error
    end

    @testset "an unexpected background result is an error" begin
        m = model()
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:nonsense"), 1))
        @test m.modal_kind == :error && occursin("unexpected background result :nonsense", m.modal.message)
    end

    @testset "n selects the first N filekeys" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))   # tier
        end
        update!(m, KeyEvent(:enter))
        settle!(m)
        update!(m, KeyEvent(:down))       # jlevt
        update!(m, KeyEvent(:enter))
        settle!(m)
        update!(m, KeyEvent(:down))       # phy
        update!(m, KeyEvent(:enter))
        settle!(m)
        update!(m, KeyEvent(:down))       # p18
        update!(m, KeyEvent(:enter))
        settle!(m)
        update!(m, KeyEvent(:down))       # detectors
        update!(m, KeyEvent(:down))       # r000
        update!(m, KeyEvent(:enter))
        settle!(m)
        run_node = current_node(m)
        @test run_node.label == "r000"

        update!(m, KeyEvent('n'))
        @test m.modal_kind == :firstn
        @test find_text(draw(m), "First N filekeys") !== nothing

        update!(m, KeyEvent('x'))         # not a number
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :firstn     # the prompt stays open
        @test occursin("positive number", m.status)

        update!(m, KeyEvent(:backspace))
        update!(m, KeyEvent('1'))
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :none
        @test [c.mode for c in filekey_groups(run_node)] == [:copy, :none]
        @test occursin(format_bytes(4096), row_text(draw(m), 30))

        # Escape leaves the selection alone.
        update!(m, KeyEvent('n'))
        update!(m, KeyEvent('2'))
        update!(m, KeyEvent(:escape))
        @test m.modal_kind == :none
        @test [c.mode for c in filekey_groups(run_node)] == [:copy, :none]
    end

    @testset "space on an inherited mode excludes that node" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))   # tier
        end
        update!(m, KeyEvent(' '))
        update!(m, KeyEvent(:enter))
        settle!(m)
        update!(m, KeyEvent(:down))       # jlevt, which inherits tier's :copy
        update!(m, KeyEvent(' '))
        tb = draw(m)
        @test find_text(tb, "[ ] jlevt") !== nothing
        @test find_text(tb, "[x] jlhit") !== nothing
        @test find_text(tb, "[-] tier ") !== nothing
    end

    @testset "a listing that comes back empty keeps the cursor in the tree" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        section = current_node(m)
        update!(m, KeyEvent(:enter))
        settle!(m)
        update!(m, KeyEvent(:end_key))
        @test current_node(m) !== section
        attach_listing!(m, (section, Node[]))
        @test current_node(m) !== nothing
    end

    @testset "the production node lists the overlays" begin
        local_root = mktempdir()
        nested = Production(h, "temp/jl-dev", FIXTURE_ROOT, local_root)
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "temp/jl-dev",
                          joinpath(mktempdir(), "sel.yaml"), nothing, false, false)
        tb = draw(SyncPage(h, nested, options); width = 160)
        @test find_text(tb, "overlays: config_fixture.json, temp/config_site.yaml") !== nothing

        bare = Production(nested.name, nested.remote_root, nested.local_root, nothing,
                          nested.config, nested.roots, String[])
        @test find_text(draw(SyncPage(h, bare, options); width = 160), "overlays: none") !== nothing
    end

    @testset "production picker" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        m = sync_start!(SyncPage(h, options))
        @test find_text(draw(m), "Productions on local") !== nothing
        @test find_text(draw(m), "listing…") !== nothing
        settle!(m)
        tb = draw(m)
        @test find_text(tb, "listing…") === nothing
        @test find_text(tb, "temp/jl-dev") !== nothing
        @test find_text(tb, "test") !== nothing

        update!(m, KeyEvent(:enter))
        settle!(m)
        tb = draw(m)
        @test find_text(tb, "Production: temp/jl-dev") !== nothing
        @test find_text(tb, "config.json") !== nothing
        @test m.options.production == "temp/jl-dev"
        @test m.options.out == joinpath(default_selection_dir(), "temp-jl-dev.yaml")
        @test m.production.name == "temp/jl-dev"

        # The tree screen behaves as before: save writes the chosen file.
        m.options = Options("local", FIXTURE_ROOT, local_root, nothing, "temp/jl-dev",
                            joinpath(mktempdir(), "sel.yaml"), nothing, false, false)
        update!(m, KeyEvent('s'))
        @test load_selection(m.options.out, m.production).production == "temp/jl-dev"
    end

    @testset "picker: arrows move, errors open the modal" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        m = sync_start!(SyncPage(h, options))
        settle!(m)
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test m.production.name == "test"

        missing_root = Options("local", joinpath(FIXTURE_ROOT, "nosuch"), local_root, nothing,
                               "", "", nothing, false, false)
        m4 = sync_start!(SyncPage(h, missing_root))
        settle!(m4)
        @test m4.modal_kind == :error
        @test find_text(draw(m4), "not a directory") !== nothing

        # After the error is dismissed the picker says so and can retry.
        update!(m4, KeyEvent(:escape))
        @test m4.modal === nothing
        tb = draw(m4)
        @test find_text(tb, "no productions found") !== nothing
        @test find_text(tb, "listing…") === nothing
        m4.options = options
        update!(m4, KeyEvent('r'))
        @test find_text(draw(m4), "listing…") !== nothing
        settle!(m4)
        @test find_text(draw(m4), "temp/jl-dev") !== nothing
    end

    @testset "mouse" begin
        click(x, y) = MouseEvent(x, y, mouse_left, mouse_press, false, false, false)
        wheel(x, y, button) = MouseEvent(x, y, button, mouse_press, false, false, false)
        # Screen position of tree row k (1-based) at the current scroll offset.
        row_pos(m, k) = (m.tree.last_area.x + 2, m.tree.last_area.y + k - 1 - m.tree.offset)

        @testset "wheel scrolls the tree" begin
            m = model()
            draw(m; height = 8)
            area = m.tree.last_area
            @test tree_visible_count(m.tree) > area.height
            @test m.tree.offset == 0
            update!(m, wheel(area.x, area.y, mouse_scroll_down))
            @test m.tree.offset == 1
            @test m.tree.selected >= 2    # the selection stays in the window
            draw(m; height = 8)
            @test m.tree.offset == 1
            update!(m, wheel(area.x, area.y, mouse_scroll_up))
            @test m.tree.offset == 0
            # The wheel outside the tree does nothing.
            update!(m, wheel(area.x + 200, area.y, mouse_scroll_down))
            @test m.tree.offset == 0
        end

        @testset "click selects, second click acts like enter" begin
            m = model()
            draw(m)
            tier = 5    # root, config.json, metadata, par, tier
            update!(m, click(row_pos(m, tier)...))
            @test current_node(m).label == "tier"
            @test m.tree.selected == tier
            @test find_text(draw(m), "jlevt") === nothing

            update!(m, click(row_pos(m, tier)...))
            @test occursin("listing", row_text(draw(m), 30))
            settle!(m)
            @test find_text(draw(m), "jlevt") !== nothing

            # A click on the open row collapses it, another reopens it.
            update!(m, click(row_pos(m, tier)...))
            @test find_text(draw(m), "jlevt") === nothing
            update!(m, click(row_pos(m, tier)...))
            @test find_text(draw(m), "jlevt") !== nothing
        end

        @testset "ignored events" begin
            m = model()
            draw(m)
            area = m.tree.last_area
            before = (m.tree.selected, m.tree.offset)
            update!(m, click(area.x + 200, area.y))                                          # outside
            update!(m, MouseEvent(row_pos(m, 3)..., mouse_right, mouse_press, false, false, false))
            update!(m, MouseEvent(row_pos(m, 3)..., mouse_left, mouse_release, false, false, false))
            update!(m, MouseEvent(row_pos(m, 3)..., mouse_left, mouse_drag, false, false, false))
            update!(m, click(area.x + 2, area.y + 25))                                       # below the rows
            @test (m.tree.selected, m.tree.offset) == before
            @test isempty(m.pending)
            # A left press on a row with no dialog does select it, so the ignored events above are not vacuous.
            update!(m, click(row_pos(m, 3)...))
            @test m.tree.selected == 3

            # A dialog swallows the click: nothing is selected, answered or listed.
            open_message!(m, "Working", "a dialog the user is reading")
            kind = m.modal_kind
            tree_before = m.tree.selected
            update!(m, click(row_pos(m, 3)...))
            update!(m, click(row_pos(m, 3)...))
            @test m.modal_kind == kind
            @test m.modal !== nothing
            @test m.tree.selected == tree_before
            @test isempty(m.pending)

            m.modal = nothing
            m.modal_kind = :busy
            update!(m, click(row_pos(m, 3)...))
            @test m.tree.selected == tree_before
            @test m.modal_kind == :busy
        end

        @testset "picker" begin
            options = Options("local", FIXTURE_ROOT, mktempdir(), nothing, "", "", nothing, false, false)
            m = sync_start!(SyncPage(h, options))
            settle!(m)
            draw(m)
            area = m.picker.last_area
            update!(m, click(area.x + 1, area.y + 1))
            @test m.picker.selected == 2
            @test m.screen == :pick
            update!(m, click(area.x + 200, area.y + 1))
            @test m.picker.selected == 2
            # A click is ignored while a background task is active.
            m.running += 1
            update!(m, click(area.x + 1, area.y + 2))
            @test m.picker.selected == 2 && m.screen == :pick
            m.running -= 1
            update!(m, click(area.x + 1, area.y + 1))
            settle!(m)
            @test m.production.name == m.productions[2]
            @test find_text(draw(m), "Production: $(m.productions[2])") !== nothing
        end
    end
end
