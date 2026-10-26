# Running the dataflow

## Installing the app

JuLeAna is a Julia app. [`Pkg.Apps`](https://pkgdocs.julialang.org/v1/apps/) installs it
in its own environment and creates the command `juleana`:

```julia
import Pkg
Pkg.Apps.add("JuLeAna")                              # from the registry
Pkg.Apps.develop(path = "path/to/JuLeAna.jl")        # or from a checkout
```

The `juleana` command is placed in the `bin` folder of the first Julia depot (`~/.julia/bin`
unless `JULIA_DEPOT_PATH` is set), which must be in the `PATH`. It starts Julia with
`--threads=8,1`, `--gcthreads=8,1` (garbage collection on eight threads, plus one thread that
frees memory concurrently, which shortens the pauses of the interface while processing runs)
and `--startup-file=no`, so packages loaded by the `startup.jl` of the user are not available. Julia options before a `--` replace these defaults:

```bash
juleana --threads=16,1 -- -c config/processing_config.yaml
```

Processing needs access to the LEGEND data and metadata through the `LEGEND_DATA_CONFIG`
environment variable (see the [overview](index.md)). The data production
named there also holds the `setup/config` folder described [below](@ref "Config folder of the data production").

`LEGEND_DATA_CONFIG` may name several files separated by colons. The last one is the data
config of the production; the ones before it are overrides, e.g. of the computing site,
that apply to every production:

```bash
export LEGEND_DATA_CONFIG=/ptmp/legend/config_viper.yaml:/ptmp/legend/ref/jl-v0.8.1/config.json
```

Selecting or creating a production in JuLeAna replaces only the last file and keeps the
overrides.

## Starting

```bash
juleana                                    # config of the data production
juleana -c config/processing_config.yaml   # a given config
juleana --help                             # all options
```

`juleana` opens a terminal user interface. It reads the [processing config](@ref Configuration),
builds the dependency graph of the enabled processors, and waits on the Setup page.
Processing starts with `s`. The interface never starts workers on its own, see
[Workers](@ref running-workers).

`juleana --no-tui` runs all enabled processors without the interface, shows progress bars,
and exits. The exit code is `0` when processing finished, `1` when it failed and `2` when
it was stopped. The first `Ctrl+C` stops after the running items, the second stops at
once. Unlike the interface, `--no-tui` starts the configured workers itself: local
workers always, SLURM workers when `submit_jobs` is set. Without `submit_jobs` it writes
the SLURM start script `startjlworkers.sh` to the `setup/config` folder of the data production
for submission by hand.

The same session is available from any Julia session:

```julia
using JuLeAna
session = JuLeAna.setup_session(["-c", "config/processing_config.yaml"])
```

## Running one processor for chosen detectors

[`run_step`](@ref) runs one processor for chosen detectors from a Julia session; see
[Working in the REPL](repl.md).

## Command line options

| Option            | Description |
|:------------------|:------------|
| `--config`, `-c`  | Path of the processing config file; see [Config folder of the data production](@ref) for the default |
| `--periods`, `-p` | Periods to process, each optionally with runs: `-p 3 4` (all runs of p03 and p04), `-p 6,1` (r001 of p06), `-p 6,1-3` (r001 to r003), `-p 6,1,4-6`; repeatable, e.g. `-p 6,1 -p 7,2-4` |
| `--runs`, `-r`    | Runs to process in the periods given without runs; requires `--periods` and cannot be combined with periods given with runs |
| `--reprocess`     | Reprocess all detectors, discarding existing results; sets `reprocess` of every processor |
| `--processor-log-level` | Log level of the processors' records: `debug`, `info`, `warn` or `error`; replaces `processor_log_level` of the config and the `log_level` of each processor |
| `--processor-plot-level` | Plot level of the processors: `info` (normal plots) or `debug` (also debug plots); replaces `processor_plot_level` of the config and the `plot_level` of each processor |
| `--only_runs`, `--or` | Run only the run-level processors |
| `--only_partitions`, `--op` | Run only the partition-level processors |
| `--analysis_runs_only` | Process only runs marked as analysis runs in the metadata |
| `--no-tui`        | Run all enabled processors without the terminal user interface and exit |
| `--new-production` | Open the interface on the form for a new data production, see [Creating a data production](@ref) |
| `--submit_jobs`   | Start the workers of the selected run mode automatically (with `--no-tui`) |
| `--dataset`       | Dataset of the run lists in the metadata (`datasets/runlists`) that selects the runs; `default` (every run) when not given |
| `--runmode`, `--rm` | Run mode, `local` or `slurm`, replacing `config.runmode` |
| `--ignore_config` | Use only the command line values of the flags above instead of the config |
| `--log_path`, `-o` | Directory for log files |
| `--theme`         | Color theme of the interface for this start, such as `night-owl` or `juleana`; see [The interface](@ref) |

A flag given on the command line overrides the config value only when it is set; with
`--ignore_config` an absent flag means `false`. Without `--log_path` the logs go to a
new directory in the `jllog` tier, named by the current UTC time.

## Config folder of the data production

JuLeAna keeps what it manages in the folder `setup` next to the file named by
`LEGEND_DATA_CONFIG`: the subfolders `config`, `software` and `metadata`. A production with a
top-level `config`, `software` or `metadata-records` folder is refused with an error that
names the folders to move to `setup/config`, `setup/software` and `setup/metadata`.

The `config` folder of the data production is `setup/config`. Without `--config`, JuLeAna
reads `setup/config/processing_config.yaml` from it. If that file does not exist, JuLeAna creates the
folder and copies the `config/processing_config.yaml` shipped with JuLeAna there first. The folder also holds the worker start script `startjlworkers.sh`.

The "Processor log level" row of the Setup page cycles through "config" (each processor's
own `log_level`), `debug`, `info`, `warn` and `error`. It starts as the level given by
`--processor-log-level` or `processor_log_level` of the config. `w` writes the level to
`config.processor_log_level`, and removes that key when the row is "config".

The "Processor plot level" row works the same way for the plot level: it cycles through
"config" (each processor's own `plot_level`), `debug` and `info`, starts as the level
given by `--processor-plot-level` or `processor_plot_level` of the config, and `w` writes
it to `config.processor_plot_level`.

`w` on the Setup page writes the current settings to `config/processing_config.yaml` of
the data production, after a confirmation; an existing file is kept as
`processing_config.yaml.bak`. That file is then the default config.

## The interface

The tabs at the top open the pages, also with the keys `1` to `8`. `?` shows all keys of
the visible page, `q` or `Ctrl+C` quits (it asks first while processing runs, while the Sync page has unsaved marks, and while it transfers). The status panel under the tabs shows the state
of the session, the outcome of the last run, the workers and the countdown to the cancel
of idle workers, with the newest warning or error on the right; once a processing run
started, a bar below shows its progress and elapsed time. The bottom row lists the keys.

`T` switches to the next color theme: `night-owl` (the default, after the btop theme of
that name), `juleana` (the colors of the logo) and the themes of Tachikoma. The chosen
theme is saved in `prefs/JuLeAna/theme` in the Julia depot and used at the next start;
`--theme` selects one for a single start. The themes use the 256-color palette and leave
the background of the terminal unchanged.

1. **Setup**: select the periods, runs and processors, edit the keyword arguments of a
   processor (`e`) and the options (reprocess, check dependencies, analysis runs only and the
   run mode, `local` or `slurm`, of the next worker allocations; `e` on the Run mode row edits
   the settings of both run modes, see below), start processing (`s`), stop it (`x` after the
   running items, `X` at once), reload the config (`r`), write the settings to the
   config file (`w`), and create a new data production (`N`). The Production pane shows the
   production root, the data production and the dataset. The root is the folder the
   productions are listed under, by default the parent folder of the current production.
   `Enter` or a click on the `Root` line edits it in place: type the path, `Tab` completes it
   (several candidates are listed below the lines), `Enter` sets it (it must be an existing
   absolute folder; `~` is expanded) and `Esc` cancels. While the root is edited, all keys
   go to its text. `Enter` or a click on the other lines opens a list of the productions
   under the root (all folders up to four levels below it that hold a `config.json` or
   `config.yaml`, shown as paths relative to the root; hidden folders and symbolic links
   are skipped, and a production is not searched for further productions) or of the datasets (`default` and the names in the metadata
   `datasets/runlists`). Choosing one cancels the worker allocations and reloads the
   session; it is possible while no processing runs. The Dataset pane below shows the runinfo of the
   period or run under the cursor of the periods.

   `e` on the Run mode row of the Options pane opens the editor of the run mode settings,
   grouped under `local` and `slurm`: the number of local workers (`local_n`, a positive
   integer) and the lists `julia_settings` (local), `flags` and `julia_settings` (SLURM). A
   list has one row per entry, for example `--nodes=1`. `Up` and `Down` move, `Enter` edits
   the number or entry under the cursor (and adds an entry on the heading of a list), `a`
   adds an entry to the list under the cursor, `d` deletes the entry, and `Esc` closes the
   editor. While a value is typed, `Enter` applies it with [`SetRunmodeSettings`](@ref) and
   shows an error for an invalid value, and `Esc` drops it. The settings apply to the
   next worker allocations and the start script of the session, and `w` writes them to the
   config file.
2. **Graph**: the processors with their dependencies, run-level processors on the left
   and partition-level processors on the right. `Space` selects a processor, `d` adds the
   steps that selected steps wait for, and `v` switches the state icons between the last
   run and the state on disk.
3. **Workers**: the worker allocations and the workers, see [Workers](@ref running-workers).
4. **Progress**: the steps of the processing run by period and run, with their state; `Enter`
   on a step shows its messages.
5. **Log**: the messages of the session, filtered by level (`l`) or text (`/`).
6. **Reports**: the Markdown reports of the steps, in processing order, and the failures
   they list; `Enter` opens a report. How a report counts as ok, warn or fail is described
   under [Report status](@ref). The first entry, if the file exists, is the
   processing history `history.md`.
7. **History**: the processing state of every processor in the runs on disk. The columns are
   the periods and runs selected in the session; `a` switches to all periods and runs of the
. **Sync**: the data sync tool, see [Data sync tool](sync.md). The page is created when the tab is first shown.

Every processing run appends a section to `history.md` in the `jllog` tier. The History
page and the `v` view of the Graph page show the state on disk, also from earlier sessions.

## [Workers](@id running-workers)

Processing runs on worker processes, which connect to the running `juleana` process.
The interface starts workers only on request: `a` on the Workers page, or `W` on the
Setup page, starts a worker allocation by running the start script `startjlworkers.sh`
in the `setup/config` folder of the data production. JuLeAna regenerates the script for every
session from the processing config; it holds the cookie and the address of the running
process. The Workers page shows and edits the script (`e`, `Ctrl+S` saves); edits apply to
the session.

An allocation is a group of workers started by one run of the script, local or as SLURM
jobs. An allocation runs in its own process group. `c` cancels the selected allocation and
`C` all allocations, after a confirmation; a cancel ends the processes and cancels the
SLURM jobs that carry the job name of the allocation. Quitting `juleana` cancels all
allocations.

Idle allocations are cancelled after `idle_timeout_minutes` of the
[config](@ref Configuration) (default 20, `0` disables) without processing. The status panel under the tabs
shows the countdown; `p` on the Workers page postpones the cancel.

## Running on a login node

On a cluster, `juleana` runs on a login node and manages the production, while the
processing runs on compute nodes. Start it inside `tmux` or `screen` so that it keeps
running when the SSH connection ends:

```bash
tmux new -s juleana
juleana
```

Detach with `Ctrl+b d` and attach again with `tmux attach -t juleana`.

### SLURM workers

In the `slurm` run mode the start script submits SLURM jobs with the settings of
`runmode_settings.slurm` in the config, such as the number of nodes. `o` on the Workers
page opens a form of the common options: partition, time limit, nodes, workers per node
(`--ntasks-per-node`), threads per worker (`--cpus-per-task`) and memory per node
(`--mem`). `Enter` edits the option under the cursor, and an empty value removes it. The
form changes the SLURM flags of the session, like the editor of the run mode settings on
the Setup page (`e` on the Run mode row), and `w` on the Setup page writes them to the
config. The script on the Workers page can also be edited directly. Start further
allocations with `a`; running allocations keep their settings. The settings can also be
changed during a processing run, for the allocations started afterwards.

## Creating a data production

A data production is a folder with the metadata, the generated output and a data config
file. `juleana --new-production` opens the interface on a form for a new one, and `N` on the
Setup page opens the same form. Without `--config` and without `LEGEND_DATA_CONFIG`, the
interface opens on the form as well and loads no session.

The form asks for

- the name and the parent folder (by default the folder that holds the current production),
- the URL of the `legend-metadata` repository,
- whether to check out branches in the metadata and which ones: a branch or tag of the
  whole `legend-metadata` repository (empty by default; all submodules are then updated to
  the commits it records), then the `jldataprod` branch for the `jldataprod` config and
  overrides submodules and the `dataprod` branch for the metadata and its other submodules
  (both `main` by default, applied on top of the first; empty branches are not checked out),
- extra tier paths, `label` and folder of tiers that are kept elsewhere,
- parameter folders to copy, each with a `rpars` or `ppars` component in its path,
- whether to set the new production as the default in the startup file of the shell
  (`.bashrc` or `.zshrc`, by `$SHELL`), and
- whether to copy the software into the production (yes by default).

`↑`, `↓` and `Shift-Tab` move between the fields, `Tab` completes the path in a path field
(parent folder, extra tier path, parameter folder), lists the folders that match and moves to
the next field when there is nothing to complete, typed characters and `Backspace` edit a text
field, `Space` or `Enter` flips a yes/no field, `Ctrl-N` adds a row to the list under the
cursor and `Ctrl-D` removes it, `Ctrl-O` creates the production and `Esc` closes the form.
The input is checked first and the first problem is shown in the form. An existing folder
is refused.

The production folder `<parent>/<name>` then holds

- `legend-metadata`, a recursive clone of the metadata with the chosen branches checked out,
- the folders `generated/{tier,jllog,jlplt,jlreport,jlpar/rpars,jlpar/ppars}`,
- `config.yaml`, the data config with one `tier/<label>` entry per extra tier path,
- the copied parameters in `generated/jlpar`,
- `setup/software`, with one subfolder per recorded state of the software: a copy of the JuLeAna
  checkout and of the other developed packages of the running environment, each a git
  repository with one commit, a manifest that refers to the copies, `SNAPSHOT.toml` and
  `PROVENANCE.md` with the source folder, commit and uncommitted changes of each package
  (see [`JuLeAna.record_software`](@ref) and [`JuLeAna.snapshot_software`](@ref)), and
- optionally the line `export LEGEND_DATA_CONFIG=<production>/config.yaml` in the shell
  startup file, replacing earlier lines that export the variable.

The form shows the log of the creation. Afterwards this process uses the new production:
it cancels its worker allocations, sets `LEGEND_DATA_CONFIG` and loads a session from it.

## Reproducing a production

Every processing run first records the software of the process in the `setup/software` folder
of the production (the folder that holds the data config), see
[`JuLeAna.record_software`](@ref). A new snapshot is kept if its `fingerprint` in
`SNAPSHOT.toml`, computed from the Julia version and the git trees of all copied packages,
differs from that of every existing snapshot; otherwise the existing snapshot is reused.
The run fails if the recording fails. The subfolder is named
`<date>-<JuLeAna commit>`, with `-modified` if JuLeAna had uncommitted changes. The
processing history names it in the software line of the run, for example
`Software: JuLeAna 0.2.0 (bab9df2), Julia 1.12.7, snapshot setup/software/2026-10-22T100704Z-bab9df2`.

To run the software of a run again, use that snapshot:

```sh
cd <production>/setup/software/<snapshot>/JuLeAna.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
export LEGEND_DATA_CONFIG=<production>/config.yaml
julia --project=. -m JuLeAna --no-tui ...
```

`Pkg.develop(path = "<snapshot>/JuLeAna.jl")` and `Pkg.add(path = "<snapshot>/JuLeAna.jl")`
install the snapshot into another environment; `add` installs the committed tree.
`Pkg.Apps.develop(path = "<snapshot>/JuLeAna.jl")` replaces the globally installed
`juleana` app.

Every run also records the metadata in the `setup/metadata` folder of the production, see
[`JuLeAna.record_metadata`](@ref): the commit of `legend-metadata` and of each of its
submodules, the uncommitted changes of each as a patch, its untracked files (copied up to
1 MB, larger ones by their git hash only) and copies of the data config files and the
processing config. The metadata is only read with git. As for the software, a record with
the same `fingerprint` in `METADATA.toml` is reused, the run fails if the recording fails,
and the subfolder is named `<date>-<metadata commit>`, with `-modified` if anything was not
committed or a submodule was not at the commit the metadata records. The history names it in
the line `Metadata: setup/metadata/<record>` of the run. The `PROVENANCE.md` of a record
lists the commands that restore the metadata: clone it, check out the recorded commits,
apply the patches and copy the untracked files back.

## Updating

Update JuLeAna and the LEGEND packages in the environment of the app with

```julia
import Pkg
Pkg.Apps.update("JuLeAna")
```

For an app installed with `Pkg.Apps.develop`, pull the checkout first. The update also
updates the dependencies in the `Project.toml` environment of the checkout.
