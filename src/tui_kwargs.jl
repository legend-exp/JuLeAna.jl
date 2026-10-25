# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# A literal of Julia syntax: a number, `true`/`false`, a string, a `:symbol`, or a vector
# of these. Anything else, in particular code, is rejected.
function literal_value(ex)
    ex isa Union{Number,Bool,AbstractString} && return ex
    ex isa QuoteNode && ex.value isa Symbol && return ex.value
    if ex isa Expr && ex.head === :vect
        values = map(literal_value, ex.args)
        return isempty(values) ? Any[] : [v for v in values]
    end
    return throw(ArgumentError("not a literal value: $ex"))
end

"""
    JuLeAna.parse_kwarg_value(text::AbstractString, current)

Parse the text `text` typed for a processor kwarg whose value is `current` (`nothing` for
a kwarg that is not set). The text follows the type of `current`: `true`/`false` for a
`Bool`, a number for an `Integer` or a float, the text itself for a string, and names
separated by commas for a vector of symbols. Otherwise the text must be a Julia literal:
a number, `true`/`false`, a string in quotes, a `:symbol`, or a vector of these such as
`[:a, :b]`; it is only parsed, never evaluated. Throws an `ArgumentError` naming the
expected form when the text does not fit.

# Examples
```jldoctest
julia> JuLeAna.parse_kwarg_value("12", 10)
12

julia> JuLeAna.parse_kwarg_value("V01, V02", [:V00])
2-element Vector{Symbol}:
 :V01
 :V02

julia> JuLeAna.parse_kwarg_value("[1, 2]", nothing)
2-element Vector{Int64}:
 1
 2
```
"""
function parse_kwarg_value(text::AbstractString, current)
    text = strip(text)
    function typed(T, what)
        value = tryparse(T, text)
        isnothing(value) && throw(ArgumentError("expected $what, got `$text`"))
        return value
    end
    if current isa Bool
        text in ("true", "false") || throw(ArgumentError("expected true or false, got `$text`"))
        return text == "true"
    end
    current isa Integer && return typed(Int, "an integer")
    current isa AbstractFloat && return typed(Float64, "a number")
    current isa AbstractString && return String(text)
    current isa AbstractVector{Symbol} && return Symbol[Symbol(strip(s)) for s in split(text, ',') if !isempty(strip(s))]
    try
        # malformed text parses to an `:error` or `:incomplete` expression, which is no literal
        return literal_value(Meta.parse(text; raise = false))
    catch e
        e isa ArgumentError || rethrow()
        throw(ArgumentError("expected a Julia literal (number, true/false, \"text\", :name or [...]), got `$text`"))
    end
end

# Text of `value` in the form `parse_kwarg_value` reads back for the same type.
format_kwarg(value::AbstractVector{Symbol}) = join(value, ", ")
format_kwarg(value::AbstractString) = String(value)
format_kwarg(value) = repr(value)

"""
    KwargsEditor(step::Symbol)

State of the overlay that edits the kwargs of the processor `step` on the Setup page:
the cursor row, the text being typed while a value is edited (`nothing` otherwise), and
the error of the last typed value.
"""
mutable struct KwargsEditor
    const step::Symbol
    cursor::Int
    text::Union{Nothing,String}
    error::Union{Nothing,String}
end

KwargsEditor(step::Symbol) = KwargsEditor(step, 1, nothing, nothing)

# The processor of the editor in `snap`, or `nothing` if it is gone.
function editor_processor(editor::KwargsEditor, snap)
    isnothing(snap) && return nothing
    i = findfirst(p -> p.name === editor.step, snap.processors)
    return isnothing(i) ? nothing : snap.processors[i]
end

# The levels of a processor that the editor shows above its kwargs, in the order Enter steps
# through them.
const EDITOR_LEVELS = (log_level = (Logging.Info, Logging.Debug, Logging.Warn, Logging.Error), plot_level = (:info, :debug))

# Rows of the editor: the log and the plot level, then the kwargs in alphabetical order, so
# that setting a kwarg does not move it: the kwargs set in the config or the session and the
# accepted ones, with whether each is set.
function editor_rows(proc)
    return vcat([(key, true) for key in keys(EDITOR_LEVELS)],
                [(key, haskey(proc.kwargs, key)) for key in sort!(collect(union(keys(proc.kwargs), something(proc.accepted, Symbol[]))))])
end

# Text of the log or plot level `value`.
format_level(value::LogLevel) = only(name for (name, level) in LOG_LEVELS if level == value)
format_level(value::Symbol) = string(value)

