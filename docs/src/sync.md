# Data sync tool

The data sync tool mirrors part of a remote LEGEND data production onto this machine, so that the
dataflow and the analysis scripts can run against real data without an open session on the cluster.
The mirror keeps the remote layout, and the tool writes a `config_local.yaml` beside it that
`LegendDataManagement` opens. The Julia module is [`JuLeAna.Sync`](@ref JuLeAna.Sync).

`juleana-sync` opens the screen alone, and `S` on the Setup page of `juleana` opens it in a window.
Install the apps with `Pkg.Apps.develop(path = "path/to/JuLeAna.jl")`; from a checkout,
`julia --project=. -m JuLeAna.Sync` runs `juleana-sync`. `--production` is the production's path relative
to the remote root; without it, the screen lists every directory with a `config.json` or `config.yaml` up
to three levels below the root to choose from.

## Sync configuration

The tool reads and writes `$XDG_CONFIG_HOME/juleana/sync` (`~/.config/juleana/sync` if `XDG_CONFIG_HOME`
is unset), written `<config dir>` below.

| File | Content |
|------|---------|
| `hosts.yaml` | Per host alias: `remote_root` and optionally `julia`, `julia_project`, `staging` (see [Extract mode](@ref sync-extract)); the package's `config/sync/hosts.yaml` is read if this file is missing. |
| `settings.yaml` | Optional `local_root: <directory>`, the default of the Local root field. |
| `<host>/<production>.yaml` | Saved selections, one directory per host; `/` in the production name becomes `-`. |

Without `settings.yaml` or `--local-root` there is no Local root, and Connect, Estimate and Transfer
refuse. A selection records the host its tree was built from; loading it for another host is
refused. A malformed file stops `juleana-sync` with a message that names the file; `juleana` shows the
message in the window and keeps running. Site files `config_<site>.json`, `.yaml` or `.yml` in the
directories from the remote root down to the production's parent redirect path keys; the tool applies
them over the production's config, deeper files last, and copies them with the production.

## The screen

The settings panel is at the top, the production tree and the details of the row under the cursor below it.
The last row shows `[k/N] step` while an operation runs, else the pending transfer and the selection file.

| Field | Option | Input |
|-------|--------|-------|
| Host | `--host` | An alias from `hosts.yaml` or any ssh alias; default `cslg4`. |
| Remote root | `--remote-root` | A path on the host; empty uses the entry in `hosts.yaml`. |
| Production | `--production` | `Enter` lists the productions on the host. |
| Local root | `--local-root` | An existing local directory. |
| Mount root | `--mount-root` | An existing local directory for link mode, or empty for none. |
| Staging | `--staging` | An absolute path on the host or one starting with `~`; empty is the host default. |
| Jobs | `--jobs` | An integer of 0 or more; 0 lets the helper decide. |
| Selection | `--out` | A path ending in `.yaml`; empty is `<config dir>/<host>/<production>.yaml`. |

`Tab` and `Shift-Tab` move through the fields and the tree. `Enter` edits a field, `Tab` completes a
directory in the two local root fields and an alias in the Host field, and `Esc` cancels. An invalid value
stays in the field; the message row reads `<name> must be <reason>[, got <value>]`, and connecting,
estimating and transferring are refused until it is valid. Changing the host, remote root, production, local
root or mount root, or loading a selection, while the tree has unsaved marks asks before discarding them.
Connect checks the host, GNU rsync and the productions and runs by itself at the start.

The tree shows the production's config file, one branch per configured path key and, if present, the
`setup` folder; `[-]` marks a row with a selection below it. The settings panel takes only `c o s e t p`.

| Key | Action |
|-----|--------|
| `↑` `↓` `home` `end`, mouse wheel | Move the cursor, scroll |
| `enter`, click on the selected row | Expand or collapse; lists the directory the first time |
| `space` | Copy this row (`[x]`), or stop copying it |
| `l` | Link this row through the mount instead (`[~]`); needs a mount root |
| `n` | On a run directory: copy the first N filekeys |
| `x` | On a detector row of a per-filekey tier: extract this detector (`[e]`) |
| `c` | Connect |
| `o` / `s` | Load / save the selection file of the Selection field |
| `e` | Ask rsync exactly what the selection would move |
| `t` | Estimate, confirm, transfer |
| `p` | Collapse or expand the settings panel |
| `T` | Next color theme |
| `q`, `ctrl+c` | Leave; asks first about unsaved marks and a running transfer |

## Copy, link and extract

- **Copy** mirrors the row with rsync. Symlinks in a copied directory are mirrored as symlinks.
- **Link** puts a symlink at the row's place in the mirror, pointing into the mount root where the remote
  filesystem is mounted (for example with `sshfs`). The links work only while it is mounted.
