# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Productions as JuLeAna creates them: `config.yaml` with `$_`-relative paths, a tier path into a
# sibling production, and the `setup` folder with the processing config, software snapshots and
# metadata records.
function make_yaml_remote()
    root = mktempdir()
    old = mkpath(joinpath(root, "juleana", "preprod", "old"))
    write(joinpath(old, "config.json"), """{"setups": {"l200": {"paths": {"metadata": "\$_/legend-metadata/",
                                         "tier": "\$_/generated/tier/"}}}}""")
    mkpath(joinpath(old, "legend-metadata"))
    mkpath(joinpath(old, "generated", "tier", "jlpks"))
    new = mkpath(joinpath(root, "juleana", "ref", "new"))
    write(joinpath(new, "config.yaml"), """
        setups:
          l200:
            paths:
              metadata: '\$_/legend-metadata/'

              tier: '\$_/generated/tier/'
              tier/jlpks: '\$_/../../preprod/old/generated/tier/jlpks/'
              tier/jllog: '\$_/generated/jllog/'

              par: '\$_/generated/jlpar/'
        """)
    write(joinpath(mkpath(joinpath(new, "legend-metadata")), "README.md"), "metadata\n")
    foreach(d -> mkpath(joinpath(new, "generated", d)), ("tier", "jllog", "jlpar"))
    write(joinpath(mkpath(joinpath(new, "setup", "config")), "processing_config.yaml"), "processors: {}\n")
    write(joinpath(mkpath(joinpath(new, "setup", "software", "2026-10-23T090400Z-abcdef0")), "SNAPSHOT.toml"), "julia = \"1.12\"\n")
    mkpath(joinpath(new, "setup", "metadata"))
    return root
end

@testset "productions with config.yaml" begin
    h = LocalHost()
    root = make_yaml_remote()

    @testset "listing finds config.json and config.yaml productions" begin
        @test list_productions(h, root) == ["juleana/preprod/old", "juleana/ref/new"]
    end

    @testset "a config.yaml production and its setup folder" begin
        p = Production(h, "juleana/ref/new", root, mktempdir())
        @test p.config_file == "config.yaml" && p.setup_config
        roots = Dict(p.roots)
        @test roots["tier"] == joinpath(root, "juleana", "ref", "new", "generated", "tier")
        @test roots["tier/jlpks"] == joinpath(root, "juleana", "preprod", "old", "generated", "tier", "jlpks")
        tree = production_tree(h, p)
        @test [c.label for c in tree.children] == ["config.yaml", "metadata", "par", "tier", "tier/jllog", "tier/jlpks", "setup"]
        @test last(tree.children).kind == :section
        @test mandatory_copies(p) == [joinpath("juleana", "ref", "new", "config.yaml"),
                                      joinpath("juleana", "ref", "new", "setup", "config"),
                                      joinpath("juleana", "ref", "new", "legend-metadata")]
    end

    @testset "a config.json production without a setup folder" begin
        p = Production(h, "juleana/preprod/old", root, mktempdir())
        @test p.config_file == "config.json" && !p.setup_config
        @test [c.label for c in production_tree(h, p).children] == ["config.json", "metadata", "tier"]
        @test mandatory_copies(p) == [joinpath("juleana", "preprod", "old", "config.json"),
                                      joinpath("juleana", "preprod", "old", "legend-metadata")]
    end

    @testset "a folder with both config files or neither is refused" begin
        both = mkpath(joinpath(mktempdir(), "both"))
        write(joinpath(both, "config.json"), "{}")
        write(joinpath(both, "config.yaml"), "{}\n")
        @test_throws "holds both config.json and config.yaml" Production(h, "both", dirname(both), mktempdir())
        @test_throws "holds neither config.json nor config.yaml" Production(h, "juleana", root, mktempdir())
    end

    @testset "the mandatory copies make a usable mirror" begin
        p = Production(h, "juleana/ref/new", root, mktempdir())
        sel = Selection(p, "local", production_tree(h, p))
        apply!(h, p, sel)
        mirror = joinpath(p.local_root, "juleana", "ref", "new")
        @test read(joinpath(mirror, "config.yaml"), String) == read(joinpath(root, "juleana", "ref", "new", "config.yaml"), String)
        @test isfile(joinpath(mirror, "setup", "config", "processing_config.yaml"))
        @test isfile(joinpath(mirror, "legend-metadata", "README.md"))
        @test !isdir(joinpath(mirror, "setup", "software"))
        paths = only(values(readprops(joinpath(mirror, "config_local.yaml")).setups)).paths
        @test String(paths[Symbol("tier/jlpks")]) == joinpath(p.local_root, "juleana", "preprod", "old", "generated", "tier", "jlpks")
    end
end
