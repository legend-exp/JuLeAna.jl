# API: steps, plots, logging and reports

Functions for the named steps of the processors and their debugging, for saving plots, for
the log files, and for the reports of the processors.

## Steps and failures

```@docs
JuLeAna.root_exception
JuLeAna.@process_step
JuLeAna.ProcessStepError
JuLeAna.Failure
JuLeAna.failure
JuLeAna.failures
JuLeAna.failure_info
JuLeAna.failure_variables
JuLeAna.@locals
JuLeAna.rerun
```

## Plots

```@docs
JuLeAna.save_plot
JuLeAna.@debug_plot
```

## Logging

```@docs
JuLeAna.processing_logger
JuLeAna.ProcessorLevelLogger
JuLeAna.@debug_progress
JuLeAna.DEBUG_LOG_PACKAGES
JuLeAna.process_log_file
JuLeAna.parse_log_level
UnderscoreSafeLogger
JuLeAna.escape_log_underscores
```

## Reports

```@docs
master_status
JuLeAna.process_skipped
detector_status
JuLeAna.timing_table
JuLeAna.write_report
```
