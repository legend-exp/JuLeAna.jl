# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using JuLeAna: CreateProduction, ProductionForm
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot, find_text, row_text
using Logging: Logging, with_logger
using Test

# Render the form `form` into a `width` x `height` test backend.
function render_production_form(form, snap = nothing; width = 100, height = 24)
    tb = TestBackend(width, height)
    JuLeAna.render_production(form, snap, Rect(1, 1, width, height), tb.buf)
    return tb
end

production_screen(tb) = join((row_text(tb, r) for r in 1:tb.height), "\n")

# Keys applied to `form`: the commands sent and the results of the keys.
function production_press!(form, keys...)
    sent = Any[]
    results = [JuLeAna.production_key!(form, k, cmd -> push!(sent, cmd)) for k in keys]
    return sent, results
end

production_typed(text) = KeyEvent.(collect(text))

# Deliver the events of the task queue of `m` until `cond()` holds.
function production_settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

function production_render_tui(m, width = 110, height = 30)
    return (tb = TestBackend(width, height); Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]));
            tb)
end

# The data config of the session is a temporary folder: the process environment of the
# session must never point at real data while the forms create productions.
withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "prods", "current", "config.json")) do
    @testset "New data production form" begin
        parent = mktempdir()
        tierdir = mkpath(joinpath(mktempdir(), "tier"))
        parsdir = mkpath(joinpath(mktempdir(), "rpars"))

        @testset "defaults" begin
            form = ProductionForm()
            @test form.parent == dirname(dirname(ENV["LEGEND_DATA_CONFIG"]))
            @test form.metadata_url == JuLeAna.METADATA_URL
            @test form.checkout && form.jldataprod_branch == "main" && form.dataprod_branch == "main"
            @test form.copy_software && !form.set_default && form.phase === :edit
            @test first.(JuLeAna.production_fields(form)) ==
                  [:name, :parent, :url, :checkout, :metadata_ref, :jldataprod, :dataprod, :add_tier, :add_par, :set_default,
                   :copy_software, :create]
            withenv("LEGEND_DATA_CONFIG" => nothing) do
                @test ProductionForm().parent == ""
            end
        end

        @testset "typing, moving and toggles" begin
            form = ProductionForm(; shell = "zsh", home = "/home/x")
            production_press!(form, production_typed("prod1x")..., KeyEvent(:backspace))
            @test form.name == "prod1"
            sent, results = production_press!(form, KeyEvent(:down), KeyEvent(:down), KeyEvent(:down))
            @test form.cursor == 4 && isempty(sent) && all(==(true), results)
            # Space flips the yes/no field and hides the branch fields
            production_press!(form, KeyEvent(' '))
            @test !form.checkout && length(JuLeAna.production_fields(form)) == 9
            production_press!(form, KeyEvent(:enter))
            @test form.checkout
            # Space is text in a text field
            production_press!(form, KeyEvent(:up), KeyEvent(:up), KeyEvent(:up), KeyEvent(:up), KeyEvent(' '), KeyEvent('a'))
            @test form.name == "prod1 a"
            # Tab wraps around, Shift-Tab goes back
            production_press!(form, KeyEvent(:backtab))
            @test form.cursor == length(JuLeAna.production_fields(form))
            production_press!(form, KeyEvent(:tab))
            @test form.cursor == 1
            production_press!(form, KeyEvent(:enter))
            @test form.cursor == 2
            # the field for the default production names the startup file
            tb = render_production_form(form)
            @test find_text(tb, "Set as default in .zshrc") !== nothing
            @test find_text(render_production_form(ProductionForm(; shell = "bash")), "Set as default in .bashrc") !== nothing
            @test find_text(render_production_form(ProductionForm(; shell = "fish")), "Set as default in the shell startup file") !==
                  nothing
            # a key release changes nothing
            before = form.name
            JuLeAna.production_key!(form, KeyEvent(:char, 'z', Tachikoma.key_release), identity)
            @test form.name == before
            @test JuLeAna.production_key!(form, KeyEvent(:escape), identity) === :close
        end

        @testset "path completion" begin
            root = realpath(mktempdir())
            foreach(d -> mkpath(joinpath(root, d)), ["alpha/one", "alpha/two", "alpine", "beta", ".hidden", "home/x"])
            write(joinpath(root, "alfile"), "")
            complete(text) = JuLeAna.complete_path(text; home = joinpath(root, "home"))
            # a single folder completes with a trailing slash, files are not candidates
            @test complete(joinpath(root, "be")) == (; text = joinpath(root, "beta") * "/", candidates = ["beta/"])
            # several folders complete to the common prefix and are listed
            @test complete(joinpath(root, "a")) == (; text = joinpath(root, "alp"), candidates = ["alpha/", "alpine/"])
            @test complete(joinpath(root, "alpha") * "/") == (; text = joinpath(root, "alpha") * "/", candidates = ["one/", "two/"])
            # nothing to add: unchanged, hidden folders only for a dot, no match, missing folder, relative
            @test complete(joinpath(root, "beta") * "/").candidates == String[]
            @test complete(joinpath(root, "")).candidates == ["alpha/", "alpine/", "beta/", "home/"]
            @test complete(joinpath(root, ".")) == (; text = joinpath(root, ".hidden") * "/", candidates = [".hidden/"])
            @test complete(joinpath(root, "zz")) == (; text = joinpath(root, "zz"), candidates = String[])
            @test complete(joinpath(root, "missing", "a")).candidates == String[]
            @test complete("relative") == (; text = "relative", candidates = String[])
            # a leading ~ is expanded
            @test complete("~/") == (; text = joinpath(root, "home", "x") * "/", candidates = ["x/"])
            @test complete("~/x").text == joinpath(root, "home", "x") * "/"

            form = ProductionForm(; parent = joinpath(root, "a"), home = joinpath(root, "home"))
            form.cursor = 2
            sent, _ = production_press!(form, KeyEvent(:tab))
            # extends the text and lists the candidates, the cursor stays
            @test form.cursor == 2 && form.parent == joinpath(root, "alp") && form.hint == "alpha/  alpine/"
            @test find_text(render_production_form(form), "alpha/  alpine/") !== nothing
            production_press!(form, KeyEvent(:tab))
            @test form.cursor == 2 && form.hint == "alpha/  alpine/"
            production_press!(form, KeyEvent('h'), KeyEvent(:tab))
            @test form.parent == joinpath(root, "alpha") * "/" && form.cursor == 2 && form.hint == ""
            # nothing left to complete: Tab moves on, Shift-Tab moves back
            form.parent = joinpath(root, "beta") * "/"
            production_press!(form, KeyEvent(:tab))
            @test form.cursor == 3 && form.parent == joinpath(root, "beta") * "/"
            production_press!(form, KeyEvent(:backtab))
            @test form.cursor == 2
            # the listing is limited
            many = mkpath(joinpath(root, "many"))
            foreach(i -> mkpath(joinpath(many, "d$i")), 10:21)
            form.parent = many * "/d"
            form.cursor = 2
            production_press!(form, KeyEvent(:tab))
            @test endswith(form.hint, "d17/  and 4 more") && form.parent == many * "/d"
            # Tab on a field that is not a path moves on
            form.cursor = 1
            production_press!(form, KeyEvent(:tab))
            @test form.cursor == 2
            form.tier_labels, form.tier_paths, form.pars = ["x"], [joinpath(root, "be")], [joinpath(root, "be")]
            for kind in (:tier_path, :par)
                form.cursor = findfirst(f -> f[1] === kind, JuLeAna.production_fields(form))
                production_press!(form, KeyEvent(:tab))
                @test JuLeAna.production_text(form, JuLeAna.production_fields(form)[form.cursor]) == joinpath(root, "beta") * "/"
            end
            @test occursin("Tab complete", production_screen(render_production_form(form)))
        end

        @testset "list rows" begin
            form = ProductionForm()
            fields() = JuLeAna.production_fields(form)
            at(kind) = findfirst(f -> f[1] === kind, fields())
            form.cursor = at(:add_tier)
            production_press!(form, KeyEvent(:enter))
            @test form.tier_labels == [""] && fields()[form.cursor] == (:tier_label, 1)
            production_press!(form, production_typed("fast")..., KeyEvent(:down), production_typed("/data/fast")...)
            @test form.tier_labels == ["fast"] && form.tier_paths == ["/data/fast"]
            # Ctrl-N on a row adds another row after the last one
            production_press!(form, KeyEvent(:ctrl, 'n'))
            @test length(form.tier_labels) == 2 && fields()[form.cursor] == (:tier_label, 2)
            production_press!(form, KeyEvent(:ctrl, 'd'))
            @test form.tier_labels == ["fast"] && form.tier_paths == ["/data/fast"]
            form.cursor = at(:add_par)
            production_press!(form, KeyEvent(:enter), production_typed("/p/rpars")..., KeyEvent(:ctrl, 'n'),
                              production_typed("/q/ppars")...)
            @test form.pars == ["/p/rpars", "/q/ppars"] && fields()[form.cursor] == (:par, 2)
            production_press!(form, KeyEvent(:delete))
            @test form.pars == ["/p/rpars"]
            # removing needs the cursor on a row
            form.cursor = 1
            production_press!(form, KeyEvent(:ctrl, 'd'))
            @test form.pars == ["/p/rpars"] && form.tier_labels == ["fast"]
            # a form with rows scrolls to keep the cursor visible in a small area
            form.cursor = at(:create)
            @test find_text(render_production_form(form; height = 6), "[ Create ]") !== nothing
        end

        @testset "the spec" begin
            form = ProductionForm(; parent = "  $parent ", shell = "zsh", home = "/h")
            form.name = " p1 "
            form.checkout = false
            form.tier_labels, form.tier_paths = ["fast", "", "slow"], [tierdir, "", tierdir]
            form.pars = [parsdir, "  "]
            form.set_default = true
            spec = JuLeAna.production_spec(form)
            @test spec.name == "p1" && spec.parent == parent && spec.metadata_url == JuLeAna.METADATA_URL
            @test isnothing(spec.jldataprod_branch) && isnothing(spec.dataprod_branch)
            @test spec.tier_paths == ["fast" => tierdir, "slow" => tierdir]
            @test spec.pars == [parsdir] && spec.set_default && spec.copy_software
            @test spec.shell == "zsh" && spec.home == "/h"
            form.checkout, form.jldataprod_branch, form.dataprod_branch = true, "dev", " main"
            spec = JuLeAna.production_spec(form)
            @test spec.jldataprod_branch == "dev" && spec.dataprod_branch == "main" && isnothing(spec.metadata_ref)
            form.metadata_ref = " v1.0 "
            @test JuLeAna.production_spec(form).metadata_ref == "v1.0"
            form.checkout = false
            @test isnothing(JuLeAna.production_spec(form).metadata_ref)
        end

        @testset "invalid input is shown and sends nothing" begin
            form = ProductionForm(; parent)
            form.cursor = length(JuLeAna.production_fields(form))
            sent, _ = production_press!(form, KeyEvent(:enter))
            @test isempty(sent) && form.phase === :edit
            @test occursin("production name", form.error)
            @test find_text(render_production_form(form), "production name") !== nothing
            # the next key clears the message
            production_press!(form, KeyEvent(:up))
            @test isnothing(form.error)
            form.name = "p1"
            form.parent = "relative"
            sent, _ = production_press!(form, KeyEvent(:ctrl, 'o'))
            @test isempty(sent) && occursin("absolute path", form.error)
            form.parent = parent
            form.tier_labels, form.tier_paths = ["fast"], [joinpath(parent, "missing")]
            sent, _ = production_press!(form, KeyEvent(:ctrl, 'o'))
            @test isempty(sent) && occursin("is not a folder", form.error)
            mkpath(joinpath(parent, "taken"))
            form.name, form.tier_labels, form.tier_paths = "taken", String[], String[]
            sent, _ = production_press!(form, KeyEvent(:ctrl, 'o'))
            @test isempty(sent) && occursin("exists", form.error) && form.phase === :edit
        end

        @testset "a valid form sends CreateProduction" begin
            form = ProductionForm(; parent, shell = "zsh", home = "/h")
            form.name, form.checkout, form.copy_software = "p1", false, false
            form.tier_labels, form.tier_paths, form.pars = ["fast"], [tierdir], [parsdir]
            form.cursor = length(JuLeAna.production_fields(form))
            sent, _ = production_press!(form, KeyEvent(:enter))
            @test length(sent) == 1 && sent[1] isa CreateProduction
            spec = sent[1].spec
            @test spec.name == "p1" && spec.parent == parent && spec.tier_paths == ["fast" => tierdir] && spec.pars == [parsdir]
            @test isnothing(spec.jldataprod_branch) && !spec.copy_software && !spec.set_default
            @test form.phase === :creating && form.path == joinpath(parent, "p1")
            # nothing is accepted while the production is created
            sent, results = production_press!(form, KeyEvent(:escape), KeyEvent(:ctrl, 'o'), KeyEvent('x'))
            @test isempty(sent) && all(==(true), results) && form.phase === :creating && form.name == "p1"
            # Ctrl-O submits from a text field too
            form2 = ProductionForm(; parent)
            form2.name = "p2"
            sent, _ = production_press!(form2, KeyEvent(:ctrl, 'o'))
            @test only(sent).spec.jldataprod_branch == "main" && only(sent).spec.copy_software
        end

        @testset "creating, created and failed" begin
            form = ProductionForm(; parent)
            form.name = "p1"
            production_press!(form, KeyEvent(:ctrl, 'o'))
            form.answer_at = 3
            loading = (; state = :loading, last_error = nothing)
            # before the command is accepted, nothing of the snapshot counts
            JuLeAna.production_sync!(form, (; state = :ready, last_error = nothing), ["old"])
            @test form.phase === :creating && isempty(form.log)
            # an answer to another command is not the answer
            JuLeAna.production_answer!(form, 2, nothing)
            @test !form.accepted
            JuLeAna.production_answer!(form, 3, nothing)
            @test form.accepted
            JuLeAna.production_sync!(form, loading, ["Created /x/p1", "Cloning the metadata"])
            tb = render_production_form(form, loading)
            @test find_text(tb, "Creating $(joinpath(parent, "p1"))") !== nothing
            @test find_text(tb, "Cloning the metadata") !== nothing && find_text(tb, "Created /x/p1") !== nothing
            # only the newest lines that fit are shown
            JuLeAna.production_sync!(form, loading, ["line $i" for i in 1:100])
            tb = render_production_form(form, loading; height = 10)
            @test find_text(tb, "line 100") !== nothing && find_text(tb, "line 50") === nothing
            # created and loaded
            JuLeAna.production_sync!(form, (; state = :ready, last_error = nothing), ["done"])
            @test form.phase === :done
            tb = render_production_form(form)
            @test find_text(tb, "Created and loaded $(joinpath(parent, "p1"))") !== nothing
            @test JuLeAna.production_key!(form, KeyEvent('x'), identity) === :finished

            # a failure returns to the form with the message of the controller
            form = ProductionForm(; parent)
            form.name = "p1"
            production_press!(form, KeyEvent(:ctrl, 'o'))
            form.answer_at = 1
            JuLeAna.production_answer!(form, 1, nothing)
            JuLeAna.production_sync!(form, (; state = :idle, last_error = "git clone failed"), ["Created x"])
            @test form.phase === :edit && form.error == "git clone failed" && form.name == "p1"
            @test find_text(render_production_form(form), "git clone failed") !== nothing
            # a rejected command returns to the form with its message
            form = ProductionForm(; parent)
            form.name = "p1"
            production_press!(form, KeyEvent(:ctrl, 'o'))
            form.answer_at = 1
            JuLeAna.production_answer!(form, 1, ArgumentError("CreateProduction is not possible while the controller is :running"))
            @test form.phase === :edit && occursin("not possible while the controller is :running", form.error)
        end

        @testset "the interface without a session" begin
            noconfig = Dict{String,Any}("config" => nothing, "new_production" => false)
            calls = Threads.Atomic{Int}(0)
            loader(_) = (Threads.atomic_add!(calls, 1); error("no session in this test"))
            # no config: no LoadSession, the form opens after the startup screen
            m = JuLeAna.JuLeAnaTUI(DataflowController(noconfig; loader); splash_seconds = 0.0,
                                   sync_settings = JuLeAna.offline_sync_settings())
            JuLeAna.start!(m)
            @test !isnothing(m.production)
            @test production_settle!(() -> !isnothing(m.snap) && !JuLeAna.splash_active(m), m; timeout = 10)
            @test calls[] == 0 && m.snap.state === :idle && isnothing(m.snap.last_error) && m.pending == 0
            tb = production_render_tui(m)
            @test find_text(tb, "New data production") !== nothing && find_text(tb, "Parent folder") !== nothing
            @test occursin("Ctrl-O create", production_screen(tb)) && !occursin("quit", production_screen(tb))
            # every page renders without a session
            Tachikoma.cleanup!(m)

            # `--new-production` with a config does not load a session either
            withconfig = Dict{String,Any}("config" => "config/processing_config.yaml", "new_production" => true)
            m = JuLeAna.JuLeAnaTUI(DataflowController(withconfig; loader); splash_seconds = 0.0)
            JuLeAna.start!(m)
            @test !isnothing(m.production)
            @test production_settle!(() -> !isnothing(m.snap), m; timeout = 10)
            @test calls[] == 0 && m.snap.state === :idle
            Tachikoma.cleanup!(m)

            # a config without the flag loads the session as before
            plain = Dict{String,Any}("config" => "config/processing_config.yaml", "new_production" => false)
            m = JuLeAna.JuLeAnaTUI(DataflowController(plain; loader); splash_seconds = 0.0)
            with_logger(Logging.NullLogger()) do
                JuLeAna.start!(m)
                @test production_settle!(() -> calls[] == 1 && !isnothing(m.snap) && !isnothing(m.snap.last_error), m; timeout = 20)
            end
            @test isnothing(m.production)
            Tachikoma.cleanup!(m)
        end

        @testset "closing the form and N on the Setup page" begin
            noconfig = Dict{String,Any}("config" => nothing, "new_production" => false)
            m = JuLeAna.JuLeAnaTUI(DataflowController(noconfig; loader = _ -> error("unused")); splash_seconds = 0.0)
            JuLeAna.start!(m)
            @test production_settle!(() -> !isnothing(m.snap), m; timeout = 10)
            m.splash = false
            # the keys of the pages are text while the form is open
            Tachikoma.update!(m, KeyEvent('3'))
            Tachikoma.update!(m, KeyEvent('q'))
            @test m.page == 1 && !Tachikoma.should_quit(m) && m.production.name == "3q"
            Tachikoma.update!(m, KeyEvent(:escape))
            @test isnothing(m.production)
            # every page renders without a session
            for page in 1:length(JuLeAna.TUI_PAGES)
                m.page = page
                @test production_render_tui(m) isa TestBackend
            end
            m.page = 1
            @test find_text(production_render_tui(m), "No session loaded") !== nothing
            @test occursin("N: new data production", production_screen(production_render_tui(m, 140)))
            # `n` stays "uncheck all" for the checklists; `N` opens the form
            Tachikoma.update!(m, KeyEvent('n'))
            @test isnothing(m.production)
            Tachikoma.update!(m, KeyEvent('N'))
            @test !isnothing(m.production) && !m.setup.new_production
            # a mouse click on a tab does not leave the form
            Tachikoma.update!(m, Tachikoma.MouseEvent(1, 1, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
            @test !isnothing(m.production)
            Tachikoma.update!(m, KeyEvent(:escape))
            # Ctrl-C quits from the form
            Tachikoma.update!(m, KeyEvent('N'))
            Tachikoma.update!(m, KeyEvent(:ctrl_c))
            @test Tachikoma.should_quit(m)
            Tachikoma.cleanup!(m)
        end

        @testset "a failing creation through the controller" begin
            noconfig = Dict{String,Any}("config" => nothing, "new_production" => false)
            m = JuLeAna.JuLeAnaTUI(DataflowController(noconfig; loader = _ -> error("unused")); splash_seconds = 0.0)
            JuLeAna.start!(m)
            @test production_settle!(() -> !isnothing(m.snap), m; timeout = 10)
            m.splash = false
            form = m.production
            form.name, form.parent, form.checkout, form.copy_software = "p1", parent, false, false
            # the clone of a folder that is no repository fails after the first log line
            form.metadata_url = joinpath(parent, "no-repository")
            form.cursor = length(JuLeAna.production_fields(form))
            with_logger(Logging.NullLogger()) do
                Tachikoma.update!(m, KeyEvent(:enter))
                @test form.phase === :creating && form.answer_at == m.answered + m.pending
                @test production_settle!(() -> form.phase === :edit, m)
            end
            @test occursin("failed", form.error) && form.accepted
            @test any(startswith("Created "), form.log) && m.snap.state === :idle
            @test find_text(production_render_tui(m), "failed") !== nothing
            @test ENV["LEGEND_DATA_CONFIG"] == joinpath(dirname(dirname(ENV["LEGEND_DATA_CONFIG"])), "current", "config.json")
            Tachikoma.cleanup!(m)
        end
    end
end
