# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Names of the detectors chosen by `run_step`; `nothing` outside of it. `parallel` sets it
# again on the workers.
const DETECTOR_SELECTION = ScopedValue{Union{Nothing,Set{String}}}(nothing)

# `false` inside `run_step` with `outputs = :temp`: parameters and validity are not written.
# `parallel` sets it again on the workers.
const WRITE_PARS = ScopedValue{Bool}(true)

# Inside `run_step`: collects the reports the processor writes and the results of `parallel`.
const STEP_RECORD = ScopedValue{Any}(nothing)

"""
    detector_selected(det)::Bool

`true` unless [`run_step`](@ref) runs a processor for chosen detectors and `det` is not one
of them. Processors that loop over detectors inside one item, such as the DSP processors,
skip the detectors that are not selected.
"""
detector_selected(det) = (sel = DETECTOR_SELECTION[]; isnothing(sel) || string(det) in sel)

"""
    redo_detector(det)::Bool

`true` if [`run_step`](@ref) runs a processor for chosen detectors and `det` is one of them.
A processor processes such a detector again even if its parameters or output already
exist, as with `reprocess = true` for this detector only.
"""
redo_detector(det) = (sel = DETECTOR_SELECTION[]; !isnothing(sel) && string(det) in sel)

"""
    stored_detectors(outdata, group::AbstractString)::Vector{String}

Names of the detectors stored in `group` (e.g. `"jldsp"`) of the open LH5 file `outdata`, or
an empty vector without that group. The group is looked up by its `String` name: an
`LHDataStore` reports no `Symbol` keys.
"""
function stored_detectors(outdata, group::AbstractString)
    return haskey(outdata, group) ? String[string(k) for k in keys(outdata[group])] : String[]
end

"""
    write_pars(args...)

Write parameters with `writelprops(args...)`, except inside
[`run_step`](@ref) with `outputs = :temp`, where nothing is written.
"""
write_pars(args...) = WRITE_PARS[] ? writelprops(args...) : nothing

"""
    write_validity(args...; kwargs...)

Write a validity entry with `LegendDataManagement.LDMUtils.writevalidity`, except inside
[`run_step`](@ref) with `outputs = :temp`, where nothing is written.
"""
function write_validity(args...; kwargs...)
    return WRITE_PARS[] ? writevalidity(args...; kwargs...) : nothing
end

"""
    make_par_dir(path) -> path

Create the parameter directory `path` like `mkpath`, except inside [`run_step`](@ref) with
`outputs = :temp`, where nothing is created.
"""
make_par_dir(path) = WRITE_PARS[] ? mkpath(path) : path

"""
    write_report(filename, report)

Write the processor report `report` to `filename` with `writelreport`. Inside
[`run_step`](@ref), `report` also goes into the report of the step.
"""
function write_report(filename, report)
    record = STEP_RECORD[]
    isnothing(record) || push!(record.reports, report)
    return writelreport(filename, report)
end

"""
    PROCESSOR_TRAITS::Dict{Symbol,NamedTuple}

Properties of the registered processors that [`run_step`](@ref) needs, set by
[`register_processor!`](@ref): `output_tiers`, the data tiers the processor writes, and
`detector_selection`, whether the processor processes the detectors that
[`redo_detector`](@ref) names again and skips the others.
"""
const PROCESSOR_TRAITS = Dict{Symbol,NamedTuple{(:output_tiers, :detector_selection),Tuple{Vector{Symbol},Bool}}}()

const DEFAULT_TRAITS = (output_tiers = Symbol[], detector_selection = true)

