# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

@testset "settings.jl" begin
    # test_sync.jl sets XDG_CONFIG_HOME to a temporary directory for the whole module, so no test sees a user configuration.
    @testset "the configuration directory" begin
        mktempdir() do xdg
            withenv("XDG_CONFIG_HOME" => xdg) do
                @test config_dir() == joinpath(xdg, "juleana", "sync")
                @test default_selection_dir() == config_dir()
                @test default_hosts_file() == Sync.PACKAGED_HOSTS_FILE && isfile(default_hosts_file())
                @test default_local_root() == ""
                @test default_selection_path("a/b") == joinpath(config_dir(), "a-b.yaml")
                @test field_error(SyncSettings(), :local_root) == "Local root must be set"
                @test_throws "--local-root must be set" parse_options(String[])
                mkpath(config_dir())
                write(joinpath(config_dir(), "hosts.yaml"), "alpha:\n  remote_root: /srv/x\n")
                write(joinpath(config_dir(), "settings.yaml"), "local_root: /srv/mirror\n")
                @test default_hosts_file() == joinpath(config_dir(), "hosts.yaml")
                @test default_local_root() == "/srv/mirror"
                @test SyncSettings().local_root == "" && SyncSettings().hosts_file == Sync.PACKAGED_HOSTS_FILE
                @test user_settings().local_root == "/srv/mirror" && user_settings().hosts_file == joinpath(config_dir(), "hosts.yaml")
                @test parse_options(["--host", "alpha"]).local_root == "/srv/mirror"
                @test parse_options(["--host", "alpha", "--local-root", "/tmp"]).local_root == "/tmp"
            end
        end
    end

    @testset "broken configuration files name the file" begin
        mktempdir() do xdg
            withenv("XDG_CONFIG_HOME" => xdg) do
                mkpath(config_dir())
                settings = joinpath(config_dir(), "settings.yaml")
                hostsfile = joinpath(config_dir(), "hosts.yaml")
                write(settings, "local_root: [unclosed\n")
                @test_throws "settings.yaml" default_local_root()
                write(settings, "local_root:\n  - a\n")
                @test_throws "local_root in $settings must be a path" default_local_root()
                write(hostsfile, "alpha: [unclosed\n")
                @test_throws "hosts.yaml" host_remote_root(hostsfile, "alpha")
                @test_throws "hosts.yaml" host_helper_config(hostsfile, "alpha")
                @test_throws "hosts.yaml" hosts_choices(hostsfile)
                write(hostsfile, "alpha:\n  staging: /s\n")
                @test_throws "host alpha in $hostsfile needs a remote_root" host_remote_root(hostsfile, "alpha")
            end
        end
    end

    @testset "saving to the default path creates the configuration directory" begin
        mktempdir() do xdg
            withenv("XDG_CONFIG_HOME" => xdg) do
                @test !isdir(config_dir())
                sel = Selection("cslg4", "a/b", "/r", "/l", nothing, String[], String[], DateTime(2025, 1, 1))
                path = save_selection(default_selection_path("a/b"), sel)
                @test path == joinpath(config_dir(), "a-b.yaml") && isfile(path)
            end
        end
    end

    hosts = joinpath(mktempdir(), "hosts.yaml")
    write(hosts, "alpha:\n  remote_root: /data/a\nbeta:\n  remote_root: /data/b\n  staging: /scratch/b\n")

    @testset "defaults and the fields in panel order" begin
        s = SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "alpha")
        @test SETTINGS_FIELDS == (:host, :remote_root, :production, :local_root, :mount_root, :staging, :jobs, :selection)
        @test (s.remote_root, s.production, s.mount_root, s.staging, s.jobs, s.selection) == ("", "", "", "", "0", "")
        @test s.local_root == "/tmp"
        @test isempty(settings_errors(s))
        @test hosts_choices(hosts) == ["alpha", "beta"]
        @test hosts_choices(joinpath(mktempdir(), "none.yaml")) == String[]
    end

    @testset "each field reports its own reason" begin
        s = SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "alpha")
        @test field_error(SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "a b"), :host) ==
              "Host must be an ssh alias without whitespace, got \"a b\""
        @test field_error(SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "gamma"), :remote_root) ==
              "Remote root: host gamma is not listed in $hosts; add it there or set Remote root"
        @test field_error(SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "gamma"), :remote_root; cli = true) ==
              "host gamma is not listed in $hosts; add it there or pass --remote-root"
        @test field_error(SyncSettings(; local_root = "/tmp", hosts_file = hosts, host = "gamma", remote_root = "/x"), :remote_root) ===
              nothing
        s.production = "../x"
        @test field_error(s, :production) == "Production must be a relative path below the remote root, got \"../x\""
        s.jobs = "x"
        @test field_error(s, :jobs) == "Jobs must be an integer >= 0, got x"
        @test field_error(s, :jobs; cli = true) == "--jobs must be an integer, got x"
        s.jobs = "-1"
        @test field_error(s, :jobs) == "Jobs must be an integer >= 0, got -1"
        @test field_error(s, :jobs; cli = true) == "--jobs must not be negative, got -1"
        s.staging = "rel/dir"
        @test field_error(s, :staging) == "Staging must be an absolute path or start with ~, got rel/dir"
        @test field_error(s, :staging; cli = true) == "--staging must be an absolute path or start with ~, got rel/dir"
        s.selection = "/tmp/x.json"
        @test field_error(s, :selection) == "Selection must end in .yaml, got /tmp/x.json"
        @test field_error(s, :selection; cli = true) == "--out must end in .yaml, got /tmp/x.json"
        @test Set(first.(settings_errors(s))) == Set([:production, :jobs, :staging, :selection])
        @test_throws "Production must be a relative path" Options(s)
        # the first invalid field in panel order
        @test_throws "production name must be a relative path" Options(s; cli = true)
    end

    @testset "paths are checked only when asked" begin
        s = SyncSettings(; hosts_file = hosts, host = "alpha", local_root = joinpath(tempdir(), "no-such-dir-sync"),
                         mount_root = "/no/mount")
        @test isempty(settings_errors(s))
        @test field_error(s, :local_root; check_paths = true) == "Local root $(s.local_root) is not an existing directory"
        @test field_error(s, :mount_root; check_paths = true) == "Mount root /no/mount is not an existing directory"
        s.local_root = mktempdir()
        s.mount_root = ""
        @test isempty(settings_errors(s; check_paths = true))
    end

    @testset "Options(settings) agrees with parse_options" begin
        args = ["--host", "beta", "--production", "p/q", "--jobs", "3", "--local-root", "/tmp"]
        r = parse_settings(args; hosts_file = hosts)
        @test r.settings.host == "beta" && r.settings.jobs == "3" && r.settings.production == "p/q" && r.from === nothing
        o = Options(r.settings; r.from, r.dry_run, r.yes)
        p = parse_options(args; hosts_file = hosts)
        @test all(f -> getfield(o, f) == getfield(p, f), fieldnames(Options))
        @test (o.remote_root, o.jobs, o.helper.staging, o.out) ==
              ("/data/b", 3, "/scratch/b", joinpath(default_selection_dir(), "p-q.yaml"))
        @test selection_path(r.settings) == o.out
        t = SyncSettings(o; hosts_file = hosts)
        @test all(f -> getfield(Options(t), f) == getfield(o, f), fieldnames(Options))
        @test t.selection == ""     # the default path is not stored as an explicit one
        @test_throws "only mean something together with --from" parse_settings(["--dry-run"]; hosts_file = hosts)
    end
end
