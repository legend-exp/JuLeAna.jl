# Data sync tool

The data sync tool mirrors part of a remote LEGEND data production onto this machine so
that the dataflow and the analysis scripts can be developed against real data
without an open session on the cluster. The mirror keeps the remote layout, so
`LegendDataManagement` opens it with the config the tool writes beside it.

The tool has one screen and two ways to open it:

- `juleana-sync` opens the screen alone.
- Tab 8 "Sync" of `juleana` shows the same screen next to the dataflow pages.

``` bash
juleana-sync --host viper --production juleana/tmp/jl-v0.7.0dev1 --local-root ~/data
```

The apps are installed with `Pkg.Apps.develop(path = "path/to/JuLeAna.jl")`, which creates `juleana` and `juleana-sync`; `julia --project=. -m JuLeAna.Sync` runs the second one from a checkout.

`--production` is the production's path relative to the remote root, for example
`test`, `temp/jl-v0.6.0dev5` or `juleana/tmp/jl-v0.7.0dev1`. Without it, the
screen lists every directory with a `config.json` or a `config.yaml` up to three directories below the
root and opens a list to choose from (`↑` `↓` move, `enter` opens, `r` lists again, `esc`
closes it).

## Sync configuration

The tool reads and writes in the directory `$XDG_CONFIG_HOME/juleana/sync` (`~/.config/juleana/sync` when
`XDG_CONFIG_HOME` is not set), called the configuration directory and written `<config dir>` below; the package
directory is never written.

| File | Content |
|------|---------|
| `hosts.yaml` | host aliases with `remote_root` and optionally `julia`, `julia_project`, `staging`; if it is absent, the file shipped in the package's `config/sync` is read |
| `settings.yaml` | optional `local_root: <directory>`, the default of the Local root field |
| `<host>/<production>.yaml` | saved selections, one directory per host; `/` in the production name becomes `-`; the directories are created at the first save |

There is no default Local root: without `local_root` in `settings.yaml` or `--local-root`, the field is empty and
Connect, Estimate and Transfer refuse with "Local root must be set". A selection file anywhere else is loaded by
giving its path in the Selection field and pressing Load selection, or applied headless with `--from`. A selection
records the host its tree was built from; Load and `--from` refuse a file saved for another host and name both hosts.
A malformed file stops `juleana-sync` with a message that names the file; `juleana` shows the message in the
dialog of the Sync tab and keeps running. A `hosts.yaml` entry without `remote_root` is reported the same way when the Sync tab opens with an empty
Production field (the remote roots are read for the preselection), and otherwise at Connect if that host is used.

## The screen

The upper part is the settings panel, the lower part the production tree on the left with the
details pane of the row under the cursor on the right. The last row is the progress line.

### Settings

| Field | Option | Input |
|-------|--------|-------|
| Host | `--host` | an alias from `hosts.yaml` (Tab completes) or any ssh alias; default `cslg4` |
| Remote root | `--remote-root` | a path on the host; empty uses the host's entry in `hosts.yaml` |
| Production | `--production` | `Enter` opens the list of the productions on the host |
| Local root | `--local-root` | a local directory that exists (Tab completes); empty until set here, by `--local-root` or by `local_root` in `settings.yaml` |
| Mount root | `--mount-root` | a local directory, or empty for no link mode (Tab completes) |
| Staging | `--staging` | an absolute path or `~/...` on the host, or empty for the host default |
| Jobs | `--jobs` | an integer, 0 or larger; 0 lets the helper decide |
| Selection | `--out` | a path ending in `.yaml`; empty is `<config dir>/<host>/<production>.yaml` (see Sync configuration); `--from` does not fill it, it applies a saved selection headless |

`Tab` and `Shift-Tab` move through the fields and buttons and then to the tree, the mouse works on
every field and button, `Enter` edits a field and `Esc` cancels. An invalid value stays in the field
with its reason and blocks Connect, Estimate and Transfer. The buttons are Connect (`c`), Load selection
(`o`), Save selection (`s`), Estimate (`e`) and Transfer (`t`); the letter works from the tree and from the panel.
`p`, or a click on the title row, collapses the panel to one line; the panel is also hidden when the
terminal is too low to leave room for the tree.

Connect checks the host, GNU rsync and the productions, and opens the production named in the
Production field or the list to choose from. It runs by itself when the screen starts with valid
settings. A new Host or Remote root connects again, also when a tree is loaded; the Production, Local root and
Mount root reload the tree once a host is connected; with no connection, any change that makes the settings
valid connects.
Load selection needs an open production and an existing file. It asks Replace or Keep when the tree has
unsaved marks, then replaces the marks by the ones in the selection file; if any mark names a
directory or detector that no longer exists, nothing changes and the message names it. Changing the
host, the remote root, the production, the local root or the mount root while the tree has unsaved marks
asks before it discards them (Discard or Keep).

### The tree and its keys

- The tree shows the production's config file (`config.json`, or `config.yaml` for a production that JuLeAna
  created), then one branch per configured path key and, when the production has one, its `setup` folder with
  JuLeAna's processing config (`setup/config`), software snapshots (`setup/software`) and metadata records
  (`setup/metadata`). Directories are listed when you open them, so nothing
  walks the cluster's filesystem up front.
