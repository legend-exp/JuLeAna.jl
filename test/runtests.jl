# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

import Test

# Code that writes to the config folder of the data production, such as the worker start
# script, must never reach a real production from the tests.
withenv("LEGEND_DATA_CONFIG" => joinpath(mktempdir(), "config.json")) do
    Test.@testset "Package JuLeAna" begin
        include("test_aqua.jl")
        include("test_explicit_imports.jl")
        include("test_juleana.jl")
        include("test_process_step.jl")
        include("test_processing_config.jl")
        include("test_processor_graph.jl")
        include("test_dataflow.jl")
        include("test_pmts_calibration.jl")
        include("test_reports.jl")
        include("test_dataset_info.jl")
        include("test_history.jl")
        include("test_workers.jl")
        include("test_production.jl")
        include("test_config.jl")
        include("test_controller.jl")
        include("test_progress.jl")
        include("test_no_tui.jl")
        include("test_generic_axes.jl")
        include("test_docs.jl")
        include("test_tui.jl")
        include("test_tui_checklist.jl")
        include("test_tui_setup.jl")
        include("test_tui_runmode.jl")
        include("test_tui_progress.jl")
        include("test_tui_log.jl")
        include("test_tui_graph.jl")
        include("test_tui_reports.jl")
        include("test_tui_history.jl")
        include("test_tui_workers.jl")
        include("test_tui_production.jl")
        include("test_tui_timing.jl")
        include("test_tui_branding.jl")
        include("test_logging.jl")
    end # testset
end
