# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "options.jl" begin
    @testset "defaults" begin
        o = parse_options(String[])
        @test o.host == "cslg4"
        @test o.remote_root == "/mnt/scratch/projects/legend/data/l200"
        @test o.production == ""
        @test o.local_root == default_local_root()
        @test o.mount_root === nothing
        @test o.from === nothing
        @test o.dry_run == false
        @test o.yes == false
        @test o.out == ""
    end

    @testset "the selection file is named after the production" begin
        @test parse_options(["--production", "test"]).out ==
              joinpath(default_selection_dir(), "test.yaml")
        @test parse_options(["--production", "juleana/tmp/jl-v0.7.0dev1"]).out ==
              joinpath(default_selection_dir(), "juleana-tmp-jl-v0.7.0dev1.yaml")
    end

    @testset "remote roots per host" begin
        @test parse_options(["--host", "viper"]).remote_root == "/ptmp/oschulz/legend/data/l200"
        file = joinpath(mktempdir(), "hosts.json")
        write(file, """{"alpha": {"remote_root": "/srv/alpha"}}""")
        @test host_remote_root(file, "alpha") == "/srv/alpha"
        @test parse_options(["--host", "alpha"]; hosts_file = file).remote_root == "/srv/alpha"
        @test parse_options(["--host", "alpha", "--remote-root", "/elsewhere"];
                            hosts_file = file).remote_root == "/elsewhere"
        @test_throws "host beta is not listed in $file" host_remote_root(file, "beta")
        @test_throws "host beta is not listed in $file" parse_options(["--host", "beta"]; hosts_file = file)
        # A host that is not listed is fine when the root is given explicitly.
        @test parse_options(["--host", "beta", "--remote-root", "/x"];
                            hosts_file = file).remote_root == "/x"
    end

    @testset "overrides" begin
        o = parse_options(["--host", "other", "--production", "preprod",
                           "--remote-root", "/data/l200",
                           "--local-root", "/tmp/mirror",
                           "--mount-root", "/Volumes/cslg4",
                           "--from", "/tmp/sel.yaml", "--dry-run", "--yes"])
        @test o.host == "other"
        @test o.production == "preprod"
        @test o.remote_root == "/data/l200"
        @test o.local_root == "/tmp/mirror"
        @test o.mount_root == "/Volumes/cslg4"
        @test o.from == "/tmp/sel.yaml"
        @test o.dry_run && o.yes
        @test o.out == joinpath(default_selection_dir(), "preprod.yaml")
        @test parse_options(["--out", "/tmp/x.yaml"]).out == "/tmp/x.yaml"
        @test_throws "--out must end in .yaml, got /tmp/x.json" parse_options(["--out", "/tmp/x.json"])
    end

    @testset "user-supplied paths are made absolute" begin
        o = parse_options(["--local-root", "relative/mirror"])
        @test o.local_root == abspath("relative/mirror")

        o2 = parse_options(["--mount-root", "relative/mount"])
        @test o2.mount_root == abspath("relative/mount")

        o3 = parse_options(["--remote-root", "relative/remote"])
        @test o3.remote_root == abspath("relative/remote")
    end

    @testset "flags that need --from" begin
        @test_throws "only mean something together with --from" parse_options(["--dry-run"])
        @test_throws "only mean something together with --from" parse_options(["--yes"])
    end

    @testset "headless dry run" begin
        local_root = mktempdir()
        h = LocalHost()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        sel = Selection("local", "test", FIXTURE_ROOT, local_root, nothing,
                        [joinpath("test", "config.json"), evt], String[], now())
        selpath = save_selection(joinpath(mktempdir(), "test.yaml"), sel)

        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test",
                          selpath, selpath, true, false)
        path = tempname()
        code = open(path, "w") do io
            redirect_stdout(() -> main(options, h), io)
        end
        text = read(path, String)
        @test code == 0
        @test occursin("selected: ", text)
        # The listed copies plus the mandatory overlay and metadata entries.
        @test occursin("copy (5 files)", text)
        @test !isdir(joinpath(local_root, "temp"))
    end

    @testset "headless transfer" begin
        local_root = mktempdir()
        h = LocalHost()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        sel = Selection("local", "test", FIXTURE_ROOT, local_root, nothing,
                        [joinpath("test", "config.json"), evt], String[], now())
        selpath = save_selection(joinpath(mktempdir(), "test.yaml"), sel)

        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test",
                          selpath, selpath, false, true)
        path = tempname()
        code = open(path, "w") do io
            redirect_stdout(() -> main(options, h), io)
        end
        text = read(path, String)
        @test code == 0
        @test isfile(joinpath(local_root, evt,
                              "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"))
        @test occursin("LEGEND_DATA_CONFIG=", text)
        @test occursin("transferred ", text)
    end

    @testset "--from alone takes the production from the selection" begin
        local_root = mktempdir()
        h = LocalHost()
        sel = Selection("local", "temp/jl-dev", FIXTURE_ROOT, local_root, nothing,
                        ["temp/jl-dev/config.json", "config_fixture.json", "temp/config_site.yaml",
                         "temp/jl-dev/legend-metadata"], String[], now())
        selpath = save_selection(joinpath(mktempdir(), "sel.yaml"), sel)
        options = parse_options(["--remote-root", FIXTURE_ROOT, "--local-root", local_root,
                                 "--from", selpath, "--dry-run"])
        @test options.production == ""
        code = open(tempname(), "w") do io
            redirect_stdout(() -> main(options, h), io)
        end
        @test code == 0

        # When both are given they must agree.
        both = parse_options(["--remote-root", FIXTURE_ROOT, "--local-root", local_root,
                              "--production", "test", "--from", selpath, "--dry-run"])
        @test_throws "is for production temp/jl-dev" main(both, h)
    end

    @testset "a selection for another production is refused" begin
        local_root = mktempdir()
        h = LocalHost()
        sel = Selection("local", "preprod", FIXTURE_ROOT, local_root, nothing,
                        String[], String[], now())
        selpath = save_selection(joinpath(mktempdir(), "preprod.yaml"), sel)
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test",
                          selpath, selpath, true, true)
        @test_throws "is for production preprod" main(options, h)
    end
end
