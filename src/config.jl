# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    parse_commandline(args::AbstractVector{<:AbstractString})

Parse the command line options of the dataflow driver and return them as a
`Dict{String,Any}` keyed by the long option names. With `--help` or `--version`,
ArgParse prints the text and exits the process in a non-interactive session; in an
interactive session it returns `nothing`.

Options (see `juleana --help` for the full text):
- `--config`, `-c`: path of the processing config file. Without it, the
  [`JuLeAna.install_default_config`](@ref) file of the data production is used (copied
  from the config shipped with JuLeAna if the production has none), or `nothing` when
  `LEGEND_DATA_CONFIG` is not set (no data production is selected).
- `--periods`, `-p`: periods, each optionally with runs: `6` (all runs of p06), `6,1`
  (r001), `6,1-3` (r001 to r003), `6,1,4-6`. Each occurrence gives one vector of these
  strings, so `-p 3 4 -p 6,1` gives `[["3", "4"], ["6,1"]]`; see
  [`JuLeAna.parse_period_runs`](@ref).
- `--runs`, `-r`: run numbers for the periods given without runs, as one vector per
  occurrence.
- `--runmode`, `--rm`: `local` or `slurm`, replacing the config's run mode.
- `--dataset`: name of the dataset in the metadata `datasets/runlists` that selects the runs;
  `"default"` when not given.
- `--log_path`, `-o`: log directory; `""` when not given.
- `--theme`: name of the color theme of the interface; `nothing` when not given.
- Flags, `false` when not given: `--no-tui`, `--new-production`, `--reprocess`, `--only_runs` (`--or`),
  `--only_partitions` (`--op`), `--submit_jobs`, `--ignore_config`,
  `--analysis_runs_only`.

# Examples
```jldoctest
julia> args = JuLeAna.parse_commandline(["-c", "config.json", "-p", "3", "4", "--reprocess"]);

julia> args["periods"], args["reprocess"], args["only_runs"]
([["3", "4"]], true, false)
```
"""
function parse_commandline(args::AbstractVector{<:AbstractString})
    settings = ArgParseSettings(prog = "LEGEND Julia main data processing",
                                description = "LEGEND Julia main data processing for data processing on single server machines or via SLURM with access to LEGEND data. Please check the config for all settings related to the data processing.",
                                version = string(pkgversion(JuLeAna)), add_version = true)
    @add_arg_table! settings begin
        "--config", "-c"
        help = "path to config file; default: config/processing_config.yaml in the data production, copied there from the config shipped with JuLeAna if missing"
        arg_type = String
        "--reprocess"
        help = "reprocess all channels while deleting old data"
        action = :store_true
        "--processor-log-level"
        dest_name = "processor_log_level"
        help = "log level of the processors' records, overriding `config.processor_log_level` and each processor's `log_level`: debug, info, warn or error"
        arg_type = String
        range_tester = in(keys(LOG_LEVELS))
        "--processor-plot-level"
        dest_name = "processor_plot_level"
        help = "plot level of the processors, overriding `config.processor_plot_level` and each processor's `plot_level`: info or debug"
        arg_type = String
        range_tester = in(string.(PLOT_LEVEL_VALUES))
        "--only_runs", "--or"
        help = "process only period and runs ignoring partitions"
        dest_name = "only_runs"
        action = :store_true
        "--only_partitions", "--op"
        help = "process only partitions ignoring periods and runs"
        dest_name = "only_partitions"
        action = :store_true
        "--no-tui", "--no_tui"
        help = "run all enabled processors without the terminal user interface and exit"
        dest_name = "no_tui"
        action = :store_true
        "--new-production", "--new_production"
        help = "open the terminal user interface on the creation of a new data production"
        dest_name = "new_production"
        action = :store_true
        "--submit_jobs"
        help = "submit slurm jobs to the selected run mode"
        action = :store_true
        "--runmode", "--rm"
        help = "run mode to use for processing"
        dest_name = "runmode"
        arg_type = String
        "--ignore_config"
        help = "ignore all settings and config and only take command line arguments"
        action = :store_true
        "--theme"
        help = "color theme of the terminal user interface, such as night-owl or juleana; default: the theme last chosen with T"
        arg_type = String
        "--dataset"
        help = "dataset of the run lists in the metadata (datasets/runlists) that selects the runs"
        arg_type = String
        default = "default"
        "--log_path", "-o"
        help = "path to store log files in"
        arg_type = String
        default = ""
        "--analysis_runs_only"
        help = "process only channels that are marked as analysis runs"
        action = :store_true
        "--periods", "-p"
        help = "periods to process, each optionally with runs: 6 (all runs), 6,1 (r001), 6,1-3, 6,1,4-6; repeatable"
        nargs = '+'
        arg_type = String
        action = :append_arg
        "--runs", "-r"
        help = "runs to process in the periods given without runs"
        nargs = '+'
        arg_type = Int
        action = :append_arg
    end
    parsed_args = parse_args(append!(String[], args), settings)
    !isnothing(parsed_args) &&
        isnothing(parsed_args["config"]) &&
        haskey(ENV, "LEGEND_DATA_CONFIG") &&
        (parsed_args["config"] = install_default_config())
    return parsed_args
end

"""
    JuLeAna.data_config_files()

