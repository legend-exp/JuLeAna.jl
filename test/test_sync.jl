# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# The sync tool tests run in a module of their own so that fixtures and imported names stay out of
# `Main`: a `main` binding in `Main` would become the entry point of the test script.
module SyncTests

using Test
using Dates
using PropDicts
using TOML
import YAML
using HDF5
using LegendDataManagement: LegendDataConfig, data_path
import LegendDataManagement
using JuLeAna: Sync
using Tachikoma: TestBackend, Frame, Rect, KeyEvent, MouseEvent, mouse_left, mouse_right, mouse_press, mouse_release, mouse_drag,
                 mouse_scroll_up, mouse_scroll_down, tree_visible_count, TaskEvent, TaskQueue, GraphicsRegion, PixelSnapshot, reset!,
                 row_text,
                 find_text, style_at, drain_tasks!, render_widget!
import Tachikoma
import Tachikoma: view, update!, should_quit, init!, cleanup!

include(joinpath(@__DIR__, "sync", "fixture_lh5.jl"))
include(joinpath(@__DIR__, "sync", "fixture_extract_remote.jl"))
include(joinpath(@__DIR__, "sync", "fixture_perdet_remote.jl"))

# Sync exports nothing, so every name the tests use is named here.
using JuLeAna.Sync: main, RemoteHost, SSHHost, LocalHost, DirEntry,
                    run_remote, list_dir, dir_sizes, read_file, rsync_source,
                    ssh_command, parse_dir_listing, has_control_master,
                    Production, parse_production_config, production_roots,
                    overlay_files, list_productions, host_remote_root, relative, to_local, to_mount, local_config, write_local_config,
                    normdir,
                    Node, tier_file_id, group_children, production_tree, expand!,
                    node_local_state, filekey_groups,
                    Selection, effective_mode, set_mode!, filekey_files, run_dirs, period_detector_nodes, covering_extract, exclude!,
                    first_n_filekeys!, find_node!,
                    selection_propdict, save_selection, load_selection, mandatory_copies, apply_selection!,
                    Estimate, format_bytes, running_estimate, format_estimate, format_not_in_run, parse_rsync_stats,
                    Progress, TransferResult, check_rsync, check_mount, rsync_command,
                    parse_progress, rsync_dry_run, remove_stale_links!, create_links!,
                    apply!, summary_text,
                    Options, parse_options, run_headless, default_local_root, default_selection_dir, default_hosts_file, config_dir,
                    default_selection_path,
                    SyncPage, SyncApp, sync_key!, sync_mouse!, sync_task!, sync_hints, sync_dirty, sync_busy, sync_text_input, spawn!,
                    sync_start!,
                    checkbox, node_label, build_tree, rebuild_tree!, current_node,
                    request_expand!, attach_listing!, show_error!, save!, details, status_bar,
                    render_sync, run_tui, task_queue,
                    open_estimate!, start_transfer!, open_prompt!, open_message!,
                    apply_prompt!, refresh_local_state!, render_prompt,
                    remote_command, stream_remote, remote_home, expand_home, file_exists, dir_exists, make_dir,
                    parse_df, free_bytes, push_command, push_file, remove_staged!,
                    HelperConfig, EnvironmentStatus, remote_julia, julia_project, staging_dir,
                    ensure_environment, environment_ready, environment_problem, bootstrap_command,
                    bootstrap_environment!, parse_record, run_helper, helper_command, inspect_files, host_helper_config,
                    HELPER_SCRIPT, HELPER_PACKAGES, DEFAULT_REMOTE_JULIA,
                    DEFAULT_REMOTE_PROJECT, REMOTE_STAGING_SCRIPT,
                    ExtractEntry, DetectorEntry, covering_detector, ensure_detectors!, detector_nodes, period_file_nodes, attach_detectors!,
                    expand_detectors!, has_detectors,
                    ExtractJob, staging_production_dir, plan_extraction, plan_detector_files, plan_bytes, plan_group_bytes,
                    prepare_extraction,
                    ExtractProgress, STAGING_MARGIN, check_staging_space, reduced_groups, reconcile_local, rsync_listed,
                    with_environment!, start_bootstrap!, environment_ready!, request_detectors!, run_estimate!, toggle_extract!,
                    StepProgress, Steps, NO_STEPS, format_step, StepPrinter, failed_step, with_failed_step, apply_steps, estimate_selection,
                    detector_steps,
                    SyncSettings, SETTINGS_FIELDS, user_settings, field_error, settings_errors, hosts_choices, selection_path,
                    parse_settings,
                    FieldEdit, PANEL_FIELDS, PANEL_BUTTONS, PANEL_ITEMS, panel_rects, revalidate!, change_setting!, refresh_options!,
                    blocked,
                    open_picker!, start_connect!, connect!, load_selection!, start_load!, discard_guard!, render_progress, start!, stop!

