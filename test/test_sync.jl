# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# A module of its own keeps fixtures out of `Main`, where a `main` binding would become the script's entry point.
module SyncTests

using Test
using Dates: now
using HDF5
using JuLeAna: Sync
using JuLeAna.Sync: main, SSHHost, LocalHost, Production, relative, to_local, remote_command, check_mount, config_dir,
                    default_local_root, host_remote_root, production_tree, find_node!, Node, expand!, set_mode!, first_n_filekeys!,
                    Selection, save_selection, load_selection, ExtractEntry, DetectorEntry, HelperConfig, run_helper,
                    plan_extraction, reconcile_local, remove_stale_links!, apply!, SyncStopped, Options, SyncPage

include(joinpath(@__DIR__, "sync", "fixture.jl"))

const REMOTE = make_remote()
const TIER = joinpath(REMOTE, "test", "generated", "tier")

withenv("XDG_CONFIG_HOME" => mktempdir()) do
    @testset "Sync" begin
        h = LocalHost()
        production(; mount = nothing) = Production(h, "test", REMOTE, mktempdir(); mount_root = mount)
        evt = joinpath(TIER, "jlevt", "phy", "p18", "r000")
        evt_file(key) = joinpath(evt, "l200-p18-r000-phy-$key-tier_jlevt.lh5")
        mandatory = ["test/config.json", "test/legend-metadata"]

        @testset "quoting, malformed configuration files and selections" begin
            args = ["(", ")", "a;b", "a|b", "*", "~/x", "\$HOME", "it's", "two words", "%h\t%f"]
            remote = last(remote_command(SSHHost("cslg4", nothing), `printf '%s\n' $args`).exec)
            @test readlines(`sh -c $remote`) == args
            withenv("XDG_CONFIG_HOME" => mktempdir()) do
                mkpath(config_dir())
                write(joinpath(config_dir(), "settings.yaml"), "local_root: [unclosed\n")
                @test_throws "settings.yaml" default_local_root()
                hosts = joinpath(config_dir(), "hosts.yaml")
                write(hosts, "alpha: [unclosed\n")
                @test_throws "hosts.yaml" host_remote_root(hosts, "alpha")
            end

            p = production()
            root = production_tree(h, p)
            set_mode!(find_node!(h, p, root, relative(p, evt)).children[1], :copy)
            sel = Selection(p, "cslg4", root)
            @test sel.copy == sort([mandatory; relative(p, evt_file("20251107T191821Z"))])
            path = save_selection(joinpath(mktempdir(), "sel.yaml"), sel)
            @test_throws "saved for host cslg4, but the current host is other" load_selection(path, p; host = "other")
            @test_throws "dir must be relative, got /abs/run" ExtractEntry("/abs/run", ["a"])
            @test_throws "dir must not contain .., got a/../b" ExtractEntry("a/../b", ["a"])
            node = Node("r000", evt, :dir)
            expand!(h, p, node)
            @test first_n_filekeys!(node, 1) == 1 && [c.mode for c in node.children] == [:copy, :none]
        end

        @testset "local files, then apply!: copy, link, mount check and per-detector files" begin
            p = production()
            file = relative(p, evt_file("20251107T191821Z"))
            sel = Selection("local", "test", REMOTE, p.local_root, nothing, [file], String[], now())
            path = joinpath(p.local_root, file)
            mkpath(dirname(path))
            symlink("/nowhere", path)
            @test remove_stale_links!(p, sel) == 1 && !ispath(path)
            write(path, "x")
            @test remove_stale_links!(p, sel) == 0 && isfile(path)
            dsp = joinpath(TIER, "jldsp", "cal", "p18", "r000")
            files = [joinpath(dsp, "l200-p18-r000-cal-$key-tier_jldsp.lh5") for key in ("20251107T191821Z", "20251107T192416Z")]
            for (kind, n) in ((:copy, 1), (:link, 1), (:above, 2))
                p = production()
                sel = Selection("local", "test", REMOTE, p.local_root, nothing, mandatory, String[], now(),
                                [ExtractEntry(relative(p, dsp), ["B00000C"])])
                plan = first(plan_extraction(h, p, sel, joinpath(mktempdir(), "stage"); helper = HelperConfig(; julia = "/nonexistent")))
                target = to_local(p, files[1])
                mkpath(kind == :above ? dirname(dirname(target)) : dirname(target))
                kind == :copy ? cp(files[1], target) : symlink("/nowhere", kind == :above ? dirname(target) : target)
                runnable, conflicts = reconcile_local(p, plan)
                @test conflicts == [relative(p, f) for f in files[1:n]] && length(runnable) == 2 - n
            end

            @test_throws "is not a mount point" check_mount(production(; mount = mktempdir()))
            p = production(; mount = "/")
            dsp = relative(p, joinpath(TIER, "jldsp"))
            sel = Selection("local", "test", REMOTE, p.local_root, "/", [mandatory; relative(p, evt)], [dsp], now())
            result = apply!(h, p, sel)
            @test (result.files, result.links) == (4, 1) && readlink(joinpath(p.local_root, dsp)) == joinpath("/", dsp)
            p = production(; mount = "/")
            period = relative(p, joinpath(TIER, "jlqcs", "cal", "p18"))
            entries = [DetectorEntry(period, ["B00000C"], :copy), DetectorEntry(period, ["V01234A"], :link)]
            sel = Selection("local", "test", REMOTE, p.local_root, "/", mandatory, String[], now(), ExtractEntry[], entries)
            result = apply!(h, p, sel)
            @test (result.files, result.links) == (4, 1) && result.not_in_run == [(joinpath(period, "r001"), "V01234A")]
            detector_file(run, detector) = joinpath(p.local_root, period, run, "l200-p18-$run-cal-$detector-tier_jlqcs.lh5")
            @test filesize(detector_file("r001", "B00000C")) == 300 && islink(detector_file("r000", "V01234A"))
        end

        @testset "extraction: both layouts, a stop, a finished run and the helper's guards" begin
            p = production()
            stage = joinpath(mktempdir(), "stage")
            helper = HelperConfig(; staging = stage)
            dsp, pks = joinpath(TIER, "jldsp", "cal", "p18", "r000"), joinpath(TIER, "jlpks", "cal", "p18")
            dsp_file = joinpath(dsp, "l200-p18-r000-cal-20251107T191821Z-tier_jldsp.lh5")
            pks_file = joinpath(pks, "r000", "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5")
            sel = Selection("local", "test", REMOTE, p.local_root, nothing, mandatory, String[], now(),
                            [ExtractEntry(relative(p, dsp), ["B00000C", "aux"]), ExtractEntry(relative(p, pks), ["B00000C", "aux"])])
            job(source, groups, destination) = Dict("source" => source, "groups" => groups, "destination" => destination)
            @test_throws SyncStopped apply!(h, p, sel; helper, jobs = 2,
                                            report = s -> s.step == "pulling extracted files" && throw(SyncStopped()))
            @test isfile(joinpath(stage, "test", relative(p, dsp_file))) && !ispath(to_local(p, dsp_file))
            result = apply!(h, p, sel; helper, jobs = 2)
            @test (result.extracted_files, result.extracted_groups) == (5, 9) && !isdir(joinpath(stage, "test"))
            h5open(to_local(p, dsp_file), "r") do out   # <detector>/<tier>
                @test collect(keys(out)) == ["B00000C", "aux"] && read(out["aux"]["jldsp"]["waveform"]) == collect(Int32, 1:300)
            end
            h5open(to_local(p, pks_file), "r") do out   # <tier>/<detector>
                @test collect(keys(out["jlpks"])) == ["B00000C", "aux"] && read_attribute(out["jlpks"], "origin") == "fixture"
            end
            @test result.not_in_run == [(relative(p, joinpath(pks, "r001")), "aux")]
            foreign = write_lh5(joinpath(mktempdir(), "foreign.lh5"), ["B00000C"]; tier = "jlpks", tier_first = true)
            before = read(foreign)
            @test_throws "is not a reduced file written by this tool" run_helper(h, helper, "extract",
                                                                                 Dict("job" => [job(pks_file, ["B00000C"], foreign)]))
            @test read(foreign) == before
            @test_throws "is the source" run_helper(h, helper, "extract", Dict("job" => [job(dsp_file, ["aux"], dsp_file)]))
            @test_throws "refusing to modify it" Sync.bootstrap_environment!(h,
                                                                             HelperConfig(; julia_project = dirname(Base.active_project())))
        end

        @testset "headless runs from a saved selection: a dry run and a transfer" begin
            local_root = mktempdir()
            sel = Selection("local", "test", REMOTE, local_root, nothing, [mandatory; relative(production(), evt)], String[], now())
            from = save_selection(joinpath(mktempdir(), "sel.yaml"), sel)
            function headless(options)
                path = tempname()
                code = open(io -> redirect_stdout(() -> main(options, h), io), path, "w")
                return code, read(path, String)
            end
            code, text = headless(Options("local", REMOTE, local_root, nothing, "test", from, from, true, false))
            @test code == 0 && occursin("copy (4 files)", text) && !isdir(joinpath(local_root, "test", "generated"))
            code, text = headless(Options("local", REMOTE, local_root, nothing, "test", from, from, false, true))
            @test code == 0 && occursin("transferred ", text) && isdir(joinpath(local_root, "test", "generated"))
        end

        @testset "a remote root of /, a path key through a symlink and an unreadable entry of setup/config" begin
            remote = make_remote()
            prod = joinpath(remote, "test")
            p = Production(h, relpath(prod, "/"), "/", mktempdir())
            @test relative(p, joinpath(prod, "config.json")) == joinpath(p.name, "config.json")
            @test Sync.preselect_production(remote * "0/test", [remote * "/"]) === nothing
            link = joinpath(mktempdir(), "link")
            symlink(remote, link)
            tier_key(tier) = write(joinpath(prod, "config.json"),
                                   """{"setups": {"l200": {"paths": {"metadata": "\$_/legend-metadata/", "tier": "$tier"}}}}""")
            tier_key("/nonexistent/tier")
            @test_throws "also with symlinks resolved" Production(h, "test", link, mktempdir())
            tier_key(joinpath(realpath(prod), "generated", "tier"))
            config = mkpath(joinpath(prod, "setup", "config"))
            write(joinpath(config, "processing.json"), "{}")
            hidden = joinpath(config, "startjlworkers[1].sh")    # the brackets check that the rsync exclude is escaped
            write(hidden, "")
            chmod(hidden, 0o000)
            p = Production(h, "test", link, mktempdir())
            @test Dict(p.roots)["tier"] == joinpath(link, "test", "generated", "tier")
            result = apply!(h, p, Selection(p, "local", production_tree(h, p)))
            @test result.unreadable == ["test/setup/config/startjlworkers[1].sh"] &&
                  isfile(joinpath(p.local_root, "test", "setup", "config", "processing.json"))
            @test occursin(joinpath(p.local_root, "test", "generated", "tier"), read(result.config, String))
        end

        include(joinpath(@__DIR__, "test_sync_screen.jl"))
    end
end

end # module
