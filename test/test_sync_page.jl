# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "page.jl: settings panel" begin
    h = LocalHost()
    click(x, y) = MouseEvent(x, y, mouse_left, mouse_press, false, false, false)

    function model(; out = joinpath(mktempdir(), "test.yaml"), hosts = nothing)
        local_root = mktempdir()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test", out, nothing, false, false)
        m = SyncPage(h, p, options)
        m.panel_open = true
        hosts === nothing || (m.settings.hosts_file = hosts)
        return m
    end
    rect_of(m, name) = Dict(m.panel_rects)[name]
    click_on!(m, name) = (r = rect_of(m, name); sync_mouse!(m, click(r.x + 1, r.y)))
    type!(m, text) = foreach(c -> sync_key!(m, KeyEvent(c)), text)
    function tab_to!(m, name)
        for _ in 1:(length(PANEL_ITEMS) + 1)
            m.focus == :panel && PANEL_ITEMS[m.cursor] == name && return m
            sync_key!(m, KeyEvent(:tab))
        end
        error("Tab never reached $name")
    end

    @testset "the panel shows every field with its value and the buttons" begin
        m = model()
        tb = draw(m; width = 120, height = 30)
        for text in ("Settings", "Host", "local", "Remote root", "Production", "test", "Local root", "Mount root", "(none)", "Staging",
                     "(host default)", "Jobs", "Selection", "Save selection", "Estimate", "Transfer")
            @test find_text(tb, text) !== nothing
        end
        @test find_text(tb, "Host").y == find_text(tb, "Remote root").y           # two columns when wide
        narrow = draw(model(); width = 80, height = 40)
        @test find_text(narrow, "Host").y != find_text(narrow, "Remote root").y   # one row per field when narrow
        @test occursin("unsaved", row_text(tb, 30))                               # the status line stays on the last row
    end

    @testset "a page without a production renders its panel and a status row" begin
        local_root = mktempdir()
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "", "", nothing, false, false)
        m = SyncPage(h, options)                               # the productions are being listed: no tree yet
        @test m.root === nothing
        tb = draw(m; width = 120, height = 30)
        @test find_text(tb, "Settings") !== nothing && find_text(tb, "No production is open") !== nothing
        @test occursin("Connect (c) lists the productions", row_text(tb, 30))      # no status_bar without a tree
        for key in (' ', 'l', 'n', 'x', 's', 'e', 't')
            m.status = ""
            @test sync_key!(m, KeyEvent(key))
            @test occursin("Open a production first", m.status)
        end
        m.status = ""
        tab_to!(m, :save)
        sync_key!(m, KeyEvent(:enter))
        @test occursin("Open a production first", m.status)
        settle!(m)
    end

    @testset "the panel collapses to one summary line" begin
        m = model()
        # 6 panel rows + 2 border rows + 6 body rows + the progress row = 15: one row less collapses the panel.
        @test find_text(draw(m; height = 14), "▸ local") !== nothing && find_text(draw(m; height = 14), "Settings") === nothing
        @test find_text(draw(m; height = 15), "Settings") !== nothing && find_text(draw(m; height = 15), "▸ local") === nothing
        sync_key!(m, KeyEvent('p'))
        @test !m.panel_open
        tb = draw(m; height = 30)
        @test find_text(tb, "▸ local") !== nothing && find_text(tb, "Settings") === nothing
        sync_mouse!(m, click(m.summary_rect.x + 1, m.summary_rect.y))
        @test m.panel_open && find_text(draw(m; height = 30), "Settings") !== nothing
        sync_mouse!(m, click(m.summary_rect.x + 1, m.summary_rect.y))             # the title row toggles too
        @test !m.panel_open
    end

    @testset "Tab visits every field and button, then the tree" begin
        m = model()
        draw(m)
        @test m.focus == :tree
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
        # Tree keys do nothing while the panel has the focus.
        sync_key!(m, KeyEvent(:tab))
        before = current_node(m)
        sync_key!(m, KeyEvent(:down))
        @test current_node(m) === before && m.cursor == 2
        sync_key!(m, KeyEvent(' '))
        @test !sync_dirty(m)
    end

    @testset "Enter edits, Escape cancels, Enter commits" begin
        m = model()
        draw(m)
        tab_to!(m, :jobs)
        sync_key!(m, KeyEvent(:enter))
        @test m.edit.field == :jobs && m.edit.text == "0"
        sync_key!(m, KeyEvent(:backspace))
        type!(m, "7")
        @test find_text(draw(m), "7▏") !== nothing
        sync_key!(m, KeyEvent(:escape))
        @test m.edit === nothing && m.settings.jobs == "0"
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:backspace))
        type!(m, "7")
        sync_key!(m, KeyEvent(:enter))
        @test m.edit === nothing && m.settings.jobs == "7" && m.options.jobs == 7
        # Selection: the explicit path replaces the default and is what s saves to.
        out = joinpath(mktempdir(), "other.yaml")
        tab_to!(m, :selection)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, out)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent('s'))
        @test isfile(out)
    end

    @testset "an invalid value is shown with its reason and blocks actions" begin
        m = model()
        draw(m)
        tab_to!(m, :jobs)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:backspace))
        type!(m, "x")
        sync_key!(m, KeyEvent(:enter))
        @test m.errors[:jobs] == "Jobs must be an integer >= 0, got x"
        tb = draw(m)
        @test find_text(tb, "Jobs must be an integer >= 0, got x") !== nothing           # focused field: the reason is in the message row
        r = rect_of(m, :jobs)
        @test style_at(tb, r.x + 12, r.y) == Tachikoma.tstyle(:error)                  # the value, after the 12-column label
        sync_key!(m, KeyEvent('e'))
        @test m.modal_kind == :none && occursin("Jobs must be an integer", m.status)
        sync_key!(m, KeyEvent('t'))
        @test m.modal_kind == :none
        tab_to!(m, :jobs)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:backspace))
        type!(m, "2")
        sync_key!(m, KeyEvent(:enter))
        @test isempty(m.errors)
        sync_key!(m, KeyEvent('e'))
        @test m.modal_kind == :estimating
        settle!(m)
        # A missing Local root is an error here although parse_options accepts it.
        m2 = model()
        m2.settings.local_root = joinpath(tempdir(), "no-such-dir-sync")
        revalidate!(m2)
        @test occursin("is not an existing directory", m2.errors[:local_root])
    end

    @testset "a field in edit captures every key, otherwise the host keys fall through" begin
        m = model()
        for key in (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'), KeyEvent(:ctrl_c))
            @test !sync_key!(m, key)                       # tree focus
        end
        tab_to!(m, :host)
        @test !sync_key!(m, KeyEvent('q'))                 # panel focus, not editing
        sync_key!(m, KeyEvent(:enter))
        text = m.edit.text
        for key in (KeyEvent('q'), KeyEvent('?'), KeyEvent('T'), KeyEvent('3'))
            @test sync_key!(m, key)
        end
        @test m.edit.text == text * "q?T3" && sync_text_input(m)
        sync_key!(m, KeyEvent(:escape))
        @test !sync_text_input(m)
    end

    @testset "Tab completes local paths and host names" begin
        base = mktempdir()
        mkpath(joinpath(base, "alpha"))
        mkpath(joinpath(base, "alpine"))
        hosts = joinpath(mktempdir(), "hosts.yaml")
        write(hosts, "alpha:\n  remote_root: /a\nbeta:\n  remote_root: /b\n")
        m = model(; hosts)
        draw(m)
        tab_to!(m, :local_root)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, joinpath(base, "al"))
        sync_key!(m, KeyEvent(:tab))
        @test m.edit.text == joinpath(base, "alp") && occursin("alpha/", m.edit.hint) && occursin("alpine/", m.edit.hint)
        sync_key!(m, KeyEvent(:escape))
        tab_to!(m, :host)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, "al")
        sync_key!(m, KeyEvent(:tab))
        @test m.edit.text == "alpha"
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:5)
        sync_key!(m, KeyEvent(:tab))                           # no prefix: lists both, text unchanged
        @test m.edit.text == "" && occursin("alpha", m.edit.hint) && occursin("beta", m.edit.hint)
    end

    @testset "mouse: fields start an edit, buttons act, the wheel scrolls the picker" begin
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
        # Nothing reacts to the mouse while a dialog is open.
        before = m.focus
        @test !click_on!(m, :jobs) && m.edit === nothing && m.focus == before
    end

    @testset "the Production field opens the picker, Escape closes it" begin
        m = model()
        draw(m)
        tab_to!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)                                              # lists the productions
        @test m.picking && find_text(draw(m), "Productions on local") !== nothing
        sync_key!(m, KeyEvent(:escape))
        @test !m.picking && m.settings.production == "test"
        sync_key!(m, KeyEvent(:enter))                          # the productions are known now: the list opens at once
        @test m.picking
        sync_key!(m, KeyEvent(:enter))                          # the first row
        @test m.running == 1                                    # one background task opens it, not two
        settle!(m)
        @test !m.picking && m.production.name == m.productions[1] && m.settings.production == m.productions[1]
        @test find_text(draw(m), "Production: $(m.productions[1])") !== nothing
    end

    @testset "choosing a production asks before dropping unsaved marks" begin
        m = model()
        draw(m)
        sync_key!(m, KeyEvent(' '))                                # marks the root: dirty
        @test sync_dirty(m)
        tab_to!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        sync_key!(m, KeyEvent(:enter))                             # choose the first row
        @test m.modal_kind == :discard && m.running == 0 && occursin("Discard the marks on test", m.modal.message)
        sync_key!(m, KeyEvent(:enter))                             # the dialog opens on Keep
        @test m.modal_kind == :none && m.running == 0 && sync_dirty(m)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:left))
        sync_key!(m, KeyEvent(:enter))   # Discard
        @test m.running == 1
        settle!(m)
        @test !m.picking && m.production.name == m.productions[1]
    end
end
