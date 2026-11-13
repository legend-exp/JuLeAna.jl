# API

```@docs
JuLeAna
```

## Running the dataflow

```@docs
JuLeAna.main
JuLeAna.setup_session
JuLeAna.run_no_tui
JuLeAna.run_tui
JuLeAna.parse_commandline
JuLeAna.mirror_override_folders
JuLeAna.data_config_files
JuLeAna.with_production_config
JuLeAna.production_setup_dir
JuLeAna.production_config_dir
JuLeAna.default_config_file
JuLeAna.install_default_config
JuLeAna.parse_period_runs
JuLeAna.init_process
DataflowSession
JuLeAna.report_path
JuLeAna.read_report
JuLeAna.report_index
JuLeAna.failure_summary
JuLeAna.report_overview
JuLeAna.write_master_reports
JuLeAna.dataset_summary
JuLeAna.period_summary
JuLeAna.history_path
JuLeAna.history_section
JuLeAna.append_history
JuLeAna.read_history
JuLeAna.history_grid
JuLeAna.latest_item_seconds
JuLeAna.disk_counts
JuLeAna.disk_state
run_processing
run_step
JuLeAna.ReportPlot
JuLeAna.display_report
JuLeAna.processors
JuLeAna.StepOutput
JuLeAna.@using_packages
ProcessingStopped
JuLeAna.WorkerQueue
JuLeAna.resort!
JuLeAna.partition_periods
JuLeAna.rank_order_dependencies
```

## Data productions

```@docs
JuLeAna.ProductionSpec
JuLeAna.check_production
JuLeAna.create_production
JuLeAna.data_config_text
JuLeAna.running_manifest
JuLeAna.snapshot_software
JuLeAna.record_software
JuLeAna.software_version
JuLeAna.record_metadata
JuLeAna.production_log
```

## Processing config

```@docs
ProcessingConfig
ProcessorSpec
run_steps
ProcessorGraph
processor_graph
topological_order
required_processors
dependent_processors
waited_processors
JuLeAna.waiting_chains
layered_layout
partition_steps
check_processor_kwargs
JuLeAna.PROCESSORS
JuLeAna.register_processor!
JuLeAna.PROCESSOR_TRAITS
JuLeAna.display_name
JuLeAna.RENAMED_PROCESSORS
JuLeAna.DEFAULT_REPORT_STATUS
JuLeAna.detector_filter
```

## Helpers for processors

```@docs
parallel
failure_log
JuLeAna.run_filekeys
truncate_string
truncate_error
load_qc_evaluator
JuLeAna.redo_detector
JuLeAna.detector_selected
JuLeAna.write_pars
JuLeAna.write_validity
JuLeAna.make_par_dir
```
