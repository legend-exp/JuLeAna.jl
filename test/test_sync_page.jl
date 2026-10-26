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

    @testset "mouse: fields start an edit and buttons act" begin
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

    @testset "a pending bootstrap continuation survives the discard dialog" begin
        m = model()
        draw(m)
        sync_key!(m, KeyEvent(' '))
        marker = () -> nothing
        m.continuation = marker
        tab_to!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        sync_key!(m, KeyEvent(:enter))
        @test m.modal_kind == :discard && m.continuation === marker
        sync_key!(m, KeyEvent(:enter))
        @test m.continuation === marker && m.guarded === nothing
    end

    @testset "an invalid setting or a failed open leaves the page unchanged" begin
        m = model()
        draw(m)
        tab_to!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        sync_key!(m, KeyEvent(:escape))
        tab_to!(m, :jobs)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:backspace))
        type!(m, "x")
        sync_key!(m, KeyEvent(:enter))
        production, root, options, settings_production = m.production, m.root, m.options, m.settings.production
        open_picker!(m)
        sync_key!(m, KeyEvent(:enter))
        @test !m.picking && m.running == 0 && occursin("Jobs must be an integer", m.status)
        @test m.production === production && m.root === root && m.options === options && m.settings.production == settings_production
        # An open that fails in the task changes nothing either.
        change_setting!(m, :jobs, "0")
        m.options = Options("local", joinpath(FIXTURE_ROOT, "nosuch"), m.options.local_root, nothing, "test", m.options.out, nothing, false,
                            false)
        options = m.options
        open_picker!(m)
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        @test m.modal_kind == :error && m.production === production && m.root === root && m.options === options
        @test m.settings.production == settings_production
    end

    @testset "a long edit keeps the cursor visible" begin
        m = model()
        draw(m)
        tab_to!(m, :selection)
        sync_key!(m, KeyEvent(:enter))
        type!(m, "x"^200 * "tail.yaml")
        @test find_text(draw(m), "tail.yaml▏") !== nothing
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
        @test m.guarded !== nothing
        sync_key!(m, KeyEvent(:left))
        sync_key!(m, KeyEvent(:enter))   # Discard
        @test m.running == 1
        settle!(m)
        @test !m.picking && m.production.name == m.productions[1]
    end
    # A page without a connection, as juleana-sync and juleana build it.
    function fresh(; production = "", mount_root = "", hosts = nothing)
        local_root = mktempdir()
        settings = SyncSettings(; host = "local", remote_root = FIXTURE_ROOT, production, local_root, mount_root,
                                selection = joinpath(mktempdir(), "sel.yaml"))
        hosts === nothing || (settings.hosts_file = hosts)
        return SyncPage(settings, TaskQueue(); host_factory = alias -> h)
    end

    @testset "a page without a connection renders and refuses actions politely" begin
        m = fresh()
        tb = draw(m; width = 120, height = 30)
        @test find_text(tb, "Settings") !== nothing && occursin("Connect (c) lists the productions", row_text(tb, 30))
        for key in (' ', 'l', 'n', 'x', 's', 'e', 't', 'o')
            m.status = ""
            @test sync_key!(m, KeyEvent(key))
            @test occursin("Connect first", m.status) && m.modal_kind == :none
        end
        @test m.running == 0
        tab_to!(m, :production)
        sync_key!(m, KeyEvent(:enter))                  # no connection yet: Enter connects
        @test m.running == 1 && m.connecting
        sync_key!(m, KeyEvent(:enter))                  # busy: the status says so and nothing else starts
        @test m.running == 1 && occursin("busy:", m.status)
        settle!(m)
        @test !m.connecting && m.picking
    end

    @testset "an exception in a handler opens the error dialog" begin
        m = fresh()
        m.picker = Tachikoma.SelectableList(["a"])
        m.productions = nothing
        m.picking = true                                 # a corrupt state: choosing from the list fails on it
        @test sync_key!(m, KeyEvent(:enter))
        @test m.modal_kind == :error && !isempty(m.modal.message)
    end

    @testset "host and remote root connect by themselves when no tree is loaded" begin
        m = fresh()
        draw(m)
        tab_to!(m, :host)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, "local2")
        sync_key!(m, KeyEvent(:enter))
        @test m.settings.host == "local2" && m.running == 1 && m.connecting
        settle!(m)
        @test m.host === h && m.picking
    end

    @testset "sync_start! connects when the settings are valid" begin
        m = fresh()
        sync_start!(m)
        @test m.running == 1
        settle!(m)
        @test m.host === h && m.options.remote_root == FIXTURE_ROOT
        @test m.picking && m.root === nothing && "test" in m.productions
        sync_key!(m, KeyEvent(:enter))                 # the first row of the picker
        settle!(m)
        @test m.root !== nothing && m.production.name == m.productions[1] && m.settings.production == m.productions[1]

        m2 = fresh(; production = "test")
        sync_start!(m2)
        settle!(m2)
        @test !m2.picking && m2.production.name == "test" && !sync_dirty(m2)
        m3 = SyncPage(SyncSettings(; host = "x", remote_root = "/x", local_root = mktempdir()), TaskQueue();
                      host_factory = _ -> error("unknown host x"))
        sync_start!(m3)
        settle!(m3)
        @test m3.modal_kind == :error && occursin("unknown host x", m3.modal.message) && m3.host === nothing
        bad = SyncPage(SyncSettings(; host = "x", remote_root = "/x", local_root = joinpath(tempdir(), "no-such-sync-dir")), TaskQueue())
        sync_start!(bad)
        @test bad.running == 0 && occursin("is not an existing directory", bad.status)
        empty_root = SyncPage(SyncSettings(; host = "x", remote_root = "/x", local_root = ""), TaskQueue())
        sync_start!(empty_root)
        @test empty_root.running == 0 && empty_root.status == "Local root must be set"
        @test blocked(empty_root)                     # Connect, Estimate and Transfer refuse with the same text
    end

    @testset "a production that is not on the host is an error, a suggested one is dropped" begin
        m = fresh(; production = "nope")
        sync_start!(m)
        settle!(m)
        @test m.modal_kind == :error && occursin("production nope is not on", m.modal.message) && m.root === nothing
        s = fresh(; production = "nope")
        s.suggested = true
        sync_start!(s)
        settle!(s)
        @test s.modal_kind == :none && s.settings.production == "" && occursin("nope", s.status) && s.picking
    end

    @testset "Save, Load: marks come back" begin
        m = fresh(; production = "test")
        sync_start!(m)
        settle!(m)
        tier = findfirst(c -> c.label == "tier", m.root.children)
        set_mode!(m.root.children[tier], :copy)
        sync_key!(m, KeyEvent('s'))
        saved = Selection(m.production, "local", m.root)
        @test isfile(selection_path(m.settings)) && !sync_dirty(m)
        other = fresh(; production = "test")
        other.settings.selection = selection_path(m.settings)
        other.settings.local_root = m.settings.local_root
        sync_start!(other)
        settle!(other)
        draw(other)
        sync_key!(other, KeyEvent('o'))
        @test other.running == 1
        settle!(other)
        @test Selection(other.production, "local", other.root).copy == saved.copy
        @test !sync_dirty(other) && other.saved == selection_path(other.settings)
    end

    @testset "a failing load leaves the tree untouched" begin
        m = fresh(; production = "test")
        sync_start!(m)
        settle!(m)
        tier = findfirst(c -> c.label == "tier", m.root.children)
        set_mode!(m.root.children[tier], :copy)
        m.dirty = true
        root, marks, collapsed = m.root, Selection(m.production, "local", m.root).copy, copy(m.collapsed)
        stale = Selection("local", "test", FIXTURE_ROOT, m.production.local_root, nothing,
                          ["test/config.json", "test/legend-metadata", "test/no-such-dir"], String[], now(), ExtractEntry[])
        save_selection(selection_path(m.settings), stale)
        draw(m)
        sync_key!(m, KeyEvent('o'))
        @test m.modal_kind == :discard && occursin("Replace the marks on test", m.modal.message)
        sync_key!(m, KeyEvent(:left))
        sync_key!(m, KeyEvent(:enter))    # the dialog opens on "Keep"; left selects "Replace"
        settle!(m)
        @test m.modal_kind == :error && occursin("test/no-such-dir", m.modal.message) && occursin("listing directories", m.modal.message)
        @test m.root === root && Selection(m.production, "local", m.root).copy == marks && m.collapsed == collapsed && m.dirty
        @test m.step === nothing
        # A selection of another production is refused before anything is read from the host.
        wrong = Selection("local", "other", FIXTURE_ROOT, m.production.local_root, nothing, String[], String[], now(), ExtractEntry[])
        save_selection(selection_path(m.settings), wrong)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent('o'))
        sync_key!(m, KeyEvent(:left))
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        @test occursin("is for production other", m.modal.message) && m.root === root
    end

    @testset "changing the host with unsaved marks asks first" begin
        m = fresh(; production = "test")
        sync_start!(m)
        settle!(m)
        tier = findfirst(c -> c.label == "tier", m.root.children)
        set_mode!(m.root.children[tier], :copy)
        m.dirty = true
        root = m.root
        draw(m)
        tab_to!(m, :host)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, "local2")
        sync_key!(m, KeyEvent(:enter))
        @test m.modal_kind == :discard && occursin("Discard the marks on test?", m.modal.message)
        @test m.settings.host == "local"                  # nothing changed yet
        sync_key!(m, KeyEvent(:escape))                   # Keep
        @test m.modal_kind == :none && m.settings.host == "local" && m.root === root && sync_dirty(m)
        tab_to!(m, :host)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, "local2")
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:left))
        sync_key!(m, KeyEvent(:enter))     # left selects "Discard"
        settle!(m)
        @test m.settings.host == "local2" && m.root !== root && !sync_dirty(m) && m.production.name == "test"
        # Without unsaved marks the change reloads at once.
        tab_to!(m, :production)
        sync_key!(m, KeyEvent(:enter))
        sync_key!(m, KeyEvent(:down))
        sync_key!(m, KeyEvent(:enter))
        settle!(m)
        @test m.production.name == m.productions[2]
    end

    @testset "the progress line shows each step kind" begin
        m = fresh(; production = "test")
        sync_start!(m)
        settle!(m)
        last_row(m) = row_text(draw(m; height = 30), 30)
        step(p) = update!(m, TaskEvent(Symbol("sync:step"), p))
        step(StepProgress("listing detector files", 1, 3, 2, 8, nothing, ""))
        @test occursin("[1/3] listing detector files 2/8", last_row(m)) && occursin('█', last_row(m))
        step(StepProgress("copying", 2, 3, 45, 100, 3 * 1024 * 1024, "3.2MB/s  ETA 0:00:10"))
        @test all(occursin(s, last_row(m)) for s in ("[2/3] copying 45/100", "3.0 M", "3.2MB/s  ETA 0:00:10"))
        step(StepProgress("checking files to copy", 3, 3, 0, nothing, nothing, ""))
        m.step_started = time() - 75
        @test occursin("[3/3] checking files to copy", last_row(m)) && occursin("1:15", last_row(m))
        step(StepProgress("extracting on the host", 1, 3, 1, 4, 2048, ""))
        @test m.step_started > time() - 5                 # a new step restarts the clock
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:estimate"), (Estimate(0, 0, 0, true), false, nothing, nothing)))
        @test m.step === nothing && m.modal_kind == :estimate
        update!(m, KeyEvent(:escape))                      # the dialog covers the last row
        @test occursin("selected:", last_row(m))
    end

    @testset "an estimate reports its steps and a failure names the step" begin
        m = fresh(; production = "test")
        sync_start!(m)
        settle!(m)
        seen = StepProgress[]
        sync_key!(m, KeyEvent('e'))
        @test timedwait(() -> m.tasks.active[] == 0 && isready(m.tasks.channel), 30.0) == :ok
        while isready(m.tasks.channel)
            e = take!(m.tasks.channel)
            e.id == Symbol("sync:step") && push!(seen, e.value)
            update!(m, e)
        end
        @test [s.step for s in unique(seen)] == ["checking files to copy"] && m.modal_kind == :estimate && m.step === nothing
        sync_key!(m, KeyEvent(:escape))
        update!(m, TaskEvent(Symbol("sync:step"), StepProgress("copying", 2, 3, 1, 100, nothing, "")))
        m.running += 1
        update!(m, TaskEvent(Symbol("sync:transfer"), ErrorException("rsync died")))
        @test occursin("rsync died", m.modal.message) && occursin("in step \"copying\", 2 of 3", m.modal.message)
    end

    @testset "changing the host or remote root drops the productions of the old one" begin
        m = fresh()
        sync_start!(m)
        settle!(m)
        old = copy(m.productions)
        @test m.picking && "test" in old
        sync_key!(m, KeyEvent(:escape))
        draw(m)
        tab_to!(m, :remote_root)
        sync_key!(m, KeyEvent(:enter))
        foreach(_ -> sync_key!(m, KeyEvent(:backspace)), 1:length(m.edit.text))
        type!(m, EXTRACT_ROOT)
        sync_key!(m, KeyEvent(:enter))
        @test m.connecting && m.productions === nothing && m.picker === nothing && !m.picking
        settle!(m)
        @test m.productions == list_productions(h, EXTRACT_ROOT) && m.productions != old && m.picking
        tb = draw(m)
        @test find_text(tb, first(m.productions)) !== nothing && find_text(tb, "temp/jl-dev") === nothing

        # With a production open, the host change drops the list as well.
        m2 = fresh(; production = "test")
        sync_start!(m2)
        settle!(m2)
        open_picker!(m2)
        @test m2.picking
        change_setting!(m2, :host, "local2")
        @test m2.productions === nothing && m2.picker === nothing && !m2.picking && m2.connecting
        settle!(m2)
        @test m2.productions !== nothing && m2.production.name == "test"

        # Keeping the marks leaves the old host's list alone.
        m3 = fresh(; production = "test")
        sync_start!(m3)
        settle!(m3)
        m3.dirty = true
        change_setting!(m3, :host, "local2")
        @test m3.modal_kind == :discard && m3.productions !== nothing
        sync_key!(m3, KeyEvent(:escape))
        @test m3.productions !== nothing && m3.settings.host == "local"
    end

    @testset "the five buttons fit the panel at 80 columns and wrap on narrower screens" begin
        for width in (120, 80, 60)
            m = fresh(; production = "test")
            tb = draw(m; width, height = 40)
            for label in values(Sync.BUTTON_LABELS)
                @test find_text(tb, "[ $label ]") !== nothing
            end
            rects = [r for (name, r) in m.panel_rects if name in PANEL_BUTTONS]
            @test length(rects) == 5
            for (i, a) in pairs(rects), (j, b) in pairs(rects)
                i < j && @test !(a.y == b.y && a.x < b.x + b.width && b.x < a.x + a.width)
            end
            @test all(r -> Tachikoma.right(r) <= width - 1, rects)
            @test (length(unique(r.y for r in rects)) == 1) == (width >= 80)
            click_on!(m, :connect)
            @test m.running == 1 && m.connecting
            settle!(m)
            @test m.production.name == "test"
        end
    end

end
