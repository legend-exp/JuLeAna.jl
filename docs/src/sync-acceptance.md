# Data sync tool: acceptance checklist

Run against `cslg4` and `viper`. The automated suite never touches the
clusters, so this is where the ssh, rsync and mount paths are confirmed. The
`cslg4` steps use a production chosen in the picker; pick one that holds `jlevt`
data and call it `<production>` below.

Record the date and the outcome of each step in a comment on the pull request.
Do not paste per-detector numbers or plots: sizes, file counts and timings only.

## Prerequisites

- [ ] `rsync --version | head -1` names GNU rsync 3.1 or newer, not openrsync.
- [ ] `ssh cslg4 true` succeeds without a password prompt.
- [ ] The local mirror directory exists and is writable.

## Interface

- [ ] `julia --project=. sync.jl` opens the picker, titled `Productions on cslg4`,
      and lists `test`, `temp/...`, `ref/...` and `preprod/...` productions
      within a few seconds (it shows `listing…` meanwhile).
- [ ] `enter` on a production that holds `jlevt` opens the two-pane layout,
      and the status bar reads `selected: 0 B copy (0 files), 0 links`.
- [ ] The details pane of the production row reads `overlays: config_cslg4.json`.
- [ ] The tree shows `config.json` and one row per configured path key of the
      production, at minimum `metadata`, `par`, `tier`, `tier/jldsp`,
      `tier/jlpks`, `tier/raw`.
- [ ] `enter` on `tier` lists it within a few seconds; the row shows `…listing`
      while the request is out.
- [ ] The listed directories show `…` for their size first, and the sizes fill in
      a moment later while the tree stays usable; a section keeps `…`. While a
      selected directory has no size, the status bar total ends in `?`.
- [ ] In a real terminal, the wheel scrolls the tree and the picker, a click selects a
      row, and a second click on the selected row opens, lists or collapses it like
      `enter`. Clicks do nothing while a dialog is open.
- [ ] Expanding a second directory is visibly faster than the first: the ssh
      connection is being reused.
- [ ] Expanding a period node of `tier/jldsp` lists its run directories at once and
      sizes them (about 27 GB each) with one `du -sb` call in the background; record
      how long the sizes take to appear.
- [ ] Outside a dialog, `ctrl+c` quits like `q` (offering to save first when
      the selection changed). While a transfer dialog is open no key is
      accepted; press `ctrl+c` at the terminal during a transfer and record
      whether the process still exits and what state the mirror is left in
      (partial files under `--partial` are expected).
- [ ] Walking down `tier/jldsp` → `cal` → `p18` → `r000` shows one row per
      detector, labeled with the detector name.
- [ ] Walking down `tier/jlevt` → `phy` → `p18` → `r000` shows one row per
      filekey, labeled with the timestamp, in ascending timestamp order.

## Copy one filekey

- [ ] On the `jlevt phy p18 r000` node, `n` opens the prompt; typing `1` and
      pressing `enter` marks the first timestamp `[x]` and updates the total.
- [ ] `e` shows an estimate whose byte count is within a few percent of the file
      size shown on the row.
- [ ] `t` transfers it; the gauge advances and the summary names the bytes, the
      file count and the `LEGEND_DATA_CONFIG` line.
- [ ] The file is at the mirrored path and its size matches the remote one.
- [ ] `<local-root>/<production>/config_local.yaml` exists;
      `<local-root>/<production>/config.json` is byte-identical to the remote one.
- [ ] Running `t` again transfers 0 bytes.

## Link `tier/raw` for the same run

- [ ] Mount the remote root, for example
      `sshfs cslg4:/mnt/scratch/projects/legend/data/l200 /Volumes/cslg4`.
- [ ] Restart with `--mount-root /Volumes/cslg4`.
- [ ] `l` on the `tier/raw` node for `p18 r000` marks it `[~]`.
- [ ] `t` creates a symlink at the mirrored path pointing into the mount, and
      the summary reads `created 1 links, replaced 0 stale ones`, with no line
      about skipped targets.
- [ ] Without the mount root, `l` refuses and says so in the status bar.
- [ ] With the mount unmounted, a transfer that has links refuses before moving
      anything, naming the mount root.

## Hybrid read

- [ ] `export LEGEND_DATA_CONFIG=<local-root>/<production>/config_local.yaml`
- [ ] In Julia: `using LegendDataManagement; l200 = LegendData(:l200)` and read
      the copied `jlevt` file through it.
- [ ] Read a waveform from the linked `raw` file for the same filekey; it goes
      through the mount and succeeds.