"""
    JuLeAna.processors(config = JuLeAna.default_config_file(); processors = PROCESSORS)

Table of the registered processors `processors`: the run-level processors of `config` in
the order of their rank, then the partition-level ones, then the processors that are not
in `config`. `config` is a [`ProcessingConfig`](@ref) or the path of a config file.

Columns: `Processor`; from `config` `Level` (`:run` or `:partition`), `Category`, `Rank`
and `Enabled`, `missing` for a processor that is not in `config`; and from
[`PROCESSOR_TRAITS`](@ref) `Detectors`, whether [`run_step`](@ref) can run the processor
for chosen detectors, and `OutputTiers`, the data tiers it writes.

# Examples
```julia
JuLeAna.processors()
JuLeAna.processors(joinpath(pkgdir(JuLeAna), "config", "processing_config.yaml"))
```
"""
function processors(config = default_config_file(); processors::AbstractDict{Symbol} = PROCESSORS)
    cfg = config isa ProcessingConfig ? config : ProcessingConfig(config)
    specs = vcat(sort!(collect(values(cfg.processors)); by = spec -> spec.rank),
                 sort!(collect(values(cfg.p_processors)); by = spec -> spec.rank))
    names = vcat([spec.name for spec in specs if haskey(processors, spec.name)],
                 sort!(setdiff(collect(keys(processors)), (spec.name for spec in specs))))
    spec_of = Dict(spec.name => spec for spec in specs)
    from_spec(name, field) = haskey(spec_of, name) ? getfield(spec_of[name], field) : missing
    traits(name) = get(PROCESSOR_TRAITS, name, DEFAULT_TRAITS)
    return Table(Processor = names, Level = [from_spec(n, :level) for n in names], Category = [from_spec(n, :category) for n in names],
                 Rank = [from_spec(n, :rank) for n in names], Enabled = [from_spec(n, :enabled) for n in names],
                 Detectors = [traits(n).detector_selection for n in names], OutputTiers = [traits(n).output_tiers for n in names])
end

