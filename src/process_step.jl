# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# The item that `parallel` is processing in the current task, `nothing` outside of `parallel`
const CURRENT_ITEM = ScopedValue{Any}(nothing)

# Inside `run_step` with `debug` or `pause`: a `debug_capture`, with the processor, its period
# and run, the failures that `@process_step` captures and where to stop; `nothing` otherwise.
const DEBUG_CAPTURE = ScopedValue{Any}(nothing)

# `infiltrate`: stop at the innermost failing step; `pause`: `nothing`, `:all` or the names of
# the steps to stop after when they succeed.
function debug_capture(step, args; infiltrate::Bool = false, pause = nothing)
    return (; step, args, failures = Failure[], lock = ReentrantLock(), infiltrate, pause)
end

# Called with the module, the local variables, the file and the line at each stop of
# `run_step` with `debug = :infiltrate` or `pause`; `nothing` without a stop function. The
# extension for Infiltrator sets `Infiltrator.infiltrate`, which opens its prompt.
const STOP_HOOK = Ref{Any}(nothing)

# Whether a failed `@process_step` runs its `on_error` hook: the `error_plots` setting of the
# running processor, or the `error_plots` keyword of `run_step`. `parallel` sets it again on
# the workers.
const ERROR_PLOTS = ScopedValue{Bool}(false)

"""
    ProcessStepError <: Exception

The error thrown by [`@process_step`](@ref) when its block fails: the step name `name`, the
item of [`parallel`](@ref) that was processed (`nothing` outside of `parallel`) and the
[`root_exception`](@ref) `exception` of the failure. It prints as `"<name>: <exception>"`.
"""
struct ProcessStepError <: Exception
    name::String
    item::Any
    exception::Any
end

Base.show(io::IO, e::ProcessStepError) = print(io, e.name, ": ", e.exception)

"""
    @process_step name block
    @process_step name on_error = hook block

Run `block` as one named step of a processor and return its value. If `block` throws, log
`"<name> failed for <detector>: <error>"` as an `@error` and throw a
[`ProcessStepError`](@ref) with the [`root_exception`](@ref) of the failure. The detector is
that of the item [`parallel`](@ref) is processing; without one, the message has no
`for <detector>`.

`name` is a string, usually with interpolations; it is only evaluated when `block` fails.
When steps are nested, only the innermost failing step logs: an outer step passes the
`ProcessStepError` on unchanged. `block` has the variable scope of a `try` block: it can
assign variables of the enclosing function, and variables first assigned in `block` are
local to it.

Inside [`run_step`](@ref) with `debug = true`, the innermost failing step also captures a
[`Failure`](@ref) with the local variables of the processor at the step, see
[`JuLeAna.failure`](@ref). With `debug = :infiltrate`, it also stops there in an
Infiltrator prompt. With `pause`, a step whose name is selected stops after it succeeded,
with the value of `block` as the variable `step_value`.

`hook` is a function without arguments that saves a debug plot of the failure, with the
variables of the processor, and a plot name starting with `error_`; the report of
[`run_step`](@ref) links such plots instead of embedding them. The innermost failing step
calls it when the `error_plots` setting of the processor (or of `run_step`) is on, before
the `ProcessStepError` is thrown. If `hook` throws, a warning is logged and the error of the
step is thrown unchanged. `hook` is only evaluated when `block` fails.

# Examples
```julia
result_simple, report_simple = @process_step "\$e_type simple calibration" begin
    simple_calibration(e_uncal, th228_lines, left_window_sizes, right_window_sizes)
end

result_simple, report_simple = @process_step "\$e_type simple calibration" on_error = () ->
        save_plot(lplot(e_uncal), l200, filekey, det, Symbol("error_simple_calibration_\$e_type")) begin
    simple_calibration(e_uncal, th228_lines, left_window_sizes, right_window_sizes)
end
```
"""
macro process_step(name, args...)
    isempty(args) && throw(ArgumentError("@process_step needs a name and a block"))
    block, options = last(args), Base.front(args)
    hook = nothing
    for option in options
        Meta.isexpr(option, :(=), 2) && first(option.args) === :on_error ||
            throw(ArgumentError("@process_step: unknown option `$option`, expected `on_error = hook`"))
        hook = last(option.args)
    end
    err, value = gensym("err"), gensym("value")
    file, line = string(__source__.file), __source__.line
    return quote
        $value = try
            $(esc(block))
        catch $err
            # `Base.@locals` must run here, in the processor; it only runs in debug mode
            process_step_failed($err, $(esc(name)), $file, $line, capturing($err) ? Base.@locals() : nothing, $(QuoteNode(block)),
                                $__module__, $(esc(hook)))
        end
        pausing() && process_step_paused($(esc(name)), $file, $line, Base.@locals(), $__module__, $value, $(QuoteNode(block)))
        $value
    end
