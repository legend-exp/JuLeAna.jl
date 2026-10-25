# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Test
using Logging
using LegendDataManagement: DataPeriod, DataRun, readlprops

const CONFIG_DIR = joinpath(dirname(@__DIR__), "config")

# Nested `Dict{String,Any}`, as produced by a plain JSON parser.
stringdict(x) = x
stringdict(d::AbstractDict) = Dict{String,Any}(string(k) => stringdict(v) for (k, v) in d)

process_a(cfg, l200, period, run; reprocess::Bool = false, timeout::Int = 0) = nothing
# A callable struct stands in for a processor, as a test double might.
struct PartitionStub end
(::PartitionStub)(cfg, l200, period; kwargs...) = true
const STUB_PROCESSORS = Dict{Symbol,Any}(:process_a => process_a, :p_process_b => PartitionStub())

@testset "processing config" begin
    shipped = ProcessingConfig(joinpath(CONFIG_DIR, "processing_config.yaml"))
    base = stringdict(readlprops(joinpath(CONFIG_DIR, "processing_config.yaml")))

    @testset "repository configs" begin
        @test shipped.runmode === :slurm
        @test !shipped.submit_jobs
        @test shipped.local_n == 64
        @test shipped.local_julia_settings == String[]
        @test "--nodes=1" in shipped.slurm_flags && "--time=01:00:00" in shipped.slurm_flags
        @test shipped.env_variables["JULIA_WORKER_TIMEOUT"] == "240"
        @test shipped.log_level == JuLeAna.parse_log_level("info")
        @test shipped.periods == DataPeriod.([16, 18, 19, 20, 21, 22])
        @test isnothing(shipped.runs)
        @test !shipped.analysis_runs_only && !shipped.only_partitions && !shipped.only_runs
        @test shipped.log_path == ""
        spec = shipped.processors[:process_dsp_cal]
        @test spec.level === :run && spec.category === :cal && spec.rank == 6 && !spec.enabled
        @test spec.dependencies == [:p_process_aoe_optimization_cal, :process_aoe_optimization_cal]
        @test spec.kwargs ==
              Dict{Symbol,Any}(:reprocess => false, :max_wvfs => 1000, :timeout => 0, :use_partition_pars => true, :use_cache => true)
        @test shipped.p_processors[:p_process_energy_cal].level === :partition
        @test shipped.p_processors[:p_process_energy_cal].category === :cal
        @test shipped.p_processors[:p_process_skm_phy].category === :phy

        from_strings = ProcessingConfig(base)
        @test run_steps(from_strings; enabled_only = false) == run_steps(shipped; enabled_only = false)
        @test from_strings.processors[:process_dsp_cal].kwargs == spec.kwargs
        @test sprint(show, shipped) == "ProcessingConfig(runmode=:slurm, 0/20 run and 0/12 partition processors enabled)"
        @test occursin("rank=6", sprint(show, spec))
    end

    @testset "steps" begin
        # the shipped config enables no processor; the steps are chosen in the interface
        @test isempty(run_steps(shipped)) && isempty(partition_steps(shipped))
        d = deepcopy(base)
        foreach(((section, name),) -> d[section][name]["enabled"] = true,
                [("processors", "process_evt_phy"), ("processors", "process_psd_efficiencies_cal"), ("p_processors", "p_process_skm_phy")])
        some = ProcessingConfig(d)
        @test run_steps(some) == [:process_psd_efficiencies_cal, :process_evt_phy]
        @test partition_steps(some) == [:p_process_skm_phy]
        all_steps = run_steps(shipped; enabled_only = false)
        @test length(all_steps) == 20 && first(all_steps) === :process_daq_energy_calibration_cal
        @test issorted(all_steps; by = s -> shipped.processors[s].rank)
        @test length(partition_steps(shipped; enabled_only = false)) == 12
    end

    @testset "overrides" begin
        # a config with analysis_runs_only = true and only_runs = false
        analysis = deepcopy(base)
        analysis["processing"]["analysis_runs_only"] = true
        @test ProcessingConfig(analysis; analysis_runs_only = false).analysis_runs_only
        @test !ProcessingConfig(analysis; analysis_runs_only = false, ignore_config = true).analysis_runs_only
        @test !ProcessingConfig(base; ignore_config = true).analysis_runs_only
        @test ProcessingConfig(base; only_runs = true).only_runs
        @test !ProcessingConfig(base; only_runs = nothing).only_runs
        @test ProcessingConfig(base; submit_jobs = true, ignore_config = true).submit_jobs
        @test ProcessingConfig(base; runmode = "slurm").runmode === :slurm
        cfg = ProcessingConfig(base; periods = [5], runs = [1, 2], log_path = "logs")
        @test cfg.periods == [DataPeriod(5)] && cfg.runs == DataRun.([1, 2]) && cfg.log_path == "logs"
        @test isnothing(ProcessingConfig(base; periods = [5]).runs)

        @test !shipped.processors[:process_dsp_cal].kwargs[:reprocess]
        reprocessed = ProcessingConfig(base; reprocess = true)
        @test all(s -> s.kwargs[:reprocess], values(reprocessed.processors))
        @test all(s -> s.kwargs[:reprocess], values(reprocessed.p_processors))
    end

    @testset "kwargs conversion" begin
        d = deepcopy(base)
        d["processors"]["process_evt_phy"]["kwargs"]["subsystems"] = Any["geds", "spms"]
        d["processors"]["process_evt_phy"]["kwargs"]["empty"] = Any[]
        kwargs = ProcessingConfig(d).processors[:process_evt_phy].kwargs
        @test kwargs[:subsystems] == [:geds, :spms] && kwargs[:subsystems] isa Vector{Symbol}
        @test kwargs[:empty] isa Vector{Symbol} && isempty(kwargs[:empty])
    end

    @testset "validation" begin
        edited(f) = (d = deepcopy(base); f(d); d)

        @test_throws "missing key `processors.process_dsp_cal.rank`" ProcessingConfig(edited(d -> delete!(d["processors"]["process_dsp_cal"],
                                                                                                          "rank")))
        @test_throws "missing key `config.runmode_settings.local.n`" ProcessingConfig(edited(d -> delete!(d["config"]["runmode_settings"]["local"],
                                                                                                          "n")))
        @test_throws "missing key `config.log_level`" ProcessingConfig(edited(d -> delete!(d["config"], "log_level")))
        @test_throws "`config.log_level` must be one of" ProcessingConfig(edited(d -> d["config"]["log_level"] = "verbose"))
        @test_throws "missing key `processing.only_runs`" ProcessingConfig(edited(d -> delete!(d["processing"], "only_runs")))
        @test_throws "unknown key `processors.process_dsp_cal.n_workers`" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["n_workers"] = "all"))
        @test !shipped.processors[:process_dsp_cal].error_plots
        @test ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["error_plots"] = true)).processors[:process_dsp_cal].error_plots
        @test_throws "`processors.process_dsp_cal.error_plots` must be a Bool" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["error_plots"] = "yes"))
        @test shipped.processors[:process_dsp_cal].log_level == Logging.Info
        @test ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["log_level"] = "debug")).processors[:process_dsp_cal].log_level ==
              Logging.Debug
        @test_throws "missing key `processors.process_dsp_cal.log_level`" ProcessingConfig(edited(d -> delete!(d["processors"]["process_dsp_cal"],
                                                                                                               "log_level")))
        @test_throws "missing key `p_processors.p_process_energy_cal.log_level`" ProcessingConfig(edited(d -> delete!(d["p_processors"]["p_process_energy_cal"],
                                                                                                                      "log_level")))
        @test_throws "`processors.process_dsp_cal.log_level` must be one of \"debug\", \"info\", \"warn\" or \"error\", got \"verbose\"" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["log_level"] = "verbose"))
        @test ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1).log_level == Logging.Info
        @test isnothing(shipped.processor_log_level)
        @test ProcessingConfig(edited(d -> d["config"]["processor_log_level"] = "debug")).processor_log_level == Logging.Debug
        @test_throws "`config.processor_log_level` must be one of" ProcessingConfig(edited(d -> d["config"]["processor_log_level"] = "verbose"))
        @test isnothing(ProcessingConfig(; processors = Dict{Symbol,ProcessorSpec}(), p_processors = Dict{Symbol,ProcessorSpec}()).processor_log_level)
        @test shipped.processors[:process_dsp_cal].plot_level === :info
        @test ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["plot_level"] = "debug")).processors[:process_dsp_cal].plot_level ===
              :debug
        @test_throws "missing key `processors.process_dsp_cal.plot_level`" ProcessingConfig(edited(d -> delete!(d["processors"]["process_dsp_cal"],
                                                                                                                "plot_level")))
        @test_throws "missing key `p_processors.p_process_energy_cal.plot_level`" ProcessingConfig(edited(d -> delete!(d["p_processors"]["p_process_energy_cal"],
                                                                                                                       "plot_level")))
        @test_throws "`processors.process_dsp_cal.plot_level` must be one of \"info\" or \"debug\", got \"verbose\"" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["plot_level"] = "verbose"))
        @test ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1).plot_level === :info
        @test isnothing(shipped.processor_plot_level)
        @test ProcessingConfig(edited(d -> d["config"]["processor_plot_level"] = "debug")).processor_plot_level === :debug
        @test_throws "`config.processor_plot_level` must be one of \"info\" or \"debug\"" ProcessingConfig(edited(d -> d["config"]["processor_plot_level"] = "verbose"))
        @test isnothing(ProcessingConfig(; processors = Dict{Symbol,ProcessorSpec}(), p_processors = Dict{Symbol,ProcessorSpec}()).processor_plot_level)
        @test shipped.plot_formats == [:png]
        @test ProcessingConfig(edited(d -> d["config"]["plot_formats"] = ["png", "jls"])).plot_formats == [:png, :jls]
        @test ProcessingConfig(edited(d -> d["config"]["plot_formats"] = ["jls"])).plot_formats == [:jls]
        @test_throws "`config.plot_formats` must list only \"png\" or \"jls\", got [\"gif\"]" ProcessingConfig(edited(d -> d["config"]["plot_formats"] = ["gif"]))
        @test_throws "`config.plot_formats` must list at least one of" ProcessingConfig(edited(d -> d["config"]["plot_formats"] = String[]))
        @test_throws "`config.plot_formats` lists a format twice" ProcessingConfig(edited(d -> d["config"]["plot_formats"] = ["png", "png"]))
        @test_throws "`config.plot_formats` must be a list of strings" ProcessingConfig(edited(d -> d["config"]["plot_formats"] = [1]))
        @test ProcessingConfig(; processors = Dict{Symbol,ProcessorSpec}(), p_processors = Dict{Symbol,ProcessorSpec}()).plot_formats ==
              [:png]
        @test_throws "unknown key `config.remote_workers`" ProcessingConfig(edited(d -> d["config"]["remote_workers"] = []))
        @test_throws "unknown key `extra`" ProcessingConfig(edited(d -> d["extra"] = 1))
        # the idle timeout is optional
        @test shipped.idle_timeout_minutes == 20
        @test ProcessingConfig(edited(d -> delete!(d["config"], "idle_timeout_minutes"))).idle_timeout_minutes == 20
        @test ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = 0)).idle_timeout_minutes == 0
        @test ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = 2.5)).idle_timeout_minutes == 2.5
        @test_throws "`config.idle_timeout_minutes` must be zero or positive, got -1.0" ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = -1))
        @test_throws "`config.idle_timeout_minutes` must be a Real" ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = "20"))
        @test_throws "`p_processors.p_process_energy_cal.category` must be \"cal\" or \"phy\"" ProcessingConfig(edited(d -> d["p_processors"]["p_process_energy_cal"]["category"] = "physics"))
        @test_throws "`processors.process_dsp_cal.enabled` must be a Bool" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["enabled"] = "yes"))
        @test_throws "`processors.process_dsp_cal.rank` must be a $Int" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["rank"] = 5.5))
        @test_throws "`config.runmode_settings.local.n` must be positive" ProcessingConfig(edited(d -> d["config"]["runmode_settings"]["local"]["n"] = 0))
        @test_throws "names unknown processor `p_process_missing`" ProcessingConfig(edited(d -> push!(d["processors"]["process_dsp_cal"]["dependencies"],
                                                                                                      "p_process_missing")))
        @test_throws "in both `processors` and `p_processors`: process_dsp_cal" ProcessingConfig(edited(d -> d["p_processors"]["process_dsp_cal"] = deepcopy(d["processors"]["process_dsp_cal"])))
        @test_throws "only one of `only_partitions` or `only_runs`" ProcessingConfig(base; only_runs = true, only_partitions = true)
        @test_throws "only one of `only_partitions` or `only_runs`" ProcessingConfig(edited(d -> (d["processing"]["only_runs"] = true;
                                                                                                  d["processing"]["only_partitions"] = true)))
        @test_throws "runmode must be \"local\" or \"slurm\"" ProcessingConfig(base; runmode = "cluster")
        @test_throws "runmode must be \"local\" or \"slurm\"" ProcessingConfig(edited(d -> d["config"]["runmode"] = "cluster"))
        @test_throws "runs without periods" ProcessingConfig(base; runs = [1])
        # a config may enable no processor; the steps are then selected in the interface
        none = ProcessingConfig(edited(d -> foreach(p -> p["enabled"] = false, (values(d["processors"])..., values(d["p_processors"])...))))
        @test isempty(run_steps(none)) && isempty(partition_steps(none))
    end

    @testset "order of the processors" begin
        edited(f) = (d = deepcopy(base); f(d); d)
        # the shipped config without `processing.order` and without dependencies
        plain = edited() do d
            delete!(d["processing"], "order")
            foreach(s -> s["dependencies"] = String[], vcat(collect(values(d["processors"])), collect(values(d["p_processors"]))))
        end
        # without `processing.order`, each processor also depends on the one before it in rank order
        ranked = @test_logs (:warn, r"run in rank order") match_mode = :any ProcessingConfig(plain)
        @test ranked.processors[:process_decay_time_cal].dependencies == [:process_peak_split_cal]
        @test ranked.p_processors[:p_process_filter_optimization_cal].dependencies == [:p_process_decay_time_cal]
        @test ranked.processors[:process_peak_split_cal].dependencies == [:process_daq_energy_calibration_cal]
        @test isempty(ranked.processors[:process_daq_energy_calibration_cal].dependencies)
        # with `order: dependencies` only the listed dependencies count
        plain["processing"]["order"] = "dependencies"
        declared = ProcessingConfig(plain)
        @test isempty(declared.processors[:process_decay_time_cal].dependencies)
        plain["processing"]["order"] = "rank"
        deps(cfg) = Dict(n => s.dependencies for (n, s) in merge(cfg.processors, cfg.p_processors))
        @test deps(ProcessingConfig(plain)) == deps(ranked)
        @test_throws "`processing.order` must be \"rank\" or \"dependencies\", got \"name\"" ProcessingConfig(edited(d -> d["processing"]["order"] = "name"))

        # equal ranks are ordered by name; a dependency on the predecessor is not repeated
        spec(name, rank, deps = Symbol[]) = ProcessorSpec(; name, level = :run, category = :cal, rank, dependencies = deps)
        chained = JuLeAna.rank_order_dependencies(Dict(:b => spec(:b, 1), :a => spec(:a, 1), :c => spec(:c, 2, [:b])))
        @test [chained[n].dependencies for n in (:a, :b, :c)] == [Symbol[], [:a], [:b]]

        @test declared.max_parallel_steps == 0
        @test ProcessingConfig(edited(d -> d["processing"]["max_parallel_steps"] = 4)).max_parallel_steps == 4
        @test_throws "`processing.max_parallel_steps` must be a $Int" ProcessingConfig(edited(d -> d["processing"]["max_parallel_steps"] = "4"))
    end

    @testset "constructors" begin
        samefields(a, b) = all(f -> getfield(a, f) == getfield(b, f), fieldnames(typeof(a)))

        spec = shipped.processors[:process_dsp_cal]
        spec_fields = NamedTuple{fieldnames(ProcessorSpec)}(getfield.(Ref(spec), fieldnames(ProcessorSpec)))
        @test samefields(ProcessorSpec(spec_fields...), spec)
        @test samefields(ProcessorSpec(; spec_fields...), spec)
        minimal = ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1)
        @test minimal.enabled && isempty(minimal.dependencies) && isempty(minimal.kwargs)
        @test_throws "processor `x` has level :other" ProcessorSpec(; name = :x, level = :other, category = :cal, rank = 1)
        @test_throws "key `p_processors.x.category` must be \"cal\" or \"phy\"" ProcessorSpec(; name = :x, level = :partition,
                                                                                              category = :physics, rank = 1)
        @test_throws "key `processors.x.dependencies` names the processor itself" ProcessorSpec(; name = :x, level = :run, category = :cal,
                                                                                                rank = 1, dependencies = [:x])

        fields = NamedTuple{fieldnames(ProcessingConfig)}(getfield.(Ref(shipped), fieldnames(ProcessingConfig)))
        @test samefields(ProcessingConfig(fields...), shipped)
        @test samefields(ProcessingConfig(; fields...), shipped)
        positional(; kw...) = ProcessingConfig(values(merge(fields, kw))...)
        @test_throws "runmode must be \"local\" or \"slurm\", got :cluster" positional(runmode = :cluster)
        @test_throws "`config.runmode_settings.local.n` must be positive" positional(local_n = 0)
        @test_throws "only one of `only_partitions` or `only_runs`" positional(only_runs = true, only_partitions = true)
        @test_throws "`config.processor_plot_level` must be \"info\" or \"debug\"" positional(processor_plot_level = :verbose)
        @test_throws "`config.plot_formats` must list only" positional(plot_formats = [:gif])
        @test_throws "`config.plot_formats` must list at least one of" positional(plot_formats = Symbol[])
        @test_throws "`config.plot_formats` lists a format twice" positional(plot_formats = [:png, :png])
        @test_throws "`processors` entry `renamed` holds the spec of `process_dsp_cal`" positional(processors = Dict(:renamed => spec))
        @test_throws "`p_processors.process_dsp_cal` has level :run" positional(p_processors = Dict(:process_dsp_cal => spec))
        partition_twin = ProcessorSpec(; name = :process_dsp_cal, level = :partition, category = :cal, rank = 1)
        @test_throws "in both `processors` and `p_processors`: process_dsp_cal" positional(p_processors = merge(shipped.p_processors,
                                                                                                                Dict(:process_dsp_cal =>
                                                                                                                         partition_twin)))
        orphan = ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1, dependencies = [:missing])
        @test_throws "key `processors.x.dependencies` names unknown processor `missing`" ProcessingConfig(; processors = Dict(:x => orphan),
                                                                                                          p_processors = Dict{Symbol,
                                                                                                                              ProcessorSpec}())
        first_run = ProcessorSpec(; name = :a, level = :run, category = :cal, rank = 1)
        second_run = ProcessorSpec(; name = :b, level = :run, category = :cal, rank = 2, dependencies = [:a])
        # dependencies may name processors of the same level
        @test ProcessingConfig(; processors = Dict(:a => first_run, :b => second_run), p_processors = Dict{Symbol,ProcessorSpec}()).processors[:b].dependencies ==
              [:a]
        @test_throws "`processing.max_parallel_steps` must be zero or positive" positional(max_parallel_steps = -1)
        idle = ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1, enabled = false)
        @test isempty(run_steps(ProcessingConfig(; processors = Dict(:x => idle), p_processors = Dict{Symbol,ProcessorSpec}())))

        # A run selection over all periods is valid; runs are matched within each period.
        @test isnothing(positional(periods = nothing, runs = DataRun.([1, 2])).periods)
    end

    @testset "check_processor_kwargs" begin
        processor(entries...) = Dict{String,Any}("enabled" => true, "category" => "cal", "rank" => 1, "dependencies" => Any[],
                                                 "log_level" => "info", "plot_level" => "info", "kwargs" => Dict{String,Any}(entries...))
        d = deepcopy(base)
        d["processors"] = Dict{String,Any}("process_a" => processor("reprocess" => true, "timeout" => 1))
        d["p_processors"] = Dict{String,Any}("p_process_b" => processor("anything" => 1))
        @test isnothing(check_processor_kwargs(ProcessingConfig(d); processors = STUB_PROCESSORS))

        d["processors"]["process_a"]["kwargs"]["only_pulser"] = true
        @test_throws "`process_a` does not accept keyword(s) only_pulser" check_processor_kwargs(ProcessingConfig(d);
                                                                                                 processors = STUB_PROCESSORS)
        d["processors"]["process_missing"] = processor()
        @test_throws "`process_missing` is not a registered processor" check_processor_kwargs(ProcessingConfig(d);
                                                                                              processors = STUB_PROCESSORS)
        d["processors"]["process_missing"]["enabled"] = false
        d["processors"]["process_a"]["kwargs"] = Dict{String,Any}()
        @test isnothing(check_processor_kwargs(ProcessingConfig(d); processors = STUB_PROCESSORS))

        # `run_processing` passes `only_first_period` to partition processors and may pass `reprocess`.
        p_process_c(cfg, l200, period; reprocess::Bool = false) = true
        d["p_processors"]["p_process_c"] = processor()
        @test_throws "`p_process_c` does not accept keyword(s) only_first_period" check_processor_kwargs(ProcessingConfig(d);
                                                                                                         processors = merge(STUB_PROCESSORS,
                                                                                                                            Dict(:p_process_c =>
                                                                                                                                     p_process_c)))
        process_d(cfg, l200, period, run) = nothing
        d["p_processors"]["p_process_c"]["enabled"] = false
        d["processors"]["process_d"] = processor()
        @test_throws "`process_d` does not accept keyword(s) reprocess" check_processor_kwargs(ProcessingConfig(d);
                                                                                               processors = merge(STUB_PROCESSORS,
                                                                                                                  Dict(:process_d =>
                                                                                                                           process_d)))
    end

    @testset "registered processors" begin
        @test isnothing(check_processor_kwargs(shipped))
        processors = run_steps(shipped; enabled_only = false) ∪ partition_steps(shipped; enabled_only = false)
        @test isempty(setdiff(processors, keys(JuLeAna.PROCESSORS)))

        # Every processor entry in the shipped config, enabled or not, should match its function's keywords.
        all_enabled = deepcopy(base)
        for (name, entry) in (all_enabled["processors"]..., all_enabled["p_processors"]...)
            entry["enabled"] = haskey(JuLeAna.PROCESSORS, Symbol(name))
        end
        @test isnothing(check_processor_kwargs(ProcessingConfig(all_enabled)))
        dsp = deepcopy(base)
        dsp["processors"]["process_dsp_cal"]["enabled"] = true
        @test isnothing(check_processor_kwargs(ProcessingConfig(dsp)))
        dsp["processors"]["process_dsp_cal"]["kwargs"]["use_partition_filter"] = true
        @test_throws "`process_dsp_cal` does not accept keyword(s) use_partition_filter" check_processor_kwargs(ProcessingConfig(dsp))
    end

    @testset "display_name" begin
        @test JuLeAna.display_name(:process_decay_time_cal) == "decay_time"
        @test JuLeAna.display_name(:p_process_sipm_calibration_phy) == "sipm_calibration"
        @test JuLeAna.display_name(:process_dsp_aux_phy) == "dsp_aux"
        @test JuLeAna.display_name(:dsp_cal) == "dsp"
        for name in keys(JuLeAna.PROCESSORS)
            display = JuLeAna.display_name(name)
            @test !startswith(display, "process_") && !startswith(display, "p_process_")
            @test !endswith(display, "_cal") && !endswith(display, "_phy")
            @test occursin(display, string(name))
        end
        # a display name is unique among the processors of one level and category
        for level in (:run, :partition), category in (:cal, :phy)

            specs = [s
                     for s in vcat(collect(values(shipped.processors)), collect(values(shipped.p_processors)))
                     if s.level === level && s.category === category]
            names = JuLeAna.display_name.(getfield.(specs, :name))
            @test allunique(names)
        end
    end

    @testset "former processor names" begin
        d = deepcopy(base)
        d["processors"]["process_decay_time"] = pop!(d["processors"], "process_decay_time_cal")
        d["p_processors"]["p_process_energy"] = pop!(d["p_processors"], "p_process_energy_cal")
        d["processors"]["process_dsp_cal"]["dependencies"] = ["p_process_aoe_optimization_cal", "p_process_filter_optimization",
                                                              "p_process_decay_time"]
        cfg = @test_logs (:warn, r"`p_process_decay_time` is now named `p_process_decay_time_cal`") (:warn,
                                                                                                     r"`p_process_energy` is now named `p_process_energy_cal`") (:warn,
                                                                                                                                                                 r"`p_process_filter_optimization` is now named `p_process_filter_optimization_cal`") (:warn,
                                                                                                                                                                                                                                                       r"`process_decay_time` is now named `process_decay_time_cal`") ProcessingConfig(d)
        @test haskey(cfg.processors, :process_decay_time_cal) && !haskey(cfg.processors, :process_decay_time)
        @test haskey(cfg.p_processors, :p_process_energy_cal)
        @test cfg.processors[:process_dsp_cal].dependencies ==
              [:p_process_aoe_optimization_cal, :p_process_filter_optimization_cal, :p_process_decay_time_cal]
        @test cfg.processors[:process_decay_time_cal].name === :process_decay_time_cal

        both = deepcopy(base)
        both["processors"]["process_decay_time"] = deepcopy(both["processors"]["process_decay_time_cal"])
        @test_throws "has both `process_decay_time` and `process_decay_time_cal`" ProcessingConfig(both)

        @test_logs ProcessingConfig(base)
        @test all(((old, new),) -> haskey(JuLeAna.PROCESSORS, new) && !haskey(JuLeAna.PROCESSORS, old), JuLeAna.RENAMED_PROCESSORS)
    end
end