Return the files named by the environment variable `LEGEND_DATA_CONFIG`, which separates
them by colons as LegendDataManagement reads them. The last file is the data config of the
data production; the files before it are overrides, e.g. of the computing site, that
LegendDataManagement applies on top of it for every production.

Throws an `ArgumentError` if `LEGEND_DATA_CONFIG` is not set.
"""
function data_config_files()
    haskey(ENV, "LEGEND_DATA_CONFIG") || throw(ArgumentError("data_config_files: the environment variable LEGEND_DATA_CONFIG is not set"))
    return String.(split(ENV["LEGEND_DATA_CONFIG"], r":(?!\\)"))
end

"""
    JuLeAna.with_production_config(config::AbstractString)

Return the value of `LEGEND_DATA_CONFIG` that selects the data production whose data config
is `config`: the override files of [`JuLeAna.data_config_files`](@ref) followed by `config`,
or `config` alone if `LEGEND_DATA_CONFIG` is not set.
"""
function with_production_config(config::AbstractString)
    return join(vcat(haskey(ENV, "LEGEND_DATA_CONFIG") ? data_config_files()[1:(end - 1)] : String[], config), ":")
end

"""
    JuLeAna.production_setup_dir()

Return the path of the `setup` folder of the data production: the folder `setup` next
to the data config of the production, the last file of [`JuLeAna.data_config_files`](@ref),
in the folder that `\$_` stands for in that file. It holds the subfolders `config`,
`software` and `metadata` that JuLeAna manages. The folder need not exist and is not created.

Throws an `ArgumentError` if `LEGEND_DATA_CONFIG` is not set, or if the production folder
has a top-level `config`, `software` or `metadata-records` folder; their contents belong in
`setup/config`, `setup/software` and `setup/metadata`.
"""
function production_setup_dir()
    production = dirname(abspath(last(data_config_files())))
    old = [("config", "setup/config"), ("software", "setup/software"), ("metadata-records", "setup/metadata")]
    found = filter(m -> isdir(joinpath(production, first(m))), old)
    isempty(found) || throw(ArgumentError("The data production $production has folders in the old layout. Move " *
                                          join(["$a/ to $b/" for (a, b) in found], ", ") *
                                          "."))
    return joinpath(production, "setup")
end

"""
    JuLeAna.production_config_dir()

Return the path of the `config` folder of the data production, the subfolder `config` of
the [`JuLeAna.production_setup_dir`](@ref). The folder need not exist.

Throws an `ArgumentError` under the conditions of [`JuLeAna.production_setup_dir`](@ref).
"""
production_config_dir() = joinpath(production_setup_dir(), "config")

"""
    JuLeAna.default_config_file()