- **Extract** transfers only the chosen detectors of per-filekey tiers such as `jldsp` and `raw`, which
  store all detectors of a time slice in one HDF5 file. The reduced files keep their names and paths.

A run or period directory of a per-filekey tier has a `detectors` row above its filekeys; `enter` lists the
detectors in the first file of each run, with sizes, and `x` marks one. On a period, `x` extracts the
detector from every run that holds it; a run that lacks it is reported as "not in run". Per-detector tiers
such as `jlqcs` have one file per detector; there `space` and `l` on a period's `detectors` row copy or
link that detector's files from every run, and `x` is refused. A copy or link mark and an extract mark
never cover the same run. A reduced file never replaces a full local copy and is never written through a
symlink; such paths are skipped and listed in the summary. A later extraction adds to the groups of an
earlier one.

### [Extract mode](@id sync-extract)

A helper script run by the host's Julia copies the chosen HDF5 groups into reduced files in the staging
directory; rsync pulls them and the tool removes them from staging. An interrupted run resumes from the
staged files and the `.juleana-partial` directories.

| `hosts.yaml` key | Default | Meaning |
|------|---------|---------|
| `julia` | `~/.juliaup/bin/julia` | Julia executable on the host |
| `julia_project` | `~/.julia/environments/juleana-sync` | Environment with HDF5 and ParallelProcessingTools |
| `staging` | `${TMPDIR:-/tmp}/juleana-sync-$(id -un)` | Staging directory; use a scratch area if `/tmp` is small |

If the environment does not exist, the screen shows the `Pkg.add` command and asks before creating it. The
tool never modifies an existing environment; name another `julia_project` instead. `--jobs N` allows at
most N workers; by default the helper runs in the main process for fewer than four files and otherwise uses
`min(8, files, cores ÷ 2)` workers.

## In `juleana`

`S` on the Setup page opens the screen in a window that replaces the visible page and connects at the
first opening; the Setup page's production is offered if it lies below the local root or a host's remote
root. `Esc` cancels an edit and closes a list or dialog; at the tree it closes the window, which keeps the
selection and settings. While a sync runs, `Esc` asks:

| Key | Action |
|-----|--------|
| `b` | Close the window; the sync goes on in the background |
| `s` | Stop the estimate or transfer; not offered while the helper environment is checked or created |
| `c`, `Esc` | Stay |

A stop acts at the next progress reading; staged files are kept and the next run resumes from them. The
status panel shows `sync running` and the current step. A sync writes into the production that processing
reads, so `S` is refused while processing runs and processing cannot start while a sync runs.

## Headless use

`juleana-sync --from <config dir>/cslg4/test.yaml --yes` applies a saved selection without the screen.
The production is taken from the selection; if `--production` is also given, the two must agree. The
estimate is always printed first; `--dry-run` stops there and `--yes` transfers without asking.

## Command line options

| Option | Description |
|--------|-------------|
| `--host ALIAS` | ssh alias of the machine holding the production (default `cslg4`) |
| `--remote-root PATH` | Remote directory with the productions (default: `hosts.yaml`) |
| `--local-root PATH` | Local mirror directory (default: `local_root` in `settings.yaml`) |
| `--mount-root PATH` | Mount of the remote root; enables link mode |
| `--production PATH` | Production relative to the remote root (default: choose on the screen) |
| `--out FILE` | Where the screen saves the selection; must end in `.yaml` |
| `--jobs N` | Worker processes of the extraction helper |
| `--staging PATH` | Staging directory on the host |
| `--from FILE` | Apply a saved selection without the screen |
| `--dry-run` | With `--from`: print what would move, then stop |
| `--yes` | With `--from`: transfer without asking |

## Requirements

- GNU `rsync` 3.1 or newer on this machine (the `openrsync` of macOS lacks the progress output).
- `ssh` access to the host, and GNU `find`, `du` and `rmdir` on it. ssh runs in batch mode and never asks
  for a password, one-time code or host-key confirmation; a host that needs one, or whose ssh config shares
  a connection (`ControlMaster`), must be opened first with `ssh <host>`. Connections give up after 20 s of
  connecting or about a minute of silence. Extraction also needs Julia and the helper environment on the
  host. `Compression no` in `~/.ssh/config` avoids a single-core limit of 15-30 MB/s.

## What the tool never does

It never writes to a remote production, never deletes local data and never rewrites the mirrored config
file. On the host it writes only below its staging directory, apart from the environment it offers to
create, and removes only the files it staged. Locally, the only things it removes are symlinks it created
itself, where a copy or a new link replaces them; regular files and directories are never removed.