# `update!` and `view` on a page deliver an event to it the way its host does.
update!(p::SyncPage, e::KeyEvent) = (sync_key!(p, e); p)
update!(p::SyncPage, e::MouseEvent) = (sync_mouse!(p, e); p)
update!(p::SyncPage, e::TaskEvent) = (sync_task!(p, e) || error("not a sync event: $(e.id)"); p)
view(p::SyncPage, f::Frame) = render_sync(p, f.area, f.buffer)

queue_of(m::SyncPage) = m.tasks
queue_of(m::SyncApp) = m.queue

function draw(m; width = 100, height = 30)
    tb = TestBackend(width, height)
    reset!(tb.buf)
    view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end

# Deliver the background results exactly as the app loop does, until no task is running and no event waits.
function settle!(m)
    queue = queue_of(m)
    t_end = time() + 30
    while time() < t_end
        drain_tasks!(e -> update!(m, e), queue)
        queue.active[] == 0 && !isready(queue.channel) && return nothing
        sleep(0.01)
    end
    return error("the background tasks did not finish within 30 s")
end

# Deliver exactly the next background event, so a test can look at the model between a listing and the sizes that follow it.
function deliver_next!(m)
    queue = queue_of(m)
    timedwait(() -> isready(queue.channel), 30.0) == :ok || error("no background event within 30 s")
    return update!(m, take!(queue.channel))
end

const SYNC_FIXTURES = joinpath(@__DIR__, "sync", "fixtures")

# No test reads or writes the user's configuration: hosts, settings and selections live in a temporary
# XDG_CONFIG_HOME whose settings.yaml names a local root, as a configured user has one.
const TEST_LOCAL_ROOT = mktempdir()
const TEST_CONFIG_HOME = mktempdir()
mkpath(joinpath(TEST_CONFIG_HOME, "juleana", "sync"))
write(joinpath(TEST_CONFIG_HOME, "juleana", "sync", "settings.yaml"), "local_root: $TEST_LOCAL_ROOT\n")

# A fresh copy of the fixture per run: tests write into the mirror and must never touch the committed
# tree. The copy's absolute path is what `@REMOTE_ROOT@` and PropDicts' `$_` both have to resolve to,
# so it can only be known at run time.
const FIXTURE_ROOT = let dest = joinpath(mktempdir(), "remote")
    cp(joinpath(SYNC_FIXTURES, "remote"), dest)
    template = read(joinpath(dest, "test", "config.json.in"), String)
    write(joinpath(dest, "test", "config.json"), replace(template, "@REMOTE_ROOT@" => dest))
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

withenv("XDG_CONFIG_HOME" => TEST_CONFIG_HOME) do
    @testset "Sync" begin
        run_file("test_sync_extract_helper.jl")
        run_file("test_sync_remote.jl")
        run_file("test_sync_helper.jl")
        run_file("test_sync_steps.jl")
        run_file("test_sync_production.jl")
        run_file("test_sync_inventory.jl")
        run_file("test_sync_selection.jl")
        run_file("test_sync_extract_tree.jl")
        run_file("test_sync_tierdet_tree.jl")
        run_file("test_sync_perdet_tree.jl")
        run_file("test_sync_extract_estimate.jl")
        run_file("test_sync_extract_transfer.jl")
        run_file("test_sync_tierdet_transfer.jl")
        run_file("test_sync_perdet_transfer.jl")
        run_file("test_sync_perdet_estimate.jl")
        run_file("test_sync_tierdet_estimate.jl")
        run_file("test_sync_estimate.jl")
        run_file("test_sync_transfer.jl")
        run_file("test_sync_options.jl")
        run_file("test_sync_settings.jl")
        run_file("test_sync_extract_options.jl")
        run_file("test_sync_tui.jl")
        run_file("test_sync_app.jl")
        run_file("test_sync_page.jl")
        run_file("test_sync_extract_tui.jl")
        run_file("test_sync_tierdet_tui.jl")
        run_file("test_sync_perdet_tui.jl")
    end
end # withenv: the user's configuration directory is untouched and restored

end # module
