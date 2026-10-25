# Working in the REPL

The `juleana` interface runs whole productions. To run one processor for a few detectors,
to look at its plots, or to find out why a detector failed, use [`run_step`](@ref) from a
Julia session. This page describes that workflow.

## Setting up

Use an environment in which JuLeAna is under development, plus ParallelProcessingTools if
the session starts its own workers:

```julia
import Pkg
Pkg.develop(path = "path/to/JuLeAna.jl")
Pkg.add("ParallelProcessingTools")
```

Processing needs the LEGEND data and metadata through the `LEGEND_DATA_CONFIG` environment
variable (see [Running the dataflow](running.md)). Set it before starting Julia, or in the
session before the first call of `run_step`:

```julia
ENV["LEGEND_DATA_CONFIG"] = "/path/to/production/config.json"
using JuLeAna
```

`using JuLeAna` makes the names of the packages JuLeAna works with available, such as
`LegendDataManagement`, `LegendSpecFits`, `ParallelProcessingTools` and `CairoMakie` (see the
`export` list in `src/JuLeAna.jl`), so `LegendDataManagement.FileKey` works without loading
the package in the environment of the session. [`JuLeAna.@using_packages`](@ref) also loads
the names these packages export, e.g. `channelinfo` or `fit_peaks`, as `using` each package
would:

```julia
JuLeAna.@using_packages
```

`run_step` reads the processing config of the data production by default. The config shipped
with JuLeAna, or any other file, is given with `config`:

```julia
config = joinpath(pkgdir(JuLeAna), "config", "processing_config.yaml")
```

[`JuLeAna.processors`](@ref)`(config)` lists the registered processors with their level,
category and rank.

## Workers in the REPL

The items of a processor, e.g. its detectors, run in the calling process when no workers are
started. To run them on workers, start workers from the session. They need JuLeAna, so load
it on all of them before they start:

```julia
using JuLeAna
ParallelProcessingTools.@always_everywhere using JuLeAna
ParallelProcessingTools.runworkers(ParallelProcessingTools.OnLocalhost(n = 4))
```

`runworkers` returns at once and the workers join the pool when they are up;
`ParallelProcessingTools.worker_resources()` lists them. Log records of items that run on
workers go to the log files of the workers, not to the terminal of the session, so no
processor messages on the terminal while the items run means that they run on workers.

The serial debugging described [below](@ref "Debugging a failed detector") runs the items in
the calling process whether or not workers are started.

## Running one processor

[`run_step`](@ref) runs one processor for one period, and for a run-level processor one
run, for the detectors you choose:

```julia
step = run_step(:process_energy_calibration_cal, 3, 0; detectors = [:V01234A])
step = run_step(:p_process_energy_cal, 3; detectors = [:V01234A])   # partition level, no run
```

Replace `:V01234A` by a detector of the run. The chosen detectors are processed again, also
when they already have parameters. The other keywords are

- `outputs`: by default (`:temp`), the plots, reports and data files of the processor go to
  a temporary directory, one for the whole Julia session, and no parameters or validity are
  written; the other detectors are not run. With `outputs = :production`, everything is
  written to the data production: the other detectors are skipped as already processed, so
  the parameters and the report of the run stay complete. This cannot be undone, so test it
  with `LEGEND_DATA_CONFIG` pointing to a copy of the data production.
- `output_dir`: the directory of the temporary outputs instead of the session directory.
- `config`: another config file than the one of the data production.
- `show_report`: whether to display the report at the end; `true` by default in an
  interactive session.
- other keywords, such as `timeout = 0`, are keyword arguments of the processor.

Each call appends its report to `reports/<step>.md` in the output directory: the report rows
of the chosen detectors and, below them, the plots of each detector in the order they were
saved. The returned [`JuLeAna.StepOutput`](@ref) holds

- `step.report`: the report of this call, with the plots by file name,
- `step.report_file`, `step.output_dir`,
- `step.reports`: the complete reports the processor wrote, with all detectors,
- `step.results`: the `item => result` pairs of the items the processor ran, where
  `result` has at least `processed` and `log`, the report row of the item,
- `step.failures`: the failed steps captured with `debug`, see below.

The processors that do not support chosen detectors (`process_evt_phy`,
`p_process_skm_phy` and the stability plots) run for all detectors, without `detectors`.
`?run_step` lists all keywords.

## Debugging a failed detector

The work of a processor is divided into named steps, written as
[`JuLeAna.@process_step`](@ref) blocks. When a step fails, the processor logs which step failed for
which detector and goes on with the next item. With `debug = true`, `run_step` runs the
items one after the other in the calling process and keeps each failed step as a
[`JuLeAna.Failure`](@ref) with the variables of the processor at that step:

```julia
step = run_step(:process_energy_calibration_cal, 3, 0; detectors = [:V01234A], debug = true)
JuLeAna.failures()      # all failed steps of the last run_step call
f = JuLeAna.failure()   # the first one; shows the step name, the error and the code of the step
f.e_cal                 # a variable of the processor, as a property
propertynames(f)        # all captured variables
JuLeAna.@locals f       # define all of them as variables in Main
```

