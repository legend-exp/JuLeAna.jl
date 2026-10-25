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
| mouse wheel | Scroll the tree or the production picker |
| left click | Select a row; a click on the selected row does what `enter` does |
| `space` | Copy this row (`[x]`), or stop copying it; on a detector row of a per-detector tier, copy that detector's files |
| `l` | Reach this row through the mount instead (`[~]`); needs `--mount-root`; on a detector row of a per-detector tier, link that detector's files |
| `n` | On a run directory: copy the first N filekeys |
| `x` | On a detector row below a `detectors` row of a per-filekey tier (of a run or of a period): extract this detector (`[e]`), or stop extracting it |
| `e` | Ask rsync exactly what the selection would move |
| `t` | Estimate, confirm, and transfer |
| `s` | Save the selection to `config/sync/<production>.yaml` |
| `q` | Leave, offering to save first |
| `ctrl+c` | Same as `q`, outside a dialog |

A `[-]` marker means the row itself is not selected but something below it is.
While a transfer is running, the interface accepts no key until it finishes.
The mouse is ignored while a dialog is open or the interface is busy.
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
`space`, `l` and `n` on a detector row of a per-filekey tier only point to `x`. A copy or link mark and an
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

### Detector files of per-detector tiers

Tiers such as `jlqcs`, `jlpks`, `jlaux` and `jlhit` hold one file per detector and run,
named like `l200-p16-r000-cal-B00000C-tier_jlqcs.lh5`; each run directory already
shows one row per detector file. A period directory whose first run directory with
tier files holds such files has a `detectors` row above its run directories. `enter`
on it lists every run directory of the period (one directory listing per run, no
remote helper, no HDF5, no environment check) and shows the union of the detector
names, each sized by the sum of its files over the runs. The details pane names the
runs that hold the detector.

On such a detector row `space` copies the detector's files from every run of the
period and `l` links them, both through the usual rsync run and mount root; `x` is
refused, because there is nothing to extract from a file that holds one detector. The
run-level row of that detector shows the inherited `[x]` or `[~]` and cannot be
toggled or excluded; unmark the period's detector instead. Other detectors of the same
run and other runs can still be marked. A period-level mark and a whole copy or link
exclude each other as extraction does: the mark is refused while the period, a run that
holds the detector, a directory above, or one of the detector's files is copied or
linked, and copying or linking a run, the period or a directory above is refused while
a detector mark covers it. A copy mark and a link mark for the same detector and
period cannot both exist.

A directory holds one kind of tier file. A run directory with both filekey files and
per-detector files is an error that names the run and one file of each kind. In a
period the first run directory with tier files decides which kind the `detectors` row
lists; a run of the other kind contributes nothing to the row and is reported as "not
in run" when the selection is planned. A run with two files for one detector is an
error naming the run and both files.

The selection stores the marks by intent, under the `detector_files` key of the YAML
file (`dir` is the period directory relative to the remote root):

```yaml
detector_files:
  - dir: juleana/jl-v0.8.1/generated/tier/jlqcs/cal/p16
    detectors: [B00000C, V01234A]
    mode: copy
```

The files are looked up when a transfer or estimate is planned, so a run added after
the selection was saved is included. A run without a file for a detector is reported
as "not in run" (`<detector> in <run>`, in the estimate, the headless output and the
summary), as is a run directory without per-detector files; a period without any
per-detector file is an error naming the entry. A file that the copy list already
covers is not transferred twice. The status bar counts a marked row once, with one
file or link per run that holds the detector.

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
