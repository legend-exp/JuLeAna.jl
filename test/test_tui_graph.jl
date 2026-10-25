# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, row_text, style_at
using LegendDataManagement: DataPeriod, DataRun
using Test

# Render the Graph page of `page` into an `area` of a `width` x `height` test backend.
function render_graph_page(page, snap, prog, width = 120, height = 30; area = Rect(1, 1, width, height))
    tb = TestBackend(width, height)
    JuLeAna.render_graph(page, snap, prog, area, tb.buf)
    return tb
end

graph_text(tb) = join((row_text(tb, r) for r in 1:tb.height), "\n")

# Position `(x, y)` of the first occurrence of `text`, counted in characters.
function locate(tb, text)
    for y in 1:tb.height
        row = row_text(tb, y)
        pos = findfirst(text, row)
        isnothing(pos) || return (; x = length(row, 1, first(pos) - 1) + 1, y)
    end
    return nothing
end

function graph_press(page, snap, sent, key::Symbol)
    return JuLeAna.graph_key!(page, KeyEvent(key), snap, cmd -> push!(sent, cmd))
end
function graph_press(page, snap, sent, key::Char)
    return JuLeAna.graph_key!(page, KeyEvent(key), snap, cmd -> push!(sent, cmd))
end

function entry(name, level, rank; deps = Symbol[], enabled = true, category = :cal)
    return (; name, level, category, rank, enabled, dependencies = deps)
end

# Run level r_a, r_b, r_c (needs p_x), r_off; partition level p_x (needs r_b), p_y
# (needs r_a and r_b). Topological order: r_a r_b r_off p_x r_c p_y.
function graph_snapshot(; run_steps = Symbol[], partition_steps = Symbol[])
    processors = [entry(:r_a, :run, 1), entry(:r_b, :run, 2), entry(:r_c, :run, 3; deps = [:p_x]), entry(:r_off, :run, 4; enabled = false),
                  entry(:p_x, :partition, 1; deps = [:r_b], category = :phy), entry(:p_y, :partition, 2; deps = [:r_a, :r_b])]
    return (; processors, run_steps, partition_steps)
end

const GRAPH_ORDER = [:r_a, :r_b, :r_off, :p_x, :r_c, :p_y]