Return the path of the default processing config file of the data production,
`setup/config/processing_config.yaml` (see [`JuLeAna.production_config_dir`](@ref)). The
file need not exist; see [`JuLeAna.install_default_config`](@ref).
"""
default_config_file() = joinpath(production_config_dir(), "processing_config.yaml")

"""
    JuLeAna.install_default_config()

Return the [`JuLeAna.default_config_file`](@ref). If the file does not exist, first
create the [`JuLeAna.production_config_dir`](@ref) and copy the
`config/processing_config.yaml` shipped with JuLeAna into it, logging the copy. An
existing file is never overwritten. A `processing_config.json` next to the file is
ignored with a warning.
"""
function install_default_config()
    path = default_config_file()
    if !isfile(path)
        legacy = joinpath(dirname(path), "processing_config.json")
        isfile(legacy) && @warn "Ignoring $legacy: the processing config is read from YAML; using $path"
        shipped = joinpath(pkgdir(JuLeAna), "config", "processing_config.yaml")
        cp(shipped, joinpath(mkpath(dirname(path)), basename(path)))
        @info "Copied the processing config shipped with JuLeAna ($shipped) to $path"
    end
    return path
end

"""
    JuLeAna.parse_period_runs(period_args, run_args)

Turn the `--periods` and `--runs` options of [`parse_commandline`](@ref) into
`(periods, runs)`. `period_args` and `run_args` are vectors with one vector per
occurrence of the option: strings like `"6"`, `"6,1"`, `"6,1-3"` or `"6,1,4-6"` for
periods, and run numbers for runs.

`periods` is a `Vector{DataPeriod}` in the given order, or `nothing` without
`--periods`. `runs` is
- a `Dict{DataPeriod,Vector{DataRun}}` with the sorted runs of each period given with
  runs, when any is; the other periods keep all their runs;
- else the `--runs` numbers as a `Vector{DataRun}` for all given periods;
- else `nothing`.

Throws an `ArgumentError` for a malformed string, a period given twice, a run range
that ends before it starts, and for `--runs` together with periods given with runs.

# Examples
```jldoctest
julia> periods, runs = JuLeAna.parse_period_runs([["3", "6,1-3"], ["7,2,5"]], []);

julia> string.(periods), sort([string(p) => string.(r) for (p, r) in runs])
(["p03", "p06", "p07"], ["p06" => ["r001", "r002", "r003"], "p07" => ["r002", "r005"]])
```
"""
function parse_period_runs(period_args, run_args)
    periods = DataPeriod[]
    period_runs = Dict{DataPeriod,Vector{DataRun}}()
    function number(text, spec)
        n = tryparse(Int, strip(text))
        isnothing(n) && throw(ArgumentError("invalid period or run `$text` in `-p $spec`"))
        return n
    end
    for spec in Iterators.flatten(period_args)
        parts = split(spec, ',')
        period = DataPeriod(number(first(parts), spec))
        period in periods && throw(ArgumentError("period $period is given more than once"))
        push!(periods, period)
        length(parts) > 1 || continue
        runs = Int[]
        for part in parts[2:end]
            bounds = number.(split(part, '-'; limit = 2), spec)
            first(bounds) <= last(bounds) || throw(ArgumentError("run range `$part` in `-p $spec` ends before it starts"))
            append!(runs, first(bounds):last(bounds))
        end
        period_runs[period] = DataRun.(sort!(unique!(runs)))
    end
    global_runs = DataRun[DataRun(r) for r in Iterators.flatten(run_args)]
    !isempty(period_runs) &&
        !isempty(global_runs) &&
        throw(ArgumentError("`-r` cannot be combined with periods given with runs (`-p 6,1`)"))
    runs = !isempty(period_runs) ? period_runs : isempty(global_runs) ? nothing : global_runs
    return isempty(periods) ? nothing : periods, runs
end

"""
    JuLeAna.mirror_override_folders(l200::LegendData)
    JuLeAna.mirror_override_folders(overrides::AbstractString, base::AbstractString)

