# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const LOG_LEVELS = Dict("debug" => Logging.Debug, "info" => Logging.Info, "warn" => Logging.Warn, "error" => Logging.Error)

"""
    parse_log_level(level::AbstractString)

Return the `Logging.LogLevel` named by `level`: `"debug"`, `"info"`, `"warn"` or
`"error"`. Throw an `ArgumentError` for any other value.

# Examples
```jldoctest
julia> JuLeAna.parse_log_level("warn")
Warn
```
"""
function parse_log_level(level::AbstractString)
    haskey(LOG_LEVELS, level) ||
        throw(ArgumentError("processing_config: key `config.log_level` must be one of \"debug\", \"info\", \"warn\" or \"error\", got $(repr(level))"))
    return LOG_LEVELS[level]
end

# Log level of the running processor, set by `run_processing` and `run_step`; `nothing`
# outside of a processor. `parallel` sets it again on the workers.
const PROCESSOR_LOG_LEVEL = ScopedValue{Union{Nothing,LogLevel}}(nothing)

# A progress line of `@debug_progress`: its description and the count.
const PROGRESS_LINE = r"^\[ Progress: (.*) \d+/\d+$"

"""
    @debug_progress desc for x in iterable
        ...
    end

Run the loop and, when the log level of the running processor is `debug` (see
[`ProcessorSpec`](@ref) and [`run_step`](@ref)), print a line `[ Progress: <desc> <i>/<n>` to
`stdout` at the start of iteration `i` of `n`, and `<desc> <n>/<n>` after the loop. The lines
are plain output, not log records, so that a worker's lines reach the head process; the
Workers page of the terminal user interface shows only the newest line of each `desc`. The
loop body may use `continue`.

# Examples
```julia
@debug_progress "Filekey HPGe: \$fk" for chinfo_det in chinfo
    detector_selected(chinfo_det.detector) || continue
    ...
end
```
"""
macro debug_progress(desc, loop)
    (Meta.isexpr(loop, :for) && Meta.isexpr(loop.args[1], :(=))) ||
        throw(ArgumentError("@debug_progress: expected a loop `for x in iterable ... end`"))
    var, iterable = loop.args[1].args
    return quote
        local desc, items = $(esc(desc)), $(esc(iterable))
        local show = something(PROCESSOR_LOG_LEVEL[], Logging.Info) <= Logging.Debug
        local n, i = length(items), 0
        for $(esc(var)) in items
            i += 1
            show && (println(stdout, "[ Progress: ", desc, " ", i, "/", n); flush(stdout))
            $(esc(loop.args[2]))
        end
        show && (println(stdout, "[ Progress: ", desc, " ", n, "/", n); flush(stdout))
        nothing
    end
end

"""
    DEBUG_LOG_PACKAGES

Name prefixes of the packages whose debug records a processor at log level `debug` writes:
JuLeAna, the Legend packages, BAT and the JuliaPhysics packages of the dataflow. A module
counts when its name or the name of one of its parent modules starts with one of them, so
submodules and package extensions such as `LegendMakieExt` are included.
"""
const DEBUG_LOG_PACKAGES = ("JuLeAna", "Legend", "BAT", "RadiationDetectorDSP", "RadiationDetectorSignals", "RadiationSpectra",
                            "SolidStateDetectors")

# Whether `mod` or one of its parent modules is named with a prefix of `DEBUG_LOG_PACKAGES`.
function debug_log_package(mod::Module)
    while true
        name = String(nameof(mod))
        any(prefix -> startswith(name, prefix), DEBUG_LOG_PACKAGES) && return true
        parentmodule(mod) === mod && return false
        mod = parentmodule(mod)
    end
end

"""
    ProcessorLevelLogger(inner::AbstractLogger, level::LogLevel)

Logger that passes to `inner` the records at or above the log level of the running
processor (see [`ProcessorSpec`](@ref)), or at or above `level` outside of a processor.
Debug records pass when that level is `Logging.Debug` and their module is listed in
`JULIA_DEBUG`, or, inside a processor, belongs to one of the [`DEBUG_LOG_PACKAGES`](@ref).
Records of other modules are rejected before their message is built.
"""
struct ProcessorLevelLogger{L<:AbstractLogger} <: AbstractLogger
    inner::L
    level::LogLevel
end

function passes(logger::ProcessorLevelLogger, level, _module, group)
    processor_level = PROCESSOR_LOG_LEVEL[]
    effective = something(processor_level, logger.level)
    level = convert(LogLevel, level)
    level > Logging.Debug && return level >= effective
    effective <= Logging.Debug || return false
    # `JULIA_DEBUG` lets debug records reach the logger without `shouldlog`
    return Base.CoreLogging.env_override_minlevel(group, _module) ||
           (!isnothing(processor_level) && _module isa Module && debug_log_package(_module))
