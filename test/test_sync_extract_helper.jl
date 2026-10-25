# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "remote/extract.jl" begin
    script = Sync.HELPER_SCRIPT
    project = dirname(Base.active_project())
    work = mktempdir()
    sources = [write_lh5(joinpath(work, "src", "a.lh5"); scale = 1),
               write_lh5(joinpath(work, "src", "b.lh5"); scale = 2)]

    # Run the script as the sync tool does: a TOML job file in, one TOML record
    # per line on standard output.
    function run_script(command, spec; jobs = nothing, jobfile = nothing)
        if jobfile === nothing
            jobfile = joinpath(mktempdir(), "job.toml")
            open(io -> TOML.print(io, spec), jobfile, "w")
        end
        extra = jobs === nothing ? String[] : ["--jobs", string(jobs)]
        out = IOBuffer()
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(
            `$(Base.julia_cmd()) --project=$project $script $command $jobfile $extra`);
            stdout = out, stderr = err))
        lines = filter(!isempty, split(String(take!(out)), '\n'))
        (; code = proc.termsignal != 0 ? -proc.termsignal : proc.exitcode, records = [TOML.parse(l)["r"] for l in lines],
           stderr = String(take!(err)))
    end

    extract_spec(dest) = Dict("job" => [
        Dict("source" => sources[i], "groups" => ["B00000C", "aux"],
             "destination" => joinpath(dest, "o$i.lh5")) for i in 1:2])

    @testset "inspect reports each group's stored bytes" begin
        r = run_script("inspect", Dict("files" => sources))
        @test r.code == 0
        @test [rec["file"] for rec in r.records] == sources
        @test r.records[1]["groups"] == ["B00000C", "V01234A", "aux"]
        @test r.records[1]["bytes"] == [4 * 100, 4 * 200, 4 * 300]
        @test r.records[2]["bytes"] == [4 * 200, 4 * 400, 4 * 600]
        @test [rec["layout"] for rec in r.records] == ["", ""]
    end

    @testset "inspect with a group list sizes only those groups" begin
        flat = sources[1]
        tiered = write_lh5_tier_det(joinpath(work, "src", "sized.lh5"))
        for (file, layout) in ((flat, ""), (tiered, "jldsp"))
            full = only(run_script("inspect", Dict("files" => [file])).records)
            @test !haskey(full, "sized")
            r = run_script("inspect", Dict("job" => [Dict("file" => file, "groups" => ["aux", "B00000C"])]))
            @test r.code == 0
            rec = only(r.records)
            @test rec["groups"] == full["groups"] == ["B00000C", "V01234A", "aux"]
            @test rec["layout"] == layout
            @test rec["sized"] == ["aux", "B00000C"]
            @test rec["bytes"] == [full["bytes"][3], full["bytes"][1]]
            # Files without a list in the same job are sized in full.
            mixed = run_script("inspect", Dict("files" => [file],
                                               "job" => [Dict("file" => file, "groups" => ["V01234A"])]); jobs = 1)
            @test mixed.records[1] == full
            @test mixed.records[2]["bytes"] == [full["bytes"][2]]
            @test mixed.records[2]["sized"] == ["V01234A"]
            bad = run_script("inspect", Dict("job" => [Dict("file" => file, "groups" => ["B00000C", "Z99999Z"])]))
            @test bad.code != 0
            @test occursin("group Z99999Z not found in $file", bad.stderr)
        end
        plain = write_lh5(joinpath(work, "src", "sized-plain.lh5"); groups = ["x"])
        r = run_script("inspect", Dict("job" => [Dict("file" => plain, "groups" => ["x"])]))
        @test r.code != 0
        @test occursin("group x not found in $plain", r.stderr)
    end

    @testset "extract copies the chosen groups in the main process" begin
        dest = joinpath(work, "out-main")
        r = run_script("extract", extract_spec(dest))
        @test r.code == 0
        files = filter(rec -> rec["event"] == "file", r.records)
        @test [rec["status"] for rec in files] == ["extracted", "extracted"]
        summary = only(filter(rec -> rec["event"] == "summary", r.records))
        @test summary["files"] == 2
        @test summary["extracted"] == 2
        @test summary["skipped"] == 0
        @test summary["groups"] == 4
        @test summary["workers"] == 0
        for i in 1:2
            h5open(joinpath(dest, "o$i.lh5"), "r") do out
                h5open(sources[i], "r") do src
                    @test collect(keys(out)) == ["B00000C", "aux"]
                    for name in ("B00000C", "aux")
                        @test read(out[name]["jldsp"]["waveform"]) ==
                              read(src[name]["jldsp"]["waveform"])
                        @test read_attribute(out[name], "unit") == "keV"
                    end
                    @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"]
                    @test read_attribute(out, "juleana_sync_source") == sources[i]
                end
            end
            @test !isfile(joinpath(dest, "o$i.lh5.partial"))
        end
    end

    @testset "a finished file is skipped until its source changes" begin
        dest = joinpath(work, "out-main")
        r = run_script("extract", extract_spec(dest))
        @test [rec["status"] for rec in r.records if rec["event"] == "file"] ==
              ["skipped", "skipped"]
        sleep(1.1)
        touch(sources[1])
        r2 = run_script("extract", extract_spec(dest))
        @test sort([rec["status"] for rec in r2.records if rec["event"] == "file"]) ==
              ["extracted", "skipped"]
        # A different group list is not a finished file.
        spec = extract_spec(dest)
        spec["job"][2]["groups"] = ["V01234A"]
        r3 = run_script("extract", spec)
        @test [rec["status"] for rec in r3.records if rec["event"] == "file"] ==
              ["skipped", "extracted"]
        h5open(joinpath(dest, "o2.lh5"), "r") do out
            @test collect(keys(out)) == ["V01234A"]
        end
    end

    @testset "two workers produce the same files" begin
        dest = joinpath(work, "out-workers")
        r = run_script("extract", extract_spec(dest); jobs = 2)
        @test r.code == 0
        @test sort([rec["status"] for rec in r.records if rec["event"] == "file"]) ==
              ["extracted", "extracted"]
        @test only(filter(rec -> rec["event"] == "summary", r.records))["workers"] == 2
        @test any(rec["worker"] != 1 for rec in r.records if rec["event"] == "file")
        for i in 1:2
            h5open(joinpath(dest, "o$i.lh5"), "r") do out
                h5open(sources[i], "r") do src
                    @test read(out["B00000C"]["jldsp"]["waveform"]) ==
                          read(src["B00000C"]["jldsp"]["waveform"])
                end
            end
        end
        r2 = run_script("inspect", Dict("files" => sources); jobs = 2)
        @test r2.code == 0
        @test sort([rec["file"] for rec in r2.records]) == sort(sources)
    end

    @testset "--jobs caps the workers by the file count" begin
        one = Dict("job" => extract_spec(joinpath(work, "out-one"))["job"][1:1])
        r = run_script("extract", one; jobs = 2)
        @test r.code == 0
        @test only(filter(rec -> rec["event"] == "summary", r.records))["workers"] == 0
    end

    @testset "a failing file stops the job with a nonzero exit" begin
        for jobs in (nothing, 2)
            dest = joinpath(work, "out-bad-$(jobs)")
            spec = extract_spec(dest)
            spec["job"][1]["groups"] = ["missing"]
            r = run_script("extract", spec; jobs)
            @test r.code == 1
            jobs === nothing || @test occursin("On worker", r.stderr)
            @test occursin("$(sources[1]): group missing not found in $(sources[1])", r.stderr)
            @test !isfile(joinpath(dest, "o1.lh5"))
            @test !isfile(joinpath(dest, "o1.lh5.partial"))
        end
    end

    @testset "an unreadable source names the file" begin
        notes = joinpath(work, "src", "notes.lh5")
        write(notes, "not an HDF5 file")
        spec = Dict("job" => [Dict("source" => notes, "groups" => ["aux"],
                                   "destination" => joinpath(work, "out-notes", "n.lh5"))])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin(notes, r.stderr)
    end

    @testset "no further file is started after a failure" begin
        many = [write_lh5(joinpath(work, "many", "m$i.lh5")) for i in 1:6]
        dest = joinpath(work, "out-many")
        spec = Dict("job" => [Dict("source" => many[i],
                                   "groups" => i == 1 ? ["missing"] : ["aux"],
                                   "destination" => joinpath(dest, "o$i.lh5")) for i in 1:6])
        r = run_script("extract", spec; jobs = 2)
        @test r.code == 1
        @test occursin("group missing not found in $(many[1])", r.stderr)
    end

    @testset "a corrupt destination stops the job and names both files" begin
        dest = joinpath(work, "out-corrupt", "o1.lh5")
        mkpath(dirname(dest))
        write(dest, "garbage bytes")
        spec = Dict("job" => [Dict("source" => sources[1], "groups" => ["aux"],
                                   "destination" => dest)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin(sources[1], r.stderr)
        @test occursin(dest, r.stderr)
        @test read(dest, String) == "garbage bytes"
    end

    @testset "a destination that is not a reduced file is never overwritten" begin
        dest = joinpath(work, "out-plain", "o1.lh5")
        mkpath(dirname(dest))
        h5open(f -> f["x"] = [1, 2, 3], dest, "w")
        before = read(dest)
        spec = Dict("job" => [Dict("source" => sources[1], "groups" => ["aux"],
                                   "destination" => dest)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin("existing destination $dest is not a reduced file written by this tool", r.stderr)
        @test read(dest) == before
    end

    @testset "the destination may not be the source" begin
        copy = joinpath(work, "src", "copy.lh5")
        cp(sources[1], copy; force = true)
        before = read(copy)
        spec = Dict("job" => [Dict("source" => copy, "groups" => ["aux"], "destination" => copy)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin("destination $copy is the source $copy", r.stderr)
        @test read(copy) == before
        @test !isfile(copy * ".partial")
    end

    @testset "a missing job file fails with a message" begin
        r = run_script("inspect", Dict("files" => sources); jobfile = joinpath(work, "nope.toml"))
        @test r.code == 1
        @test occursin("extract.jl:", r.stderr)
    end

    @testset "the helper keeps BLAS to one thread" begin
        env = copy(ENV)
        delete!(env, "OPENBLAS_NUM_THREADS")
        delete!(env, "OMP_NUM_THREADS")
        delete!(env, "OPENBLAS_DEFAULT_NUM_THREADS")
        code = """
            const LOADED_AS_LIBRARY = true
            include($(repr(script)))
            using LinearAlgebra, Distributed
            println(get(ENV, "OPENBLAS_NUM_THREADS", "unset"))
            start_workers(2)
            println(join(remotecall_fetch.(() -> get(ENV, "OPENBLAS_NUM_THREADS", "unset"), workers()), ","))
            println(join(remotecall_fetch.(() -> LinearAlgebra.BLAS.get_num_threads(), workers()), ","))
            stopworkers()
            """
        out = read(setenv(`$(Base.julia_cmd()) --startup-file=no --project=$project -e $code`, env), String)
        @test split(out, '\n')[1:3] == ["1", "1,1", "1,1"]
    end

    @testset "--jobs below one is rejected" begin
        r = run_script("inspect", Dict("files" => sources); jobs = 0)
        @test r.code == 2
        @test occursin("usage:", r.stderr)
    end

    @testset "a bad command line is rejected" begin
        r = run_script("frobnicate", Dict("files" => String[]))
        @test r.code == 2
        @test occursin("usage:", r.stderr)
    end

    @testset "inspect classifies the group layouts" begin
        both = write_lh5_tier_det(joinpath(work, "src", "n.lh5"))
        one_detector = write_lh5(joinpath(work, "src", "one.lh5"); groups = ["B00000C"])
        only_aux = write_lh5_tier_det(joinpath(work, "src", "aux.lh5"); groups = ["aux"])
        events = write_lh5(joinpath(work, "src", "evt.lh5"); groups = ["jlevt"], inner = "tables")
        plain = write_lh5(joinpath(work, "src", "plain.lh5"); groups = ["x", "y"])
        two_tiers = joinpath(work, "src", "two.lh5")
        h5open(two_tiers, "w") do f
            for tier in ("jldsp", "jlhit")
                create_group(create_group(f, tier), "B00000C")
            end
        end
        channels = write_lh5(joinpath(work, "src", "ch.lh5"); groups = ["ch1104000", "ch1110402"])
        files = [both, one_detector, only_aux, events, plain, two_tiers, channels]
        r = run_script("inspect", Dict("files" => files); jobs = 1)
        @test r.code == 0
        got = Dict(rec["file"] => (rec["groups"], rec["layout"]) for rec in r.records)
        @test got[both] == (["B00000C", "V01234A", "aux"], "jldsp")
        @test only(filter(rec -> rec["file"] == both, r.records))["bytes"] == [400, 800, 1200]
        # A single top-level detector group is the older layout, not a tier group.
        @test got[one_detector] == (["B00000C"], "")
        # No detector id anywhere: no detector axis, and no group is reported.
        @test got[only_aux] == ([], "")
        @test got[events] == ([], "")
        @test got[plain] == ([], "")
        # Channel-id groups (jl-v0.4 form) are detectors of the older layout.
        @test got[channels] == (["ch1104000", "ch1110402"], "")
        # The new layout needs exactly one top-level group.
        @test got[two_tiers] == ([], "")
    end

    @testset "the helper recognizes the detector names" begin
        names = ["B00000C", "P00664B", "V01234A", "C000RG1", "C00ANG3", "S001", "PMT001",
                 "PULS01", "PULS01ANA", "AUX01", "DUMMY1", "DUMMY12", "BSLN01", "MUON01",
                 "ch1110402", "ch1104000", "ch123",
                 "b00000c", "B0000C", "B00000Q", "ch0010402", "ch12", "aux", "jlevt", "S01", "PMT1"]
        files = [write_lh5_tier_det(joinpath(work, "ids", "$i.lh5"); groups = [name])
                 for (i, name) in pairs(names)]
        r = run_script("inspect", Dict("files" => files); jobs = 1)
        layout_of = Dict(rec["file"] => rec["layout"] for rec in r.records)
        # The helper follows the strict detector id forms, one pattern per detector
        # family, so these names are not detectors even where the installed
        # LegendDataManagement accepts them.
        loose = ["B0000C", "B00000Q", "S01", "PMT1"]
        for (file, name) in zip(files, names)
            if name in loose
                @test layout_of[file] == ""
            else
                expected = LegendDataManagement._can_convert_to(LegendDataManagement.DetectorId, name) ||
                           LegendDataManagement._can_convert_to(LegendDataManagement.ChannelId, name)
                @test (layout_of[file] == "jldsp") == expected
            end
        end
        @test count(f -> layout_of[f] == "jldsp", files) == 17
    end

    @testset "the tier/detector fixture run" begin
        dir = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier", "jlpks", "cal", "p18")
        files = [joinpath(dir, "r000", "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5"),
                 joinpath(dir, "r000", "l200-p18-r000-cal-20251107T192416Z-tier_jlpks.lh5"),
                 joinpath(dir, "r001", "l200-p18-r001-cal-20251108T101010Z-tier_jlpks.lh5")]
        r = run_script("inspect", Dict("files" => files); jobs = 1)
        @test [rec["layout"] for rec in r.records] == ["jlpks", "jlpks", "jlpks"]
        @test [rec["groups"] for rec in r.records] ==
              [["B00000C", "V01234A", "aux"], ["B00000C", "V01234A", "aux"], ["B00000C", "V01234A"]]
        @test [rec["bytes"] for rec in r.records] ==
              [[400, 800, 1200], [800, 1600, 2400], [400, 800]]
    end

    @testset "extract copies detectors of the tier/detector layout" begin
        src = write_lh5_tier_det(joinpath(work, "src", "t.lh5"))
        dest = joinpath(work, "out-tier")
        spec = Dict("job" => [Dict("source" => src, "groups" => ["B00000C", "aux"],
                                   "destination" => joinpath(dest, "t.lh5"))])
        r = run_script("extract", spec)
        @test r.code == 0
        h5open(joinpath(dest, "t.lh5"), "r") do out
            h5open(src, "r") do s
                @test collect(keys(out)) == ["jldsp"]
                @test collect(keys(out["jldsp"])) == ["B00000C", "aux"]
                for name in ("B00000C", "aux")
                    @test read(out["jldsp"][name]["waveform"]) == read(s["jldsp"][name]["waveform"])
                    @test read_attribute(out["jldsp"][name], "unit") == "keV"
                end
                @test read_attribute(out["jldsp"], "origin") == "fixture"
                @test read_attribute(out["jldsp"], "revision") == 7
                @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"]
                @test read_attribute(out, "juleana_sync_source") == src
            end
        end
        @test !isfile(joinpath(dest, "t.lh5.partial"))

        # A tier group without attributes is copied as an empty group.
        bare = write_lh5_tier_det(joinpath(work, "src", "bare.lh5"); tier_attributes = Dict{String,Any}())
        spec = Dict("job" => [Dict("source" => bare, "groups" => ["V01234A"],
                                   "destination" => joinpath(dest, "bare.lh5"))])
        @test run_script("extract", spec).code == 0
        h5open(joinpath(dest, "bare.lh5"), "r") do out
            @test collect(keys(out["jldsp"])) == ["V01234A"]
            @test isempty(keys(attrs(out["jldsp"])))
        end

        # The other layouts still extract, and the two-worker path handles both.
        old = write_lh5(joinpath(work, "src", "old.lh5"))
        both = Dict("job" => [
            Dict("source" => src, "groups" => ["V01234A"], "destination" => joinpath(dest, "w1.lh5")),
            Dict("source" => old, "groups" => ["V01234A"], "destination" => joinpath(dest, "w2.lh5"))])
        r2 = run_script("extract", both; jobs = 2)
        @test r2.code == 0
        @test h5open(f -> collect(keys(f["jldsp"])), joinpath(dest, "w1.lh5"), "r") == ["V01234A"]
        @test h5open(f -> collect(keys(f)), joinpath(dest, "w2.lh5"), "r") == ["V01234A"]
    end

    @testset "tier/detector files: skip rule and union rebuild" begin
        src = write_lh5_tier_det(joinpath(work, "src", "u.lh5"))
        dest = joinpath(work, "out-union", "u.lh5")
        job(groups) = Dict("job" => [Dict("source" => src, "groups" => groups, "destination" => dest)])
        status(r) = only(rec["status"] for rec in r.records if rec["event"] == "file")

        @test status(run_script("extract", job(["B00000C"]))) == "extracted"
        @test status(run_script("extract", job(["B00000C"]))) == "skipped"
        # The union the client sends after reading the old group list rebuilds the file.
        @test status(run_script("extract", job(["B00000C", "V01234A"]))) == "extracted"
        h5open(dest, "r") do out
            @test collect(keys(out["jldsp"])) == ["B00000C", "V01234A"]
            @test read_attribute(out["jldsp"], "origin") == "fixture"
            @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "V01234A"]
        end
        @test status(run_script("extract", job(["B00000C", "V01234A"]))) == "skipped"
        sleep(1.1)
        touch(src)
        @test status(run_script("extract", job(["B00000C", "V01234A"]))) == "extracted"
        # A file that is not a reduced file is never overwritten.
        foreign = write_lh5_tier_det(joinpath(work, "out-union", "foreign.lh5"))
        spec = Dict("job" => [Dict("source" => src, "groups" => ["B00000C"], "destination" => foreign)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin("is not a reduced file written by this tool", r.stderr)
    end

    @testset "an old-layout reduced file is rebuilt with the union" begin
        src = write_lh5(joinpath(work, "src", "oldu.lh5"))
        dest = joinpath(work, "out-oldunion", "o.lh5")
        job(groups) = Dict("job" => [Dict("source" => src, "groups" => groups, "destination" => dest)])
        status(r) = only(rec["status"] for rec in r.records if rec["event"] == "file")
        @test status(run_script("extract", job(["B00000C"]))) == "extracted"
        @test status(run_script("extract", job(["B00000C", "V01234A"]))) == "extracted"
        h5open(dest, "r") do out
            @test collect(keys(out)) == ["B00000C", "V01234A"]
            @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "V01234A"]
        end
        r = run_script("inspect", Dict("files" => [dest]); jobs = 1)
        @test only(r.records)["groups"] == ["B00000C", "V01234A"]
        @test only(r.records)["layout"] == ""
    end

    @testset "extract names the file and the detector it cannot use" begin
        src = write_lh5_tier_det(joinpath(work, "src", "m.lh5"))
        dest = joinpath(work, "out-miss", "m.lh5")
        spec = Dict("job" => [Dict("source" => src, "groups" => ["Z99999Z"], "destination" => dest)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin("$src: group Z99999Z not found in $src", r.stderr)
        @test !isfile(dest) && !isfile(dest * ".partial")

        events = write_lh5(joinpath(work, "src", "evt2.lh5"); groups = ["jlevt"], inner = "tables")
        spec = Dict("job" => [Dict("source" => events, "groups" => ["jlevt"],
                                   "destination" => joinpath(work, "out-miss", "e.lh5"))])
        r2 = run_script("extract", spec)
        @test r2.code == 1
        @test occursin("$events: no detector axis, cannot extract jlevt", r2.stderr)
    end
end
