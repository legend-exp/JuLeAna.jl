# ![JuLeAna](logo/juleana.png) 
# Dataflow
This package contains the main dataflow scripts to run the analysis for LEGEND-200 data in julia.
It consists of a dataflow implementation to run an analysis on a [SLURM](https://slurm.schedmd.com)-based cluster system including following features:
- Parallel processing of data based on [ParalellProcessingTools](https://github.com/oschulz/ParallelProcessingTools.jl) to interactively connect new SLURM processes to a running `julia` session.
- Data processing of all `tier` up to the `evt` level.
- Automated report generation based on Markdown files with high level overview of each processing step.
- Automated plot generation of monitoring and analysis plots.
- Automated `pars` generation with `validity` flagging
- Partition and run based processing with automated dataflow control.
folder.

# Quick Start
To start the processing just execute the `main.jl` script with the julia interpreter.
``` bash
julia main.jl -c config/processing_config.json
```
You should consider to put all necessary packages in a single environment. The current standard environment is found in the `Project.toml` and `Manifest.toml` files in the dataflow folder and will be automatically activated if no other project is specified. 

# Command line options
The script also offers command line options to have a handy way of processing things in the command line. A help menu is available in the command line with the `--help` flag. The following options are availbale at the moment:

| Command           | Description         |
|-------------------|---------------------|
| `--config`, `-c`  | Path to config file |
| `--periods`, `-p` | Periods to process |
| `--runs`, `-r`    | Runs to process |
| `--partitions` | Partitions to process |
|`--reprocess`      | Reprocess all channels while deleting old data, overwrite all `reprocess` flags |
| `--only_runs`     | Process only runs ignoring periods and partitions |
| `--only_partitions` | Process only partitions ignoring periods and runs |
| `--analysis_runs_only` | Process only runs which are marked as analysis runs |
| `--submit_slurm` | Automatically add a SLURM process to the session |

# Debug mode
To enable the `debug` mode for fast and interactive dataflow debugging and testing, the `-i` flag for `interactive` has to be passed as argument upfront the `main.jl` script.
``` bash
julia -i main.jl -c config/processing_config.json
```
This will start a `debug` menu with the following options:
- **Execute Processors**: Execute individual processors which can be selected from two sub-menus consisting of `processors` and `p-processors`. Additionally, the `reprocess` flag as well as a `check_dependency` flag can be set globally.
- **Reload Processors**: Reload all processor scripts from disk. Good to modify scripts without exiting session.
- **Select Periods**: Select periods which should be processed.
- **Reload processing config**: Reload processing config and `argparse` new from disk. Good to modify `processor` and `p-processor` settings without exiting session.
- **Reset dependency graph**: Reset the dependency graph and restore initial graph before any processing happened and recheck all dependencies.
- **Submit Workers**: Submit new workers to the session. This can be useful to add new workers to the session without exiting the session.
- **Exit**: Exit the debug menu and continue with the processing.

The `debug` menu can be exited with the `Ctrl+c` command.
It can also be manually invoked by calling `menu()` in the julia REPL.

# Setup
To set up the dataflow, you need to have a running `julia` configuration on a login node of a SLURM based cluster with the corresponding acces to the *LEGEND data*. To help you set this up, the folder `setup/` contains helper scripts based on `bash` to guide you through the setup process. 

## Installation
To install your own julia on a cluster and do all necessary pre-steps to be able to process data, you can find a more detailed introduction to Juleana and the setup process in the [How-to-Legend](https://github.com/LisaSchlueter/HowTo-Legend/tree/main) repository including detailed instructions on how to setup things on different clusters. 

**Important**: Before you can run any of the code, you need to make sure that you activated the production environment once and installed all necessary packages. You can do this by running the following command:
``` julia
import Pkg; Pkg.activate("path/to/legend-julia-dataflow")
Pkg.instantiate()
Pkg.precompile()
```

## Production environment
If you want to run the dataflow, you a need a place to store the output of your data production. This is called a prodcution environment. Since it does not only contains your generated data, but also input data like e.g. `legend-metadata`, it requires a certain structure. To help you guide through that process, a bash script is provided `setup/production.sh` to guide you trhough that process. You can run it with the following command:
``` bash
bash setup/production.sh
```
It will ask for the new production name and folder and then create the necessary structure for you. It is sometimes necessary to link certain data folders to different locations to avoid copying the data multiple times. This can be done within the setup process automatically.

## Tmux environment
To run the dataflow, the `main.jl` script will be executed on a login node providing only simple production management functionality while the actual processing happens on the compute nodes. To avoid the script from stopping when you close the terminal, it is recommended to use a `tmux` session. To help you set up a tmux session, a bash script is provided in the `setup/` folder. You can run it with the following command:
``` bash
bash setup/tmux.sh
```
It will create a new tmux session with the name `Juelana` and several windows for the different tasks. You can then attach to the session with `tmux attach -t Juelana` and detach with `Ctrl+b d`. In the `monitoring` window, you will find a current overview of free nodes and jobs in the SLURM queue from your user. This will help you monitor the progress of your jobs and check how many free resources are available and can be accessed by you.

## SLURM integration
After you set up a tmux session, you can start the dataflow by running the `main.jl` script with the julia interpreter in the first window. This will start the dataflow and give you information about the running steps in the terminal. However, this will not start any SLRUM processes for you. So to say, the script will wait at the beginning for new workers which the user has to add manually. This can be done with the `startjlworkers.sh` which the dataflow will write automatically to the dataflow folder. Here, you can find the slurm settings to add workers to the running julia session. You can run the script with the following command:
``` bash
bash startjlworkers.sh
```
Feel free to edit the settings in the script e.g. the number of nodes etc. It is also possible to run the script multiple times to add more workers to the running julia session. This is why the SLURM tab in the tmux session has multiple panes.

**Info** If you activate the `submit_slurm` option, the script will automatically add a new SLURM process to the running julia session. This can be useful to automate the process of adding new workers to the session.

# Configuration File
To comunicate with the dataflow, you need to set up a configuration file. An example can be found in the `config/` folder.
The `processing_config.json` file can be used to set up your own specific analysis chain in a simple JSON format. The file contains the following fields:
## `config`
In the config section, you can pass `ENV` environemnt variables, slurm settings and julia settings. 
1. **`env_variables`**: field can be used to pass environment variables to the analysis. This can be useful to set up the analysis for different data sets. For a stable analysis, you should always set the `JULIA_WORKER_TIMEOUT` variable for `ParallelProcessingTools` and the `GKWSwstype` variable for the `GR` plotting backend. In addition, it can be useful to set the `JULIA_DEBUG` variable to enable debugging information for different packages.
2. **`slurm_settings`**: field can be used to pass options to the slurm processors. All available options can found in the [SLURM documentation](https://slurm.schedmd.com). Please also refer to the documentation of the specific cluster you are using and adapt the settings appropriately.
3. **`julia_settings`**: field can be used to pass options to the julia interpreter. This can be useful to set additional settings for the julia interpreter such as `--heap-size-hint` etc. Please refer to the [`julia` documentation](https://docs.julialang.org/en/v1/manual/command-line-interface/) for all available options.

## `processing`
In the processing section, you can set which `periods` and `runs` you wanna process in your chain as well as different general settings. You can either pass an array with the corresponding run, period and partition numbers in any combination or just use the `"all"` keyword to process all available data such as e.g.
``` json
"processing": {
    "periods": [3],
    "runs": ["all"],
}
```
which will process all available runs in period 3 and only partition 1. You can also use the `"all"` keyword for all fields to process all available data.

Other options are:
1. **`analysis_run_only`**: flag can be used to only process runs which are set as `analysis_run` in the `legend-metadata`. This can be useful to only process runs which have passed quality criteria and are accepted as to be used in the final analysis.
2. **`only_runs`**: flag can be used to only process runs ignoring partitions processors.
3. **`only_partitions`**: flag can be used to only process partitions ignoring runs processors.
4. **`submit_slurm`**: flag can be used to automatically add a new SLURM process to the running julia session. This can be useful to automate the process of adding new workers to the session.

## `processors` and `p_processors`
In the processors section, you can set which processors should be used in the analysis chain.

**Info**: It is necessary to have at least one entry.

You can configure the `processors` section with the following layout
``` json
"process_dsp_cal": {
            "enabled": true,
            "n_workers": "all",
            "category": "cal",
            "rank": 5,
            "kwargs": {
                "reprocess": true,
                "max_wvfs": 1000,
                "timeout": 0,
                "use_partition_filter": true
            },
            "dependencies": ["p_process_aoe_optimization"]
        },
```
which will result in adding the `process_dsp_cal` processor to the list and process it according to its settings. 

**Info**: The `p_processors` work in a similar manner as the `processor` with the one difference that they act on partitions rather then runs.

The following fields are available:
1. **`enabled`**: flag can be used to enable or disable the processor in the chain.
2. **`n_workers`**: field can be used to set the number of workers for the processor. This can be set to `"all"` to use all available workers which will result in a worker pool with the size of the number of channels/filekeys.
3. **`rank`**: field can be used to set the rank of the processor in the chain. This can be useful if the order of the processing matters. The processors will be sorted by the rank and then processed in this order.
4. **`category`**: field can be used to set the category of the processor. This is important to tell the dataflow if the processor is acting on `cal` or `phy` data.
5. **`kwargs`**: field can be used to pass additional keyword arguments to the processor. This can be useful to set specific settings for the processor. Please refer to the processor documentation for all available options.
6. **`dependencies`**: field can be used to set dependencies to other processors. This can be useful if the processor needs to wait for a *partition* processor to finish before it can start. The processor will only start if the *partition* processor (and all lower ranks) has finished successfully.

# Data sync tool

`sync.jl` mirrors part of a remote LEGEND data production onto this machine so
that the dataflow and the analysis scripts can be developed against real data
without an open session on the cluster. The mirror keeps the remote layout, so
`LegendDataManagement` opens it with the config the tool writes beside it.

``` bash
julia --project=. sync.jl --production test
```

`--production` is the production's path relative to the remote root, for example
`test`, `temp/jl-v0.6.0dev5` or `juleana/tmp/jl-v0.7.0dev1`. Without it, the
interface opens on a picker that lists every directory with a `config.json`
within three levels of the root (`↑` `↓` move, `enter` opens, `q` quits).

This opens a terminal interface:

- The left pane is the production's tree: its `config.json`, then one branch per
  configured path key. Directories are listed when you open them, so nothing
  walks the cluster's filesystem up front.
- The right pane describes the row under the cursor and lists the keys.
- The status bar's left span shows what the current selection would transfer;
  its right span shows where the selection will be saved, relative to
  `config/sync`.

| Key | Action |
|-----|--------|
| `↑` `↓` `home` `end` | Move the cursor |
| `enter` | Expand or collapse; lists the directory the first time |
| `space` | Copy this row (`[x]`), or stop copying it |
| `l` | Reach this row through the mount instead (`[~]`); needs `--mount-root` |
| `n` | On a run directory: copy the first N filekeys |
| `x` | On a detector row below a `detectors` row (of a run or of a period): extract this detector (`[e]`), or stop extracting it |
| `e` | Ask rsync exactly what the selection would move |
| `t` | Estimate, confirm, and transfer |
| `s` | Save the selection to `config/sync/<production>.yaml` |
| `q` | Leave, offering to save first |
| `ctrl+c` | Same as `q`, outside a dialog |

A `[-]` marker means the row itself is not selected but something below it is.
While a transfer is running, the interface accepts no key until it finishes.
A successful transfer's summary ends with any warnings rsync printed.

## Extracting detectors

Per-filekey tiers such as `jldsp` and `raw` store all detectors of a time slice
in one HDF5 file, so copying one detector's data for a run means copying the whole
run. Extract mode transfers only the chosen detectors' groups, in files that keep
their original names and sit at their original paths in the mirror. Both group
layouts of the productions are supported and need no setting: `<detector>/<tier>`
(the top-level groups are the detectors, as in jl-v0.4.0) and `<tier>/<detector>` (one
top-level group named after the tier whose children are the detectors, as in
jl-v0.8.0). The tool decides per file: if a top-level group name is a detector name
(a detector id such as B00000C or a channel id such as ch1110402), the top-level
groups are the detectors; otherwise, if the file has exactly one top-level group and
one of its children is a detector name, the children are the
detectors; otherwise the file has no detector axis (`jlevt`, `jlskm`, `jlpmt`). A
reduced file of the second layout contains the tier group with its attributes and the
chosen children.

Open a run directory of such a tier. Its `detectors` row is the first row below the
run, above the filekey rows; press `enter` on it. The
tool inspects the first file of the run on the host and lists its detectors with
their sizes. Move onto a detector and press `x` to mark it `[e]`. A period directory
(a directory with run directories `r000`, ... of which at least one holds filekey
files) has a `detectors` row too, above its run directories: it lists the union of
the detectors of the first file of every run, sized by the first-file bytes times the run's file count summed
over the runs that hold the detector, and `x` on one of its rows extracts that
detector from every run of the period. The run-level row of a detector that the
period extracts shows the inherited `[e]` and cannot be toggled; unmark the period
row instead. A run-level and a period-level mark for the same detector may coexist;
the plan merges them per run, so nothing is extracted twice. The status bar shows the
approximate extracted size (`~1.2 G extract (2 files)`: the sizes in the first file
times the number of files); `e` inspects every file and shows the exact size, the
free space of the staging directory and the detectors left out (see below).
`space`, `l` and `n` on a detector row only point to `x`. A copy or link mark and an
extract mark never cover the same run. A run-level detector mark is refused while its
run, its period or a directory above is copied or linked. A period-level detector mark
is refused while any run that holds the detector, or the period or a directory above,
is copied or linked; runs that do not hold the detector do not matter. Marking a run,
a period or a directory above them with `space` or `l` is refused while a detector
mark below covers that run (a period-level mark covers the runs that hold the
detector). The status line names the detector, its directory and the mark that blocks
it. Filekey rows of the same
run can still be marked for copying: a file that is copied whole is left out of the
extraction. A directory whose first files have no detector axis has no `detectors`
row after the inspection. The detector list of a run comes from its first file; if a
later file of the run lacks a chosen detector, the extraction aborts with a message
naming the detector and the file.

When a detector is extracted for a period and a run does not hold it, that run is
left out for that detector and the pair is reported as "not in run" (in the exact
estimate, the headless estimate and the summary, as `<detector> in <run>`). A run
that holds none of the chosen detectors gets no job. A run directory of the period
without tier files, and a run whose first file has no per-detector groups, are reported
the same way, as "not in run" for every chosen detector, so a processing gap shows up
there as well. Nothing else is left out of the extraction without a message, except
files that a copy mark already covers.

Extraction runs on the host. A helper script (`src/sync/remote/extract.jl`) is
copied to the staging directory and run with the host's Julia. It copies the chosen
groups with `HDF5.copy_object` into a reduced file of the same name in the staging
directory (no decoding, attributes preserved), using worker processes for runs with
many files. rsync then pulls the staging directory into the mirror with the same
flags as every other transfer, and the tool removes the files it staged. Reduced
files carry the root attributes `juleana_sync_groups` and `juleana_sync_source`. A
staged file that already holds the same groups and is not older than its source is
not extracted again, so an interrupted extraction can be run again.

An interrupted transfer leaves `.juleana-partial` directories in the mirror (the
`--partial-dir` of every transfer); running the same selection again resumes from
them. After a failed transfer the staged files stay on the host, and the error names
the staging directory.

A reduced file never replaces a full local copy and is never written through a
symlink. When the local file is a full copy, or the file or any directory above it in
the mirror is a symlink, the tool reports the path in the summary ("kept N existing
files instead of extracting") and skips it. A reduced file from an earlier extraction
is rebuilt with the union of the old and the new groups, so a later extraction never
loses groups. The summary of an extraction reads `extracted N files, N groups`,
followed by the bytes rsync moved for them.

The interface accepts no key while it checks the helper environment, creates it, or
transfers. During a transfer the gauge reads `extracting k/N files` while the helper
runs and shows the rsync progress afterward.

### Remote setup

Per host, `config/sync/hosts.yaml` accepts these optional keys next to `remote_root`:

| Key | Default | Meaning |
|-----|---------|---------|
| `julia` | `~/.juliaup/bin/julia` | Julia executable on the host |
| `julia_project` | `~/.julia/environments/juleana-sync` | Environment with HDF5 and ParallelProcessingTools |
| `staging` | `${TMPDIR:-/tmp}/juleana-sync-$(id -un)` | Staging directory (an absolute path or one starting with `~`); set it to a scratch area (for example `/ptmp/<user>/juleana-sync`) when `/tmp` on the login node is small |

`hosts.yaml` is tracked in git; the selections saved under `config/sync/` are
git-ignored. The free space of `/tmp` on `viper` has not been measured; if a run's
selection does not fit there, set `staging` for `viper` to a directory below
`/ptmp/<user>/`.

When the environment is missing or lacks a package, the interface shows the
`Pkg.add` command and asks before running it (`Create` or `Cancel`). `Create` only
works when the environment directory does not exist: the tool never modifies an
existing environment and refuses it with an error. Add the missing packages yourself
or name another `julia_project`. A headless run reports the same command as an error.
The estimate measures the free space on the nearest existing ancestor of the staging
directory and leaves only the helper script and an empty `jobs/` directory in the
staging root.

`--jobs N` allows at most N worker processes, capped by the file count (N of 2 or
more uses workers whenever there are two or more files; a single file always runs in
the main process). A negative or non-integer N is rejected. Without it the helper
runs in the main process for fewer than four files and otherwise uses
`min(8, files, cores ÷ 2)` workers. `--staging PATH` overrides the staging directory; PATH is a path on the host, absolute or starting with `~`.

## Command line options

| Option | Description |
|--------|-------------|
| `--host ALIAS` | ssh alias of the machine holding the production (default `cslg4`) |
| `--remote-root PATH` | Remote directory holding the productions (default: the entry for `--host` in `config/sync/hosts.yaml`) |
| `--local-root PATH` | Local directory mirroring it (default `../data` next to this checkout) |
| `--mount-root PATH` | Where the remote root is mounted; enables link mode |
| `--production PATH` | Production to sync, relative to the remote root (default: choose in the interface) |
| `--out FILE` | Where the interface saves the selection (default `config/sync/<production>.yaml`, with `/` in the production path replaced by `-`); the name must end in `.yaml` |
| `--jobs N` | Worker processes the remote extraction helper may use (default: the helper decides) |
| `--staging PATH` | Staging directory on the host for extraction (default: the host's `staging` key, else `${TMPDIR:-/tmp}/juleana-sync-$(id -un)`) |
| `--from FILE` | Apply a saved selection without starting the interface; the production is taken from the selection unless `--production` is given, in which case the two must agree; a selection saved as `.json` is read as well |
| `--dry-run` | With `--from`: ask rsync what would move and print it, then stop |
| `--yes` | With `--from`: transfer without asking |

## Hosts, layouts and site overlays

The remote root of each host is listed in `config/sync/hosts.yaml`, so
`--host viper` works without `--remote-root`. The productions sit at different
places on the two sites:

- `cslg4`: `test/`, `temp/<name>/`, `ref/<name>/` and `preprod/...` below the
  root.
- `viper`: `juleana/{auto,preprod,ref,tmp}/<name>/` below the root, with the raw
  data at `raw-compressed/` beside `juleana/`.

Each site keeps a config next to its productions that redirects some path keys,
for example `config_cslg4.json` in the root of `cslg4` and `config_viper.yaml` in
`juleana/` on `viper`. The tool applies every file named
`config_<site>.json`, `.yaml` or `.yml` in the directories from the remote root
down to the parent of the production. The production's own `config.json` is read
first, then the overlays from the root downwards. A later file wins, so each
overlay overrides the production and a deeper overlay overrides a shallower one.
`$_` expands to the directory of the file it is written in. The overlays are
always copied with the production, and `config_local.yaml` is derived from the
merged config. The row of the production in the interface lists the overlays
that were applied.

## Re-applying a selection

``` bash
julia --project=. sync.jl --from config/sync/test.yaml --yes
```

The saved selection lists only the rows that were chosen explicitly, so it stays
readable and keeps working as new runs appear under a chosen directory.

## Requirements

- GNU `rsync` 3.1 or newer on this machine. macOS ships Apple `openrsync`, which
  has neither `--info=progress2` nor a readable `--stats`; install GNU rsync with
  `brew install rsync` and put it ahead of `/usr/bin` in `PATH`. The tool refuses
  to start otherwise rather than transferring without progress or totals.
- `ssh` access to the host, and GNU `find`, `du` and `rmdir` on it (all present
  on `cslg4`).
  The tool runs `ssh` in batch mode and gives it and `rsync` no terminal input: a
  connection that would need a prompt (password, passphrase, host-key confirmation)
  fails at once with ssh's error. For hosts that need interactive authentication,
  open the connection in a terminal first (`ssh <host>`).
- For extraction, Julia on the host (`~/.juliaup/bin/julia` by default) and an
  environment with HDF5.jl and ParallelProcessingTools.jl; neither host needs
  `h5ls`, `h5copy` or h5py.
- A copied directory's remote symlinks, such as a `current` pointer, are
  mirrored as symlinks rather than resolved.

## Link mode

A linked row is not copied: the tool puts a symlink at its place in the mirror
pointing into `--mount-root`, where the remote filesystem is mounted (with
`sshfs`, `rclone mount`, or anything else). Syncing `jlevt` for a run and linking
`tier/raw` for the same run gives a mirror where every file is at its usual path:
the analysis tiers are local, and reading a few waveforms out of a raw file goes
through the mount. With the mount absent, opening a linked file fails with
`ENOENT` rather than appearing to succeed.

## What the tool never does

It never writes to a remote data production, never deletes local data, and never
rewrites the mirrored `config.json`. On the remote host it writes only below its own
staging directory, apart from the Julia environment it offers to create (see above),
and the only files it removes there are the ones it staged.
Locally, the only things it removes are symlinks: one standing where a real copy is
about to land, and one standing where a fresh link is about to replace it. A regular
file or a directory is never removed. The one exception to never replacing a file is
a reduced file written by the tool itself, which is rebuilt with the union of its
old and new groups. The local
config it writes is a sibling, `config_local.yaml`, so the mirror stays
byte-identical to the remote.
