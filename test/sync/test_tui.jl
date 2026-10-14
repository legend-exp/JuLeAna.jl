@testset "tui.jl" begin
    h = LocalHost()

    # Render the model the way the app loop does: its own Frame over a TestBackend
    # buffer, so row_text and find_text can read the result back.
    function draw(m::SyncModel; width = 100, height = 30)
        tb = TestBackend(width, height)
        reset!(tb.buf)
        view(m, Frame(tb.buf, Rect(1, 1, width, height),
                      GraphicsRegion[], PixelSnapshot[]))
        tb
    end

    # Wait for the background work and deliver its results exactly as the app
    # loop does. TaskQueue offers no predicate for "an event is waiting", so this
    # reads the channel drain_tasks! itself reads: a change to that field would
    # break the public reader with it and surface here. Waiting for `active` to
    # fall back to zero is what makes a transfer settle as one unit: it pushes
    # progress readings long before it pushes its result.
    function settle!(m::SyncModel)
        timedwait(() -> m.tasks.active[] == 0 && isready(m.tasks.channel), 30.0) == :ok ||
            error("the background task did not finish within 30 s")
        drain_tasks!(e -> update!(m, e), m.tasks)
    end

    function model(; mount_root = nothing, out = joinpath(mktempdir(), "test.json"))
        local_root = mktempdir()
        p = Production(h, "test", FIXTURE_ROOT, local_root; mount_root)
        options = Options("local", FIXTURE_ROOT, local_root, mount_root, "test",
                          out, nothing, false, false)
        SyncModel(h, p, options)
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
        settle!(m)
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
        out = joinpath(mktempdir(), "sync", "test.json")
        m = model(; out)
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(' '))
        @test m.dirty
        update!(m, KeyEvent('s'))
        @test !m.dirty
        @test isfile(out)
        # The right span names the selection file. A path outside the default
        # selection directory is shown by its basename, so the bar fits.
        @test occursin("saved: test.json", row_text(draw(m), 30))
        back = load_selection(out, m.production)
        @test joinpath("test", "config.json") in back.copy
        @test joinpath("test", "legend-metadata") in back.copy
    end

    @testset "q quits" begin
        m = model()
        @test !should_quit(m)
        update!(m, KeyEvent('q'))
        @test should_quit(m)
        @test task_queue(m) === m.tasks
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
        @test isfile(joinpath(m.production.local_root, "test", "config_local.json"))
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
        @test_throws "unexpected background result :nonsense" update!(m, TaskEvent(:nonsense, 1))
    end

    @testset "n selects the first N filekeys" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))   # tier
        end
        update!(m, KeyEvent(:enter)); settle!(m)
        update!(m, KeyEvent(:down))       # jlevt
        update!(m, KeyEvent(:enter)); settle!(m)
        update!(m, KeyEvent(:down))       # phy
        update!(m, KeyEvent(:enter)); settle!(m)
        update!(m, KeyEvent(:down))       # p18
        update!(m, KeyEvent(:enter)); settle!(m)
        update!(m, KeyEvent(:down))       # detectors
        update!(m, KeyEvent(:down))       # r000
        update!(m, KeyEvent(:enter)); settle!(m)
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

    @testset "q asks to save when the selection changed" begin
        out = joinpath(mktempdir(), "test.json")
        m = model(; out)
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(' '))
        update!(m, KeyEvent('q'))
        @test m.modal_kind == :quit
        @test !should_quit(m)
        update!(m, KeyEvent(:enter))       # confirm: save and quit
        @test should_quit(m)
        @test isfile(out)

        # With nothing changed, q leaves at once.
        m2 = model()
        update!(m2, KeyEvent('q'))
        @test should_quit(m2)
    end

    @testset "ctrl-c leaves the way q does" begin
        m = model()
        update!(m, KeyEvent(:ctrl_c))
        @test should_quit(m)

        changed = model()
        update!(changed, KeyEvent(:down))
        update!(changed, KeyEvent(' '))
        update!(changed, KeyEvent(:ctrl_c))
        @test changed.modal_kind == :quit
        @test !should_quit(changed)
    end

    @testset "space on an inherited mode excludes that node" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))   # tier
        end
        update!(m, KeyEvent(' '))
        update!(m, KeyEvent(:enter)); settle!(m)
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
        update!(m, KeyEvent(:enter)); settle!(m)
        update!(m, KeyEvent(:end_key))
        @test current_node(m) !== section
        attach_listing!(m, (section, Node[]))
        @test current_node(m) !== nothing
    end

    @testset "the production node lists the overlays" begin
        local_root = mktempdir()
        nested = Production(h, "temp/jl-dev", FIXTURE_ROOT, local_root)
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "temp/jl-dev",
                          joinpath(mktempdir(), "sel.json"), nothing, false, false)
        tb = draw(SyncModel(h, nested, options); width = 160)
        @test find_text(tb, "overlays: config_fixture.json, temp/config_site.yaml") !== nothing

        bare = Production(nested.name, nested.remote_root, nested.local_root, nothing,
                          nested.config, nested.roots, String[])
        @test find_text(draw(SyncModel(h, bare, options); width = 160), "overlays: none") !== nothing
    end

    @testset "production picker" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        m = SyncModel(h, options)
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
        @test m.options.out == joinpath(DEFAULT_SELECTION_DIR, "temp-jl-dev.json")
        @test m.production.name == "temp/jl-dev"

        # The tree screen behaves as before: save writes the chosen file.
        m.options = Options("local", FIXTURE_ROOT, local_root, nothing, "temp/jl-dev",
                            joinpath(mktempdir(), "sel.json"), nothing, false, false)
        update!(m, KeyEvent('s'))
        @test load_selection(m.options.out, m.production).production == "temp/jl-dev"
    end

    @testset "picker: arrows move, q and ctrl-c quit, errors open the modal" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        m = SyncModel(h, options)
        settle!(m)
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test m.production.name == "test"

        m2 = SyncModel(h, options)
        settle!(m2)
        update!(m2, KeyEvent('q'))
        @test should_quit(m2)
        m3 = SyncModel(h, options)
        update!(m3, KeyEvent(:ctrl_c))
        @test should_quit(m3)

        missing_root = Options("local", joinpath(FIXTURE_ROOT, "nosuch"), local_root, nothing,
                               "", "", nothing, false, false)
        m4 = SyncModel(h, missing_root)
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
end
