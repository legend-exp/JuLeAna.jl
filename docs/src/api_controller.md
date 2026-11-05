# API: controller and workers

The headless state of an interactive dataflow session, the commands that change it, and the
workers it starts and ends.

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
JuLeAna.item_timings
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
JuLeAna.worker_start_script
JuLeAna.start_script!
JuLeAna.edit_start_script!
JuLeAna.add_workers!
JuLeAna.update_job_ids!
JuLeAna.update_steps!
JuLeAna.WorkerAttributes
JuLeAna.StepInfo
JuLeAna.worker_attributes
JuLeAna.kill_worker
JuLeAna.cancel_allocation!
JuLeAna.cancel_all!
JuLeAna.allocations
JuLeAna.mark_activity!
JuLeAna.idle_deadline
JuLeAna.check_idle!(::JuLeAna.WorkerManager)
JuLeAna.workers_overview
```