"""
    run_step(step::Symbol, period, run = nothing; detectors = nothing, outputs = :temp,
        output_dir = nothing, config = JuLeAna.default_config_file(), l200 = nothing,
        show_report::Bool = isinteractive(), debug = false, pause = nothing, error_plots = nothing, log_level = nothing,
        plot_level = nothing,
        processors::AbstractDict{Symbol} = PROCESSORS, kwargs...)

Run the processor `step` for `period` and, for a run-level processor, `run`, in the
calling Julia process, for example in the REPL. A partition-level processor takes no
`run`. `step` is the name of a registered processor, a key of [`JuLeAna.PROCESSORS`](@ref),
and [`JuLeAna.processors`](@ref) lists them with their level, category and rank;
`?JuLeAna.<step>`, e.g. `?JuLeAna.process_energy_calibration_cal`, shows what the
processor does and its keywords.

Only the defaults are needed: by default, nothing is written to the data production, and
the plots, reports and data files go to a temporary directory.

# Keywords
- `detectors`: the detectors to process, e.g. `[:V01234A]`; they are processed again, also
  when their parameters or output exist. `nothing` (the default) processes all detectors,
  with `reprocess = true` unless given. A detector that the processor does not process in
  this run or partition stops the call with an error listing the detectors it processes.
- `outputs`: `:temp` (the default) writes the plots, reports and the data tiers the
  processor writes (its `output_tiers`, see [`register_processor!`](@ref)) to
  `output_dir`, and no parameters or validity; parameters are read from the production,
  and the detectors not in `detectors` are not run. `:production` writes everything to the
  production paths of `l200`, which cannot be undone; the detectors not in `detectors` are
  skipped as already processed, so the parameters, validity and reports stay complete.
- `output_dir`: the directory of the temporary outputs; by default one temporary directory
  for all calls in the Julia session, see `step.output_dir`. The report of each call is
  appended to `<output_dir>/reports/<step>.md`: the report of the processor with only the
  rows of `detectors`, and below it the plots of each detector the processor saved during
  this call, in the order they were saved.
- `config`: a [`ProcessingConfig`](@ref) or the path of a config file; by default the
  config of the data production. The processor must be in it; for a processor that is not,
  use the config of the package, `joinpath(pkgdir(JuLeAna), "config", "processing_config.yaml")`.
- `l200`: the `LegendData` to use; by default `LegendData(:l200)`, built after the
  `env_variables` of `config` are set.
- `show_report`: display the report at the end with [`display_report`](@ref); the default
  in an interactive session.
- `debug`: `true` runs the items one after the other in the calling process, without
  workers and `timeout`, and captures each failed [`@process_step`](@ref) as a
  [`Failure`](@ref) with the variables of the processor at that step; see
  [`JuLeAna.failure`](@ref). A summary of the failures is printed at the end.
  `:infiltrate` does the same and also stops at each failed step in an Infiltrator
  prompt with these variables; leaving the prompt goes on with the error. Needs
  `using Infiltrator`.
- `pause`: `:all`, or the names of steps, e.g. `["e_cusp simple calibration"]`, with their
  interpolations done: stop in an Infiltrator prompt after each of these steps that
  succeeds, with the variables of the processor and the value of the step as
  `step_value`. Implies `debug = true` if `debug` is `false`. Needs `using Infiltrator`.
- `error_plots`: whether a failed [`@process_step`](@ref) runs its `on_error` hook, which
  saves a debug plot; `nothing` (the default) takes the `error_plots` setting of the
  processor in `config`.
  In the report, these plots, whose names start with `error_`, are linked, not embedded.
- `log_level`: `:debug`, `:info`, `:warn` or `:error`: the processor logs at this level,
  also to the terminal; at `:debug` this includes the debug records of the
  [`DEBUG_LOG_PACKAGES`](@ref). `nothing` (the default) takes the `log_level` of the
  processor in `config`, which applies to the log files only. Items on workers log to the
  workers' log files.
- `plot_level`: `:info` or `:debug`; at `:debug` the processor also saves its
  [`@debug_plot`](@ref) plots, which the report shows like the others. `nothing` (the
  default) takes the `plot_level` of the processor in `config`.
- `processors`: the processors by name, [`JuLeAna.PROCESSORS`](@ref) by default.
- `kwargs`: keyword arguments of the processor, e.g. `timeout = 0`. The processor gets the
  keyword arguments of `config`, then `only_first_period = false` for a partition-level
  processor and `reprocess = true` when `detectors` is `nothing`, then `kwargs`.

# Workers
The items of the processor, e.g. its detectors, go to the workers of the
ParallelProcessingTools worker pool, or run in the calling process when no workers are
started. Workers started from the session need JuLeAna and ParallelProcessingTools in the
active environment:

```julia
using JuLeAna
ParallelProcessingTools.@always_everywhere using JuLeAna
ParallelProcessingTools.runworkers(ParallelProcessingTools.OnLocalhost(n = 4))
```

`runworkers` returns at once; the workers join the pool when they are up, see
`ParallelProcessingTools.worker_resources()`.

# Returns
Return a [`StepOutput`](@ref) with the report, the reports of the processor, the
results of its items and the captured failures.

Throws an `ArgumentError` if `step` is not registered or not in `config`, if `run` is given
for a partition-level processor or missing for a run-level one, if `detectors` is given for
a processor that cannot select detectors, or if `outputs` is not `:temp` or `:production`.

# Examples
```julia
using JuLeAna
# run level: a detector of p03 r000
step = run_step(:process_energy_calibration_cal, 3, 0; detectors = [:V01234A])
# partition level, no run
step = run_step(:p_process_energy_cal, 3; detectors = [:V01234A])
JuLeAna.display_report(step.report)
# capture the failed steps of a detector
step = run_step(:process_energy_calibration_cal, 3, 0; detectors = [:V01234A], debug = true)
f = JuLeAna.failure()
```
"""
function run_step(step::Symbol, period, run = nothing; detectors = nothing, outputs::Symbol = :temp, output_dir = nothing,
                  config = default_config_file(), l200 = nothing, show_report::Bool = isinteractive(), debug::Union{Bool,Symbol} = false,
                  pause = nothing, error_plots::Union{Nothing,Bool} = nothing, log_level::Union{Nothing,Symbol} = nothing,
                  plot_level::Union{Nothing,Symbol} = nothing, processors::AbstractDict{Symbol} = PROCESSORS, kwargs...)
    haskey(processors, step) || throw(ArgumentError("run_step: unregistered processor `$step`"))
    isnothing(log_level) ||
        haskey(LOG_LEVELS, string(log_level)) ||
        throw(ArgumentError("run_step: `log_level` is $(repr(log_level)), expected :debug, :info, :warn or :error"))
    plot_level in (nothing, :info, :debug) ||
        throw(ArgumentError("run_step: `plot_level` is $(repr(plot_level)), expected :info or :debug"))
    debug in (false, true, :infiltrate) || throw(ArgumentError("run_step: `debug` is $(repr(debug)), expected false, true or :infiltrate"))
    isnothing(pause) ||
        pause === :all ||
        pause isa AbstractVector{<:AbstractString} ||
        throw(ArgumentError("run_step: `pause` is $(repr(pause)), expected :all or a vector of step names"))
    (debug === :infiltrate || !isnothing(pause)) &&
        isnothing(STOP_HOOK[]) &&
        throw(ArgumentError("run_step: `debug = :infiltrate` and `pause` stop in an Infiltrator prompt; run `using Infiltrator` first"))
    outputs in (:temp, :production) || throw(ArgumentError("run_step: `outputs` is $(repr(outputs)), expected :temp or :production"))
    traits = get(PROCESSOR_TRAITS, step, DEFAULT_TRAITS)
    !isnothing(detectors) &&
        !traits.detector_selection &&
        throw(ArgumentError("run_step: processor `$step` cannot select detectors, run it without `detectors`"))
    cfg = config isa ProcessingConfig ? config : ProcessingConfig(config)
    spec = haskey(cfg.processors, step) ? cfg.processors[step] : get(cfg.p_processors, step, nothing)
    isnothing(spec) && throw(ArgumentError("run_step: processor `$step` is not in the config"))
    spec.level === :run && isnothing(run) && throw(ArgumentError("run_step: the run-level processor `$step` needs a run"))
    spec.level === :partition && !isnothing(run) && throw(ArgumentError("run_step: the partition-level processor `$step` takes no run"))
    if isnothing(l200)
        # the environment variables must be set before the metadata is loaded
        foreach(((key, value),) -> ENV[key] = value, cfg.env_variables)
        l200 = LegendData(:l200)
    end
    dir = mkpath(isnothing(output_dir) ? session_output_dir() : output_dir)
    step_l200 = outputs === :temp ? redirect_outputs(l200, dir, vcat([:jlplt, :jlrep, :jllog], traits.output_tiers)) : l200
    period = DataPeriod(period)
    args = spec.level === :run ? (period, DataRun(run)) : (period,)
    defaults = merge(spec.level === :partition ? (; only_first_period = false) : (;), isnothing(detectors) ? (; reprocess = true) : (;))
    selection = isnothing(detectors) ? nothing : Set(string.(detectors))
    record = (reports = Any[], results = Any[])
    failures = LAST_FAILURES[] = Failure[]
    capture = debug === false && isnothing(pause) ? nothing :
              merge(debug_capture(step, args; infiltrate = debug === :infiltrate, pause), (; failures))
    level = isnothing(log_level) ? spec.log_level : LOG_LEVELS[string(log_level)]
    started = time()
    run_processor() = with(DETECTOR_SELECTION => selection, WRITE_PARS => outputs === :production, STEP_RECORD => record,
                           DEBUG_CAPTURE => capture, ERROR_PLOTS => something(error_plots, spec.error_plots), PROCESSOR_LOG_LEVEL => level,
                           PLOT_LEVEL => something(plot_level, spec.plot_level), PLOT_FORMATS => cfg.plot_formats) do
        return processors[step](cfg, step_l200, args...; merge(NamedTuple(spec.kwargs), defaults, NamedTuple(kwargs))...)
    end
    # a level given here also applies to the terminal
    isnothing(log_level) ? run_processor() : Logging.with_logger(run_processor, ProcessorLevelLogger(Logging.current_logger(), level))
    plot_roots = if spec.level === :run
        [joinpath(step_l200.tier[:jlplt], "rplt", string(spec.category), string(period), string(DataRun(run)))]
    else
        pplt = joinpath(step_l200.tier[:jlplt], "pplt")
        isnothing(selection) ? [pplt] : [joinpath(pplt, det) for det in selection]
    end
    report = step_report(step, args, spec.level, outputs, dir, selection, record.reports, plot_roots, started)
    report_file = joinpath(mkpath(joinpath(dir, "reports")), "$step.md")
    open(io -> (show(io, MIME"text/markdown"(), report); println(io)), report_file, "a")
    @info "run_step: report appended to $report_file"
    # outside of the logger, which shows messages as text only
    show_report && display_report(report)
    isnothing(capture) || print_failures(stdout, failures)
    return StepOutput(step, args, report, report_file, record.reports, dir, record.results, failures)
