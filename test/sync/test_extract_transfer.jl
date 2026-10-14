@testset "extract: apply!" begin
    h = LocalHost()
    dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
    files = [joinpath(dsp, "l200-p18-r000-cal-20251107T191821Z-tier_jldsp.lh5"),
             joinpath(dsp, "l200-p18-r000-cal-20251107T192416Z-tier_jldsp.lh5")]

    function setup()
        stage = joinpath(mktempdir(), "stage")
        Production(h, "xprod", EXTRACT_ROOT, mktempdir()), HelperConfig(; staging = stage), stage
    end
    selection(p, groups) = Selection("local", "xprod", EXTRACT_ROOT, p.local_root, nothing,
        ["xprod/config.json", "xprod/legend-metadata"], String[], now(),
        [ExtractEntry(relative(p, dsp), groups)])
    groups_of(path) = h5open(f -> collect(keys(f)), path, "r")

    @testset "extracts, pulls, and cleans the staging directory" begin
        p, helper, stage = setup()
        seen = ExtractProgress[]
        result = apply!(h, p, selection(p, ["B00000C", "aux"]); helper,
                        extract_progress = e -> push!(seen, e))
        @test (result.extracted_files, result.extracted_groups) == (2, 4)
        @test isempty(result.conflicts)
        @test [(e.done, e.total) for e in seen] == [(1, 2), (2, 2)]
        for file in files
            local_file = to_local(p, file)
            @test groups_of(local_file) == ["B00000C", "aux"]
            h5open(local_file, "r") do out
                h5open(file, "r") do src
                    @test read(out["aux"]["jldsp"]["waveform"]) == read(src["aux"]["jldsp"]["waveform"])
                end
                @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"]
            end
        end
        @test !isdir(joinpath(stage, "xprod"))          # the staged files are gone ...
        @test isfile(joinpath(stage, "extract.jl"))     # ... and only they
        @test isfile(joinpath(p.local_root, "xprod", "config_local.yaml"))
        text = summary_text(result)
        @test occursin("extracted 2 files, 4 groups", text)
        @test occursin("LEGEND_DATA_CONFIG=", text)

        # A later extraction of another detector keeps the groups that are there.
        apply!(h, p, selection(p, ["V01234A"]); helper)
        @test groups_of(to_local(p, files[1])) == ["B00000C", "V01234A", "aux"]
    end

    @testset "a full local copy or a link is never replaced" begin
        p, helper, stage = setup()
        mkpath(dirname(to_local(p, files[1])))
        cp(files[1], to_local(p, files[1]))
        result = apply!(h, p, selection(p, ["B00000C"]); helper)
        @test result.conflicts == [relative(p, files[1])]
        @test result.extracted_files == 1
        @test groups_of(to_local(p, files[1])) == ["B00000C", "V01234A", "aux"]
        @test groups_of(to_local(p, files[2])) == ["B00000C"]
        @test occursin("kept 1 existing files instead of extracting (full copies or symlinks): $(relative(p, files[1]))",
                       summary_text(result))

        p2, _, stage2 = setup()
        mkpath(dirname(to_local(p2, files[1])))
        symlink("/nowhere", to_local(p2, files[1]))
        plan, _ = plan_extraction(h, p2, selection(p2, ["B00000C"]), stage2)
        runnable, conflicts = reconcile_local(p2, plan)
        @test conflicts == [relative(p2, files[1])]
        @test [j.source for j in runnable] == files[2:2]
        @test readlink(to_local(p2, files[1])) == "/nowhere"

        @test reduced_groups(files[1]) === nothing
        @test_throws "absent.lh5" reduced_groups(joinpath(mktempdir(), "absent.lh5"))

        # A link above the file is a conflict too, even when it dangles.
        p3, _, stage3 = setup()
        mkpath(dirname(dirname(to_local(p3, files[1]))))
        symlink("/nowhere", dirname(to_local(p3, files[1])))
        plan3, _ = plan_extraction(h, p3, selection(p3, ["B00000C"]), stage3)
        runnable3, conflicts3 = reconcile_local(p3, plan3)
        @test conflicts3 == [relative(p3, f) for f in files]
        @test isempty(runnable3)
    end

    @testset "the staging directory must have room" begin
        @test check_staging_space("/s", 10^6, 1000) === nothing
        @test_throws "has 1.0 K free but the extraction needs about 4.0 K" check_staging_space("/s", 1024, 4096)
    end

    @testset "a failure keeps the staged files and a rerun resumes" begin
        p, helper, stage = setup()
        sel = selection(p, ["B00000C"])
        err = try
            apply!(h, p, sel; helper, extract_progress = _ -> error("interrupted"))
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("interrupted", err.msg)
        @test occursin("kept in $stage", err.msg)
        @test isfile(joinpath(stage, "xprod", relative(p, files[1])))
        @test !isfile(to_local(p, files[1]))

        result = apply!(h, p, sel; helper)
        @test result.extracted_files == 2
        @test groups_of(to_local(p, files[1])) == ["B00000C"]
        @test !isdir(joinpath(stage, "xprod"))
    end

    @testset "a failing cleanup names the staging directory" begin
        p, helper, stage = setup()
        staged_dir = dirname(joinpath(stage, "xprod", relative(p, files[1])))
        # Once the last file is staged, removing the staged files is not permitted.
        lock_staged(e) = e.done == e.total && chmod(staged_dir, 0o555)
        err = try
            apply!(h, p, selection(p, ["B00000C"]); helper, extract_progress = lock_staged)
        catch e
            e
        finally
            chmod(staged_dir, 0o755)
        end
        @test err isa ErrorException
        @test occursin("already in the local mirror", err.msg)
        @test occursin("kept in $stage", err.msg)
        @test groups_of(to_local(p, files[1])) == ["B00000C"]
        @test isfile(joinpath(stage, "xprod", relative(p, files[1])))
    end

    @testset "an unreadable local file is an error naming the path" begin
        p, helper, stage = setup()
        mkpath(dirname(to_local(p, files[1])))
        write(to_local(p, files[1]), "garbage")
        @test_throws "remove the file before retrying" apply!(h, p, selection(p, ["B00000C"]); helper)
        @test read(to_local(p, files[1]), String) == "garbage"
    end
end
