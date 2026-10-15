using Test
using Dates
using PropDicts
using TOML
import YAML
using HDF5
using LegendDataManagement: LegendDataConfig, data_path
import LegendDataManagement
using Tachikoma: TestBackend, Frame, Rect, KeyEvent, MouseEvent, mouse_left, mouse_right,
                 mouse_press, mouse_release, mouse_drag, mouse_scroll_up, mouse_scroll_down,
                 tree_visible_count, TaskEvent, GraphicsRegion, PixelSnapshot,
                 reset!, row_text, find_text, drain_tasks!, render_widget!,
                 view, update!, should_quit

include(joinpath(@__DIR__, "..", "..", "src", "sync", "JuleanaSync.jl"))
include(joinpath(@__DIR__, "fixture_lh5.jl"))
include(joinpath(@__DIR__, "fixture_extract_remote.jl"))
include(joinpath(@__DIR__, "fixture_perdet_remote.jl"))

# JuleanaSync exports nothing, so every name the tests use is named here. Each
# task appends the names from its Interfaces/Produces block to this line.
using .JuleanaSync: main,
    RemoteHost, SSHHost, LocalHost, DirEntry,
    run_remote, list_dir, dir_sizes, read_file, rsync_source,
    ssh_command, parse_dir_listing, has_control_master,
    Production, parse_production_config, production_roots,
    overlay_files, list_productions, host_remote_root, relative, to_local, to_mount, local_config, write_local_config, normdir,
    Node, tier_file_id, group_children, production_tree, expand!,
    node_local_state, filekey_groups,
    Selection, effective_mode, set_mode!, filekey_files, run_dirs, period_detector_nodes, covering_extract, exclude!, first_n_filekeys!, find_node!,
    selection_propdict, save_selection, load_selection, mandatory_copies, apply_selection!,
    Estimate, format_bytes, running_estimate, format_estimate, format_not_in_run, parse_rsync_stats,
    Progress, TransferResult, check_rsync, check_mount, rsync_command,
    parse_progress, rsync_dry_run, remove_stale_links!, create_links!,
    apply!, summary_text,
    Options, parse_options, run_headless, DEFAULT_LOCAL_ROOT, DEFAULT_SELECTION_DIR, DEFAULT_HOSTS_FILE,
    SyncModel, checkbox, node_label, build_tree, rebuild_tree!, current_node,
    request_expand!, attach_listing!, show_error!, save!, details, status_bar,
    render_sync, run_tui, task_queue,
    open_estimate!, start_transfer!, open_prompt!, open_message!,
    apply_prompt!, refresh_local_state!, render_prompt,
    remote_command, stream_remote, remote_home, expand_home, file_exists, dir_exists, make_dir,
    parse_df, free_bytes, push_command, push_file, remove_staged!,
    HelperConfig, EnvironmentStatus, remote_julia, julia_project, staging_dir,
    ensure_environment, environment_ready, environment_problem, bootstrap_command,
    bootstrap_environment!, parse_record, run_helper, helper_command, inspect_files, host_helper_config,
    HELPER_SCRIPT, HELPER_PACKAGES, DATAFLOW_PROJECT, DEFAULT_REMOTE_JULIA,
    DEFAULT_REMOTE_PROJECT, REMOTE_STAGING_SCRIPT,
    ExtractEntry, DetectorEntry, covering_detector, ensure_detectors!, detector_nodes, period_file_nodes, attach_detectors!,
    expand_detectors!, has_detectors,
    ExtractJob, staging_production_dir, plan_extraction, plan_detector_files, plan_bytes, plan_group_bytes, prepare_extraction,
    ExtractProgress, STAGING_MARGIN, check_staging_space, reduced_groups, reconcile_local, rsync_listed,
    with_environment!, start_bootstrap!, environment_ready!, request_detectors!, run_estimate!, toggle_extract!

# A fresh copy of the fixture per run: tests write into the mirror and must never
# touch the committed tree. The copy's absolute path is what `@REMOTE_ROOT@` and
# PropDicts' `$_` both have to resolve to, so it can only be known at run time.
const FIXTURE_ROOT = let dest = joinpath(mktempdir(), "remote")
    cp(joinpath(@__DIR__, "fixtures", "remote"), dest)
    template = read(joinpath(dest, "test", "config.json.in"), String)
    write(joinpath(dest, "test", "config.json"),
          replace(template, "@REMOTE_ROOT@" => dest))
    rm(joinpath(dest, "test", "config.json.in"))
    dest
end

const EXTRACT_ROOT = make_extract_remote()
const TIER_DET_ROOT = make_tier_det_remote()
const PERDET_ROOT = make_per_detector_remote()

const LOCAL_ROOT = mktempdir()

const SELECTED_TEST_FILES = filter(!isempty, split(get(ENV, "SYNC_TEST_FILES", ""), ','))
run_file(name) = (isempty(SELECTED_TEST_FILES) || name in SELECTED_TEST_FILES) &&
                 include(joinpath(@__DIR__, name))

@testset "JuleanaSync" begin
    run_file("test_extract_helper.jl")
    run_file("test_remote.jl")
    run_file("test_helper.jl")
    run_file("test_production.jl")
    run_file("test_inventory.jl")
    run_file("test_selection.jl")
    run_file("test_extract_tree.jl")
    run_file("test_tierdet_tree.jl")
    run_file("test_perdet_tree.jl")
    run_file("test_extract_estimate.jl")
    run_file("test_extract_transfer.jl")
    run_file("test_tierdet_transfer.jl")
    run_file("test_perdet_transfer.jl")
    run_file("test_tierdet_estimate.jl")
    run_file("test_estimate.jl")
    run_file("test_transfer.jl")
    run_file("test_options.jl")
    run_file("test_extract_options.jl")
    run_file("test_tui.jl")
    run_file("test_extract_tui.jl")
    run_file("test_tierdet_tui.jl")
end