- The details pane describes the row under the cursor.
- When nothing runs, the progress line shows what the current selection would transfer on its left and where the
  selection will be saved on its right (`unsaved: <production>.yaml` until it is saved, `saved: <production>.yaml` afterwards,
  relative to the configuration directory when the file lies in it).

| Key | Action |
|-----|--------|
| `Tab` `Shift-Tab` | Move between the settings panel and the tree |
| `↑` `↓` `home` `end` | Move the cursor |
| `enter` | Expand or collapse; lists the directory the first time |
| mouse wheel | Scroll the tree or the production list |
| left click | Select a row; a click on the selected row does what `enter` does |
| `space` | Copy this row (`[x]`), or stop copying it; on a detector row of a per-detector tier, copy that detector's files |
| `l` | Reach this row through the mount instead (`[~]`); without a mount root the line says "set Mount root"; on a detector row of a per-detector tier, link that detector's files |
| `n` | On a run directory: copy the first N filekeys |
| `x` | On a detector row below a `detectors` row of a per-filekey tier (of a run or of a period): extract this detector (`[e]`), or stop extracting it |
| `c` | Connect: list the productions of the host |
| `o` | Load the selection file; needs an open production and an existing file |
| `s` | Save the selection to the file of the Selection field |
| `e` | Ask rsync exactly what the selection would move |
| `t` | Estimate, confirm, and transfer |
| `p` | Collapse or expand the settings panel |
| `q` | Leave, offering to save first when the selection has unsaved marks; does nothing while a transfer runs |
| `ctrl+c` | Same as `q` outside a dialog; during a transfer it opens the quit dialog |

A `[-]` marker means the row itself is not selected but something below it is.
While a transfer runs, the helper environment is checked or created, or the estimate waits for rsync, only `ctrl+c`
reacts to the keyboard. Every other dialog answers the arrow keys, `Tab`, `Enter` and `Esc`. The mouse is ignored
while a dialog is open.
A successful transfer's summary ends with any warnings rsync printed.

### Progress line

Every long operation reports its steps in the progress line as `[k/N] step`, for example
`[2/4] checking files to copy`. A step with a known total shows a bar and a count, such as
`[1/4] listing detector files 3/12`; extracting on the host adds the bytes staged so far
(`[3/7] extracting on the host 2/5  <bytes>`), and the rsync steps count to 100 and add the rate and remaining time. A step without a
total shows a moving indicator and the elapsed time. The estimate reports listing the detector files of the
selection, planning the extraction, sizing the extract groups, checking the files to copy and the free space of the staging directory.
The transfer reports extracting on the host, copying, pulling the extracted files, creating links and cleaning up
the staging directory. Opening a `detectors` row reports "listing runs" (per-detector tiers), "reading first files" (a period) or
"reading first file" (a run), and loading a selection reports "listing directories".
A failure names the step it happened in. A headless run prints the same steps as updating lines. When nothing
runs, the line shows the running estimate and the selection file.

### In `juleana`

Tab 8 is created when it is first shown, so starting `juleana` costs nothing when the tab is not
used. If the production of the Setup tab lies below the local root, or below the remote root of a host
in `hosts.yaml`, its path relative to that root is offered as the production; Connect then checks the
name against the productions of the chosen host and either opens it or reports that it is not a production on
that host and opens the list. Changing the production on the Sync tab does not change the Setup tab.

The keys of `juleana` (`1` to `8`, `?`, `T`, `q`) keep their meaning on this tab unless a field is being
edited or a dialog is open. `q` or `ctrl+c` asks before leaving when the selection has unsaved marks or a
transfer or an environment creation runs; while one runs the page takes `q`, so use `ctrl+c` then. The dialog lists one line per key that applies:

| Key | Shown when | Action |
|-----|------------|--------|
| `s` | processing runs | Stop after the running items, then quit; the line adds the sync work that is lost (an interrupted transfer or environment creation, the unsaved selection) |
| `w` | the selection has unsaved marks | Save the selection, then quit; if processing or a transfer still runs, the dialog stays open |
| `q` | always | Quit now, ending the processing run and its workers, interrupting the transfer or environment creation and discarding the unsaved selection, as far as each applies |
| `c` | always | Cancel |

`juleana-sync` shows one quit dialog: the "Transfer running" dialog (Quit now or Keep running) when a transfer or an
environment creation runs, otherwise the "Unsaved selection" dialog (Save and quit or Quit without saving), which names
the file the selection would be saved to. Quit now on the transfer dialog does not ask about the marks. `Esc` closes
either dialog without quitting and without saving.

### Running on cslg4

`hosts.yaml` lists `cslg4` and `viper`. To sync from `viper` to `cslg4`, start the screen on `cslg4`,
choose the host `viper` and a local root on `cslg4` (for example under `/mnt/scratch`). `ssh viper` has
to work without a password from `cslg4`. Connect checks the system `rsync` on `cslg4` and names the
version found if it is not GNU rsync 3.1 or newer.

