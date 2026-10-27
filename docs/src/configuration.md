# Configuration

```@meta
DocTestSetup = :(using JuLeAna)
```

The processing config file sets up the analysis chain. The config shipped with JuLeAna
is `config/processing_config.yaml`. Without
`--config`, `juleana` reads `config/processing_config.yaml` in the data production (the
folder `config` next to the file named by `LEGEND_DATA_CONFIG`). If that file does not
exist, JuLeAna first copies the config shipped with JuLeAna there; a `processing_config.json` in that folder is ignored with a warning. `w` on the Setup page of the interface writes the
current settings to that file and keeps the previous file as `processing_config.yaml.bak`.
See [Running the dataflow](running.md). The
file is loaded into a [`ProcessingConfig`](@ref); all keys of the `config` and
`processing` sections are required except `idle_timeout_minutes`, `processor_log_level`, `processor_plot_level` and `plot_formats`, and a missing or
unknown key stops the dataflow with an error that names the key.

## `config`

The run mode, the worker settings, environment variables and logging:

1. **`runmode`**: `"local"` or `"slurm"`.
2. **`submit_jobs`**: start the workers of the selected run mode automatically.
3. **`runmode_settings`**: `local.n` (number of local workers) and
   `local.julia_settings`, `slurm.flags` and `slurm.julia_settings`.
   - **`slurm.flags`**: options passed to SLURM, see the
     [SLURM documentation](https://slurm.schedmd.com) and the documentation of the
     cluster you use.
   - **`julia_settings`**: options passed to the `julia` processes of the workers, such
     as `--heap-size-hint`; see the
     [`julia` command line documentation](https://docs.julialang.org/en/v1/manual/command-line-interface/).
     Without `--threads` in `local.julia_settings`, each local worker gets the number of
     CPU threads of the host divided by `local.n` (at least one), so the workers together
     use each CPU thread once.
4. **`env_variables`**: environment variables set for the dataflow and its workers,
   for example to select a data set. Set `JULIA_WORKER_TIMEOUT` for a stable connection
   of the ParallelProcessingTools workers; `JULIA_DEBUG` enables debug messages of the
   listed packages.
5. **`log_level`**: `"debug"`, `"info"`, `"warn"` or `"error"`, the level of the records
   that every process writes to its log file in the log directory (`head.log` for the
   main process, `worker-<id>-<host>.log` for each worker). `"debug"` adds the debug
   records of the packages listed in `JULIA_DEBUG`.
6. **`processor_log_level`** (optional): `"debug"`, `"info"`, `"warn"` or `"error"`.
   Without it, the processors' own records are written at `log_level`. With it, it
   replaces `log_level` for them; see `log_level` of the processor entries below. The command line option
   `--processor-log-level` replaces the value of the config, and the "Processor log level"
   row of the Setup page replaces both. The level in effect is the one of the Setup page,
   else the command line, else `processor_log_level`, else the `log_level` of each
   processor entry.
7. **`processor_plot_level`** (optional): `"info"` or `"debug"`. Without it, each processor
   saves plots at the `plot_level` of its entry. With it, it replaces `plot_level` for all
   processors; see `plot_level` of the processor entries below. The command line option
   `--processor-plot-level` replaces the value of the config, and the "Processor plot level"
   row of the Setup page replaces both.
8. **`plot_formats`** (optional, default `["png"]`): a list of the formats in which plots are
   saved, `"png"` and `"jls"`, at least one, each at most once. With `"jls"`, the Makie
   figure is also saved with `Serialization` next to the PNG, under the same name with
   the extension `.jls`. The file lets you open the figure again later, but only a Julia
   session with the same package versions can read it.
9. **`idle_timeout_minutes`** (optional, default `20`): when no processing has run for
   this many minutes, the worker allocations started from the terminal user interface
   are cancelled, so that idle workers do not hold a machine or a SLURM allocation. The
   time counts from the end of the last processing run, the start of the newest
   allocation or the last postponement, whichever is latest. `0` never cancels them.

## `processing`

The `periods` and `runs` to process, each either a list of numbers or `"all"`:

```yaml
processing:
  periods: [3]
  runs: all
  ...
```

processes all available runs of period 3. `"periods": "all"` processes all periods
of the dataset. The other keys are flags:

1. **`analysis_runs_only`**: process only runs marked as analysis runs in
   `legend-metadata`, i.e. runs that passed the quality criteria for the final analysis.
2. **`only_runs`**: run only the run-level processors.
3. **`only_partitions`**: run only the partition-level processors.

Two keys are optional:

- **`order`**: `"dependencies"` or `"rank"` (the default). With `"dependencies"` the
  `dependencies` of the processors alone decide the order, and processors that do not
  depend on each other run at the same time. With `"rank"` the processors of each level
  run one after another in the order of `rank`, then name: when the config is loaded,
  every processor gets a dependency on the processor before it, and a warning asks to
  switch to `"dependencies"`.
- **`max_parallel_steps`**: the maximum number of processor steps (one processor for
  one run, or for one period at partition level) that run at the same time; `0`, the
  default, sets no limit. The steps share the workers either way.

## `processors` and `p_processors`

The run-level processors (`processors`) and partition-level processors (`p_processors`)
of the chain, keyed by processor name. At least one processor must be enabled. An entry
looks like this:

```yaml
process_dsp_cal:
  enabled: true
  category: cal
  rank: 5
  log_level: info
  plot_level: info
  detectors: "processable"
  kwargs:
    reprocess: true
    max_wvfs: 1000
    timeout: 0
    use_partition_pars: true
  dependencies: [p_process_aoe_optimization_cal]
```

All fields are required:

1. **`enabled`**: whether the processor runs.
2. **`category`**: `"cal"` or `"phy"`, the data category the processor works on.
3. **`rank`**: position in listings, and the tie rule of the scheduling: among steps
   that are ready to start, lower ranks start first.
4. **`kwargs`**: keyword arguments passed to the processor; the [Processors](@ref) page
   lists the keywords of each processor. Every enabled processor must accept all of its
   configured keywords, plus `reprocess` and, for partition processors,
   `only_first_period`, which the dataflow passes on its own. This is checked when the
   dataflow starts. The `--reprocess` command line flag sets `reprocess` to `true` for
   every processor.
5. **`dependencies`**: processors of either level that must finish first. A run
   processor waits for a run processor in the same run and for a partition processor in
   its period. A partition processor waits for a run processor in all runs of its period
   and of the other selected periods that share a default partition with it. A
   processor that is not selected passes its dependencies on: a selected processor
   waits for the selected processors that its unselected dependencies depend on.
   Every dependency must name a configured processor, the dependencies must not form a
   cycle, and processor names must be unique across `processors` and `p_processors`.

6. **`log_level`**: `"debug"`, `"info"`, `"warn"` or `"error"`, the level of the
   processor's records in the log files. With `"debug"`, the debug records of JuLeAna,
   the Legend* packages, BAT*, RadiationDetectorDSP, RadiationDetectorSignals,
   RadiationSpectra, SolidStateDetectors and their extensions are written as well while
   the processor runs. `config.processor_log_level`, when set, replaces this value for
   all processors.
7. **`plot_level`**: `"info"` or `"debug"`. With `"info"`, the processor saves its normal
   plots; with `"debug"`, it also saves its debug plots. `config.processor_plot_level`,
   when set, replaces this value for all processors.

Some processors select detectors with the `detectors` field:

- **`detectors`**: the detectors the processor works on, as a string in the syntax of
  `LegendDataManagement.ljl_propfunc`. The processor loads the channel info of its
  system and keeps the rows for which the expression is true, so the expression can use
  any column of the channel info table, for example `processable`, `usability`,
  `system`, `det_type`, `low_aoe_status` or `lq_status`. Examples:
  `"processable && usability != :off"` or
  `"processable && usability == :on && (low_aoe_status == :valid || low_aoe_status == :present)"`.
  Use `"true"` to keep every row. The expression is checked when the config is loaded;
  a column that does not exist throws an error when the processor starts. A processor
  that selects detectors and has no `detectors` entry stops with an error when it starts.
  `process_evt_phy` does not select detectors and ignores the field. The shipped
  config sets `"processable"` for all processors except the PSD processors, which also
  require a valid `low_aoe_status` or `lq_status` (and `usability == :on` at run level),
  and `process_dsp_aux_phy` and `p_process_skm_phy`, which keep all rows.

Two fields are optional:

- **`report_status`**: how the rows of the processor report give the `Processor
  Status`, see [Report status](@ref). A table from the detector usability (`on`, `ac`
  or `off`) to a table from the row status (`warning` or `failure`) to the status the
  row gives the processor (`success`, `warning` or `failure`). Entries that are not set
  keep the default of [`JuLeAna.DEFAULT_REPORT_STATUS`](@ref); an unknown usability, row
  status or status is an error. Example, which makes a failing `off` detector a
  success and a warning of an `ac` detector a failure:

  ```yaml
  report_status:
    ac:  {warning: failure}
    off: {failure: success}
  ```
- **`error_plots`**: `true` or `false` (the default). With `true`, a failed step of the
  processor saves the debug plot of its `on_error` hook, see [`JuLeAna.@process_step`](@ref).
  The plot is saved with the other plots of the detector, with a name starting with
  `error_`.

A key or dependency that uses a former processor name from `JuLeAna.RENAMED_PROCESSORS`
(for example `process_decay_time` for `process_decay_time_cal`) is read as the current
name, and a warning names both once when the config is loaded. A config that contains
both names of one processor is an error.

String lists in the `kwargs` of a processor become Julia symbol vectors when the config
is loaded: YAML `subsystems: [geds, spms, pmts, aux]` is passed as
`[:geds, :spms, :pmts, :aux]`. Use plain strings in YAML, without a leading
colon. Scalar strings, and lists outside processor `kwargs`, keep their types.

## Building a config in Julia

[`ProcessingConfig`](@ref) can also be built from keywords, which is convenient for
tests. [`run_steps`](@ref) and [`partition_steps`](@ref) return the enabled processors
in processing order:

```jldoctest config
julia> cfg = ProcessingConfig(;
           processors = Dict(
               :process_dsp_cal => ProcessorSpec(; name = :process_dsp_cal, level = :run,
                   category = :cal, rank = 5, dependencies = [:p_process_decay_time_cal]),
               :process_peak_split_cal => ProcessorSpec(; name = :process_peak_split_cal, level = :run,
                   category = :cal, rank = 1)),
           p_processors = Dict(
               :p_process_decay_time_cal => ProcessorSpec(; name = :p_process_decay_time_cal,
                   level = :partition, category = :cal, rank = 2)));

julia> run_steps(cfg)
2-element Vector{Symbol}:
 :process_peak_split_cal
 :process_dsp_cal

julia> partition_steps(cfg)
1-element Vector{Symbol}:
 :p_process_decay_time_cal

julia> check_processor_kwargs(cfg)  # all processors are registered and accept their kwargs
```

An inconsistent config is rejected when it is built:

```jldoctest config
julia> ProcessingConfig(;
           processors = Dict(:process_dsp_cal => ProcessorSpec(; name = :process_dsp_cal,
               level = :run, category = :cal, rank = 5, dependencies = [:p_process_unknown])),
           p_processors = Dict{Symbol,ProcessorSpec}())
ERROR: ArgumentError: processing_config: key `processors.process_dsp_cal.dependencies` names unknown processor `p_process_unknown`
```
