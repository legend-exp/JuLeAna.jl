@testset "extract: interface" begin
    h = LocalHost()

    function draw(m::SyncModel; width = 120, height = 30)
        tb = TestBackend(width, height)
        reset!(tb.buf)
        view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
        tb
    end
    function settle!(m::SyncModel)
        timedwait(() -> m.tasks.active[] == 0 && isready(m.tasks.channel), 60.0) == :ok ||
            error("the background task did not finish within 60 s")
        drain_tasks!(e -> update!(m, e), m.tasks)
    end
    function model(; helper = HelperConfig(; staging = joinpath(mktempdir(), "stage")),
                   mount_root = nothing)
        local_root = mktempdir()
        p = Production(h, "xprod", EXTRACT_ROOT, local_root; mount_root)
        SyncModel(h, p, Options("local", EXTRACT_ROOT, local_root, mount_root, "xprod",
                                joinpath(mktempdir(), "x.json"), nothing, false, false, 0, helper))
    end
    # Move the cursor onto the row labeled `label` and expand it.
    function open!(m::SyncModel, label)
        for _ in 1:40
            current_node(m).label == label && break
            update!(m, KeyEvent(:down))
        end
        @test current_node(m).label == label
        update!(m, KeyEvent(:enter))
        settle!(m)
        # A detectors row needs the environment check first, then the listing.
        (m.tasks.active[] > 0 || isready(m.tasks.channel)) && settle!(m)
    end
    function to_run!(m::SyncModel, tier, category)
        for label in ("tier", tier, category, "p18", "r000")
            open!(m, label)
        end
    end

    @testset "detectors are listed, marked and estimated" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        open!(m, "detectors")
        tb = draw(m)
        for name in ("B00000C", "V01234A", "aux")
            @test find_text(tb, name) !== nothing
        end
        @test occursin(format_bytes(400), row_text(tb, find_text(tb, "B00000C").y))
        @test m.environment !== nothing

        update!(m, KeyEvent(:down))                 # B00000C
        update!(m, KeyEvent('x'))
        @test current_node(m).mode == :extract
        @test find_text(draw(m), "[e] B00000C") !== nothing
        @test occursin("~800 B extract (2 files)", row_text(draw(m), 30))
        @test find_text(draw(m), "HDF5 group") !== nothing        # details pane
        @test find_text(draw(m), "[-] detectors") !== nothing

        update!(m, KeyEvent('x'))
        @test current_node(m).mode == :none
        update!(m, KeyEvent('x'))

        update!(m, KeyEvent('e')); settle!(m)   # the environment is already known
        @test m.modal_kind == :estimate
        @test m.estimate.extract_files == 2 && m.estimate.extract_exact
        @test m.estimate.extract_bytes == 400 + 800
        @test occursin("1.2 K extract (2 files)", m.modal.message)
        @test occursin("free", m.modal.message)
        update!(m, KeyEvent(:escape))
    end

    @testset "the detectors row follows the run row" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        run = current_node(m)
        @test first(run.children).kind == :detectors
        tb = draw(m)
        y = find_text(tb, "] r000").y
        @test occursin("detectors", row_text(tb, y + 1))
        update!(m, KeyEvent(:down))
        @test current_node(m).kind == :detectors
    end

    @testset "t extracts through the interface" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        open!(m, "detectors")
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent('x'))
        update!(m, KeyEvent('t')); settle!(m)
        @test m.modal.selected == :confirm
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :transfer
        settle!(m)
        @test m.modal_kind == :message
        @test occursin("extracted 2 files, 2 groups", m.modal.message)
        @test m.extracting === nothing && m.progress === nothing
        run_dir = joinpath(m.production.local_root, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
        @test length(readdir(run_dir)) == 2
    end

    @testset "a tier without per-detector groups loses its detectors row" begin
        m = model()
        to_run!(m, "jlevt", "phy")
        run = current_node(m)
        @test any(c -> c.kind == :detectors, run.children)
        open!(m, "detectors")
        @test !any(c -> c.kind == :detectors, run.children)
        @test occursin("no per-detector groups", m.status)
    end

    @testset "x only applies to detector rows" begin
        m = model()
        update!(m, KeyEvent('x'))
        @test occursin("x extracts a detector", m.status)
        @test !m.dirty
    end

    @testset "space and l do not apply to detector rows" begin
        m = model(; mount_root = mktempdir())
        to_run!(m, "jldsp", "cal")
        open!(m, "detectors")
        for key in (' ', 'l')
            m.status = ""
            update!(m, KeyEvent(key))                   # on the detectors row
            @test occursin("use x on detector rows", m.status)
            @test current_node(m).mode == :none
        end
        update!(m, KeyEvent(:down))                     # B00000C
        for key in (' ', 'l')
            m.status = ""
            update!(m, KeyEvent(key))
            @test occursin("use x on detector rows", m.status)
            @test current_node(m).mode == :none
        end
        @test !m.dirty
    end

    @testset "a run transferred whole cannot be extracted from" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        open!(m, "detectors")
        run = current_node(m).parent
        set_mode!(run, :copy)
        update!(m, KeyEvent(:down))                     # B00000C
        update!(m, KeyEvent('x'))
        @test occursin("already transferred whole", m.status)
        @test current_node(m).mode == :none
    end

    @testset "n does not apply to detector rows" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        open!(m, "detectors")
        for _ in 1:2                                    # detectors row, then B00000C
            m.status = ""
            update!(m, KeyEvent('n'))
            @test occursin("n applies to run directories", m.status)
            @test m.modal_kind == :none && m.input === nothing
            update!(m, KeyEvent(:down))
        end
    end

    @testset "keys are ignored while the environment is checked" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        while current_node(m).label != "detectors"
            update!(m, KeyEvent(:down))
        end
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :checking
        pending = m.continuation
        @test pending !== nothing
        for key in (KeyEvent('e'), KeyEvent('q'), KeyEvent('n'), KeyEvent(:enter), KeyEvent(:escape))
            update!(m, key)
        end
        @test m.modal_kind == :checking && m.modal === nothing && m.input === nothing
        @test m.continuation === pending && !m.quit
        events = TaskEvent[]
        timedwait(() -> m.tasks.active[] == 0 && isready(m.tasks.channel), 60.0) == :ok ||
            error("the environment check did not finish within 60 s")
        drain_tasks!(e -> (push!(events, e); update!(m, e)), m.tasks)
        @test [e.id for e in events] == [:environment]
        (m.tasks.active[] > 0 || isready(m.tasks.channel)) && settle!(m)
        @test m.modal_kind == :none && isempty(m.status)
        @test any(c -> c.label == "B00000C", current_node(m).children)
    end

    @testset "an estimate creates nothing on the host" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent('x'))
        staging = m.options.helper.staging
        update!(m, KeyEvent('e')); settle!(m)
        @test m.modal_kind == :estimate
        @test occursin("free", m.modal.message)
        # Inspecting the files pushes the helper into the staging root; the estimate adds nothing.
        @test !ispath(staging_production_dir(staging, m.production))
    end

    @testset "the environment dialog asks before creating anything" begin
        m = model()
        to_run!(m, "jldsp", "cal")
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent('x'))
        o = m.options
        env = joinpath(mktempdir(), "env")
        stub = write_stub_julia(joinpath(mktempdir(), "stub-julia"))
        m.options = Options(o.host, o.remote_root, o.local_root, o.mount_root, o.production, o.out,
                            o.from, o.dry_run, o.yes, 0,
                            HelperConfig(; julia = stub, julia_project = env, staging = o.helper.staging))
        m.environment = nothing

        update!(m, KeyEvent('e')); settle!(m)
        @test m.modal_kind == :bootstrap
        @test occursin("Pkg.add", m.modal.message)
        update!(m, KeyEvent(:escape))                # declined: nothing is created or estimated
        @test m.modal_kind == :none && m.continuation === nothing && !isdir(env)

        continued = Ref(false)
        with_environment!(m, () -> continued[] = true); settle!(m)
        @test m.modal_kind == :bootstrap && m.modal.selected == :confirm
        update!(m, KeyEvent(:enter))                 # create
        @test m.modal_kind == :busy
        update!(m, KeyEvent(:escape))                # no key reaches the busy dialog
        @test m.modal_kind == :busy
        settle!(m)
        @test continued[] && m.modal === nothing && environment_ready(m.environment)
        @test isfile(joinpath(env, "Project.toml"))
    end

    @testset "the gauge shows the extracting phase" begin
        m = model()
        m.progress = Progress(0, 0.0, "", "")
        m.extracting = ExtractProgress(3, 20, 4096)
        row = row_text(draw(m), 30)
        @test occursin("extracting 3/20 files", row)
        @test occursin("4.0 K", row)
    end
end