- [ ] Unmount and read it again: it fails with `ENOENT`, which is the intended
      behavior: the tool never pretends data is there.

## Headless re-apply

- [ ] `s` in the interface writes `config/sync/<production>.yaml`, with `/` in
      the production path replaced by `-`.
- [ ] `julia --project=. sync.jl --from config/sync/<production>.yaml --dry-run`
      prints an estimate of 0 bytes, because everything is already there; no
      `--production` is needed.
- [ ] Delete one copied file and re-run without `--dry-run` and with `--yes`:
      only that file comes back.
- [ ] Editing the saved file to name another production makes `--from` fail on
      load, naming both productions.

## viper

- [ ] `ssh viper true` succeeds without a password prompt.
- [ ] `julia --project=. sync.jl --host viper` opens the picker, titled
      `Productions on viper`, and lists productions below `juleana/`
      (`auto`, `preprod`, `ref`, `tmp`).
- [ ] `enter` on `juleana/tmp/jl-v0.7.0dev1` opens the tree. The details pane of
      the production row reads `overlays: juleana/config_viper.yaml`, and the
      `tier/raw` section points into `raw-compressed/` beside `juleana/`.
- [ ] Copy one `jlevt` filekey as in "Copy one filekey": `n`, `1`, `enter`.
- [ ] `e` shows an estimate within a few percent of the file size.
- [ ] `t` transfers it; the file is at the mirrored path
      `<local-root>/juleana/tmp/jl-v0.7.0dev1/...`.
- [ ] `<local-root>/juleana/config_viper.yaml` is mirrored, and
      `<local-root>/juleana/tmp/jl-v0.7.0dev1/config_local.yaml` holds absolute
      local paths for every key, including `tier/raw`.

## Detector extraction

Run on `cslg4` with a `jldsp` production, then repeat the environment and staging
steps on `viper`. Record sizes, file counts and timings only. List only known
directories (for example the staging directory below); never list a shared
top-level directory recursively.

- [ ] `ssh cslg4 '~/.juliaup/bin/julia --version'` prints a version; note it. The
      same on `viper`.
- [ ] Environment bootstrap on `cslg4`: with `~/.julia/environments/juleana-sync`
      absent, `e` on a selection with a marked detector shows "checking the helper
      environment" (no key is accepted meanwhile), then opens the "Create the
      helper environment" dialog showing the `Pkg.add` command. `Cancel` leaves the
      host unchanged and starts nothing. `Create` shows "Creating the helper
      environment" (no key accepted; record the time) and continues to the estimate.
- [ ] With an existing environment that lacks a package, the same dialog appears
      and `Create` fails with an error naming the directory ("refusing to modify
      it"); the host is unchanged. (Point `julia_project` at a scratch environment to test this
      without touching a real one.)
- [ ] The same bootstrap on `viper`. Record whether `/tmp` on the login node has
      room for one run's selection (`df -h /tmp` there); if it does not, set
      `staging` for `viper` in `config/sync/hosts.yaml` to `/ptmp/<user>/juleana-sync`.
- [ ] Walk to `tier/jldsp` -> `cal` -> `p18` -> `r000` and press `enter` on the
      `detectors` row (the first row below the run, above the filekey rows): one
      row per group of the first file, sized, within a few seconds. On a `jlevt` run the `detectors` row disappears with the status
      "have no per-detector groups". On a production in the `<tier>/<detector>`
      layout (jl-v0.8.0 on viper, for example `jlpks`) the same walk lists the
      detectors.
