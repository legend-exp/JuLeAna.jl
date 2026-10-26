# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    module JuLeAna

The Julia LEGEND Analysis dataflow.

[`JuLeAna.main`](@ref) is the entry point of the `juleana` app: it opens the terminal
user interface ([`JuLeAna.run_tui`](@ref)) or, with `--no-tui`, runs the enabled
processors with [`run_processing`](@ref). [`JuLeAna.setup_session`](@ref) reads the
processing config ([`ProcessingConfig`](@ref)), starts the workers, and returns a
[`DataflowSession`](@ref), which the [`DataflowController`](@ref) of the interface works on. The processors are the functions in `src/processors/`, registered by
name in [`JuLeAna.PROCESSORS`](@ref). The module also provides the helpers processors
share: distributing work over the worker pool with per-item failure logging
([`parallel`](@ref)), combining per-item log rows into a processor status
([`master_status`](@ref)), report text and formatting helpers, and the Markdown-safe
logger installed on the head and all workers.
"""
module JuLeAna

using ArgParse: @add_arg_table!, ArgParseSettings, parse_args
using Base64: base64encode
import CairoMakie
# Loading CommonMark activates Tachikoma's Markdown extension, which the report viewer renders with.
import CommonMark
using Dates: Dates, DateTime, Millisecond, Second, UTC, canonicalize, now, @dateformat_str
using Format: Format, format
import Graphs
using IntervalSets: IntervalSets, (..), leftendpoint, rightendpoint
using LaTeXStrings: LaTeXStrings, @L_str
using LegendDataManagement: LegendDataManagement, DataCategory, DataPeriod, DataRun, DataTier, DetectorId, FileKey, LegendData,
                            ProcessStatus, bad_filekeys, channelinfo, data_path, dataprod_config, get_aux_cal_propfunc,
                            get_aux_evt_detsel_propfunc, get_exposure, get_ged_evt_kwargs, get_values, is_analysis_run, is_lrun,
                            ljl_propfunc, lreport, lreport!, lstring, partitioninfo, process_failed, process_succeeded, process_warning,
                            read_ldata, readlprops, runinfo, start_filekey, writelprops, writelreport
using LegendDataManagement.LDMUtils: LDMUtils, create_logtbl, create_metadatatbl, create_pars, create_validity, get_partitionvalidity,
                                     get_plottitle, get_preportfilename, get_rreportfilename, get_totalTimer, savelfig, writevalidity
using LegendDataTypes: LegendDataTypes, decode_data, fast_flatten
using LegendDSP: LegendDSP, DSPConfig, dsp_decay_times, dsp_icpc_compressed, dsp_pmts, dsp_qc_flt_optimization_compressed,
                 dsp_qdrift_flt_optimization, dsp_sipm_compressed
using LegendEventAnalysis: LegendEventAnalysis, TimeEvolution, calibrate_all, calibrate_ged_detector_data, flag_coincidences, rate,
                           relative, smooth
using LegendHDF5IO: LegendHDF5IO, delete_entry!, lh5open
import LegendMakie
using LegendSpecFits: LegendSpecFits, autocal_energy, ctc_energy, cut_single_peak, fit_aoe_compton, fit_aoe_compton_combined,
                      fit_aoe_corrections, fit_calibration, fit_enc_sigmas, fit_fwhm, fit_fwhm_ft, fit_peaks, fit_sf_wl,
                      fit_single_trunc_gauss, fit_sipm_spectrum, fit_sipm_threshold, fit_sipm_wl, generate_aoe_compton_bands,
                      get_continuum_survival_fraction, get_low_aoe_cut, get_peak_survival_fraction, get_peaks_survival_fractions,
                      lq_ctc_correction, lq_norm, peakhists_gamma, set_timelimit, simple_calibration, sipm_simple_calibration
using Base.ScopedValues: ScopedValue, with
using Distributed: Distributed, AbstractWorkerPool, RemoteException, myid, nprocs, nworkers, procs, remotecall_fetch, workers
using Logging: Logging, AbstractLogger, LogLevel, global_logger
using Serialization: serialize
using LoggingExtras: ActiveFilteredLogger, FormatLogger, TeeLogger
import Makie
import Measures
using Measurements: Measurements, value as mvalue
using ParallelProcessingTools: ParallelProcessingTools, @always_everywhere, CreateOrModify, CreateOrReplace, FlexWorkerPool, OnLocalhost,
                               OnSlurm, AutoThreadPinning, onworker, ppt_worker_pool!, ppt_worker_pool, runworkers, write_files,
                               write_worker_start_script
import Printf
using PrecompileTools: @compile_workload, @setup_workload
using ProgressLogging: ProgressLogging
using ProgressMeter: ProgressMeter, Progress, next!, update!
using PropDicts: PropDicts, PropDict
using PropertyFunctions: PropertyFunctions, @pf, filterby
using StatsBase: StatsBase, Histogram, fit, mean, median, quantile, sample, std
using StructArrays: StructArray
using Tachikoma: Tachikoma
using TerminalLoggers: TerminalLogger
import ThreadPinning
import TOML
using TimerOutputs: TimerOutputs, @timeit, TimerOutput
using TypedTables: TypedTables, Table, columnnames, columns
using Unitful: Unitful, @u_str, uconvert, unit, ustrip
import UnitfulAtomic
using UUIDs: UUID, uuid4

include("markdown_logging.jl")
include("file_logging.jl")
include("log_texts.jl")
include("plots.jl")
include("process_step.jl")
include("progress.jl")
include("parallel.jl")
include("qc.jl")
include("processing_config.jl")
include("processor_graph.jl")
include("processing_loop.jl")
include("registry.jl")
include("session.jl")
include("config.jl")
include("run_step.jl")
include("reports.jl")
include("dataset_info.jl")
include("history.jl")
include("workers.jl")
include("production.jl")
include("controller.jl")
include("no_tui.jl")
include("tui_theme.jl")
include("tui_checklist.jl")
include("tui_kwargs.jl")
include("tui_runmode.jl")
include("tui_slurm.jl")
include("tui_setup.jl")
include("tui_progress.jl")
include("tui_log.jl")
include("tui_graph.jl")
include("tui_reports.jl")
include("tui_history.jl")
include("tui_workers.jl")
include("tui_production.jl")
include("tui_timing.jl")
include("sync/Sync.jl")
using .Sync: SyncPage, SyncSettings, SSHHost, PACKAGED_HOSTS_FILE, sync_key!, sync_mouse!, sync_task!, render_sync, sync_hints,
             sync_text_input, sync_start!, shielded, user_settings
include("tui.jl")
include("tui_logo.jl")
include("tui_branding.jl")
include("tui_sync.jl")

include("processors/p_process_aoe_calibration_cut_cal.jl")
include("processors/p_process_aoe_cut_cal.jl")
include("processors/p_process_aoe_optimization_cal.jl")
include("processors/p_process_decay_time_cal.jl")
include("processors/p_process_energy_cal.jl")
include("processors/p_process_filter_optimization_cal.jl")
include("processors/p_process_lq_calibration_cut_cal.jl")
include("processors/p_process_psd_efficiencies_cal.jl")
include("processors/p_process_sipm_calibration_phy.jl")
include("processors/p_process_sipm_optimization_phy.jl")
include("processors/p_process_skm_phy.jl")
include("processors/p_process_stability_plots_phy.jl")
include("processors/process_aoe_calibration_cut_cal.jl")
include("processors/process_aoe_optimization_cal.jl")
include("processors/process_ct_correction_cal.jl")
include("processors/process_daq_energy_calibration_cal.jl")
include("processors/process_decay_time_cal.jl")
include("processors/process_dsp_aux_phy.jl")
include("processors/process_dsp_cal.jl")
include("processors/process_dsp_phy.jl")
include("processors/process_energy_calibration_cal.jl")
include("processors/process_evt_phy.jl")
include("processors/process_filter_optimization_cal.jl")
include("processors/process_lq_calibration_cut_cal.jl")
include("processors/peak_split.jl")
include("processors/process_peak_split_cal.jl")
include("processors/process_peak_split_phy.jl")
include("processors/process_psd_efficiencies_cal.jl")
include("processors/process_qcs_cal.jl")
include("processors/process_qcs_phy.jl")
include("processors/process_sipm_calibration_phy.jl")
include("processors/process_sipm_optimization_phy.jl")
include("processors/process_stability_plots_phy.jl")

include("using_packages.jl")
include("precompile.jl")

# The packages a Julia session needs to work with the data and the processors; `using JuLeAna`
# makes their names, not their contents, available. A defined `ParallelProcessingTools` in
# `Main` also lets ParallelProcessingTools set up the process when the active environment
# does not have it.
export CairoMakie, Dates, Distributed, Format, IntervalSets, LaTeXStrings, LDMUtils, LegendDataManagement, LegendDataTypes, LegendDSP,
       LegendEventAnalysis, LegendHDF5IO, LegendMakie, LegendSpecFits, Makie, Measurements, Measures, ParallelProcessingTools, Printf,
       ProgressMeter, PropDicts, PropertyFunctions, StatsBase, TimerOutputs, TypedTables, Unitful, UnitfulAtomic
export UnderscoreSafeLogger
export parallel, failure_log
export master_status, detector_status, truncate_string, truncate_error
export load_qc_evaluator
export ProcessingConfig, ProcessorSpec, run_steps, partition_steps, check_processor_kwargs
export ProcessorGraph, processor_graph, topological_order, required_processors, dependent_processors, waited_processors, layered_layout
export run_processing, run_step, ProcessingStopped, ProgressStore, progress, busy_workers, step_messages, show_progress
export DataflowSession
export DataflowController, dispatch!, snapshot, ControllerCommand, LoadSession, ReloadConfig, SelectPeriods, SelectRuns, SelectSteps,
       SetReprocess, SetProcessorLogLevel, SetProcessorPlotLevel, SetAnalysisRunsOnly, SetRunmode, SetRunmodeSettings, SetCheckDependencies,
       SetKwarg, SetStepLevel, ResetKwargs, ResetDependencyGraph, StartProcessing, StopProcessing, WriteConfig, AddWorkers,
       CancelAllocation, CancelAll, PostponeIdleCancel, EditStartScript, CreateProduction, SelectProduction, SelectDataset

public production_setup_dir, effective_config, save_plot, @debug_plot, @debug_progress, root_exception, @process_step, ProcessStepError,
       Failure, failure, failures, failure_info, failure_variables, @locals, rerun, escape_log_underscores, processing_logger,
       ProcessorLevelLogger, DEBUG_LOG_PACKAGES, process_log_file, parse_log_level, PROCESSORS, register_processor!, display_name,
       RENAMED_PROCESSORS, init_process, main, setup_session, run_no_tui, run_tui, parse_commandline, mirror_override_folders, report_path,
       read_report, report_index, failure_summary, report_overview, dataset_summary, period_summary, history_path, append_history,
       read_history, history_grid, WorkerManager, start_script!, edit_start_script!, add_workers!, cancel_allocation!, cancel_all!,
       allocations, mark_activity!, idle_deadline, check_idle!, workers_overview, ProductionSpec, check_production, create_production,
       data_config_text, running_manifest, snapshot_software, record_software, software_version, record_metadata, production_log,
       ProductionForm, production_fields, production_spec, complete_path, production_key!, production_answer!, production_sync!,
       render_production, @using_packages, ReportPlot, StepOutput, display_report, processors, Sync

end # module
