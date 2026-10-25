# JuLeAna.jl

JuLeAna is the Julia dataflow of the LEGEND-200 analysis (JuLeAna, the Julia LEGEND
Analysis). It processes LEGEND-200 data from the `raw` tier up to the event level on a
single machine or on a [SLURM](https://slurm.schedmd.com) cluster:

- parallel processing with
  [ParallelProcessingTools](https://github.com/oschulz/ParallelProcessingTools.jl), which
  connects new local or SLURM worker processes to a running `julia` session;
- processing of all data tiers up to the `evt` level;
- a Markdown report for every processing step, with an overview of the results per
  detector or file;
- monitoring and analysis plots;
- parameter files (`pars`) with `validity` entries;
- run- and partition-level processing, ordered by a dependency graph.

## Concepts

**Periods, runs and partitions.** LEGEND data are organized in periods (`p03`) and runs
(`r000`), each with calibration (`cal`) and physics (`phy`) data. A partition groups
runs, possibly across periods, whose calibration data are combined to get more
statistics; the partitions of each detector are defined in the LEGEND metadata.

**Processors.** A processor is one processing step, such as the DSP of the calibration
data or the energy calibration. Each processor is a Julia function in
`src/processors/`, registered under its name in [`JuLeAna.PROCESSORS`](@ref). There are
two levels:

- run-level processors `process_xxx(processing_config, l200, period, run; kwargs...)`
  work on one run of one period;
- partition-level processors `p_process_xxx(processing_config, l200, period; kwargs...)`
  work on the partitions that contain a period.

The [Processors](@ref) page lists all of them with their inputs and outputs.

**Processing config.** A JSON or YAML file selects the periods and runs, the worker
setup, and which processors run with which keyword arguments (see
[Configuration](@ref)). It is loaded into a [`ProcessingConfig`](@ref).

**Dependencies.** A processor lists the processors it needs in `dependencies`, of
either level. A processor starts for a run or a period as soon as the processors it
depends on have finished: for a run processor in the same run, for a partition processor
in all runs of its period and of the other selected periods that share a default
partition with it. Processors that do not depend on each other run at the same time, and
so do different runs and periods. A selected processor also waits for what the
processors it depends on wait for, even when those are not selected, so it waits for
exactly what the [processor graph](@ref processor_graph) shows. Among processors that
are ready, lower `rank`s start first. [`run_processing`](@ref) implements this schedule.

**Outputs.** Processors read and write the data tiers through `LegendDataManagement`:

| Tier     | Content |
|:---------|:--------|
| `jlpks`  | waveforms around the calibration peaks |
| `jldsp`  | DSP output |
| `jlqcs`  | quality cut flags |
| `jlaux`, `jlpmt` | auxiliary channels (including the pulser), PMT data |
| `jlevt`  | events |
| `jlskm`  | skimmed events |
| `jlrep`  | Markdown reports per run and per partition |
| `jllog`  | log directories of the dataflow |

Parameters are written to `l200.par.rpars` (per run) and `l200.par.ppars` (per
partition), together with their validity.

## Installation

JuLeAna and the other LEGEND packages are registered in the
[LegendJuliaRegistry](https://github.com/legend-exp/LegendJuliaRegistry). Add it once,
next to the General registry:

```julia
import Pkg
Pkg.Registry.add("General")
Pkg.Registry.add(url = "https://github.com/legend-exp/LegendJuliaRegistry.git")
```

To run the dataflow, install JuLeAna as a Julia app, which creates the `juleana`
command:

```julia
import Pkg
Pkg.Apps.add("JuLeAna")
```

For development, install a clone of the repository instead with
`Pkg.Apps.develop(path = "path/to/JuLeAna.jl")`.

Processing needs access to the LEGEND data and metadata, configured with the
`LEGEND_DATA_CONFIG` environment variable (see `LegendDataManagement`). The
[How-to-Legend](https://github.com/LisaSchlueter/HowTo-Legend/tree/main) repository
explains the setup on the different clusters. [Running the dataflow](running.md) describes
the `juleana` terminal user interface and the next steps.