end

function print_failures(io::IO, failures)
    if isempty(failures)
        println(io, "run_step: no failed `@process_step` was captured")
        return nothing
    end
    println(io, "run_step: $(length(failures)) failed `@process_step` captured, see `JuLeAna.failure()` and `JuLeAna.failures()`:")
    for (i, f) in enumerate(failures)
        print(io, i, ". ")
        show(io, MIME"text/plain"(), f)
        println(io)
    end
end

"""
    StepOutput

The output of [`run_step`](@ref), with the fields
- `step`, `args`: the processor and its period and run,
- `report`: the report of the call as a `LegendReport`, with the plots as
  [`ReportPlot`](@ref)s; [`display_report`](@ref) shows it with the plots as images,
- `report_file`: the path of the report file the report was appended to,
- `reports`: the reports the processor wrote, complete with all detectors,
- `output_dir`: the output directory,
- `results`: the `item => result` pairs of all `parallel` calls of the processor,
- `failures`: the [`Failure`](@ref)s captured with `debug` or `pause`.
"""
struct StepOutput
    step::Symbol
    args::Tuple
    report::Any
    report_file::String
    reports::Vector{Any}
    output_dir::String
    results::Vector{Any}
    failures::Vector{Failure}
end

function Base.show(io::IO, out::StepOutput)
    return print(io, "StepOutput(", out.step, " ", join(string.(out.args), " "), ": ", length(out.results), " results, ",
                 isempty(out.failures) ? "" : "$(length(out.failures)) failures, ", "report in ", out.report_file, ")")
