# API: steps, plots and logging

Functions for the named steps of the processors and their debugging, for saving plots, and
for the log files.

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