end

min_enabled_level(::ProcessorLevelLogger) = Logging.Debug
function shouldlog(logger::ProcessorLevelLogger, level, _module, group, id)
    return passes(logger, level, _module, group) && shouldlog(logger.inner, level, _module, group, id)
end
catch_exceptions(logger::ProcessorLevelLogger) = catch_exceptions(logger.inner)

function handle_message(logger::ProcessorLevelLogger, level, message, _module, group, id, file, line; kwargs...)
    passes(logger, level, _module, group) || return nothing
    return handle_message(logger.inner, level, message, _module, group, id, file, line; kwargs...)
end

# Text of a log message: a message that can be shown as Markdown, such as a processor's
# report, is written as that Markdown.
log_text(message::AbstractString) = String(message)
function log_text(message)
    return showable(MIME"text/markdown"(), message) ? sprint(show, MIME"text/markdown"(), message) : string(message)
end

# One record per entry: `<UTC time> <level> [<module>] <message>`, further message lines
# and `key = value` pairs indented below, and the source location for warnings and errors.
# An exception is shown with `showerror`, with its backtrace if one is given.
function format_log_record(io::IO, log)
    print(io, Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss\Z"), " ", rpad(string(log.level), 5), " [", log._module, "] ")
    lines = split(log_text(log.message), '\n')
    println(io, first(lines))
    for line in lines[2:end]
        println(io, "    ", line)
    end
    for (key, value) in log.kwargs
        # `showerror` shows the errors inside wrappers such as `CompositeException`
        text = key !== :exception ? string(value) :
               value isa Tuple{Exception,Any} ? sprint(showerror, value...) : value isa Exception ? sprint(showerror, value) : string(value)
        println(io, "    ", key, " = ", replace(text, '\n' => "\n        "))
    end
    log.level >= Logging.Warn && println(io, "    @ ", log.file, ":", log.line)
    return nothing
end

"""
    processing_logger(; log_file=nothing, log_level=Logging.Info, console_level=Logging.Info)

Build the logger that [`init_process`](@ref) installs.

- With `log_file`, records are appended to that file, one timestamped entry per record,
  and the file is flushed after every record. Progress bar records of ProgressLogging
  (see [`show_progress`](@ref)) are not written. The file gets the records at or above the
  level of the running processor, and outside of a processor those at or above `log_level`
  (see [`ProcessorLevelLogger`](@ref)); at `Logging.Debug` this includes the debug records of
  the modules listed in the `JULIA_DEBUG` environment variable, and inside a processor those
  of the [`DEBUG_LOG_PACKAGES`](@ref).
- With `console_level` not `nothing`, records go to a `TerminalLogger` wrapped in an
  [`UnderscoreSafeLogger`](@ref). `console_level = Logging.Info` shows the debug
  records of the `JULIA_DEBUG` modules as well; a higher level shows only the records at
  or above it.

Throw an `ArgumentError` when neither sink is requested.
"""
function processing_logger(; log_file::Union{Nothing,AbstractString} = nothing, log_level::LogLevel = Logging.Info,
                           console_level::Union{Nothing,LogLevel} = Logging.Info)
    isnothing(log_file) &&
        isnothing(console_level) &&
        throw(ArgumentError("processing_logger: no log file and no console output requested"))
    # `JULIA_DEBUG` lets debug records of the listed modules pass every level check of the
    # composed loggers, so levels above debug are enforced on the record itself.
    at_least(level, logger) = level <= Logging.Debug ? logger : ActiveFilteredLogger(log -> log.level >= level, logger)
    sinks = AbstractLogger[]
    if !isnothing(console_level)
        console = UnderscoreSafeLogger(TerminalLogger(stderr, min(console_level, Logging.Info)))
        push!(sinks, console_level <= Logging.Info ? console : at_least(console_level, console))
    end
    if !isnothing(log_file)
        file = FormatLogger(format_log_record, log_file; append = true)
        # progress bars are for the terminal only
        no_bars = ActiveFilteredLogger(log -> !(log.message isa ProgressLogging.Progress), file)
        push!(sinks, ProcessorLevelLogger(no_bars, log_level))
    end
    return length(sinks) == 1 ? only(sinks) : TeeLogger(sinks...)
end

"""
    process_log_file(log_path::AbstractString)

Return the log file of the current process in the directory `log_path`: `head.log` on
the main process, `worker-<id>-<hostname>.log` on a worker.
"""
function process_log_file(log_path::AbstractString)
    return joinpath(log_path, myid() == 1 ? "head.log" : "worker-$(myid())-$(gethostname()).log")
end