Create every folder below `overrides` that is missing below `base`, at the same relative
path, and return the created folders. For `l200`, this is done for the parameter overrides
`<metadata>/jldataprod/overrides/par` and `base = data_path(l200, "par")`, and likewise for
`jlpar`; a missing override folder is skipped.

LegendDataManagement opens a parameter folder that exists only in the overrides as a
folder of the overrides, so a processor would write its parameters into the metadata.
With the folder in `base`, it opens that one and applies the overrides on top.
"""
function mirror_override_folders(l200::LegendData)
    created = String[]
    for db in ("par", "jlpar")
        overrides = joinpath(data_path(l200, "metadata"), "jldataprod", "overrides", db)
        isdir(overrides) && append!(created, mirror_override_folders(overrides, data_path(l200, db)))
    end
    return created
end

function mirror_override_folders(overrides::AbstractString, base::AbstractString)
    created = String[]
    for (root, _, _) in walkdir(overrides)
        folder = normpath(joinpath(base, relpath(root, overrides)))
        isdir(folder) || push!(created, mkpath(folder))
    end
    return created
end

"""
    setup_processing(parsed_args::AbstractDict)

Build the processing setup from the output of [`parse_commandline`](@ref) and return
`(l200, processing_config, periods)`.

Reads the config file, applies the command line overrides, sets `ENV` from the
config's `env_variables` (before the metadata is loaded), builds `LegendData(:l200)` for the `--dataset`,
creates the parameter folders of its override folders (see
[`JuLeAna.mirror_override_folders`](@ref)), and creates the log directory: `--log_path` when given, otherwise a directory in the `jllog` tier
named by the current UTC time (`yyyy-mm-ddTHH:MM:SSZ`). `periods` are the selected periods that are in the
dataset, or all periods of the dataset when the config selects all.
"""
function setup_processing(parsed_args::AbstractDict)
    config_dict = readlprops(parsed_args["config"])
    # command line overrides; per-period runs are applied to the session, not the config
    periods, runs = parse_period_runs(parsed_args["periods"], parsed_args["runs"])
    cli = (; runmode = parsed_args["runmode"], submit_jobs = parsed_args["submit_jobs"],
           analysis_runs_only = parsed_args["analysis_runs_only"], only_partitions = parsed_args["only_partitions"],
           only_runs = parsed_args["only_runs"], ignore_config = parsed_args["ignore_config"], reprocess = parsed_args["reprocess"],
           periods, runs = runs isa AbstractDict ? nothing : runs)
    # the command line level takes precedence over `config.processor_log_level`
    isnothing(parsed_args["processor_log_level"]) || (config_dict.config.processor_log_level = parsed_args["processor_log_level"])
    # the command line level takes precedence over `config.processor_plot_level`
    isnothing(parsed_args["processor_plot_level"]) || (config_dict.config.processor_plot_level = parsed_args["processor_plot_level"])
    processing_config = ProcessingConfig(config_dict; cli...)
    # the environment variables must be set before the metadata is loaded
    for (key, value) in processing_config.env_variables
        ENV[key] = value
    end

    @info "Loading Legend MetaData"
    dataset = Symbol(parsed_args["dataset"])
    l200 = LegendData(:l200; dataset)
    dataset == :default ||
        haskey(l200.metadata.datasets.runlists, dataset) ||
        throw(ArgumentError("dataset $dataset is not in the metadata datasets/runlists"))
    for folder in mirror_override_folders(l200)
        @info "Created the parameter folder $folder of an override folder"
    end

    log_path = mkpath(isempty(parsed_args["log_path"]) ? joinpath(l200.tier[:jllog], utc_timestamp()) : parsed_args["log_path"])
    processing_config = ProcessingConfig(config_dict; cli..., log_path)
    @info "Log path: $log_path"

    processing_config.analysis_runs_only && @info "Process only analysis runs"
    processing_config.only_partitions && @info "Process only partitions"
    processing_config.only_runs && @info "Process only runs"
    @info "Runmode: $(processing_config.runmode)"
    processing_config.submit_jobs && @info "Will submit $(processing_config.runmode) jobs"
    parsed_args["reprocess"] && @info "Reprocess all processors"

    # restrict the selected periods to those of the dataset
    available = available_periods(l200)
    periods = if isnothing(processing_config.periods)
        available
    else
        filter(in(available), processing_config.periods)
    end
    @info "Process periods: $(string.(periods))"
    if runs isa AbstractDict
        @info "Process runs: " * join(("$p: $(join(string.(r), ", "))" for (p, r) in sort!(collect(runs); by = first)), "; ")
    else
        runs = processing_config.runs
        @info isnothing(runs) ? "Process all runs of the dataset for each period" : "Process runs: $(string.(runs))"
    end

    return l200, processing_config, periods
end

"""
    JuLeAna.available_periods(l200::LegendData)
    JuLeAna.available_runs(l200::LegendData, period::DataPeriod)