end

capturing(e) = !isnothing(DEBUG_CAPTURE[]) && !(e isa ProcessStepError)

pausing() = (capture = DEBUG_CAPTURE[]; !isnothing(capture) && !isnothing(capture.pause))

# The variables of `variables` without the names that macros generate, which start with '#'.
function processor_variables(variables)
    return Dict{Symbol,Any}(k => v for (k, v) in variables if !startswith(string(k), '#'))
end

# The code of the step `block`, without line numbers, as lines of Julia
function step_code(block)
    ex = Base.remove_linenums!(deepcopy(block))
    return Meta.isexpr(ex, :block) ? join(string.(ex.args), "\n") : string(ex)
end

function process_step_paused(name, file, line, variables, mod, value, block)
    pause = DEBUG_CAPTURE[].pause
    pause === :all || string(name) in pause || return nothing
    item = CURRENT_ITEM[]
    det = hasproperty(item, :detector) ? " for $(item.detector)" : ""
    @info "Paused after $name$det; its value is `step_value`. The code of the step:\n```julia\n$(step_code(block))\n```" _file=file _line=line
    STOP_HOOK[](mod, merge(processor_variables(variables), Dict{Symbol,Any}(:step_value => value)), file, line)
    return nothing
end

function process_step_failed(e, name, file, line, variables = nothing, block = nothing, mod = nothing, on_error = nothing)
    e isa ProcessStepError && rethrow()
    item = CURRENT_ITEM[]
    step_error = ProcessStepError(string(name), item, root_exception(e))
    det = hasproperty(item, :detector) ? " for $(item.detector)" : ""
    @error "$(step_error.name) failed$det: $(truncate_error(step_error.exception))" _file=file _line=line
    capture = DEBUG_CAPTURE[]
    vars = nothing
    if !isnothing(variables) && !isnothing(capture)
        vars = processor_variables(variables)
        failure = Failure(step_error.name, capture.step, capture.args, item, step_error.exception, catch_backtrace(), vars, block, mod,
                          file, line)
        lock(() -> push!(capture.failures, failure), capture.lock)
    end
    if !isnothing(on_error) && ERROR_PLOTS[]
        try
            on_error()
        catch hook_error
            @warn "the error plot of $(step_error.name)$det failed: $(truncate_error(hook_error))" _file=file _line=line
        end
    end
    if !isnothing(vars) && capture.infiltrate
        @info "Stopped at the failed $(step_error.name)$det. The code of the step:\n```julia\n$(step_code(block))\n```" _file=file _line=line
        STOP_HOOK[](mod, vars, file, line)
    end
    return throw(step_error)
end

"""
    Failure

A failed [`@process_step`](@ref), captured by [`run_step`](@ref) with `debug = true`. The
local variables of the processor at the step are its properties, e.g. `f.aoe` for a
variable `aoe`, and `propertynames(f)` lists them. [`failure_info`](@ref) gives the step
name, processor, item and error, [`failure_variables`](@ref) all variables, and
[`JuLeAna.@locals`](@ref) defines them in the REPL.

The variables are those visible where the error is caught: the arguments and variables of
the processor, also those assigned in enclosing blocks, but not the variables first assigned
inside the failing block itself. The values are the objects themselves, not copies.
"""
struct Failure
    name::String
    step::Symbol
    args::Tuple
    item::Any
    exception::Any
    backtrace::Vector{Any}
    variables::Dict{Symbol,Any}
    block::Any
    mod::Module
    file::String
    line::Int
