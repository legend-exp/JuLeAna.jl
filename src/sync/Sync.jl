# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    JuLeAna.Sync

Mirror part of a remote LEGEND data production onto this machine. The module holds the
remote access (`SSHHost`, `LocalHost`), the production inventory and selection,
the transfer with its estimate, the command line (`juleana-sync`, `julia -m JuLeAna.Sync`) and the
terminal screen.

The remote helper `remote/extract.jl` is a standalone script that is pushed to the host and run
with the Julia found there; it is never loaded into this module.
"""
module Sync

using ArgParse: @add_arg_table!, ArgParseSettings, parse_args
using Dates: DateTime, now
using PropDicts: PropDicts, PropDict, readprops

# LegendDataManagement exports a wide surface and Tachikoma exports names such as `text`, `value`,
# `right` and `Table` that would collide with it. Both are imported by name, so a collision shows
# up here as a load error rather than at a call site. Loading LegendDataManagement is also what
# brings in JSON, which PropDicts needs for the extension that reads the productions' config.json
# files. YAML is imported for PropDicts' YAML reader and for writing the selections and local
# configs, which are YAML files.
import LegendDataManagement
import YAML
import TOML
import HDF5
using LegendDataManagement: DetectorId, Timestamp
using Tachikoma: Tachikoma, Model, Frame, Buffer, Rect, Span, KeyEvent, MouseEvent, TaskEvent, TaskQueue, list_hit, list_scroll,
                 spawn_task!, TreeView, TreeNode, selected_node, tree_visible_count, handle_key!, Block, StatusBar, Paragraph, Modal,
                 TextInput, Gauge, SelectableList, Layout, Constraint, Vertical, Horizontal, Fill, Fixed, Percent, split_layout, render,
                 tstyle, center, word_wrap, BOX_HEAVY, app, set_string!, mouse_left, mouse_press
import Tachikoma: view, update!, should_quit, task_queue, init!, cleanup!
using ..JuLeAna: tui_theme, load_theme_name, complete_path

include("remote.jl")
include("steps.jl")
include("helper.jl")
include("production.jl")
include("inventory.jl")
include("selection.jl")
include("estimate.jl")
include("transfer.jl")
include("settings.jl")
include("options.jl")
include("page.jl")
include("app.jl")

public main, Options, SyncSettings, parse_options, parse_settings, run_headless, SyncPage, SyncApp, sync_key!, sync_mouse!, sync_task!,
       render_sync, sync_hints, sync_dirty, sync_busy, sync_text_input, sync_start!, run_tui, StepProgress, Steps, StepPrinter, format_step

end # module
