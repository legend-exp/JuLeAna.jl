# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "extract: options and headless run" begin
    @testset "defaults and overrides" begin
        file = joinpath(mktempdir(), "hosts.json")
        write(file, """{"alpha": {"remote_root": "/srv/alpha"}}""")
        o = parse_options(["--host", "alpha"]; hosts_file = file)
        @test o.jobs == 0
        @test (o.helper.julia, o.helper.julia_project, o.helper.staging) == (nothing, nothing, nothing)
        o2 = parse_options(["--host", "alpha", "--jobs", "4", "--staging", "/ptmp/u/stage"]; hosts_file = file)
        @test o2.jobs == 4
        @test o2.helper.staging == "/ptmp/u/stage"
        @test_throws "--jobs must not be negative" parse_options(["--host", "alpha", "--jobs=-1"]; hosts_file = file)
        @test_throws "--jobs must be an integer" parse_options(["--host", "alpha", "--jobs", "two"]; hosts_file = file)
        @test_throws "--staging must be an absolute path or start with ~, got rel/stage" parse_options(["--host", "alpha", "--staging",
                                                                                                        "rel/stage"]; hosts_file = file)
        @test parse_options(["--host", "alpha", "--staging", "~/x"]; hosts_file = file).helper.staging == "~/x"
    end

    @testset "--staging overrides the host entry; the other keys come from the hosts file" begin
        file = joinpath(mktempdir(), "hosts.json")
        write(file, """{"alpha": {"remote_root": "/srv/alpha", "julia": "/opt/j/bin/julia",
                        "julia_project": "/envs/x", "staging": "/ptmp/u/a"}}""")
        o = parse_options(["--host", "alpha"]; hosts_file = file)
        @test (o.helper.julia, o.helper.julia_project, o.helper.staging) ==
              ("/opt/j/bin/julia", "/envs/x", "/ptmp/u/a")
        o2 = parse_options(["--host", "alpha", "--staging", "/scratch/s"]; hosts_file = file)
        @test (o2.helper.julia, o2.helper.julia_project, o2.helper.staging) ==
              ("/opt/j/bin/julia", "/envs/x", "/scratch/s")
        # A host without an entry still works with an explicit root.
        @test parse_options(["--host", "beta", "--remote-root", "/x"]; hosts_file = file).helper.staging === nothing
    end

    h = LocalHost()
    function headless(local_root, helper; dry_run, yes)
        p = Production(h, "xprod", EXTRACT_ROOT, local_root)
        dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
        sel = Selection("local", "xprod", EXTRACT_ROOT, local_root, nothing,
                        ["xprod/config.json", "xprod/legend-metadata"], String[], now(),
                        [ExtractEntry(relative(p, dsp), ["aux"])])
        selpath = save_selection(joinpath(mktempdir(), "xprod.yaml"), sel)
        options = Options("local", EXTRACT_ROOT, local_root, nothing, "xprod", selpath, selpath,
                          dry_run, yes, 0, helper)
        path = tempname()
        code = open(path, "w") do io
            redirect_stdout(() -> main(options, h), io)
        end
        code, read(path, String)
    end

    @testset "headless dry run reports the extract part and the free space" begin
        local_root = mktempdir()
        helper = HelperConfig(; staging = joinpath(mktempdir(), "stage"))
        code, text = headless(local_root, helper; dry_run = true, yes = false)
        @test code == 0
        @test occursin("extract (2 files)", text)
        @test occursin("staging $(helper.staging): ", text)
        @test occursin(" free", text)
        @test !isdir(joinpath(local_root, "xprod", "generated"))
    end

    @testset "headless transfer extracts" begin
        local_root = mktempdir()
        helper = HelperConfig(; staging = joinpath(mktempdir(), "stage"))
        code, text = headless(local_root, helper; dry_run = false, yes = true)
        @test code == 0
        @test occursin("extracting on the host 2/2", text)
        @test occursin("extracted 2 files, 2 groups", text)
        run_dir = joinpath(local_root, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
        for file in readdir(run_dir; join = true)
            @test h5open(f -> collect(keys(f)), file, "r") == ["aux"]
        end
    end

    @testset "a missing helper environment is an error that names the command" begin
        helper = HelperConfig(; julia_project = mktempdir(), staging = joinpath(mktempdir(), "stage"))
        @test_throws "does not exist" headless(mktempdir(), helper; dry_run = true, yes = false)
        err = try
            headless(mktempdir(), helper; dry_run = true, yes = false)
        catch e
            e
        end
        @test occursin("Pkg.add", err.msg)
    end
end
