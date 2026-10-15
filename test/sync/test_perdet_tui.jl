@testset "per-detector tier: interface" begin
    h = LocalHost()
    tier = joinpath(PERDET_ROOT, "dprod", "generated", "tier")
    # A helper that cannot run: these rows never need the environment dialog.
    broken = HelperConfig(; julia = "/nonexistent/julia", staging = mktempdir())

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
    function model(; mount_root = "/")
        local_root = mktempdir()
        p = Production(h, "dprod", PERDET_ROOT, local_root; mount_root)
        SyncModel(h, p, Options("local", PERDET_ROOT, local_root, mount_root, "dprod",
                                joinpath(mktempdir(), "x.yaml"), nothing, false, false, 0, broken))
    end
    function open!(m::SyncModel, label)
        for _ in 1:40
            current_node(m).label == label && break
            update!(m, KeyEvent(:down))
        end
        @test current_node(m).label == label
        update!(m, KeyEvent(:enter))
        settle!(m)
        (m.tasks.active[] > 0 || isready(m.tasks.channel)) && settle!(m)
    end
    function to_period!(m::SyncModel)
        for label in ("tier", "jlqcs", "cal", "p16")
            open!(m, label)
        end
    end
    function goto!(m::SyncModel, node)
        update!(m, KeyEvent(:home))
        for _ in 1:80
            current_node(m) === node && return
            update!(m, KeyEvent(:down))
        end
        error("row $(node.label) is not visible")
    end

    @testset "the row lists in the background without the helper environment" begin
        m = model()
        to_period!(m)
        period = current_node(m)
        @test [c.kind for c in period.children] == [:detectors, :dir, :dir]
        row = period.children[1]
        goto!(m, row)
        @test find_text(draw(m), "enter lists the detector files of every run in p16") !== nothing
        update!(m, KeyEvent(:enter))
        @test startswith(m.status, "listing")
        @test m.modal_kind == :none
        settle!(m)
        @test m.environment === nothing && m.modal === nothing
        tb = draw(m)
        @test find_text(tb, "B00000C") !== nothing && find_text(tb, "V01234A") !== nothing
        @test occursin(format_bytes(400), row_text(tb, find_text(tb, "B00000C").y))
        @test row.children[1].whole_files
    end

    @testset "space and l mark a detector, x is refused" begin
        m = model()
        to_period!(m)
        open!(m, "detectors")
        update!(m, KeyEvent(:down))                              # B00000C
        b = current_node(m)
        @test b.label == "B00000C"
        update!(m, KeyEvent(' '))
        @test b.mode == :copy && m.dirty
        @test find_text(draw(m), "[x] B00000C") !== nothing
        @test occursin("400 B copy (2 files)", row_text(draw(m), 30))
        update!(m, KeyEvent('l'))
        @test b.mode == :link
        @test find_text(draw(m), "[~] B00000C") !== nothing
        @test occursin("2 links", row_text(draw(m), 30))
        update!(m, KeyEvent('l'))
        @test b.mode == :none

        m.status = ""
        update!(m, KeyEvent('x'))
        @test occursin("hold one detector each", m.status)
        @test b.mode == :none
        update!(m, KeyEvent('n'))
        @test m.modal_kind == :none

        nomount = model(; mount_root = nothing)
        to_period!(nomount)
        open!(nomount, "detectors")
        update!(nomount, KeyEvent(:down))
        update!(nomount, KeyEvent('l'))
        @test occursin("needs a mount root", nomount.status)
    end

    @testset "details name the runs that hold the detector" begin
        m = model()
        to_period!(m)
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent(:down))     # V01234A
        tb = draw(m)
        @test find_text(tb, "V01234A") !== nothing
        @test find_text(tb, "held by r000") !== nothing
        @test find_text(tb, format_bytes(200)) !== nothing
        update!(m, KeyEvent(:up))                                    # B00000C
        @test find_text(draw(m), "held by r000, r001") !== nothing
        @test find_text(draw(m), "400 B") !== nothing
    end

    @testset "run rows show the mark and refuse to change it" begin
        m = model()
        to_period!(m)
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent(' '))        # B00000C
        period = current_node(m).parent.parent
        r000 = run_dirs(period)[1]
        goto!(m, r000); update!(m, KeyEvent(:enter)); settle!(m)
        row = r000.children[1]
        @test row.label == "B00000C"
        @test checkbox(row) == "[x]"
        goto!(m, row)
        m.status = ""
        update!(m, KeyEvent(' '))
        @test occursin("unmark the period's detector", m.status)
        @test row.mode == :none
        m.status = ""
        update!(m, KeyEvent('l'))
        @test occursin("unmark the period's detector", m.status)
        # The other detector of the run can still be marked.
        goto!(m, r000.children[2]); update!(m, KeyEvent(' '))
        @test r000.children[2].mode == :copy

        goto!(m, r000)
        m.status = ""
        update!(m, KeyEvent(' '))
        @test occursin("cannot mark r000 :copy", m.status) && r000.mode == :none
    end

    @testset "t transfers the files of a period detector" begin
        m = model()
        to_period!(m)
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent(' '))        # B00000C
        update!(m, KeyEvent(:down)); update!(m, KeyEvent(' '))        # V01234A
        update!(m, KeyEvent('t')); settle!(m)
        @test m.modal_kind == :estimate
        @test m.estimate.files == 5 && m.estimate.bytes == filesize(joinpath(PERDET_ROOT, "dprod", "config.json")) +
              filesize(joinpath(PERDET_ROOT, "dprod", "legend-metadata", "README.md")) + 100 + 200 + 300
        @test occursin("not in run: V01234A in", m.modal.message)
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test m.modal_kind == :message
        @test occursin("not in run, left out: V01234A in", m.modal.message)
        local_period = joinpath(m.production.local_root, "dprod", "generated", "tier", "jlqcs", "cal", "p16")
        @test length(readdir(joinpath(local_period, "r000"))) == 2
        @test length(readdir(joinpath(local_period, "r001"))) == 1
    end

    @testset "a saved selection is restored onto the tree" begin
        m = model()
        to_period!(m)
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent(' '))
        path = save!(m)
        sel = load_selection(path, m.production)
        @test [(e.detectors, e.mode) for e in sel.detector_files] == [(["B00000C"], :copy)]
    end

    @testset "category and filekey periods are unchanged" begin
        m = model()
        for label in ("tier", "jlqcs", "cal")
            open!(m, label)
        end
        cal = current_node(m)
        @test cal.label == "cal" && !any(c -> c.kind == :detectors, cal.children)
    end
end
