# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "tier/detector layout: interface" begin
    h = LocalHost()
    tier = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier")
    p18 = joinpath(tier, "jlpks", "cal", "p18")
    r001 = joinpath(p18, "r001")

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
    function model(; helper = HelperConfig(; staging = joinpath(mktempdir(), "stage")))
        local_root = mktempdir()
        p = Production(h, "tprod", TIER_DET_ROOT, local_root)
        SyncModel(h, p, Options("local", TIER_DET_ROOT, local_root, nothing, "tprod",
                                joinpath(mktempdir(), "x.yaml"), nothing, false, false, 0, helper))
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
    function to_period!(m::SyncModel, tier_name, category)
        for label in ("tier", tier_name, category, "p18")
            open!(m, label)
        end
    end
    # Move the cursor onto `node` from the top of the tree.
    function goto!(m::SyncModel, node)
        update!(m, KeyEvent(:home))
        for _ in 1:80
            current_node(m) === node && return
            update!(m, KeyEvent(:down))
        end
        error("row $(node.label) is not visible")
    end

    @testset "a period's detectors are listed, marked and estimated" begin
        m = model()
        to_period!(m, "jlpks", "cal")
        period = current_node(m)
        @test [c.kind for c in period.children] == [:detectors, :dir, :dir]
        open!(m, "detectors")
        tb = draw(m)
        for name in ("B00000C", "V01234A", "aux")
            @test find_text(tb, name) !== nothing
        end
        @test occursin(format_bytes(1200), row_text(tb, find_text(tb, "B00000C").y))
        @test find_text(draw(m), format_bytes(6000)) !== nothing       # the detectors row's summed size

        update!(m, KeyEvent(:down))                                    # B00000C
        update!(m, KeyEvent('x'))
        @test current_node(m).mode == :extract
        @test find_text(draw(m), "[e] B00000C") !== nothing
        @test occursin("~1.2 K extract (3 files)", row_text(draw(m), 30))
        @test find_text(draw(m), "detector of the runs of p18") !== nothing

        update!(m, KeyEvent('e')); settle!(m)
        @test m.modal_kind == :estimate
        @test (m.estimate.extract_bytes, m.estimate.extract_files, m.estimate.extract_exact) == (1600, 3, true)
        @test isempty(m.estimate.not_in_run)
        update!(m, KeyEvent(:escape))

        update!(m, KeyEvent(:down)); update!(m, KeyEvent(:down))        # aux
        update!(m, KeyEvent('x'))
        update!(m, KeyEvent('e')); settle!(m)
        @test m.estimate.extract_bytes == 1600 + 3600
        @test m.estimate.not_in_run == [(relative(m.production, r001), "aux")]
        @test occursin("1 not in run", m.modal.message)
        @test occursin("not in run: aux in $(relative(m.production, r001))", m.modal.message)
        update!(m, KeyEvent(:escape))
    end

    @testset "t extracts a period through the interface" begin
        m = model()
        to_period!(m, "jlpks", "cal")
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent('x'))          # B00000C
        update!(m, KeyEvent(:down)); update!(m, KeyEvent(:down)); update!(m, KeyEvent('x'))   # aux
        update!(m, KeyEvent('t')); settle!(m)
        @test m.modal.selected == :confirm
        update!(m, KeyEvent(:enter))
        @test m.modal_kind == :transfer
        settle!(m)
        @test m.modal_kind == :message
        @test occursin("extracted 3 files, 5 groups", m.modal.message)
        @test occursin("not in run, left out: aux in $(relative(m.production, r001))", m.modal.message)
        local_dir = joinpath(m.production.local_root, "tprod", "generated", "tier", "jlpks", "cal", "p18")
        @test length(readdir(joinpath(local_dir, "r000"))) == 2
        @test length(readdir(joinpath(local_dir, "r001"))) == 1
    end

    @testset "run-level rows show the period mark and refuse x" begin
        m = model()
        to_period!(m, "jlpks", "cal")
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent('x'))          # B00000C for the period
        period_row = current_node(m)
        period = period_row.parent.parent
        r000 = run_dirs(period)[1]
        goto!(m, r000); update!(m, KeyEvent(:enter)); settle!(m)
        run_detectors = r000.children[1]
        goto!(m, run_detectors); update!(m, KeyEvent(:enter)); settle!(m)
        (m.tasks.active[] > 0 || isready(m.tasks.channel)) && settle!(m)
        row = run_detectors.children[1]
        @test row.label == "B00000C" && row.mode == :none
        @test checkbox(row) == "[e]"
        goto!(m, row)
        @test find_text(draw(m), "yes (whole period)") !== nothing
        m.status = ""
        update!(m, KeyEvent('x'))
        @test occursin("extracted for the whole period", m.status)
        @test row.mode == :none

        # A redundant run-level mark can still be removed while the period is marked.
        set_mode!(row, :extract)
        rebuild_tree!(m)
        goto!(m, row)
        m.status = ""
        update!(m, KeyEvent('x'))
        @test row.mode == :none && isempty(m.status)
        @test checkbox(row) == "[e]"
    end

    @testset "refused marks become status lines" begin
        m = model()
        to_period!(m, "jlpks", "cal")
        open!(m, "detectors")
        update!(m, KeyEvent(:down)); update!(m, KeyEvent('x'))          # B00000C
        bnode = current_node(m)
        period = bnode.parent.parent
        goto!(m, period)
        m.status = ""
        update!(m, KeyEvent(' '))
        @test occursin("cannot mark p18 :copy: detector B00000C of p18 is marked for extraction", m.status)
        @test period.mode == :none

        goto!(m, bnode); update!(m, KeyEvent('x'))                      # unmark
        @test bnode.mode == :none
        set_mode!(run_dirs(period)[1], :copy)
        rebuild_tree!(m)
        goto!(m, bnode)
        m.status = ""
        update!(m, KeyEvent('x'))
        @test occursin("r000 is already transferred whole (:copy on r000)", m.status)
        @test bnode.mode == :none
    end

    @testset "a period without a detector axis loses its detectors row" begin
        m = model()
        to_period!(m, "jlevt", "phy")
        period = current_node(m)
        @test any(c -> c.kind == :detectors, period.children)
        open!(m, "detectors")
        @test !any(c -> c.kind == :detectors, period.children)
        @test occursin("no per-detector groups", m.status)
    end

    @testset "category and tier rows get no detectors row" begin
        m = model()
        for label in ("tier", "jlpks", "cal")
            open!(m, label)
        end
        cal = current_node(m)
        @test cal.label == "cal" && !any(c -> c.kind == :detectors, cal.children)
    end
end
