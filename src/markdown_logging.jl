import Logging: min_enabled_level, shouldlog, catch_exceptions, handle_message

"""
    escape_log_underscores(message::AbstractString)

Return `message` with every unescaped `_` outside of code spans replaced by `\\_`, so
that a Markdown renderer such as `TerminalLogger` does not read underscores in names as
emphasis.

# Examples
```jldoctest
julia> JuLeAna.escape_log_underscores("process_dsp_cal in `p_process_energy_cal`")
"process\\\\_dsp\\\\_cal in `p_process_energy_cal`"
```
"""
function escape_log_underscores(message::AbstractString)
    return replace(message, r"(`+).*?\1|(?<!\\)_"s => m -> m == "_" ? "\\_" : m)
end

"""
    UnderscoreSafeLogger(inner::AbstractLogger)

Logger that passes every record to `inner`, with string messages escaped by
[`escape_log_underscores`](@ref). Wrap a `TerminalLogger` in it so that names like
`process_dsp_cal` are shown as written instead of in italics. Level filtering and
exception handling are those of `inner`.

# Examples
```julia
using Logging, TerminalLoggers
global_logger(UnderscoreSafeLogger(TerminalLogger()))
```
"""
struct UnderscoreSafeLogger{L<:AbstractLogger} <: AbstractLogger
    inner::L
end

min_enabled_level(logger::UnderscoreSafeLogger) = min_enabled_level(logger.inner)
function shouldlog(logger::UnderscoreSafeLogger, level, _module, group, id)
    return shouldlog(logger.inner, level, _module, group, id)
end
catch_exceptions(logger::UnderscoreSafeLogger) = catch_exceptions(logger.inner)

function handle_message(logger::UnderscoreSafeLogger, level, message, _module, group, id, file, line; kwargs...)
    safe_message = message isa AbstractString ? escape_log_underscores(message) : message
    return handle_message(logger.inner, level, safe_message, _module, group, id, file, line; kwargs...)
end
