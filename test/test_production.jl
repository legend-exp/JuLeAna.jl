# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
import TOML
using Test

# git settings for the local test repositories: an identity, and cloning submodules from
# local paths, which git refuses by default
const GIT_TEST_ENV = ("GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.org", "GIT_COMMITTER_NAME" => "Test",
                      "GIT_COMMITTER_EMAIL" => "test@example.org", "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "protocol.file.allow",
                      "GIT_CONFIG_VALUE_0" => "always")

git(dir, args...) = run(pipeline(`git -C $dir $args`; stdout = devnull, stderr = devnull))

# A git repository in `dir` with a commit of `file` on `main` and, for each of `branches`,
# a branch with one more file named after it.
function test_repo(dir, file; branches = String[])
    mkpath(dir)
    git(dir, "init", "-b", "main")
    write(joinpath(dir, file), file)
    git(dir, "add", ".")
    git(dir, "commit", "-m", "init")
    for branch in branches
        git(dir, "checkout", "-b", branch)
        write(joinpath(dir, "$branch.txt"), branch)
        git(dir, "add", ".")
        git(dir, "commit", "-m", branch)
        git(dir, "checkout", "main")
    end
    return dir
end

@testset "data productions" begin
    withenv(GIT_TEST_ENV...) do
        root = mktempdir()
        hardware = test_repo(joinpath(root, "hardware"), "hw.txt"; branches = ["dev"])
        jlconfig = test_repo(joinpath(root, "jlconfig"), "jl.txt"; branches = ["jl-dev"])
        simconfig = test_repo(joinpath(root, "simconfig"), "sim.txt"; branches = ["dev"])
        metadata = test_repo(joinpath(root, "metadata"), "README.md")
        for (path, url) in
            ("hardware" => hardware, joinpath("jldataprod", "config") => jlconfig, joinpath("simprod", "config") => simconfig)
            git(metadata, "submodule", "add", url, path)
        end
        git(metadata, "commit", "-m", "submodules")
        git(metadata, "checkout", "-b", "dev")
        write(joinpath(metadata, "dev.txt"), "dev")
        git(metadata, "add", ".")
        git(metadata, "commit", "-m", "dev")
        git(metadata, "checkout", "main")

        parent = mkpath(joinpath(root, "productions"))
        inside = mkpath(joinpath(parent, "rawdata"))
        outside = mkpath(joinpath(root, "elsewhere"))
        pars = mkpath(joinpath(root, "old", "generated", "jlpar", "rpars", "ecal", "p03"))
        write(joinpath(pars, "r000.json"), "{}")
        home = mkpath(joinpath(root, "home"))

        @testset "checks" begin
            spec(; kw...) = JuLeAna.ProductionSpec(; name = "prod", parent, metadata_url = metadata, copy_software = false, kw...)
            @test JuLeAna.check_production(spec()) == joinpath(parent, "prod")
            @test_throws "may contain only letters" JuLeAna.check_production(spec(name = "a b"))
            @test_throws "must be an absolute path" JuLeAna.check_production(spec(parent = "relative"))
            @test_throws "$inside exists" JuLeAna.check_production(spec(name = "rawdata"))
            @test_throws "the branch name \"x;y\"" JuLeAna.check_production(spec(dataprod_branch = "x;y"))
            @test_throws "the branch name \"-f\"" JuLeAna.check_production(spec(metadata_ref = "-f"))
            @test_throws "tier labels must be unique" JuLeAna.check_production(spec(tier_paths = ["raw" => inside, "raw" => outside]))
            @test_throws "the tier label \"r w\"" JuLeAna.check_production(spec(tier_paths = ["r w" => inside]))
            @test_throws "is not a folder" JuLeAna.check_production(spec(tier_paths = ["raw" => joinpath(root, "missing")]))
            @test_throws "has no /rpars or /ppars component" JuLeAna.check_production(spec(pars = [outside]))
            @test_throws "the parameter folder $(joinpath(root, "missing")) does not exist" JuLeAna.check_production(spec(pars = [joinpath(root,
                                                                                                                                           "missing")]))
            @test_throws "for the shell \"fish\"" JuLeAna.check_production(spec(; set_default = true, shell = "fish", home))
            # nothing was created
            @test readdir(parent) == ["rawdata"]
        end

        @testset "create" begin
            lines = String[]
            config = JuLeAna.create_production(JuLeAna.ProductionSpec(; name = "prod", parent, metadata_url = metadata,
                                                                      jldataprod_branch = "jl-dev", dataprod_branch = "dev",
                                                                      tier_paths = ["raw" => inside, "ext" => outside],
                                                                      pars = [joinpath(root, "old", "generated", "jlpar", "rpars", "ecal")],
                                                                      set_default = true, shell = "zsh", home, copy_software = false);
                                               log = line -> push!(lines, line))
            path = joinpath(parent, "prod")
            @test config == joinpath(path, "config.yaml")
            meta = joinpath(path, "legend-metadata")
            # the branches: dev in the metadata and the hardware, jl-dev in the jldataprod config,
            # the simprod config as cloned
            @test isfile(joinpath(meta, "dev.txt"))
            @test isfile(joinpath(meta, "hardware", "dev.txt"))
            @test isfile(joinpath(meta, "jldataprod", "config", "jl-dev.txt"))
            @test isfile(joinpath(meta, "simprod", "config", "sim.txt")) && !isfile(joinpath(meta, "simprod", "config", "dev.txt"))
            @test all(d -> isdir(joinpath(path, "generated", d)), ["tier", "jllog", "jlplt", "jlreport", "jlpar/rpars", "jlpar/ppars"])
            @test read(joinpath(path, "generated", "jlpar", "rpars", "ecal", "p03", "r000.json"), String) == "{}"
            # the data config is YAML with the extra tiers after `tier`
            text = read(config, String)
            @test occursin("      tier: '\$_/generated/tier/'\n      tier/raw: '\$_/../rawdata'\n      tier/ext: '$outside'\n", text)
            # quotes and colons in a path stay part of it
            odd = joinpath(root, "odd.yaml")
            write(odd, JuLeAna.data_config_text(["odd" => "/a/it's: #1"], parent))
            @test JuLeAna.readlprops(odd).setups.l200.paths[Symbol("tier/odd")] == "/a/it's: #1"
            paths = JuLeAna.readlprops(config).setups.l200.paths
            @test paths[Symbol("tier/jllog")] == joinpath(path, "generated", "jllog") * "/" && normpath(paths[Symbol("tier/raw")]) == inside
            @test read(joinpath(home, ".zshrc"), String) == "export LEGEND_DATA_CONFIG=$config\n"
            @test any(contains("Cloning $metadata"), lines) && any(contains("Wrote $config"), lines)

            # a second production replaces the line in the startup file and keeps the others
            write(joinpath(home, ".zshrc"), "alias x=y\nexport LEGEND_DATA_CONFIG=/old/config.json\n")
            second = JuLeAna.create_production(JuLeAna.ProductionSpec(; name = "second", parent, metadata_url = metadata,
                                                                      set_default = true, shell = "zsh", home, copy_software = false);
                                               log = _ -> nothing)
            @test read(joinpath(home, ".zshrc"), String) == "alias x=y\nexport LEGEND_DATA_CONFIG=$second\n"
            @test isfile(joinpath(parent, "second", "legend-metadata", "hardware", "hw.txt"))
            @test !isfile(joinpath(parent, "second", "legend-metadata", "dev.txt"))
            # a failing clone throws
            @test_throws "failed with exit code" JuLeAna.create_production(JuLeAna.ProductionSpec(; name = "third", parent,
                                                                                                  metadata_url = joinpath(root, "missing"),
                                                                                                  copy_software = false);
                                                                           log = _ -> nothing)
        end

        @testset "metadata ref" begin
            # `main` records the hardware at its first commit, `release` and the tag `v1` at its `dev` branch
            recorded = test_repo(joinpath(root, "recorded"), "README.md")
            git(recorded, "submodule", "add", hardware, "hardware")
            git(recorded, "submodule", "add", jlconfig, joinpath("jldataprod", "config"))
            git(recorded, "commit", "-m", "submodules")
            git(recorded, "checkout", "-b", "release")
            git(joinpath(recorded, "hardware"), "fetch", "origin")
            git(joinpath(recorded, "hardware"), "checkout", "dev")
            git(recorded, "commit", "-am", "release")
            git(recorded, "tag", "v1")
            git(recorded, "checkout", "main")
            metadata = recorded
            for ref in ("release", "v1")
                lines = String[]
                JuLeAna.create_production(JuLeAna.ProductionSpec(; name = "ref-$ref", parent, metadata_url = metadata, metadata_ref = ref,
                                                                 copy_software = false); log = line -> push!(lines, line))
                meta = joinpath(parent, "ref-$ref", "legend-metadata")
                # the submodules are at the commits the ref records
                @test isfile(joinpath(meta, "hardware", "dev.txt"))
                @test any(contains("Checking out $ref"), lines) && any(contains("Updating the submodules"), lines)
            end
            JuLeAna.create_production(JuLeAna.ProductionSpec(; name = "ref-main", parent, metadata_url = metadata, copy_software = false);
                                      log = _ -> nothing)
            @test !isfile(joinpath(parent, "ref-main", "legend-metadata", "hardware", "dev.txt"))
            # a branch is checked out as a branch, a tag is detached
            @test strip(read(`git -C $(joinpath(parent, "ref-release", "legend-metadata")) branch --show-current`, String)) == "release"
            @test isempty(strip(read(`git -C $(joinpath(parent, "ref-v1", "legend-metadata")) branch --show-current`, String)))
            # the branches apply on top of the ref
            JuLeAna.create_production(JuLeAna.ProductionSpec(; name = "ref-top", parent, metadata_url = metadata, metadata_ref = "v1",
                                                             jldataprod_branch = "jl-dev", copy_software = false); log = _ -> nothing)
            top = joinpath(parent, "ref-top", "legend-metadata")
            @test isfile(joinpath(top, "hardware", "dev.txt")) && isfile(joinpath(top, "jldataprod", "config", "jl-dev.txt"))
            @test_throws "failed with exit code" JuLeAna.create_production(JuLeAna.ProductionSpec(; name = "ref-bad", parent,
                                                                                                  metadata_url = metadata,
                                                                                                  metadata_ref = "nope",
                                                                                                  copy_software = false);
                                                                           log = _ -> nothing)
        end

        @testset "software snapshot" begin
            juleana = test_repo(joinpath(root, "pkgs", "JuLeAna.jl"), "Project.toml")
            mkpath(joinpath(juleana, "src"))
            write(joinpath(juleana, "src", "JuLeAna.jl"), "module JuLeAna end")
            write(joinpath(juleana, "Manifest.toml"), "not copied")
            write(joinpath(juleana, ".gitignore"), "Manifest.toml\n")
            foo = test_repo(joinpath(root, "pkgs", "Foo"), "Project.toml")
            env = mkpath(joinpath(root, "env"))
            manifest = joinpath(env, "Manifest.toml")
            write(manifest, """
                julia_version = "1.12.7"
                manifest_format = "2.0"

                [[deps.Bar]]
                git-tree-sha1 = "0123"
                uuid = "00000000-0000-0000-0000-000000000002"
                version = "1.0.0"

                [[deps.Foo]]
                path = "../pkgs/Foo"
                uuid = "00000000-0000-0000-0000-000000000003"
                version = "0.1.0"

                [[deps.JuLeAna]]
                deps = ["Bar", "Foo"]
                git-tree-sha1 = "4567"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.2.0"
                """)
            dest = joinpath(root, "software")
            @test JuLeAna.snapshot_software(dest; manifest, source = juleana, log = _ -> nothing) == dest
            @test isfile(joinpath(dest, "JuLeAna.jl", "src", "JuLeAna.jl")) && isfile(joinpath(dest, "Foo", "Project.toml"))
            copied = TOML.parsefile(joinpath(dest, "JuLeAna.jl", "Manifest.toml"))
            @test copied["deps"]["JuLeAna"][1]["path"] == "." && !haskey(copied["deps"]["JuLeAna"][1], "git-tree-sha1")
            @test copied["deps"]["Foo"][1]["path"] == "../Foo"
            @test copied["deps"]["Bar"][1]["git-tree-sha1"] == "0123" && copied["julia_version"] == "1.12.7"
            provenance = read(joinpath(dest, "PROVENANCE.md"), String)
            commit = strip(read(`git -C $juleana rev-parse HEAD`, String))
            # the Manifest.toml of the checkout is not tracked, so the checkout counts as modified
            @test occursin("| JuLeAna | $juleana | $commit | yes |", provenance)
            @test occursin("| Foo | $foo | $(strip(read(`git -C $foo rev-parse HEAD`, String))) | no |", provenance)
            @test occursin("Pkg.Apps.develop(path = \"<this folder>/JuLeAna.jl\")", provenance)
            @test_throws "$dest exists" JuLeAna.snapshot_software(dest; manifest, source = juleana)
            @test occursin("## Reproducing", provenance) && occursin("julia --project=. -m JuLeAna --no-tui", provenance)
            # every package copy is a git repository with one commit that includes the manifest
            for (name, folder) in ("JuLeAna" => "JuLeAna.jl", "Foo" => "Foo")
                repo = joinpath(dest, folder)
                @test readlines(`git -C $repo rev-list --count HEAD`) == ["1"]
                files = [relpath(joinpath(r, f), repo) for (r, _, fs) in walkdir(repo) if !occursin(".git", relpath(r, repo)) for f in fs]
                @test Set(readlines(`git -C $repo ls-files`)) == Set(files)
                @test isempty(readlines(`git -C $repo status --porcelain`))
            end
            @test "Manifest.toml" in readlines(`git -C $(joinpath(dest, "JuLeAna.jl")) ls-tree --name-only HEAD`)
            snapshot = TOML.parsefile(joinpath(dest, "SNAPSHOT.toml"))
            @test snapshot["julia"] == string(VERSION) && snapshot["host"] == gethostname() && occursin(r"^\d{4}-", snapshot["created"])
            @test snapshot["packages"]["JuLeAna"]["commit"] == commit &&
                  snapshot["packages"]["JuLeAna"]["modified"] === true &&
                  snapshot["packages"]["Foo"]["modified"] === false &&
                  snapshot["packages"]["Foo"]["source"] == foo
            for (name, folder) in ("JuLeAna" => "JuLeAna.jl", "Foo" => "Foo")
                @test snapshot["packages"][name]["tree"] ==
                      strip(read(`git -C $(joinpath(dest, folder)) rev-parse $("HEAD^{tree}")`, String))
            end
            @test length(snapshot["fingerprint"]) == 40

            @testset "record_software" begin
                production = mkpath(joinpath(root, "recorded"))
                # an old flat layout is ignored
                mkpath(joinpath(production, "setup", "software", "JuLeAna.jl"))
                first_name = JuLeAna.record_software(production; manifest, source = juleana, log = _ -> nothing)
                @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{6}Z-", first_name) && endswith(first_name, "-$(first(commit, 7))-modified")
                @test isfile(joinpath(production, "setup", "software", first_name, "SNAPSHOT.toml"))
                @test JuLeAna.record_software(production; manifest, source = juleana, log = _ -> nothing) == first_name
                @test sort(readdir(joinpath(production, "setup", "software"))) == sort(["JuLeAna.jl", first_name])
                write(joinpath(juleana, "src", "JuLeAna.jl"), "module JuLeAna x = 1 end")
                # snapshot names have a resolution of one second
                sleep(1.1)
                second_name = JuLeAna.record_software(production; manifest, source = juleana, log = _ -> nothing)
                @test second_name != first_name && endswith(second_name, "-modified")
                @test length(readdir(joinpath(production, "setup", "software"))) == 3
                @test_throws "none.toml\": No such file" JuLeAna.record_software(production; manifest = joinpath(root, "none.toml"),
                                                                                 source = juleana, log = _ -> nothing)
                @test !any(startswith(".new-"), readdir(joinpath(production, "setup", "software")))
            end
            # the environment of this process
            @test haskey(TOML.parsefile(JuLeAna.running_manifest())["deps"], "JuLeAna")
            @test startswith(JuLeAna.software_version(), "JuLeAna $(pkgversion(JuLeAna))") &&
                  endswith(JuLeAna.software_version(), "Julia $VERSION")
        end

        @testset "metadata record" begin
            overrides = test_repo(joinpath(root, "rec-overrides"), "pz.yaml")
            meta = test_repo(joinpath(root, "rec-metadata"), "README.md")
            git(meta, "submodule", "add", overrides, "jldataprod/overrides")
            git(meta, "commit", "-m", "overrides")
            commit = strip(read(`git -C $meta rev-parse HEAD`, String))
            # a config file named `name` with its name as content
            config_file(name) = (path = joinpath(root, name); write(path, name); path)
            configs = [config_file("config.json"), config_file("processing.yaml")]
            production = mkpath(joinpath(root, "rec-production"))
            records = joinpath(production, "setup", "metadata")
            quiet = _ -> nothing

            clean = JuLeAna.record_metadata(production, meta; configs, log = quiet)
            @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{6}Z-", clean) && endswith(clean, "-$(first(commit, 7))")
            toml = TOML.parsefile(joinpath(records, clean, "METADATA.toml"))
            @test sort(collect(keys(toml["repos"]))) == [".", "jldataprod/overrides"]
            @test toml["repos"]["."]["commit"] == commit && !toml["repos"]["."]["modified"] && toml["repos"]["."]["branch"] == "main"
            @test [c["file"] for c in toml["configs"]] == ["1-config.json", "2-processing.yaml"]
            @test read(joinpath(records, clean, "config", "2-processing.yaml"), String) == "processing.yaml"
            @test isfile(joinpath(records, clean, "PROVENANCE.md"))
            # the same metadata and configs reuse the record
            @test JuLeAna.record_metadata(production, meta; configs, log = quiet) == clean
            @test readdir(records) == [clean]

            # uncommitted changes in the submodule, a small and a large untracked file
            sub = joinpath(meta, "jldataprod", "overrides")
            write(joinpath(sub, "pz.yaml"), "pz.yaml changed")
            write(joinpath(meta, "notes.txt"), "notes")
            write(joinpath(meta, "large.bin"), zeros(UInt8, JuLeAna.METADATA_COPY_LIMIT + 1))
            status_before = read(`git --no-optional-locks -C $meta status --porcelain`, String)
            index_mtime = mtime(joinpath(meta, ".git", "index"))
            sleep(1.1)  # record names have a resolution of one second
            changed = JuLeAna.record_metadata(production, meta; configs, log = quiet)
            @test changed != clean && endswith(changed, "-$(first(commit, 7))-modified")
            # the metadata is only read
            @test read(`git --no-optional-locks -C $meta status --porcelain`, String) == status_before &&
                  mtime(joinpath(meta, ".git", "index")) == index_mtime
            toml = TOML.parsefile(joinpath(records, changed, "METADATA.toml"))
            repo, subrepo = toml["repos"]["."], toml["repos"]["jldataprod/overrides"]
            @test repo["modified"] &&
                  !haskey(repo, "patch") &&
                  subrepo["modified"] &&
                  subrepo["patch"] == "patches/jldataprod/overrides.patch"
            untracked = Dict(u["path"] => u for u in repo["untracked"])
            @test untracked["notes.txt"]["copied"] &&
                  !untracked["large.bin"]["copied"] &&
                  untracked["large.bin"]["size"] == JuLeAna.METADATA_COPY_LIMIT + 1
            @test !isfile(joinpath(records, changed, "untracked", "root", "large.bin"))
            @test occursin("`./large.bin`", read(joinpath(records, changed, "PROVENANCE.md"), String))

            # the restore steps of PROVENANCE.md give the same files
            restored = joinpath(root, "restored")
            git(root, "clone", "--recursive", meta, restored)
            git(restored, "checkout", toml["repos"]["."]["commit"])
            git(joinpath(restored, "jldataprod", "overrides"), "apply", joinpath(records, changed, subrepo["patch"]))
            cp(joinpath(records, changed, "untracked", "root", "notes.txt"), joinpath(restored, "notes.txt"))
            @test read(joinpath(restored, "jldataprod", "overrides", "pz.yaml"), String) == "pz.yaml changed"
            @test read(joinpath(restored, "notes.txt"), String) == "notes"

            # a changed config file gives a new record
            write(configs[2], "processing.yaml changed")
            sleep(1.1)
            @test JuLeAna.record_metadata(production, meta; configs, log = quiet) ∉ (clean, changed)
            @test !any(startswith(".new-"), readdir(records))
            @test_throws "is not a git checkout" JuLeAna.record_metadata(production, joinpath(root, "rec-production"); log = quiet)
        end
    end
end