- [ ] On a detector row, `space`, `l` and `n` only report "use x" or "n applies to
      run directories". `x` on a detector of a run marked `space` reports `... is
      already transferred whole`.
- [ ] Mark one detector with `x`; the status bar shows `~... extract (N files)`.
      `e` shows the exact size (within a few percent of N times the row's size)
      and the line `staging <dir>: ... free`.
- [ ] `t` extracts: the gauge reads `extracting k/N files`, then the rsync
      progress. The summary reads `extracted N files, N groups`.
- [ ] The files are at the mirrored paths with the original names. `h5ls` is not
      needed: in Julia, `HDF5.h5open(file) do f; keys(f); end` lists only the
      chosen group, and a `LegendDataManagement` read of that detector's data from
      the mirror succeeds.
- [ ] `ssh cslg4 'ls -R ${TMPDIR:-/tmp}/juleana-sync-$(id -un)'` shows no data
      files after the transfer; only `extract.jl` and an empty `jobs/` directory
      remain in the staging directory.
- [ ] Re-running `t` extracts again without error and the local file still holds
      exactly the chosen groups. Marking a second detector and running `t` leaves
      both groups in the file (union rebuild).
- [ ] Put a full copy of one file of the run in the mirror (`n`, `1` on the same
      run with `space` copy), then extract: the summary reports "kept 1 existing
      files instead of extracting" and the file is unchanged.
- [ ] Replace one mirrored file's directory or the file itself with a symlink,
      then extract: the same line appears and nothing is written through the link.
- [ ] Timing: extract one detector of one `jldsp` run (about 29 GB per run) with
      `--jobs 1` and again with `--jobs 8` after deleting the local files and the
      staging directory; record both times and the number of files. Compare with
      the whole-run copy time. `--jobs -1` and `--jobs abc` are rejected at startup.
- [ ] Interrupt an extraction (`kill` the helper on the host): the next `t`
      reports the failure and names the staging directory, and the rerun skips the
      finished files. Interrupt an rsync pull and confirm `.juleana-partial`
      directories remain in the mirror and the rerun completes.
- [ ] Headless: `julia --project=. sync.jl --from config/sync/<production>.yaml --dry-run`
      prints the estimate with the extract part, then the staging directory and
      its free space. With the helper environment absent it stops with an error
      that names the `Pkg.add` command.
- [ ] A missing Julia executable (set `julia` for the host to a wrong path) stops
      with the remote error message attached.
- [ ] `git status` in the checkout shows `config/sync/hosts.yaml` as tracked and
      any saved `config/sync/<production>.yaml` as ignored.

### Tier/detector layout and period selection

- [ ] On a jl-v0.8.0 production (`jlpks` or `jldsp` in the `<tier>/<detector>`
      layout), open a run's `detectors` row: the detectors are listed with sizes.
      Extract one detector of one run: the local file has the tier group
      (`HDF5.h5open(file) do f; keys(f); end` shows only the tier) with the chosen
      child, and the tier group's attributes equal the source's.
- [ ] On an older production in the `<detector>/<tier>` layout, the same steps list
      and extract top-level groups. A file in the mirror from an earlier extraction
      is still accepted and is rebuilt with the union when another detector is
      added.
- [ ] Open a period directory (`p18`): a `detectors` row appears
      above the run directories; opening it takes a few seconds per run and lists the union of the detectors. A category directory
      (`cal`) has no such row. Record the time for a period with many runs.
- [ ] Mark one detector on the period row: the status bar shows `~... extract (N
      files)` with N the files of all runs that hold it. Open one run's `detectors`
      row: the detector shows `[e]` and `x` on it reports that it is extracted for
      the whole period.
- [ ] `space` on the period or on one of its runs while the detector is marked
      reports `cannot mark ... :copy` and names the detector; unmark the detector,
      mark the run with `space`, then `x` on a period row reports `... is already
      transferred whole`.
- [ ] A detector that one run of the period lacks: `e` lists `<detector> in <run>`
      as "not in run"; `t` extracts the other runs and the summary repeats the line.
      A run that holds none of the chosen detectors has no files in the mirror.
- [ ] Save, quit, and re-run headless with `--from`: the period entry is applied
      without the interface and gives the same extraction.

### Detector files of a per-detector tier

- [ ] On `viper`, production `jl-v0.8.1`, open `tier/jlqcs` -> `cal` -> a period:
      a `detectors` row appears above the run directories. `enter` on it shows
      `listing the detector files of ...` and then the detector names with sizes,
      without a helper environment dialog. Record the time for a period with many
      runs. A `jldsp` period still lists through the helper.
- [ ] `space` on one detector: the row reads `[x]` and the status bar shows the sum
      of its files and one file per run that holds it. `x` reports that the files
      hold one detector each. Open a run: the detector's file shows `[x]` and
      `space` or `l` on it says to unmark the period's detector.
- [ ] `t` copies exactly that detector's files of every run into the mirror (compare
      `ls` of two runs with the host) and nothing else of the period. A run that
      lacks the detector is listed as `<detector> in <run>` under "not in run" in
      the estimate and in the summary.
- [ ] Change the mark to `l` (needs `--mount-root`): symlinks to the mounted files
      are created for the same files and none for the other detectors.
- [ ] `space` on the period or on a run that holds the detector while the detector
      is marked reports `cannot mark ... :copy`; with the period copied, `space` on
      the detector row reports `... is already transferred whole`.
- [ ] Save, quit and run headless with `--from` and `--dry-run`: the estimate and the
      pairs match the interface. The saved file lists the marks under
      `detector_files`.