end

"""
    failure_info(f::Failure)::NamedTuple

The fields of the [`Failure`](@ref) `f` besides the variables: `name`, the step name;
`step` and `args`, the processor and its period and run; `item`, the item of
[`parallel`](@ref) (`nothing` outside of it) and `detector`, its detector (`nothing` if
it has none); `exception`, the [`root_exception`](@ref) of the failure, and `backtrace`;
`block`, the expression of the step, and `mod`, the module it is in; `file` and `line`,
where the step is.
"""
function failure_info(f::Failure)
    item = getfield(f, :item)
    detector = hasproperty(item, :detector) ? item.detector : nothing
    return (; name = getfield(f, :name), step = getfield(f, :step), args = getfield(f, :args), item, detector,
            exception = getfield(f, :exception), backtrace = getfield(f, :backtrace), block = getfield(f, :block), mod = getfield(f, :mod),
            file = getfield(f, :file), line = getfield(f, :line))
end

"""
    failure_variables(f::Failure)::Dict{Symbol,Any}

The local variables captured with the [`Failure`](@ref) `f`, by name.
"""
failure_variables(f::Failure) = getfield(f, :variables)

function Base.getproperty(f::Failure, name::Symbol)
    vars = failure_variables(f)
    haskey(vars, name) || throw(ArgumentError("the failure of \"$(getfield(f, :name))\" captured no variable `$name`; " *
                                              "it captured $(join(sort!(collect(keys(vars))), ", "))"))
    return vars[name]
end

function Base.propertynames(f::Failure, private::Bool = false)
    return Tuple(sort!(collect(keys(failure_variables(f)))))
end

function Base.show(io::IO, f::Failure)
    info = failure_info(f)
    return print(io, "Failure(\"", info.name, "\"", isnothing(info.detector) ? "" : " for $(info.detector)", ")")
end

function Base.show(io::IO, ::MIME"text/plain", f::Failure)
    info = failure_info(f)
    println(io, "\"", info.name, "\" failed", isnothing(info.detector) ? "" : " for $(info.detector)", " in ", info.step, " ",
            join(string.(info.args), " "), " at ", info.file, ":", info.line)
    println(io, "  error: ", truncate_error(info.exception))
    println(io, "  variables: ", join(propertynames(f), ", "))
    return print(io, "  code:\n", join(("    " * l for l in split(step_code(info.block), '\n')), '\n'))
end

# The failures of the last `run_step` call.
const LAST_FAILURES = Ref(Failure[])

"""
    JuLeAna.failures()::Vector{Failure}

The [`Failure`](@ref)s captured by the last call of [`run_step`](@ref), in the order they
happened; empty unless that call had `debug = true`. [`JuLeAna.failure`](@ref) gives the
first one.
"""
failures() = LAST_FAILURES[]

"""
    JuLeAna.failure()::Failure

The first [`Failure`](@ref) captured by the last call of [`run_step`](@ref) with
`debug = true`, or the last failure of [`JuLeAna.rerun`](@ref) that replaced it. Throws
an `ErrorException` if that call captured none.

# Examples
```julia
run_step(:process_energy_calibration_cal, 3, 0; detectors = [:V01234A], debug = true)
f = JuLeAna.failure()
f.e_uncal           # a variable of the processor at the failed step
JuLeAna.@locals f   # all of them as variables in the REPL
JuLeAna.rerun(f; e_uncal = f.e_uncal[f.e_uncal .> 100])   # the step again, with a changed variable
```
"""
function failure()
    isempty(failures()) &&
        error("no failure was captured: the last `run_step` call had no failure in a " * "`@process_step`, or no `debug = true`")
    return first(failures())