end

# The temporary output directory of `run_step` in this Julia session, created on first use.
const SESSION_OUTPUT_DIR = Ref("")

function session_output_dir()
    isempty(SESSION_OUTPUT_DIR[]) && (SESSION_OUTPUT_DIR[] = mktempdir(; prefix = "juleana-run_step-", cleanup = false))
    return SESSION_OUTPUT_DIR[]
end

# `l200` with the data tiers `tiers` in the directory `dir`; everything else, also the
# parameters, at the paths of `l200`.
function redirect_outputs(l200::LegendData, dir::AbstractString, tiers)
    setup = getfield(l200, :_config)
    keys_new = [["tier", string(t)] for t in tiers]
    paths = vcat(filter(p -> !(first(p) in keys_new), setup.paths), [k => mkpath(joinpath(dir, last(k))) for k in keys_new])
    return LegendData(LegendDataManagement.SetupConfig(sort(paths), setup.dataset), getfield(l200, :_name), getfield(l200, :_dataset))
end

# The report of `run_step`: the processor reports with only the rows of `selection`, then
# the plots below `plot_roots` saved since `started`, grouped by detector.
function step_report(step, args, level, outputs, dir, selection, reports, plot_roots, started)
    report = lreport("# $step: $(join(string.(args), " ")), $(utc_timestamp())")
    lreport!(report, "Detectors: $(isnothing(selection) ? "all" : join(sort!(collect(selection)), ", "))")
    lreport!(report, "Outputs: $outputs, `$dir`")
    for processor_report in reports, content in processor_report._contents

        lreport!(report, selected_rows(content, selection))
    end
    plots = [joinpath(root, f) for plot_root in filter(isdir, plot_roots) for (root, _, files) in walkdir(plot_root)
             for f in files if endswith(f, ".png") && mtime(joinpath(root, f)) >= started]
    isempty(plots) && return report
    lreport!(report, "# Plots")
    plot_det(file) = plot_detector(file, level)
    detectors = isnothing(selection) ? sort!(unique(plot_det.(plots))) : sort!(collect(selection))
    for det in detectors
        det_plots = sort!(filter(p -> plot_det(p) == det, plots); by = p -> (mtime(p), p))
        isempty(det_plots) && continue
        lreport!(report, "## $det")
        for file in det_plots
            name = splitext(basename(file))[1]
            lreport!(report, "### $name")
            # debug plots of failed steps are linked, so that many failures do not fill the report
            lreport!(report,
                     startswith(split(name, '-')[end], "error_") ? "[$(basename(file))]($(relpath(file, joinpath(dir, "reports"))))" :
                     ReportPlot(file))
        end
    end
    return report