Return the periods, or the runs of `period`, in the `runinfo` of `l200`, which holds the
runs of the dataset of `l200`, sorted. The data on disk is not checked.
"""
available_periods(l200::LegendData) = sort!(unique(runinfo(l200).period))

function available_runs(l200::LegendData, period::DataPeriod)
    rinfo = runinfo(l200)
    return sort!(rinfo.run[rinfo.period .== period])
end

# `runs === nothing` selects all available runs of `period`
function processable_runs(l200::LegendData, period::DataPeriod, runs::Union{AbstractVector{DataRun},Nothing})
    available = available_runs(l200, period)
    isnothing(runs) && return available
    for run in runs
        run in available || @warn "Run $run not found in period $period"
    end
    return DataRun[r for r in runs if r in available]
end

# Runs given per period; a period without an entry keeps all its runs.
function processable_runs(l200::LegendData, period::DataPeriod, runs::AbstractDict{DataPeriod})
    return processable_runs(l200, period, get(runs, period, nothing))
end

# Return `(periods, run_status, partition_status)`: the given periods that have
# processable runs, and the completion flags of every step for them. The status of a
# step starts as finished unless the step is in `run_steps` or `partition_steps`, so
# only the selected steps are waited for. `runs` is `nothing` (all runs), a vector of
# runs for every period, or a dict of runs per period (other periods keep all runs).
function setup_dependency_graph(l200::LegendData, processing_config::ProcessingConfig, periods::AbstractVector{DataPeriod},
                                runs::Union{AbstractVector{DataRun},AbstractDict{DataPeriod},Nothing}, run_steps::AbstractVector{Symbol},
                                partition_steps::AbstractVector{Symbol})
    # get all possible steps
    # `run_steps`/`partition_steps` are local names here, so read the step lists from the tables.
    possible_steps = _sorted_steps(processing_config.processors, false)
    # generate process status with all possible steps for all possible runs in all periods
    run_status = RunStatus()

    # check if each period contains any runs at all
    processable_runs_dict = Dict{DataPeriod,Vector{DataRun}}(periods .=> processable_runs.(Ref(l200), periods, Ref(runs)))
    periods = filter(p -> !isempty(processable_runs_dict[p]), periods)

    # fill
    for period in periods
        # get all processable runs
        period_runs = processable_runs_dict[period]
        run_status[period] = Dict{Symbol,Dict{DataRun,Bool}}(step => Dict{DataRun,Bool}(period_runs .=> !(step in run_steps))
                                                             for step in possible_steps)
    end

    # get all possible steps for partition processing
    possible_p_steps = _sorted_steps(processing_config.p_processors, false)
    # generate process status with all possible steps for all possible runs in all periods
    partition_status = PartitionStatus()
    for period in periods
        partition_status[period] = Dict{Symbol,Bool}(step => !(step in partition_steps) for step in possible_p_steps)
    end

    return periods, run_status, partition_status
end