@testset "Graph page" begin
    snap = graph_snapshot()

    @testset "dependent_processors and rows" begin
        g = processor_graph(snap.processors)
        @test topological_order(g) == GRAPH_ORDER
        @test JuLeAna.graph_rows(JuLeAna.GraphPage(), snap) == GRAPH_ORDER
        @test JuLeAna.graph_rows(JuLeAna.GraphPage(), nothing) == Symbol[]
        @test JuLeAna.graph_rows(JuLeAna.GraphPage(), (; processors = [], run_steps = [], partition_steps = [])) == Symbol[]
    end

    @testset "rows and lanes" begin
        tb = render_graph_page(JuLeAna.GraphPage(), snap, nothing)
        pos = Dict(n => locate(tb, string(n) * " ") for n in GRAPH_ORDER)
        @test issorted([pos[n].y for n in GRAPH_ORDER]) && allunique(p.y for p in values(pos))
        run_x = unique(pos[n].x for n in (:r_a, :r_b, :r_c, :r_off))
        part_x = unique(pos[n].x for n in (:p_x, :p_y))
        @test length(run_x) == 1 && length(part_x) == 1 && only(run_x) < only(part_x)
        @test locate(tb, "Run processors").y == locate(tb, "Partition processors").y < pos[:r_a].y
        @test locate(tb, "Run processors").x < locate(tb, "Partition processors").x
        # a node marker precedes each name, the lane line connects the nodes of a lane
        @test all(n -> Tachikoma.char_at(tb, pos[n].x - 2, pos[n].y) == '●', GRAPH_ORDER)
        @test Tachikoma.char_at(tb, pos[:r_a].x - 2, pos[:r_b].y) == '●'
        @test Tachikoma.char_at(tb, pos[:p_x].x - 2, pos[:r_c].y) == '│'
        @test Tachikoma.char_at(tb, pos[:p_x].x - 2, pos[:r_a].y) == ' '
    end

    @testset "declared edges and tracks" begin
        g = processor_graph(snap.processors)
        rows = GRAPH_ORDER
        edges = JuLeAna.graph_edges(g, rows)
        row(n) = findfirst(==(n), rows)
        # r_b -> p_x, r_b -> p_y, r_a -> p_y, p_x -> r_c
        @test edges == sort([(row(:r_b), row(:p_x)), (row(:r_b), row(:p_y)), (row(:r_a), row(:p_y)), (row(:p_x), row(:r_c))])
        track, ntracks = JuLeAna.assign_tracks(edges)
        # r_a spans rows 1-6, r_b rows 2-6, p_x rows 4-5: all overlap
        @test track[row(:r_a)] != track[row(:r_b)] != track[row(:p_x)] != track[row(:r_a)]
        @test ntracks == 3
        # spans that do not overlap share a track
        @test JuLeAna.assign_tracks([(1, 2), (3, 4)]) == (Dict(1 => 1, 3 => 1), 1)
        @test JuLeAna.assign_tracks([(1, 3), (2, 4)]) == (Dict(1 => 1, 2 => 2), 2)

        tb = render_graph_page(JuLeAna.GraphPage(), snap, nothing)
        y(n) = locate(tb, string(n) * " ").y
        text(n) = row_text(tb, y(n))
        # a left source starts its track with a corner, a target in the right lane ends in an arrow
        @test occursin("┐", text(:r_a)) && occursin("┐", text(:r_b))
        @test occursin("▶●", text(:p_x)) && occursin("▶●", text(:p_y))
        @test occursin("◀", text(:r_c))
        @test !occursin("▶", text(:r_b)) && !occursin("◀", text(:r_a)) && !occursin("◀", text(:r_b))
        # the track of r_b continues down to its last target p_y, with a branch to p_x
        col(n, ch) = (r = text(n); length(r, 1, first(findfirst(ch, r)) - 1) + 1)
        c_b = col(:r_b, "┐")
        @test Tachikoma.char_at(tb, c_b, y(:r_b) + 1) in ('│', '┼', '┤', '├')
        @test Tachikoma.char_at(tb, c_b, y(:p_x)) in ('├', '┼')
        @test Tachikoma.char_at(tb, c_b, y(:p_y)) in ('└', '┴')
        # the tracks of r_a and r_b are in different columns, and r_a's horizontal line crosses r_b's track
        @test col(:r_a, "┐") != c_b
        @test any(r -> occursin('┼', r), eachline(IOBuffer(graph_text(tb))))
    end

    @testset "nothing is drawn outside the area" begin
        area = Rect(5, 3, 70, 12)
        tb = render_graph_page(JuLeAna.GraphPage(), snap, nothing, 100, 24; area)
        outside = [(x, y) for y in 1:24, x in 1:100 if !(5 <= x < 75 && 3 <= y < 15)]
        @test all(((x, y),) -> Tachikoma.char_at(tb, x, y) == ' ', outside)
        @test locate(tb, "r_a") !== nothing
    end

    @testset "narrow area cuts the names" begin
        snap2 = (; snap...,
                 processors = [entry(:process_a_very_long_name, :run, 1),
                               entry(:p_process_another_very_long_name, :partition, 1; deps = [:process_a_very_long_name])], run_steps = [],
                 partition_steps = [])
        wide = render_graph_page(JuLeAna.GraphPage(), snap2, nothing, 120, 12)
        @test locate(wide, "a_very_long_name cal") !== nothing && locate(wide, "another_very_long_name cal") !== nothing
        @test !occursin("…", graph_text(wide))
        narrow = render_graph_page(JuLeAna.GraphPage(), snap2, nothing, 50, 12)
        @test occursin("…", graph_text(narrow))
        @test !occursin("a_very_long_name cal", row_text(narrow, 3))
        # the right border is intact
        @test all(r -> Tachikoma.char_at(narrow, 50, r) in ('┃', '┓', '┛'), 1:12)
        # even a tiny area does not throw
        for w in 3:30
            @test render_graph_page(JuLeAna.GraphPage(), snap2, nothing, w, 8) isa TestBackend
        end
    end

    @testset "loading and empty states" begin
        @test locate(render_graph_page(JuLeAna.GraphPage(), nothing, nothing), "Loading the session…") !== nothing
        empty_snap = (; processors = NamedTuple[], run_steps = Symbol[], partition_steps = Symbol[])
        @test locate(render_graph_page(JuLeAna.GraphPage(), empty_snap, nothing), "Loading the session…") !== nothing
    end

    @testset "unselected processors" begin
        sel = graph_snapshot(; run_steps = [:r_a, :r_b, :r_c], partition_steps = [:p_x, :p_y])
        page = JuLeAna.GraphPage()
        tb = render_graph_page(page, sel, nothing)
        @test locate(tb, "r_off") !== nothing
        # shown dim
        pos = locate(tb, "r_off ")
        @test style_at(tb, pos.x, pos.y).fg == Tachikoma.tstyle(:text_dim).fg
        page.cursor = :p_y
        tb = render_graph_page(page, sel, nothing)
        @test style_at(tb, locate(tb, "r_c ").x, locate(tb, "r_c ").y).fg == Tachikoma.tstyle(:text).fg
        sent = []
        @test graph_press(page, sel, sent, 'h') && !page.show_unselected && isempty(sent)
        tb = render_graph_page(page, sel, nothing)
        @test locate(tb, "Processor graph (unselected hidden)") !== nothing
        @test locate(tb, "r_off") === nothing && locate(tb, "r_c") !== nothing
        @test JuLeAna.graph_rows(page, sel) == filter(!=(:r_off), GRAPH_ORDER)
        @test graph_press(page, sel, sent, 'h') && page.show_unselected
        @test locate(render_graph_page(page, sel, nothing), "r_off") !== nothing
        # the cursor moves to a neighbor when its row is hidden
        graph_press(page, sel, sent, :end_key)
        graph_press(page, sel, sent, 'h')
        render_graph_page(page, sel, nothing)
        @test page.cursor == :p_y
        graph_press(page, sel, sent, :up)
        @test page.cursor == :r_c
        graph_press(page, sel, sent, 'h')
        @test page.cursor == :r_c && page.show_unselected
        # the selection decides, not the enabled flag of the config
        flipped = (; sel..., processors = [(; p..., enabled = !p.enabled) for p in sel.processors])
        graph_press(page, sel, sent, 'h')
        @test JuLeAna.graph_rows(page, flipped) == filter(!=(:r_off), GRAPH_ORDER)
        graph_press(page, sel, sent, 'h')
        # nothing selected and the unselected processors hidden
        graph_press(page, snap, sent, 'h')
        @test !page.show_unselected
        @test locate(render_graph_page(page, snap, nothing), "No processor is selected.") !== nothing
    end

    @testset "selection and state" begin
        snap3 = graph_snapshot(; run_steps = [:r_b], partition_steps = [:p_y])
        prog = (;
                steps = [(; step = :r_b, state = :failed), (; step = :r_b, state = :done), (; step = :p_x, state = :done),
                         (; step = :p_x, state = :done), (; step = :p_y, state = :running), (; step = :r_c, state = :stopped)])
        tb = render_graph_page(JuLeAna.GraphPage(), snap3, prog)
        y(n) = locate(tb, string(n) * " ").y
        @test occursin("r_b", row_text(tb, y(:r_b))) && occursin("[x] ✗", row_text(tb, y(:r_b)))
        @test occursin("[ ] ✓", row_text(tb, y(:p_x)))
        @test occursin("[x] ▶", row_text(tb, y(:p_y)))
        @test occursin("[ ] ■", row_text(tb, y(:r_c)))
        @test !any(c -> c in "✓✗▶■", row_text(tb, y(:r_a))[1:30])
        icon = locate(tb, "✗")
        @test style_at(tb, icon.x, icon.y).fg == Tachikoma.tstyle(:error).fg
        icon = locate(tb, "✓")
        @test style_at(tb, icon.x, icon.y).fg == Tachikoma.tstyle(:success).fg

        @test JuLeAna.last_run_state([:done, :done]) === :done
        @test JuLeAna.last_run_state([:done, :skipped]) === :done
        # an edge inside a lane leaves the lane to its track and comes back with an arrow
        lane_snap = (;
                     processors = [entry(:r_a, :run, 1), entry(:r_b, :run, 2; deps = [:r_a]), entry(:p_x, :partition, 1),
                                   entry(:p_y, :partition, 2; deps = [:p_x])], run_steps = Symbol[], partition_steps = Symbol[])
        lane_g = processor_graph(lane_snap.processors)
        lane_rows = topological_order(lane_g)
        @test JuLeAna.graph_edges(lane_g, lane_rows) == sort([(findfirst(==(:r_a), lane_rows), findfirst(==(:r_b), lane_rows)),
                                                              (findfirst(==(:p_x), lane_rows), findfirst(==(:p_y), lane_rows))])
        lane_tb = render_graph_page(JuLeAna.GraphPage(), lane_snap, nothing)
        lane_text(n) = row_text(lane_tb, locate(lane_tb, string(n) * " ").y)
        @test occursin("┐", lane_text(:r_a)) && occursin("◀", lane_text(:r_b))
        @test occursin("┌", lane_text(:p_x)) && occursin("▶●", lane_text(:p_y))
        @test JuLeAna.last_run_state([:done, :waiting]) === nothing
        @test JuLeAna.last_run_state([:failed, :running]) === :running
        @test JuLeAna.last_run_state([:done, :failed, :waiting]) === :failed
        @test JuLeAna.last_run_state([:done, :cancelled]) === :done
        @test JuLeAna.last_run_state([:waiting, :cancelled]) === :stopped
        @test JuLeAna.last_run_state([:skipped]) === nothing
        @test JuLeAna.last_run_state([:waiting]) === nothing
        @test JuLeAna.processor_states(nothing) == Dict{Symbol,Symbol}()
    end

    @testset "cursor highlight" begin
        page = JuLeAna.GraphPage()
        page.cursor = :p_x
        sel = graph_snapshot(; run_steps = [:r_a, :r_b, :r_c], partition_steps = [:p_x, :p_y])
        tb = render_graph_page(page, sel, nothing)
        style(n) = (p = locate(tb, string(n) * " "); style_at(tb, p.x, p.y))
        # p_x requires r_b, and r_c requires p_x
        @test style(:p_x).fg == Tachikoma.tstyle(:accent).fg && style(:p_x).bold
        @test style(:r_b).fg == Tachikoma.tstyle(:warning).fg && style(:r_a).fg == Tachikoma.tstyle(:text).fg
        @test style(:r_c).fg == Tachikoma.tstyle(:secondary).fg
        @test style(:r_off).fg == Tachikoma.tstyle(:text_dim).fg && style(:p_y).fg == Tachikoma.tstyle(:text).fg
        @test locate(tb, "p_x: requires 1, required by 1  phy  rank 01") !== nothing
        # the edge from r_b to p_x connects highlighted nodes: its arrow is yellow
        arrow = locate(tb, "▶●")
        @test style_at(tb, arrow.x, arrow.y).fg == Tachikoma.tstyle(:warning).fg
        # the edge from p_x to r_c is purple, and an edge to a node that is not highlighted stays plain
        p = locate(tb, "◀")
        @test style_at(tb, p.x, p.y).fg == Tachikoma.tstyle(:secondary).fg
        y_py = locate(tb, "p_y ").y
        a = findfirst("▶●", row_text(tb, y_py))
        @test style_at(tb, length(row_text(tb, y_py), 1, first(a) - 1) + 1, y_py).fg == Tachikoma.tstyle(:text_dim).fg
        # the cursor row has the highlight background
        @test style_at(tb, locate(tb, "p_x ").x, locate(tb, "p_x ").y).bg == Tachikoma.tstyle(:border).fg
        @test style_at(tb, locate(tb, "r_b ").x, locate(tb, "r_b ").y).bg != Tachikoma.tstyle(:border).fg
    end

    @testset "keys" begin
        page = JuLeAna.GraphPage()
        sent = []
        render_graph_page(page, snap, nothing)
        @test page.cursor == :r_a
        @test graph_press(page, snap, sent, :down) && page.cursor == :r_b
        @test graph_press(page, snap, sent, :end_key) && page.cursor == :p_y
        @test graph_press(page, snap, sent, :home) && page.cursor == :r_a
        @test graph_press(page, snap, sent, :pagedown) && page.cursor == :p_y
        @test graph_press(page, snap, sent, :pageup) && page.cursor == :r_a
        @test graph_press(page, snap, sent, :up) && page.cursor == :r_a
        for key in ('1', '2', '6', 'q', '?', 'x', 'f')
            @test !graph_press(page, snap, sent, key)
        end
        @test !graph_press(page, snap, sent, :escape) && !graph_press(page, snap, sent, :tab)
        @test !JuLeAna.graph_key!(page, KeyEvent(:down, Tachikoma.key_release), snap, identity)
        @test page.cursor == :r_a && isempty(sent)
        # keys do nothing without a session
        @test graph_press(JuLeAna.GraphPage(), nothing, sent, ' ') && graph_press(JuLeAna.GraphPage(), nothing, sent, 'd') && isempty(sent)
        @test graph_press(JuLeAna.GraphPage(), nothing, sent, :down)
    end

    @testset "Space toggles the selection" begin
        page = JuLeAna.GraphPage()
        sent = []
        snap4 = graph_snapshot(; run_steps = [:r_a], partition_steps = [:p_y])
        @test graph_press(page, snap4, sent, ' ')
        @test only(sent) isa SelectSteps && sent[1].run_steps == Symbol[] && sent[1].partition_steps == [:p_y]
        graph_press(page, snap4, sent, :down)
        graph_press(page, snap4, sent, ' ')
        @test sent[2].run_steps == [:r_a, :r_b] && sent[2].partition_steps == [:p_y]
        graph_press(page, snap4, sent, :down)
        graph_press(page, snap4, sent, :down)
        graph_press(page, snap4, sent, ' ')
        @test page.cursor == :p_x && sent[3].run_steps == [:r_a] && sent[3].partition_steps == [:p_x, :p_y]
    end

    @testset "d adds the required processors" begin
        page = JuLeAna.GraphPage()
        sent = []
        snap5 = graph_snapshot(; run_steps = [:r_c])
        @test graph_press(page, snap5, sent, 'd')
        @test sent[1].run_steps == [:r_b, :r_c] && sent[1].partition_steps == [:p_x]
        snap6 = graph_snapshot(; partition_steps = [:p_y])
        graph_press(page, snap6, sent, 'd')
        @test sent[2].run_steps == [:r_a, :r_b] && sent[2].partition_steps == [:p_y]
    end

    @testset "mouse" begin
        page = JuLeAna.GraphPage()
        tb = render_graph_page(page, snap, nothing)
        click(x, y) = MouseEvent(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false)
        wheel(button, x = 10, y = 10) = MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false)
        pos = locate(tb, "p_y ")
        @test JuLeAna.graph_mouse!(page, click(pos.x, pos.y), snap) && page.cursor == :p_y
        pos = locate(tb, "r_b ")
        @test JuLeAna.graph_mouse!(page, click(3, pos.y), snap) && page.cursor == :r_b
        @test JuLeAna.graph_mouse!(page, wheel(Tachikoma.mouse_scroll_down), snap) && page.cursor == :r_off
        @test JuLeAna.graph_mouse!(page, wheel(Tachikoma.mouse_scroll_up), snap) && page.cursor == :r_b
        # outside the rows and the block, and releases, do nothing
        @test !JuLeAna.graph_mouse!(page, click(3, 1), snap)
        @test !JuLeAna.graph_mouse!(page, click(3, 28), snap)
        @test !JuLeAna.graph_mouse!(page, wheel(Tachikoma.mouse_scroll_down, 500, 10), snap)
        @test !JuLeAna.graph_mouse!(page, MouseEvent(3, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_release, false, false, false), snap)
        @test page.cursor == :r_b
    end

    @testset "graph is rebuilt only when the processors change" begin
        page = JuLeAna.GraphPage()
        g = JuLeAna.page_graph!(page, snap)
        @test JuLeAna.page_graph!(page, graph_snapshot(; run_steps = [:r_a])) === g
        @test JuLeAna.page_graph!(page, (; snap..., processors = [(; p..., enabled = !p.enabled) for p in snap.processors])) === g
        @test JuLeAna.page_graph!(page, (; snap..., processors = [snap.processors[1:2]; [entry(:r_c, :run, 3)];
                                                                  snap.processors[4:6]])) !== g
    end

    @testset "shipped config" begin
        cfg = ProcessingConfig(joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        processors = [(; s.name, s.level, s.category, s.rank, s.enabled, s.dependencies)
                      for s in vcat(collect(values(cfg.processors)), collect(values(cfg.p_processors)))]
        snap7 = (; processors, run_steps = [:process_psd_efficiencies_cal], partition_steps = Symbol[])
        page = JuLeAna.GraphPage()
        tb = render_graph_page(page, snap7, nothing, 120, 40)
        @test all(p -> locate(tb, JuLeAna.display_name(p.name) * " ") !== nothing, processors)
        # the cursor row stays visible when there are fewer rows than processors
        page = JuLeAna.GraphPage()
        order = topological_order(processor_graph(processors))
        sent = []
        for key in (:end_key, :home, :pagedown, :pagedown, :down, :end_key)
            graph_press(page, snap7, sent, key)
            tb = render_graph_page(page, snap7, nothing, 120, 12)
            @test page.height == 8
            @test locate(tb, JuLeAna.display_name(page.cursor) * " ") !== nothing
        end
        @test page.cursor == last(order)
        graph_press(page, snap7, sent, :home)
        tb = render_graph_page(page, snap7, nothing, 120, 12)
        @test page.cursor == first(order) && locate(tb, JuLeAna.display_name(first(order)) * " ") !== nothing
        @test locate(tb, JuLeAna.display_name(last(order)) * " ") === nothing
    end

    @testset "pages of the interface" begin
        args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.yaml"))
        m = JuLeAna.JuLeAnaTUI(DataflowController(args; processors = Dict{Symbol,Any}(), loader = _ -> error("no session")))
        render(m) = (tb = TestBackend(110, 30); Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, 110, 30), GraphicsRegion[], PixelSnapshot[]));
                     tb)
        Tachikoma.update!(m, KeyEvent('2'))
        @test m.page == 2
        tb = render(m)
        @test locate(tb, "Loading the session…") !== nothing && locate(tb, "This page is not available yet.") === nothing
        m.snap = (; graph_snapshot(; run_steps = [:r_a])..., state = :ready, outcome = nothing, nworkers = 0, idle_deadline = nothing,
                  started = nothing, finished = nothing, last_error = nothing)
        tb = render(m)
        @test locate(tb, "r_off") !== nothing && locate(tb, "↑↓ move  Space select  d add required  h unselected") !== nothing
        # the page gets the keys first
        Tachikoma.update!(m, KeyEvent(:down))
        @test m.graph_page.cursor == :r_b && m.page == 2
        Tachikoma.update!(m, KeyEvent('h'))
        @test !m.graph_page.show_unselected && locate(render(m), "r_off") === nothing
        Tachikoma.update!(m, KeyEvent(' '))
        @test m.pending == 1
        # unused keys fall through to the interface
        Tachikoma.update!(m, KeyEvent('4'))
        @test m.page == 4
        Tachikoma.update!(m, KeyEvent('2'))
        Tachikoma.update!(m, KeyEvent('?'))
        @test m.help && locate(render(m), "Graph page") !== nothing
        Tachikoma.update!(m, KeyEvent('q'))
        @test !m.help && m.page == 2
        Tachikoma.update!(m, KeyEvent('h'))
        pos = locate(render(m), "p_y ")
        Tachikoma.update!(m, MouseEvent(pos.x, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test m.graph_page.cursor == :p_y
        Tachikoma.cleanup!(m)
    end

    @testset "state on disk" begin
        p2, p3 = DataPeriod(2), DataPeriod(3)
        r6, r7, r0 = DataRun(6), DataRun(7), DataRun(0)
        # p03 is not selected; of p02 only r006 is
        snap4 = merge(graph_snapshot(; run_steps = [:r_a, :r_b], partition_steps = [:p_x]),
                      (; periods = [p2], runs = Dict(p2 => [r6]), available_runs = Dict(p2 => [r6, r7], p3 => [r0])))
        cell(state) = (; state, date = nothing, source = :report, path = "")
        grid = (; periods = [],
                rows = [(; process = :r_a, level = :run, category = :cal,
                         cells = Dict((p2, r6) => cell(:warning), (p2, r7) => cell(:failed))),
                        (; process = :r_b, level = :run, category = :cal, cells = Dict((p3, r0) => cell(:ok))),
                        (; process = :p_x, level = :partition, category = :phy, cells = Dict((p2, nothing) => cell(:ok))),
                        (; process = :p_y, level = :partition, category = :cal,
                         cells = Dict((p2, nothing) => (; state = :failed, date = nothing, source = :history, path = "")))])
        prog = (; steps = [(; step = :r_a, state = :done)])
        page = JuLeAna.GraphPage()
        @test occursin("[x] ✓", row_text(render_graph_page(page, snap4, prog), locate(render_graph_page(page, snap4, prog), "r_a ").y))
        @test graph_press(page, snap4, [], 'v') && page.disk
        tb = TestBackend(120, 30)
        JuLeAna.render_graph(page, snap4, prog, Rect(1, 1, 120, 30), tb.buf; grid)
        y(n) = locate(tb, string(n) * " ").y
        @test occursin("[x] !", row_text(tb, y(:r_a)))
        @test occursin("[x] –", row_text(tb, y(:r_b)))
        @test occursin("[x] ✓", row_text(tb, y(:p_x)))
        @test occursin("[ ] ✗", row_text(tb, y(:p_y)))
        @test !occursin(r"[✓!✗–]", row_text(tb, y(:r_c))[1:30])
        @test occursin("on disk", row_text(tb, 1))
        # the cursor is on r_a: its counts are on the last line
        @test occursin("on disk: 1 warning of 1", row_text(tb, 29))
        # without a grid the page says that it is read
        @test locate(render_graph_page(page, snap4, prog), "on disk (reading…)") !== nothing
        @test graph_press(page, snap4, [], 'v') && !page.disk
    end
end
