# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "production.jl" begin
    h = LocalHost()
    p = Production(h, "test", FIXTURE_ROOT, LOCAL_ROOT)

    @testset "\$_ expansion and root resolution" begin
        @test p.name == "test"
        @test p.remote_root == FIXTURE_ROOT
        @test p.mount_root === nothing
        @test first.(p.roots) == ["metadata", "par", "tier", "tier/jlhit", "tier/jlpks"]
        roots = Dict(p.roots)
        # "$_" resolves to the directory holding the production's config.json.
        @test roots["metadata"] == joinpath(FIXTURE_ROOT, "test", "legend-metadata")
        @test roots["par"] == joinpath(FIXTURE_ROOT, "test", "generated", "jlpar")
        # An absolute key may point into another top-level directory of the same root.
        @test roots["tier"] ==
              joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier")
        @test roots["tier/jlhit"] ==
              joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")
    end

    @testset "path mapping" begin
        remote = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt")
        @test relative(p, remote) == joinpath("temp", "jl-dev", "generated", "tier", "jlevt")
        @test relative(p, FIXTURE_ROOT) == ""
        @test to_local(p, remote) ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt")
        @test to_local(p, FIXTURE_ROOT) == LOCAL_ROOT
        @test_throws "is not inside the remote root" relative(p, "/elsewhere/x")
        @test_throws "no mount root configured" to_mount(p, remote)

        pm = Production(h, "test", FIXTURE_ROOT, LOCAL_ROOT; mount_root = "/Volumes/cslg4")
        @test to_mount(pm, remote) ==
              joinpath("/Volumes/cslg4", "temp", "jl-dev", "generated", "tier", "jlevt")
    end

    @testset "normdir" begin
        @test normdir("/") == "/"
        @test normdir("/a/b/") == "/a/b"
    end

    @testset "configs that must be rejected" begin
        outside = """
        {"setups": {"l200": {"paths": {"tier": "/somewhere/else/tier"}}}}
        """
        cfg = parse_production_config(outside, joinpath(FIXTURE_ROOT, "test"))
        @test_throws "outside the remote root" production_roots(cfg, FIXTURE_ROOT)

        two = """
        {"setups": {"l200": {"paths": {"tier": "\$_/a"}},
                    "l1000": {"paths": {"tier": "\$_/b"}}}}
        """
        cfg2 = parse_production_config(two, joinpath(FIXTURE_ROOT, "test"))
        @test_throws "exactly one setup" production_roots(cfg2, FIXTURE_ROOT)

        @test_throws "not a file" Production(h, "nosuch", FIXTURE_ROOT, LOCAL_ROOT)

        unknown = """
        {"setups": {"l200": {"paths": {"tier": "\$NOPE/tier"}}}}
        """
        @test_throws "Unknown variable" parse_production_config(unknown, joinpath(FIXTURE_ROOT, "test"))
    end

    @testset "local_config maps a root-equal path" begin
        raw = replace("""
            {"setups": {"l200": {"paths": {"tier": "\$_/a", "root": "@REMOTE_ROOT@"}}}}
            """, "@REMOTE_ROOT@" => FIXTURE_ROOT)
        dir = joinpath(FIXTURE_ROOT, "test")
        cfg = parse_production_config(raw, dir)
        roots = production_roots(cfg, FIXTURE_ROOT)
        pr = Production("test", FIXTURE_ROOT, LOCAL_ROOT, nothing, cfg, roots, String[])
        paths = only(values(local_config(pr).setups)).paths
        # A value equal to the remote root maps into the mirror like any other
        # path inside it, not just one strictly nested below it.
        @test String(paths[Symbol("root")]) == LOCAL_ROOT
    end

    @testset "config_local.yaml" begin
        mkpath(joinpath(LOCAL_ROOT, "test"))
        path = write_local_config(p)
        @test path == joinpath(LOCAL_ROOT, "test", "config_local.yaml")
        @test isfile(path)
        # The mirrored config.json itself is never rewritten.
        @test !isfile(joinpath(LOCAL_ROOT, "test", "config.json"))

        back = readprops(path)
        paths = only(values(back.setups)).paths
        @test String(paths[Symbol("metadata")]) ==
              joinpath(LOCAL_ROOT, "test", "legend-metadata")
        @test String(paths[Symbol("tier")]) ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier")
        @test String(paths[Symbol("tier/jlhit")]) ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")

        # LegendDataManagement can build a setup from it.
        setup = LegendDataConfig(back).setups[:l200]
        @test data_path(setup, "tier", "jlhit", "cal", "p18", "r000") ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit",
                       "cal", "p18", "r000")

        @test !startswith(read(path, String), "{")
        data = withenv("LEGEND_DATA_CONFIG" => path) do
            LegendDataManagement.LegendData(:l200)
        end
        @test data_path(data, "tier") ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier")
        @test data_path(data, "tier", "jlhit") ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")
        @test data_path(data, "metadata") == joinpath(LOCAL_ROOT, "test", "legend-metadata")
    end

    @testset "nested production with overlays" begin
        n = Production(h, "temp/jl-dev", FIXTURE_ROOT, LOCAL_ROOT)
        @test n.name == "temp/jl-dev"
        @test n.overlays == ["config_fixture.json", "temp/config_site.yaml"]
        roots = Dict(n.roots)
        @test roots["metadata"] == joinpath(FIXTURE_ROOT, "temp", "jl-dev", "legend-metadata")
        @test roots["tier"] == joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier")
        # Each overlay's "\$_" is the directory the overlay sits in.
        @test roots["tier/jlpks"] == joinpath(FIXTURE_ROOT, "preprod", "jlpeaks")
        @test roots["tier/raw"] == joinpath(FIXTURE_ROOT, "temp", "raw-fixture")

        @test p.overlays == ["config_fixture.json"]
        @test Dict(p.roots)["tier/jlpks"] == joinpath(FIXTURE_ROOT, "preprod", "jlpeaks")
    end

    @testset "overlays win over the production config" begin
        root = mktempdir()
        mkpath(joinpath(root, "a", "b", "prod"))
        write(joinpath(root, "a", "b", "prod", "config.json"),
              """{"setups": {"l200": {"paths": {"metadata": "\$_/m", "tier": "\$_/t"}}}}""")
        write(joinpath(root, "config_x.json"),
              """{"setups": {"l200": {"paths": {"tier": "\$_/from-root", "par": "\$_/p"}}}}""")
        write(joinpath(root, "a", "b", "config_y.yml"),
              """setups: {l200: {paths: {tier: "\$_/from-deep"}}}""")
        write(joinpath(root, "a", "config_z.yaml"),
              """setups: {l200: {paths: {tier: "\$_/from-mid"}}}""")
        write(joinpath(root, "a", "b", "notes.json"), "{}")
        write(joinpath(root, "a", "b", "prod", "config_inner.json"), "{}")
        @test overlay_files(h, root, "a/b/prod") ==
              ["config_x.json", "a/config_z.yaml", "a/b/config_y.yml"]
        q = Production(h, "a/b/prod", root, mktempdir())
        roots = Dict(q.roots)
        @test roots["tier"] == joinpath(root, "a", "b", "from-deep")
        @test roots["par"] == joinpath(root, "p")
        @test roots["metadata"] == joinpath(root, "a", "b", "prod", "m")
    end

    @testset "production names must stay below the root" begin
        @test_throws "../escape" Production(h, "../escape", FIXTURE_ROOT, LOCAL_ROOT)
        @test_throws "temp/../../x" Production(h, "temp/../../x", FIXTURE_ROOT, LOCAL_ROOT)
        @test_throws "/etc" Production(h, "/etc", FIXTURE_ROOT, LOCAL_ROOT)
        @test_throws "relative path" Production(h, "", FIXTURE_ROOT, LOCAL_ROOT)
    end

    @testset "equivalent spellings are the same production" begin
        @test Production(h, "test/", FIXTURE_ROOT, LOCAL_ROOT).name == "test"
        @test Production(h, "./temp//jl-dev/", FIXTURE_ROOT, LOCAL_ROOT).name == "temp/jl-dev"
        @test_throws "temp/x/../../test" Production(h, "temp/x/../../test", FIXTURE_ROOT, LOCAL_ROOT)
    end

    @testset "config_local.yaml of a nested production" begin
        n = Production(h, "temp/jl-dev", FIXTURE_ROOT, LOCAL_ROOT)
        path = write_local_config(n)
        @test path == joinpath(LOCAL_ROOT, "temp", "jl-dev", "config_local.yaml")
        paths = only(values(readprops(path).setups)).paths
        @test String(paths[Symbol("tier/jlpks")]) == joinpath(LOCAL_ROOT, "preprod", "jlpeaks")
        @test String(paths[Symbol("tier/raw")]) == joinpath(LOCAL_ROOT, "temp", "raw-fixture")
        setup = LegendDataConfig(readprops(path)).setups[:l200]
        @test data_path(setup, "tier", "raw") == joinpath(LOCAL_ROOT, "temp", "raw-fixture")
    end

    @testset "list_productions" begin
        @test list_productions(h, FIXTURE_ROOT) == ["temp/jl-dev", "test"]
    end
end