[`JuLeAna.rerun`](@ref) runs the code of the failed step again with the captured variables,
optionally with some of them replaced, and returns the value of the step. It writes no
parameters or validity. If the step fails again, the new failure replaces `f`:

```julia
JuLeAna.rerun(f)                          # fails in the same way
JuLeAna.rerun(f; window = (100, 200))     # with a changed variable
```

`rerun` tries a change of a variable or of the code of the step. A change in the JuLeAna
sources is checked with another `run_step` call, which reads everything anew.

The captured variables are those visible where the error is caught: the arguments and
variables of the processor, but not variables first assigned inside the failing step itself.
Wrap such a part of the computation in a smaller step, or use `debug = :infiltrate`.

### Stopping in a prompt

With `using Infiltrator` loaded, two more modes stop in an Infiltrator prompt with the
variables of the processor as local variables:

```julia
using Infiltrator
run_step(...; detectors = [:V01234A], debug = :infiltrate)           # stop at each failed step
run_step(...; detectors = [:V01234A], pause = :all)                  # stop after every step
run_step(...; detectors = [:V01234A], pause = ["e_cusp simple calibration"])
```

`debug = :infiltrate` stops at each failed step, which also captures the failure; leaving the
prompt goes on with the error. `pause` stops after each of the named steps (or all steps)
that succeeds, with the value of the step as `step_value`. The names are the step names with
their interpolations done, as the log messages show them. The code of the step is logged at
each stop. `pause` implies `debug = true`.

Infiltrator stops only in code that the REPL started. JuLeAna's extension for Infiltrator
turns this check off for the session, so the stops also work when `run_step` is run from a
file in the VS Code editor.

### Plots of failed steps

`error_plots = true` runs the `on_error` hook of a failed step, which saves a debug plot of
the failure with the variables of the processor. Without the keyword, the `error_plots`
setting of the processor in the config applies. The names of these plots start with
`error_`; the report links them instead of embedding them.

## Log and plot levels

The `log_level` and `plot_level` of a processor are set in the [config](configuration.md)
(`processor_log_level` and `processor_plot_level` set them for all processors) and in the
interface. `run_step` takes them as keywords for one call:

```julia
run_step(...; log_level = :debug, plot_level = :debug)
```

- `log_level` is `:debug`, `:info`, `:warn` or `:error`. The processor logs at this level
  also to the terminal. At `:debug` this includes the debug records of JuLeAna, the Legend
  packages, BAT and the JuliaPhysics packages of the dataflow, see
  [`JuLeAna.DEBUG_LOG_PACKAGES`](@ref). Without the keyword, the level of the config applies
  to the log files only. Items on workers log to the log files of the workers.
- `plot_level` is `:info` or `:debug`. At `:debug` the processor also saves the plots made
  with `@debug_plot`, which the report shows like the others.

## Reports in the REPL

The report of a `run_step` call is `step.report`; `step.report_file` is the file it was
appended to. [`JuLeAna.display_report`](@ref) shows both, with the plots as images where the
display allows it, see [below](@ref "Plots and reports in terminals"):

```julia
JuLeAna.display_report(step.report)
JuLeAna.display_report(step.report_file)
```

The reports that production runs wrote are Markdown files in the `jlrep` tier.
[`JuLeAna.report_path`](@ref) builds the path of the report of a processor, and
[`JuLeAna.read_report`](@ref) reads its state, the number of entries, warnings and failures
and the failed entries:

```julia
l200 = LegendData(:l200)
path = JuLeAna.report_path(l200, :process_energy_calibration_cal, :run, DataPeriod(3), DataRun(0), :cal)
JuLeAna.read_report(path).failures
JuLeAna.display_report(path)
```

[`JuLeAna.report_index`](@ref) reads the reports of several processors and runs into a
table of rows, and [`JuLeAna.failure_summary`](@ref) groups the failed entries of such rows
by processor and detector. The `processors` argument takes the processor entries of the
config:

```julia
cfg = JuLeAna.ProcessingConfig(config)
rows = JuLeAna.report_index(l200, [cfg.processors[:process_energy_calibration_cal]], [DataPeriod(3)], [DataRun(0)])
JuLeAna.failure_summary(rows)
```

## Plots and reports in terminals

`display_report` shows a `ReportPlot` with `display(MIME"image/png"(), plot)`, so the plots
appear as images only if a display in the Julia display stack accepts `image/png`. In a
terminal, a package provides it:

- Ghostty and Kitty: `using KittyTerminalImages`.
- Terminals with Sixel support: `using ImageInTerminal` (with ImageIO installed, which reads
  the PNG), then `ImageInTerminal.ENCODER_BACKEND[] = :Sixel`.

Load only one of these packages per session. Without such a display, a plot is shown by its
file name. In `tmux`, the image escape sequences reach the terminal only if passthrough is
on: `set -g allow-passthrough on` in `~/.tmux.conf`.

In the VS Code Julia REPL with the plot pane on, `display_report` sends the whole report,
with its tables and embedded plots, to the plot pane as one HTML page, so no image package
is needed.