"""
    JuLeAna.kwargs_key!(editor::KwargsEditor, evt::Tachikoma.KeyEvent, snap, send)

Handle the key `evt` in the kwargs editor and return `:close` when the editor closes,
`true` otherwise; the editor uses every key. Up and Down move, Enter starts editing the
value under the cursor and, while editing, sends it as [`SetKwarg`](@ref) once it parses
(see [`JuLeAna.parse_kwarg_value`](@ref)); on the log or plot level row, Enter sets the next
level with [`SetStepLevel`](@ref). Escape stops editing or closes the editor; `u` resets the
kwarg or level under the cursor and `U` all kwargs and levels of the processor with
[`ResetKwargs`](@ref).
"""
function kwargs_key!(editor::KwargsEditor, evt::Tachikoma.KeyEvent, snap, send)
    proc = editor_processor(editor, snap)
    isnothing(proc) && return :close
    rows = editor_rows(proc)
    editor.cursor = clamp(editor.cursor, 1, max(1, length(rows)))
    key, char = evt.key, evt.char
    if !isnothing(editor.text)
        if key == :enter
            name = first(rows[editor.cursor])
            try
                value = parse_kwarg_value(editor.text, get(proc.kwargs, name, nothing))
                send(SetKwarg(editor.step, name, value))
                editor.text, editor.error = nothing, nothing
            catch e
                e isa ArgumentError || rethrow()
                editor.error = e.msg
            end
        elseif key == :escape
            editor.text, editor.error = nothing, nothing
        elseif key == :backspace
            editor.text = chop(editor.text)
        elseif key == :char && isprint(char)
            editor.text *= char
        end
        return true
    end
    if key == :escape
        return :close
    elseif key in (:up, :down)
        editor.cursor = clamp(editor.cursor + (key == :up ? -1 : 1), 1, max(1, length(rows)))
    elseif key == :enter && haskey(EDITOR_LEVELS, first(rows[editor.cursor]))
        name = first(rows[editor.cursor])
        cycle = EDITOR_LEVELS[name]
        current = findfirst(==(getproperty(proc, name)), cycle)
        send(SetStepLevel(editor.step, name, cycle[mod1(something(current, 0) + 1, length(cycle))]))
    elseif key == :enter
        name = first(rows[editor.cursor])
        editor.text = haskey(proc.kwargs, name) ? format_kwarg(proc.kwargs[name]) : ""
    elseif key == :char && char == 'u'
        send(ResetKwargs(editor.step, first(rows[editor.cursor])))
    elseif key == :char && char == 'U'
        send(ResetKwargs(editor.step))
    end
    return true
end

"""
    JuLeAna.render_kwargs(editor::KwargsEditor, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the kwargs editor as a box in the middle of `area`: a row for the log and the plot level
of the processor, then one row per kwarg in alphabetical order with its value, `*` and the
config value for a changed level or kwarg, and dimmed the accepted kwargs that are not set;
the text being typed and the last error below.
"""
function render_kwargs(editor::KwargsEditor, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    proc = editor_processor(editor, snap)
    isnothing(proc) && return nothing
    lines = Tuple{String,Any}[]
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    highlight, error_style = Tachikoma.tstyle(:accent, bold = true), Tachikoma.tstyle(:error, bold = true)
    for (i, (name, isset)) in enumerate(editor_rows(proc))
        line = if haskey(EDITOR_LEVELS, name)
            changed = name in proc.overridden
            label = replace(string(name), "_" => " ")
            "$(changed ? "*" : " ") $label = $(format_level(getproperty(proc, name)))" *
            (changed ? "   (config: $(format_level(getproperty(proc, Symbol("config_", name)))))" : "")
        elseif isset
            changed = name in proc.overridden
            "$(changed ? "*" : " ") $name = $(format_kwarg(proc.kwargs[name]))" *
            (changed ? "   (config: " * (haskey(proc.config_kwargs, name) ? format_kwarg(proc.config_kwargs[name]) : "not set") * ")" : "")
        else
            "  $name"
        end
        push!(lines, (line, i == editor.cursor ? highlight : isset ? text : dim))
    end
    length(lines) == length(EDITOR_LEVELS) && push!(lines, ("  This processor takes no kwargs.", dim))
    push!(lines, ("", text))
    isnothing(editor.text) || push!(lines, ("new value: " * editor.text * "▏", highlight))
    isnothing(editor.error) || push!(lines, (editor.error, error_style))
    push!(lines, ("Enter: edit/set, next level   u/U: reset one/all   Esc: back", dim))

    width = min(area.width, max(50, maximum(l -> textwidth(first(l)), lines) + 4))
    height = min(area.height, length(lines) + 2)
    box = Tachikoma.center(area, width, height)
    for y in box.y:Tachikoma.bottom(box), x in box.x:Tachikoma.right(box)

        Tachikoma.set_char!(buf, x, y, ' ', text)
    end
    inner = Tachikoma.render(Tachikoma.Block(title = "Settings of $(display_name(editor.step)) $(proc.category) (this session)",
                                             border_style = Tachikoma.tstyle(:border_focus)), box, buf)
    for (i, (line, style)) in enumerate(lines)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        Tachikoma.set_string!(buf, inner.x + 1, y, line, style; max_x = Tachikoma.right(inner))
    end
    return nothing
end