end

"""
    ReportPlot(file)

The PNG plot `file` in the report of [`run_step`](@ref). In the Markdown and HTML report,
the plot is embedded as an image; as text, it is shown by its file name.
[`display_report`](@ref) displays it as an image.
"""
struct ReportPlot
    file::String
end

Base.show(io::IO, ::MIME"image/png", p::ReportPlot) = write(io, read(p.file))

function Base.show(io::IO, ::MIME"text/html", p::ReportPlot)
    return print(io, "<img src=\"data:image/png;base64,$(base64encode(read(p.file)))\" width=\"800\">")
end

Base.show(io::IO, ::MIME"text/plain", p::ReportPlot) = print(io, p.file)

# The VS Code plot pane shows HTML of this MIME type; other displays do not accept it.
const PLOT_PANE_HTML = MIME"application/vnd.julia-vscode.plotpane+html"()

# The Markdown report `markdown` as an HTML page, with its tables, HTML status cells and
# embedded plots.
function report_html(markdown::AbstractString)
    parser = CommonMark.Parser()
    CommonMark.enable!(parser, CommonMark.TableRule())
    style = "<style>body{background:white;color:black;font-family:sans-serif} " *
            "table{border-collapse:collapse} th,td{border:1px solid #999;padding:2px 6px}</style>"
    return style * CommonMark.html(parser(markdown))
end

"""
    display_report(report)
    display_report(path::AbstractString)

Display the report `report` of [`run_step`](@ref), e.g. `step.report`, or the Markdown
report file at `path`, e.g. a report of the production found with
[`JuLeAna.report_path`](@ref) or `step.report_file`.

In VS Code with the plot pane on, the report is shown there as one page, with its tables
and plots. Otherwise `report` is shown with `display`: the text and tables as usual, and
each [`ReportPlot`](@ref) as an image by the first display in the display stack that shows
`image/png`. In a terminal, such displays come with KittyTerminalImages (Kitty, Ghostty)
and ImageInTerminal (terminals with Sixel support, needs ImageIO to read the PNG). Without
such a display, a plot is shown by its file name. A report file is shown as formatted
Markdown text.

# Examples
```julia
using KittyTerminalImages
JuLeAna.display_report(step.report)
JuLeAna.display_report(JuLeAna.report_path(l200, :process_energy_calibration_cal, :run, DataPeriod(3), DataRun(0), :cal))
```
"""
function display_report(report)
    if displayable(PLOT_PANE_HTML)
        display(PLOT_PANE_HTML, report_html(sprint(show, MIME"text/markdown"(), report)))
        return nothing
    end
    text = Any[]
    show_text() = isempty(text) || (display(lreport(text...)); empty!(text))
    for content in report._contents
        if content isa ReportPlot
            show_text()
            try
                display(MIME"image/png"(), content)
            catch e
                # no display in the display stack shows `image/png`
                e isa MethodError && e.f === display || rethrow()
                display(content)
            end
        else
            push!(text, content)
        end
    end
    show_text()
    return nothing
end

function display_report(path::AbstractString)
    isfile(path) || throw(ArgumentError("display_report: there is no report file at $path"))
    markdown = read(path, String)
    if displayable(PLOT_PANE_HTML)
        display(PLOT_PANE_HTML, report_html(markdown))
    else
        parser = CommonMark.Parser()
        CommonMark.enable!(parser, CommonMark.TableRule())
        display(parser(markdown))
    end
    return nothing
end

# The detector in a plot file name `<setup>-<period>-<run>-<category>-<detector>-<name>.png` of
# a run-level processor or `<setup>-<partition>-<category>-<detector>-<name>.png` of a
# partition-level one.
function plot_detector(file, level::Symbol)
    return String(split(basename(file), '-')[level === :run ? 5 : 4])
end

# `content` with only the rows whose `Detector` is in `selection`.
function selected_rows(content, selection)
    (isnothing(selection) || !(content isa StructArray) || !hasproperty(content, :Detector)) && return content
    return content[[string(det) in selection for det in content.Detector]]
end