Every ssh connection of the tool gives up connecting after 20 s and ends when the host stops answering for four
15 s probes, so a dropped connection fails after about a minute with ssh's error instead of hanging. ssh never asks for a
password or a one-time code, so a host that needs one, or whose ssh config shares one connection (`ControlMaster`,
as for `viper`), has to be opened first with `ssh <host>`; when ssh cannot reach the host, the error says so.

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
the plan merges them per run, so nothing is extracted twice. The progress line shows the
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

The screen takes no key but `ctrl+c` while it checks the helper environment, creates it, or
transfers. During a transfer the progress line reads `[k/N] extracting on the host d/t` with the staged bytes while the helper
runs and shows the rsync progress afterward (see Progress line).

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
covers is not transferred twice. The progress line counts a marked row once, with one
file or link per run that holds the detector.

### Remote setup

Per host, `hosts.yaml` (see Sync configuration) accepts these optional keys next to `remote_root`:

| Key | Default | Meaning |
|-----|---------|---------|
| `julia` | `~/.juliaup/bin/julia` | Julia executable on the host |
| `julia_project` | `~/.julia/environments/juleana-sync` | Environment with HDF5 and ParallelProcessingTools |
| `staging` | `${TMPDIR:-/tmp}/juleana-sync-$(id -un)` | Staging directory (an absolute path or one starting with `~`); set it to a scratch area (for example `/ptmp/<user>/juleana-sync`) when `/tmp` on the login node is small |

The free space of `/tmp` on `viper` has not been measured; if a run's
selection does not fit there, set `staging` for `viper` to a directory below
`/ptmp/<user>/`.

When the environment is missing or lacks a package, the screen shows the
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
| `--remote-root PATH` | Remote directory holding the productions (default: the entry for `--host` in `hosts.yaml`) |
| `--local-root PATH` | Local directory mirroring it (default: `local_root` in `settings.yaml`; no default otherwise) |
| `--mount-root PATH` | Where the remote root is mounted; enables link mode |
| `--production PATH` | Production to sync, relative to the remote root (default: choose on the screen) |
| `--out FILE` | Where the screen saves the selection (default `<config dir>/<host>/<production>.yaml`, the configuration directory of Sync configuration, with `/` in the production path replaced by `-`); the name must end in `.yaml` |
| `--jobs N` | Worker processes the remote extraction helper may use (default: the helper decides) |
| `--staging PATH` | Staging directory on the host for extraction (default: the host's `staging` key, else `${TMPDIR:-/tmp}/juleana-sync-$(id -un)`) |
| `--from FILE` | Apply a saved selection without starting the screen; the production is taken from the selection unless `--production` is given, in which case the two must agree; a selection saved as `.json` is read as well |
| `--dry-run` | With `--from`: ask rsync what would move and print it, then stop |
| `--yes` | With `--from`: transfer without asking |

## Hosts, layouts and site overlays

The remote root of each host is listed in `hosts.yaml`, so
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
down to the parent of the production. The production's own config file is read
first, then the overlays from the root downwards. A later file wins, so each
overlay overrides the production and a deeper overlay overrides a shallower one.
`$_` expands to the directory of the file it is written in. The overlays are
always copied with the production, together with its config file, its metadata
checkout and, if it exists, its `setup/config` folder, so that `juleana` can process the
mirror with the production's processing config. `config_local.yaml` is derived from the
merged config. A production folder holding both `config.json` and `config.yaml` is
refused, because only one of them can be the config that `LEGEND_DATA_CONFIG` names. The row of the production on the screen lists the overlays
that were applied.

## Re-applying a selection

``` bash
juleana-sync --from <config dir>/cslg4/test.yaml --yes
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

## Transfer speed

rsync runs over ssh, and when the ssh config shares one connection (`ControlMaster`), it uses that
connection with the options the connection was opened with. With `Compression yes`, ssh compresses
everything with zlib on a single core. LEGEND HDF5 files shrink by less than a third, and compressing them
caps the transfer at roughly 15–30 MB/s. Between raven and cslg4 the same file moved at 15 MB/s with
compression and at about 180 MB/s without. The extraction on the host is rarely the slow part: it reduces
hundreds of files in about a minute.

To turn compression off, set `Compression no` in the `Host` or `Match` blocks of `~/.ssh/config` that cover
the host and any jump host (for the MPCDF hosts, both the `gate*` block and the `raven*,viper*` block).
The setting applies to new connections only; close a shared connection with `ssh -O exit <host>` and
open it again with `ssh <host>`.

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
rewrites the mirrored config file. On the remote host it writes only below its own
staging directory, apart from the Julia environment it offers to create (see above),
and the only files it removes there are the ones it staged.
Locally, the only things it removes are symlinks: one standing where a real copy is
about to land, and one standing where a fresh link is about to replace it. A regular
file or a directory is never removed. The one exception to never replacing a file is
a reduced file written by the tool itself, which is rebuilt with the union of its
old and new groups. The local
config it writes is a sibling, `config_local.yaml`, so the mirror stays
byte-identical to the remote.
