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
JuLeAna.dataset_summary
JuLeAna.period_summary
JuLeAna.history_path
JuLeAna.history_section
JuLeAna.append_history
JuLeAna.read_history
JuLeAna.history_grid
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
JuLeAna.partition_periods
JuLeAna.rank_order_dependencies
```

## Controller

```@docs
DataflowController
dispatch!
snapshot
wait(::DataflowController)
progress
busy_workers
step_messages
ProgressStore
show_progress
JuLeAna.effective_config
ControllerCommand
LoadSession
ReloadConfig
SelectPeriods
SelectRuns
SelectSteps
SetReprocess
SetProcessorLogLevel
SetProcessorPlotLevel
SetAnalysisRunsOnly
SetRunmode
SetRunmodeSettings
SetCheckDependencies
SetKwarg
SetStepLevel
ResetKwargs
ResetDependencyGraph
StartProcessing
StopProcessing
WriteConfig
AddWorkers
CancelAllocation
CancelAll
PostponeIdleCancel
EditStartScript
CreateProduction
SelectProduction
SelectDataset
JuLeAna.check_idle!(::DataflowController)
```

## Workers

```@docs
JuLeAna.WorkerManager
JuLeAna.WorkerAllocation
JuLeAna.set_worker_config!
JuLeAna.start_script!
JuLeAna.edit_start_script!
JuLeAna.add_workers!
JuLeAna.update_job_ids!
JuLeAna.cancel_allocation!
JuLeAna.cancel_all!
JuLeAna.allocations
JuLeAna.mark_activity!
JuLeAna.idle_deadline
JuLeAna.check_idle!(::JuLeAna.WorkerManager)
JuLeAna.workers_overview
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
layered_layout
partition_steps
check_processor_kwargs
JuLeAna.PROCESSORS
JuLeAna.register_processor!
JuLeAna.PROCESSOR_TRAITS
JuLeAna.display_name
JuLeAna.RENAMED_PROCESSORS
```

## Helpers for processors

```@docs
parallel
failure_log
master_status
JuLeAna.process_skipped
detector_status
truncate_string
truncate_error
load_qc_evaluator
JuLeAna.redo_detector
JuLeAna.detector_selected
JuLeAna.write_pars
JuLeAna.write_validity
JuLeAna.make_par_dir
JuLeAna.write_report
```
