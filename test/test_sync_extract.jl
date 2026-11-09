# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Every test that starts the extraction helper runs it through `counted_helper`; the driver reports the count.
@testset "extraction helper script" begin
    h = LocalHost()
    helper = counted_helper()
    work = mktempdir()
    job(source, groups, destination) = Dict("source" => source, "groups" => groups, "destination" => destination)
    status_of(records) = [(r["status"]) for r in records if r["event"] == "file"]

    @testset "inspect classifies the group layouts and sizes only the requested groups" begin
        src(name) = joinpath(work, "src", name)
        flat = write_lh5(src("a.lh5"))
        tiered = write_lh5_tier_det(src("n.lh5"))
        sized_flat = write_lh5(src("sized-flat.lh5"))
        sized_tier = write_lh5_tier_det(src("sized-tier.lh5"))
        one_detector = write_lh5(src("one.lh5"); groups = ["B00000C"])
        only_aux = write_lh5_tier_det(src("aux.lh5"); groups = ["aux"])
        events = write_lh5(src("evt.lh5"); groups = ["jlevt"], inner = "tables")
        plain = write_lh5(src("plain.lh5"); groups = ["x", "y"])
        channels = write_lh5(src("ch.lh5"); groups = ["ch1104000", "ch1110402"])
        two_tiers = src("two.lh5")
        h5open(two_tiers, "w") do f
            for tier in ("jldsp", "jlhit")
                create_group(create_group(f, tier), "B00000C")
            end
        end
        valid = ["B00000C", "P00664B", "V01234A", "C000RG1", "C00ANG3", "S001", "PMT001", "PULS01", "PULS01ANA", "AUX01", "DUMMY1",
                 "DUMMY12", "BSLN01",
                 "MUON01", "ch1110402", "ch1104000", "ch123"]
        invalid = ["b00000c", "B0000C", "B00000Q", "ch0010402", "ch12", "aux", "jlevt", "S01", "PMT1"]
        named = Dict(name => write_lh5_tier_det(joinpath(work, "ids", "$i.lh5"); groups = [name])
                     for (i, name) in enumerate([valid; invalid]))
        files = [flat, tiered, one_detector, only_aux, events, plain, two_tiers, channels, values(named)...]
        spec = Dict("files" => files,
                    "job" =>
                        [Dict("file" => sized_flat, "groups" => ["aux", "B00000C"]), Dict("file" => sized_tier, "groups" => ["V01234A"])])

        seen = Dict{String,Any}[]
        records = run_helper(h, helper, "inspect", spec; jobs = 1, on_record = r -> push!(seen, r))
        @test seen == records && length(records) == length(files) + 2
        by_file = Dict(r["file"] => r for r in records)
        @test (by_file[flat]["groups"], by_file[flat]["bytes"], by_file[flat]["layout"]) ==
              (["B00000C", "V01234A", "aux"], [400, 800, 1200], "")
        @test (by_file[tiered]["bytes"], by_file[tiered]["layout"]) == ([400, 800, 1200], "jldsp") && !haskey(by_file[flat], "sized")
        @test (by_file[sized_flat]["sized"], by_file[sized_flat]["bytes"], by_file[sized_flat]["groups"]) ==
              (["aux", "B00000C"], [1200, 400], ["B00000C", "V01234A", "aux"])
        @test (by_file[sized_tier]["sized"], by_file[sized_tier]["bytes"], by_file[sized_tier]["layout"]) == (["V01234A"], [800], "jldsp")
        # A single top-level detector group, channel ids and files without a detector id are the older layouts or have no detector axis.
        @test (by_file[one_detector]["groups"], by_file[one_detector]["layout"]) == (["B00000C"], "")
        @test (by_file[channels]["groups"], by_file[channels]["layout"]) == (["ch1104000", "ch1110402"], "")
        for file in (only_aux, events, plain, two_tiers)
            @test (by_file[file]["groups"], by_file[file]["layout"]) == (String[], "")
        end
        # The helper follows the strict detector id forms, one pattern per detector family.
        @test all(name -> by_file[named[name]]["layout"] == "jldsp", valid) && all(name -> by_file[named[name]]["layout"] == "", invalid)
        @test isfile(joinpath(helper.staging, "extract.jl")) && !isfile(joinpath(helper.staging, "jobs", "inspect.toml"))
    end

    @testset "a failing file stops two workers with an error that names the file and the group" begin
        src = write_lh5(joinpath(work, "bad", "a.lh5"))
        dest = joinpath(work, "out-bad")
        spec = Dict("job" => [job(src, ["missing"], joinpath(dest, "o1.lh5")), job(src, ["aux"], joinpath(dest, "o2.lh5"))])
        err = try
            run_helper(h, helper, "extract", spec; jobs = 2)
        catch e
            sprint(showerror, e)
        end
        @test occursin("On worker", err) && occursin("$src: group missing not found in $src", err)
        @test !isfile(joinpath(dest, "o1.lh5")) && !isfile(joinpath(dest, "o1.lh5.partial"))
        @test isfile(joinpath(helper.staging, "jobs", "extract.toml"))   # a failed run keeps its job file
    end

    # Both layouts and a tier group without attributes, extracted by two workers.
    flat = write_lh5(joinpath(work, "src", "flat.lh5"); scale = 2)
    tiered = write_lh5_tier_det(joinpath(work, "src", "tier.lh5"))
    bare = write_lh5_tier_det(joinpath(work, "src", "bare.lh5"); tier_attributes = Dict{String,Any}())
    dest = joinpath(work, "out")
    first_spec = Dict("job" => [job(flat, ["B00000C", "aux"], joinpath(dest, "flat.lh5")),
                                job(tiered, ["B00000C", "aux"], joinpath(dest, "tier.lh5")),
                                job(bare, ["V01234A"], joinpath(dest, "bare.lh5"))])

    @testset "two workers extract the chosen groups of both layouts" begin
        records = run_helper(h, helper, "extract", first_spec; jobs = 2)
        @test status_of(records) == ["extracted", "extracted", "extracted"]
        summary = only(filter(r -> r["event"] == "summary", records))
        @test (summary["files"], summary["extracted"], summary["skipped"], summary["groups"], summary["workers"]) == (3, 3, 0, 5, 2)
        @test any(r["worker"] != 1 for r in records if r["event"] == "file") && !isfile(joinpath(dest, "flat.lh5.partial"))
        h5open(joinpath(dest, "flat.lh5"), "r") do out
            h5open(flat, "r") do s
                @test collect(keys(out)) == ["B00000C", "aux"]
                @test all(g -> read(out[g]["jldsp"]["waveform"]) == read(s[g]["jldsp"]["waveform"]) &&
                               read_attribute(out[g], "unit") == "keV", ["B00000C", "aux"])
                @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"] && read_attribute(out, "juleana_sync_source") == flat
            end
        end
        h5open(joinpath(dest, "tier.lh5"), "r") do out
            h5open(tiered, "r") do s
                @test collect(keys(out)) == ["jldsp"] && collect(keys(out["jldsp"])) == ["B00000C", "aux"]
                @test all(g -> read(out["jldsp"][g]["waveform"]) == read(s["jldsp"][g]["waveform"]) &&
                               read_attribute(out["jldsp"][g], "unit") == "keV", ["B00000C", "aux"])
                @test (read_attribute(out["jldsp"], "origin"), read_attribute(out["jldsp"], "revision")) == ("fixture", 7)
                @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"]
            end
        end
        h5open(joinpath(dest, "bare.lh5"), "r") do out
            @test collect(keys(out["jldsp"])) == ["V01234A"] && isempty(keys(attrs(out["jldsp"])))
        end
    end

    @testset "a finished file is skipped, a changed source or group list is rebuilt, a foreign file is never overwritten" begin
        sleep(1.1)   # modification times have a one-second resolution
        touch(bare)
        foreign = write_lh5_tier_det(joinpath(dest, "foreign.lh5"))
        before = read(foreign)
        spec = Dict("job" => [job(flat, ["B00000C", "aux"], joinpath(dest, "flat.lh5")),
                              job(tiered, ["B00000C", "V01234A", "aux"], joinpath(dest, "tier.lh5")),
                              job(bare, ["V01234A"], joinpath(dest, "bare.lh5")), job(tiered, ["B00000C"], foreign)])
        seen = Dict{String,Any}[]
        @test_throws "existing destination $foreign is not a reduced file written by this tool" run_helper(h, helper, "extract", spec;
                                                                                                           on_record = r -> push!(seen, r))
        @test status_of(seen) == ["skipped", "extracted", "extracted"]
        h5open(joinpath(dest, "tier.lh5"), "r") do out
            @test collect(keys(out["jldsp"])) == ["B00000C", "V01234A", "aux"] && read_attribute(out["jldsp"], "origin") == "fixture"
            @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "V01234A", "aux"]
        end
        @test read(foreign) == before
    end

    @testset "the destination may not be the source" begin
        before = read(flat)
        @test_throws "destination $flat is the source $flat" run_helper(h, helper, "extract", Dict("job" => [job(flat, ["aux"], flat)]))
        @test read(flat) == before && !isfile(flat * ".partial")
    end
