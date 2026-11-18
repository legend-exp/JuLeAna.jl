# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

struct StepProgress
    step::String
    index::Int
    count::Int
    done::Int
    total::Union{Nothing,Int}
    bytes::Union{Nothing,Int}
    detail::String
end

# Like any failing callback it stops the child process the reading came from.
struct SyncStopped <: Exception end

Base.showerror(io::IO, ::SyncStopped) = print(io, "stopped on request")

# A step name outside `names` is an error, so the count and index shown agree with the operation.
struct Steps{F}
    names::Vector{String}
    report::F
end

const NO_STEPS = Steps(String[], nothing)

function (steps::Steps)(name::AbstractString; done = 0, total = nothing, bytes = nothing, detail = "")
    steps.report === nothing && return nothing
    index = findfirst(==(name), steps.names)
    index === nothing && throw(ArgumentError("unknown step $name; the operation has $(steps.names)"))
    steps.report(StepProgress(name, index, length(steps.names), done, total, bytes, detail))
    return nothing
end

function format_step(p::StepProgress)
    return string("[", p.index, "/", p.count, "] ", p.step, p.total === nothing ? "" : " $(p.done)/$(p.total)",
                  p.bytes === nothing ? "" : "  " * format_bytes(p.bytes), isempty(p.detail) ? "" : "  " * p.detail)
end

Base.@kwdef mutable struct StepPrinter
    io::IO = stdout
    last::Union{Nothing,StepProgress} = nothing
    width::Int = 0
end

function (printer::StepPrinter)(p::StepProgress)
    changed = printer.last !== nothing && printer.last.step != p.step
    changed && println(printer.io)
    printer.last = p
    line = format_step(p)
    pad = changed ? 0 : max(0, printer.width - length(line))
    printer.width = length(line)
    print(printer.io, "\r", line, " "^(pad + 3))
    flush(printer.io)
    return nothing
end

function with_failed_step(f, printer::StepPrinter, err::IO = stderr)
    try
        return f()
    catch
        printer.last === nothing || (println(printer.io); println(err, "failed in step \"", printer.last.step, "\""))
        rethrow()
    end
end
