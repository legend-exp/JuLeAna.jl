# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    StepProgress(step, index, count, done, total, bytes, detail)

One progress reading of a long operation: the name of the step, its position `index` of `count`
steps, `done` of `total` units (`total` is `nothing` when the step has no known size) and the bytes
moved so far (`nothing` when not measured). `detail` is free text such as the rsync rate and ETA.
"""
struct StepProgress
    step::String
    index::Int
    count::Int
    done::Int
    total::Union{Nothing,Int}
    bytes::Union{Nothing,Int}
    detail::String
end

"""
    Steps(names, report)

The steps of one operation, in execution order, and the callback that receives a
[`StepProgress`](@ref) for each reading (`nothing` reports nothing). Calling the object with a step
name reports that step; a name outside `names` is an error, so the count and the index shown to the
user always agree with the operation.
"""
struct Steps{F}
    names::Vector{String}
    report::F
end

const NO_STEPS = Steps(String[], nothing)

function (steps::Steps)(name::AbstractString; done::Integer = 0, total::Union{Nothing,Integer} = nothing,
                        bytes::Union{Nothing,Integer} = nothing, detail::AbstractString = "")
    steps.report === nothing && return nothing
    index = findfirst(==(name), steps.names)
    index === nothing && throw(ArgumentError("unknown step $name; the operation has $(steps.names)"))
    steps.report(StepProgress(name, index, length(steps.names), done, total, bytes, detail))
    return nothing
end

"""
    format_step(p::StepProgress)::String
"""
function format_step(p::StepProgress)
    text = string("[", p.index, "/", p.count, "] ", p.step)
    p.total === nothing || (text *= string(" ", p.done, "/", p.total))
    p.bytes === nothing || (text *= "  " * format_bytes(p.bytes))
    isempty(p.detail) || (text *= "  " * p.detail)
    return text
end

"""
    StepPrinter(io = stdout)

A progress callback for headless runs: each reading rewrites the current line and a new step starts a new
line. [`failed_step`](@ref) names the last step reported, which is the one an error came from.
"""
mutable struct StepPrinter
    io::IO
    last::Union{Nothing,StepProgress}
end

StepPrinter(io::IO = stdout) = StepPrinter(io, nothing)

function (printer::StepPrinter)(p::StepProgress)
    printer.last === nothing || printer.last.step == p.step || println(printer.io)
    printer.last = p
    print(printer.io, "\r", format_step(p), "   ")
    flush(printer.io)
    return nothing
end

failed_step(printer::StepPrinter) = printer.last === nothing ? "" : printer.last.step