end

@testset "extraction through apply!" begin
    h = LocalHost()
    dsp = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000")
    files = [joinpath(dsp, "l200-p18-r000-cal-20251107T191821Z-tier_jldsp.lh5"),
             joinpath(dsp, "l200-p18-r000-cal-20251107T192416Z-tier_jldsp.lh5")]
    groups_of(path) = h5open(f -> collect(keys(f)), path, "r")
    function selection(p, groups)
        return Selection("local", "xprod", EXTRACT_ROOT, p.local_root, nothing, ["xprod/config.json", "xprod/legend-metadata"], String[],
                         now(),
                         [ExtractEntry(relative(p, dsp), groups)])
    end

    @testset "staged files are kept when the run fails and removed after it succeeds" begin
        stage = joinpath(mktempdir(), "stage")
        p, helper = Production(h, "xprod", EXTRACT_ROOT, mktempdir()), counted_helper(; staging = stage)
        s = selection(p, ["B00000C", "aux"])
        err = try
            apply!(h, p, s; helper, report = step -> step.step == "pulling extracted files" && error("interrupted"))
        catch e
            e
        end
        @test err isa ErrorException && occursin("interrupted", err.msg) && occursin("kept in $stage", err.msg)
        @test isfile(joinpath(stage, "xprod", relative(p, files[1]))) && !ispath(to_local(p, files[1]))

        seen, progress = StepProgress[], ExtractProgress[]
        result = apply!(h, p, s; helper, report = step -> push!(seen, step), extract_progress = e -> push!(progress, e))
        @test (result.extracted_files, result.extracted_groups) == (2, 4) && isempty(result.conflicts)
        @test unique(step.step for step in seen) ==
              ["planning extraction", "sizing extract groups", "extracting on the host", "copying", "pulling extracted files",
               "creating links", "cleaning up staging"]
        @test [(e.done, e.total) for e in progress] == [(1, 2), (2, 2)]
        for file in files
            @test groups_of(to_local(p, file)) == ["B00000C", "aux"]
            h5open(to_local(p, file), "r") do out
                h5open(file, "r") do src
                    @test read(out["aux"]["jldsp"]["waveform"]) == read(src["aux"]["jldsp"]["waveform"])
                end
                @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"]
            end
        end
        @test !isdir(joinpath(stage, "xprod")) && isfile(joinpath(stage, "extract.jl"))   # the staged files are gone, and only they
        @test isfile(joinpath(p.local_root, "xprod", "config_local.yaml"))
        @test occursin("extracted 2 files, 4 groups", summary_text(result)) && occursin("LEGEND_DATA_CONFIG=", summary_text(result))
    end

    @testset "a stop from the step report reaches the caller unchanged" begin
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        report = step -> step.step == "extracting on the host" && throw(SyncStopped())
        @test_throws SyncStopped apply!(h, p, selection(p, ["B00000C"]); helper = counted_helper(), report)
        @test !ispath(to_local(p, files[1]))
    end

    @testset "a reduced file in the mirror is kept with the union of the groups" begin
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        local_file = write_lh5(to_local(p, files[1]); groups = ["B00000C"])
        h5open(f -> attrs(f)["juleana_sync_groups"] = ["B00000C"], local_file, "r+")
        plan, _ = plan_extraction(h, p, selection(p, ["aux"]), joinpath(mktempdir(), "stage");
                                  helper = HelperConfig(; julia = "/nonexistent/julia"))
        runnable, conflicts = reconcile_local(p, plan)
        @test isempty(conflicts) && [(j.source, j.groups) for j in runnable] == [(files[1], ["B00000C", "aux"]), (files[2], ["aux"])]
        @test_throws "inspected 1 files for a plan of 2 jobs" plan_group_bytes(plan, [(["aux"], [1])])
        @test_throws "got 2 sizes for 1 groups of $(files[2])" plan_group_bytes(plan, [(["aux"], [1]), (["aux"], [1, 2])])
        @test plan_bytes(h, HelperConfig(; julia = "/nonexistent/julia"), ExtractJob[]) == 0
    end

    @testset "an unreadable local file and a missing environment are errors that say what to do" begin
        p = Production(h, "xprod", EXTRACT_ROOT, mktempdir())
        mkpath(dirname(to_local(p, files[1])))
        write(to_local(p, files[1]), "garbage")
        @test_throws "remove the file before retrying" reconcile_local(p,
                                                                       first(plan_extraction(h, p, selection(p, ["aux"]), mktempdir();
                                                                                             helper = HelperConfig(;
                                                                                                                   julia = "/nonexistent/julia"))))
        @test read(to_local(p, files[1]), String) == "garbage"
        no_env = HelperConfig(; julia_project = mktempdir(), staging = joinpath(mktempdir(), "stage"))
        err = try
            apply!(h, p, selection(p, ["aux"]); dry_run = true, helper = no_env)
        catch e
            e
        end
        @test occursin("does not exist", err.msg) && occursin("Pkg.add", err.msg)
    end

    @testset "a period entry merges with run entries, leaves out files copied whole and reports the runs that lack a detector" begin
        p = Production(h, "tprod", TIER_DET_ROOT, mktempdir())
        stage = joinpath(mktempdir(), "stage")
        helper = counted_helper(; staging = stage)
        p18 = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier", "jlpks", "cal", "p18")
        tier_files = [joinpath(p18, "r000", "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5"),
                      joinpath(p18, "r000", "l200-p18-r000-cal-20251107T192416Z-tier_jlpks.lh5"),
                      joinpath(p18, "r001", "l200-p18-r001-cal-20251108T101010Z-tier_jlpks.lh5")]
        entries = [ExtractEntry(relative(p, p18), ["B00000C", "aux"]), ExtractEntry(relative(p, joinpath(p18, "r001")), ["V01234A"])]
        sel = Selection("local", "tprod", TIER_DET_ROOT, p.local_root, nothing,
                        ["tprod/config.json", "tprod/legend-metadata", relative(p, tier_files[2])],
                        String[], now(), entries)
        progress = ExtractProgress[]
        result = apply!(h, p, sel; helper, extract_progress = e -> push!(progress, e))
        @test (result.extracted_files, result.extracted_groups) == (2, 4) &&
              result.not_in_run == [(relative(p, joinpath(p18, "r001")), "aux")]
        @test [(e.done, e.total) for e in progress] == [(1, 2), (2, 2)]
        tier_groups(path) = h5open(f -> collect(keys(f["jlpks"])), path, "r")
        @test tier_groups(to_local(p, tier_files[1])) == ["B00000C", "aux"] &&
              tier_groups(to_local(p, tier_files[3])) == ["B00000C", "V01234A"]
        @test reduced_groups(to_local(p, tier_files[2])) === nothing   # copied whole, never reduced
        h5open(to_local(p, tier_files[1]), "r") do out
            @test read_attribute(out["jlpks"], "origin") == "fixture" && read(out["jlpks"]["aux"]["waveform"]) == collect(Int32, 1:300)
        end
        text = summary_text(result)
        @test occursin("extracted 2 files, 4 groups", text) &&
              occursin("not in run, left out: aux in $(relative(p, joinpath(p18, "r001")))", text)
        @test !isdir(joinpath(stage, "tprod"))
        empty_period = ExtractEntry(relative(p, joinpath(dirname(p18), "p19")), ["B00000C"])
        @test_throws "holds no filekey files and no run directory with filekey files" plan_extraction(h, p,
                                                                                                      Selection("local", "tprod",
                                                                                                                TIER_DET_ROOT, p.local_root,
                                                                                                                nothing, String[], String[],
                                                                                                                now(), [empty_period]),
                                                                                                      stage;
                                                                                                      helper = HelperConfig(;
                                                                                                                            julia = "/nonexistent/julia"))
    end
end

@test all(==("1"), readlines(HELPER_COUNT))   # every helper process starts with one BLAS thread requested