end

"""
    JuLeAna.@locals f

Define the variables captured with the [`Failure`](@ref) `f` as global variables of the
calling module, e.g. the REPL, and return their names.
"""
macro locals(f)
    return :(define_locals($__module__, $(esc(f))))
end

function define_locals(mod::Module, f::Failure)
    vars = failure_variables(f)
    foreach(((name, value),) -> @eval(mod, $name = $(QuoteNode(value))), vars)
    return sort!(collect(keys(vars)))
end

"""
    JuLeAna.rerun(f::Failure; overrides...)

Run the block of the failed step `f` again, with the variables captured in `f` and the
variables in `overrides` set to the given values, and return the value of the block. The
block runs in the module of the processor, with the item of `f` as the current item, and
writes no parameters or validity, see [`write_pars`](@ref).

If the block fails again, the new [`Failure`](@ref) replaces `f` in
[`JuLeAna.failures`](@ref), and the root error is thrown. To check a fix in the
configuration, run [`run_step`](@ref) again, which reads everything anew.

Throws an `ArgumentError`, without running the block, if a name in `overrides` is not a
captured variable, or if the block contains a `return`, a `break` or `continue` outside
of a loop in the block, or a `@goto`, all of which leave the block.

# Examples
```julia
f = JuLeAna.failure()
JuLeAna.rerun(f)                         # fails again in the same way
JuLeAna.rerun(f; window = (100, 200))    # with a changed variable
```
"""
function rerun(f::Failure; overrides...)
    info = failure_info(f)
    vars = merge(failure_variables(f), Dict{Symbol,Any}(overrides))
    unknown = setdiff(keys(overrides), keys(failure_variables(f)))
    isempty(unknown) || throw(ArgumentError("rerun: $(join(sort!(collect(unknown)), ", ")) " *
                                            "$(length(unknown) == 1 ? "is not a captured variable" : "are not captured variables") of \"$(info.name)\"; " *
                                            "the captured variables are $(join(propertynames(f), ", "))"))
    leaving = block_exit(info.block)
    isnothing(leaving) || throw(ArgumentError("rerun: the block of \"$(info.name)\" contains `$leaving`, which " *
                                              "leaves the block, so the block cannot run on its own"))
    step = Expr(:macrocall, GlobalRef(@__MODULE__, Symbol("@process_step")), LineNumberNode(info.line, Symbol(info.file)), info.name,
                info.block)
    ex = Expr(:let, Expr(:block, (:($name = $(QuoteNode(value))) for (name, value) in vars)...), step)
    capture = debug_capture(info.step, info.args)
    try
        return with(() -> @eval(info.mod, $ex), DEBUG_CAPTURE => capture, CURRENT_ITEM => info.item, WRITE_PARS => false)
    catch e
        e isa ProcessStepError && !isempty(capture.failures) || rethrow()
        new_failure = first(capture.failures)
        i = findfirst(x -> x === f, failures())
        isnothing(i) ? pushfirst!(failures(), new_failure) : (failures()[i] = new_failure)
        throw(getfield(new_failure, :exception))
    end
end

# The first `return`, `break`, `continue` or `@goto` in `ex` that leaves `ex`, as a string;
# `nothing` if there is none. `break` and `continue` inside a loop of `ex`, and everything
# inside a function definition, stay in `ex`.
function block_exit(ex, in_loop::Bool = false)
    ex isa Expr || return nothing
    ex.head === :return && return "return"
    ex.head in (:break, :continue) && return in_loop ? nothing : string(ex.head)
    ex.head === :macrocall && first(ex.args) === Symbol("@goto") && return "@goto"
    (ex.head in (:function, :->) || ex.head === :(=) && Meta.isexpr(first(ex.args), :call)) && return nothing
    body_in_loop = in_loop || ex.head in (:for, :while)
    for arg in ex.args
        leaving = block_exit(arg, body_in_loop)
        isnothing(leaving) || return leaving
    end
    return nothing
end
