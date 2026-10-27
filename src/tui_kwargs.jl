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

State of the overlay that edits the settings of the processor `step` on the Setup page: the
fields of its [`ProcessorSpec`](@ref) and its kwargs. The overlay holds the cursor row, the text
being typed while a value is edited (`nothing` otherwise), and the error of the last typed value.
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

# Order in which Enter steps through the values of a setting that has a fixed set of values.
const EDITOR_CYCLES = (category = (:cal, :phy), log_level = (Logging.Info, Logging.Debug, Logging.Warn, Logging.Error),
                       plot_level = (:info, :debug), report_status = REPORT_STATUS_RESULTS)

# Rows of the editor, in the order they are listed: whether the processor is selected, its
# settings, the cells of its report status table (`path` is the usability and the status of
# the report row), then its kwargs in alphabetical order, so that setting a kwarg does not
# move it: the kwargs set in the config or the session and the accepted ones, with whether
# each is set.
function editor_rows(proc)
    rows = [(; kind = :setting, key, isset = true, path = Symbol[])
            for key in (:enabled, :category, :rank, :dependencies, :error_plots, :log_level, :plot_level, :detectors)]
    append!(rows,
            (; kind = :report, key = :report_status, isset = true, path = [usability, row]) for usability in REPORT_STATUS_USABILITIES
            for row in REPORT_STATUS_ROWS)
    for key in sort!(collect(union(keys(proc.kwargs), something(proc.accepted, Symbol[]))))
        push!(rows, (; kind = :kwarg, key, isset = haskey(proc.kwargs, key), path = Symbol[]))
    end
    return rows
end

# Text of the log or plot level `value`.
format_level(value::LogLevel) = only(name for (name, level) in LOG_LEVELS if level == value)
format_level(value::Symbol) = string(value)

# The value of the setting row `row` of `proc`, or of `proc.config_spec` with `config = true`.
function row_value(proc, row; config::Bool = false)
    source = config ? proc.config_spec : proc
    row.key === :enabled && return config ? proc.enabled : proc.selected
    row.key === :report_status && return source.report_status[row.path[1]][row.path[2]]
    row.key === :log_level && return config ? proc.config_log_level : proc.log_level
    row.key === :plot_level && return config ? proc.config_plot_level : proc.plot_level
    return getproperty(source, row.key)
end

# Text of the value `value` of the setting `key`.
format_setting(::Val{:dependencies}, value) = isempty(value) ? "none" : join(value, ", ")
format_setting(::Val{:detectors}, value) = isnothing(value) ? "not set" : value
format_setting(::Val{:log_level}, value) = format_level(value)
format_setting(::Val{:enabled}, value) = value ? "selected" : "not selected"
format_setting(::Val, value) = string(value)
format_setting(key::Symbol, value) = format_setting(Val(key), value)

# Label of a row.
function row_label(row)
    row.kind === :report && return "report status $(row.path[1]), $(row.path[2]) row"
    return replace(string(row.key), "_" => " ")
end

# The ProcessorSpec of `proc` with the settings in `changes` replaced; throws an `ArgumentError`
# when it is invalid.
function candidate_spec(proc; changes...)
    values = merge((; proc.category, proc.rank, proc.dependencies, proc.error_plots, proc.log_level, proc.plot_level, proc.detectors,
                    proc.report_status), NamedTuple(changes))
    return ProcessorSpec(proc.name, proc.level, proc.enabled, values.category, values.rank, values.dependencies, proc.kwargs,
                         values.error_plots, values.log_level, values.plot_level, values.detectors, values.report_status)
end

# The value the text `text` gives to the setting row `row` of `proc`, which is a processor of `snap`;
# throws an `ArgumentError` that says what is wrong when the text is not valid.
function parse_setting(proc, row, text::AbstractString, snap)
    text = strip(text)
    if row.key === :rank
        value = tryparse(Int, text)
        isnothing(value) && throw(ArgumentError("expected an integer, got `$text`"))
        return value
    elseif row.key === :dependencies
        value = Symbol[Symbol(strip(s)) for s in split(text, ',') if !isempty(strip(s))]
        candidate_spec(proc; dependencies = value)
        processor_graph(p.name === proc.name ? (; p.name, p.level, p.rank, dependencies = value) : p for p in snap.processors)
        return value
    else
        value = isempty(text) ? nothing : String(text)
        candidate_spec(proc; detectors = value)
        return value
    end
end

"""
    JuLeAna.kwargs_key!(editor::KwargsEditor, evt::Tachikoma.KeyEvent, snap, send)

Handle the key `evt` in the settings editor and return `:close` when the editor closes,
`true` otherwise; the editor uses every key. Up and Down move. Enter changes the setting under
the cursor: it selects or deselects the processor with [`SelectSteps`](@ref) (row `enabled`),
flips `error plots`, steps `category`, the log and plot level and the cells of the report status
through their values, and starts editing the text of `rank`, `dependencies` (names separated
by commas), `detectors` (an `ljl_propfunc` expression; empty text removes it) and the kwargs.
While text is edited, Enter sends it as [`SetStepSetting`](@ref) or [`SetKwarg`](@ref) once it is valid (see
[`JuLeAna.parse_kwarg_value`](@ref)) and otherwise shows the error and sends nothing. Escape stops editing or closes the editor; `u`
resets the setting or kwarg under the cursor (the selection returns to the `enabled` of the
config) and `U` all settings and kwargs of the processor with [`ResetKwargs`](@ref).
"""
function kwargs_key!(editor::KwargsEditor, evt::Tachikoma.KeyEvent, snap, send)
    proc = editor_processor(editor, snap)
    isnothing(proc) && return :close
    rows = editor_rows(proc)
    editor.cursor = clamp(editor.cursor, 1, max(1, length(rows)))
    key, char = evt.key, evt.char
    row = rows[editor.cursor]
    if !isnothing(editor.text)
        if key == :enter
            try
                if row.kind === :kwarg
                    send(SetKwarg(editor.step, row.key, parse_kwarg_value(editor.text, get(proc.kwargs, row.key, nothing))))
                else
                    send(SetStepSetting(editor.step, row.key, parse_setting(proc, row, editor.text, snap)))
                end
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
    elseif key == :enter && row.key === :enabled
        set_selected!(proc, !proc.selected, snap, send)
    elseif key == :enter && row.key === :error_plots
        send(SetStepSetting(editor.step, :error_plots, !proc.error_plots))
    elseif key == :enter && row.key === :report_status
        table = deepcopy(proc.report_status)
        usability, status = row.path
        cycle = EDITOR_CYCLES.report_status
        table[usability][status] = cycle[mod1(something(findfirst(==(table[usability][status]), cycle), 0) + 1, length(cycle))]
        send(SetStepSetting(editor.step, :report_status, table))
    elseif key == :enter && row.key in (:category, :log_level, :plot_level)
        cycle = EDITOR_CYCLES[row.key]
        next = cycle[mod1(something(findfirst(==(row_value(proc, row)), cycle), 0) + 1, length(cycle))]
        send(row.key === :category ? SetStepSetting(editor.step, :category, next) : SetStepLevel(editor.step, row.key, next))
    elseif key == :enter
        current = row.kind === :kwarg ? (haskey(proc.kwargs, row.key) ? format_kwarg(proc.kwargs[row.key]) : "") :
                  row.key === :dependencies ? join(proc.dependencies, ", ") : string(something(row_value(proc, row), ""))
        editor.text = current
    elseif key == :char && char == 'u'
        row.key === :enabled ? set_selected!(proc, proc.enabled, snap, send) : send(ResetKwargs(editor.step, row.key))
    elseif key == :char && char == 'U'
        send(ResetKwargs(editor.step))
    end
    return true
end

# Send the selection of `proc` (`selected`) with the steps already selected in `snap`.
function set_selected!(proc, selected::Bool, snap, send)
    steps = proc.level === :run ? snap.run_steps : snap.partition_steps
    steps = selected ? union(steps, [proc.name]) : setdiff(steps, [proc.name])
    send(proc.level === :run ? SelectSteps(steps, snap.partition_steps) : SelectSteps(snap.run_steps, steps))
    return nothing
end

"""
    JuLeAna.render_kwargs(editor::KwargsEditor, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the settings editor as a box in the middle of `area`: a row for each setting of the
processor, each cell of its report status, and each kwarg in alphabetical order, with the
value, `*` and the config value for a changed setting or kwarg, and dimmed the accepted
kwargs that are not set; the text being typed and the last error below. A list longer than
the box scrolls to keep the cursor row visible.
"""
function render_kwargs(editor::KwargsEditor, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    proc = editor_processor(editor, snap)
    isnothing(proc) && return nothing
    lines = Tuple{String,Any}[]
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    highlight, error_style = Tachikoma.tstyle(:accent, bold = true), Tachikoma.tstyle(:error, bold = true)
    rows = editor_rows(proc)
    for (i, row) in enumerate(rows)
        line = if row.kind === :kwarg
            if row.isset
                changed = row.key in proc.overridden
                "$(changed ? "*" : " ") $(row.key) = $(format_kwarg(proc.kwargs[row.key]))" *
                (changed ?
                 "   (config: " * (haskey(proc.config_kwargs, row.key) ? format_kwarg(proc.config_kwargs[row.key]) : "not set") * ")" :
                 "")
            else
                "  $(row.key)"
            end
        else
            value, config = row_value(proc, row), row_value(proc, row; config = true)
            changed = value != config
            "$(changed ? "*" : " ") $(row_label(row)) = $(format_setting(row.key, value))" *
            (changed ? "   (config: $(format_setting(row.key, config)))" : "")
        end
        push!(lines, (line, i == editor.cursor ? highlight : row.isset ? text : dim))
    end
    all(row -> row.kind !== :kwarg, rows) && push!(lines, ("  This processor takes no kwargs.", dim))
    footer = Tuple{String,Any}[("", text)]
    isnothing(editor.text) || push!(footer, ("new value: " * editor.text * "▏", highlight))
    isnothing(editor.error) || push!(footer, (editor.error, error_style))
    push!(footer, ("Enter: edit/set, next value   u/U: reset one/all   Esc: back", dim))

    width = min(area.width, max(60, maximum(l -> textwidth(first(l)), vcat(lines, footer)) + 4))
    height = min(area.height, length(lines) + length(footer) + 2)
    visible = height - length(footer) - 2
    first_line = clamp(editor.cursor - visible ÷ 2, 1, max(1, length(lines) - visible + 1))
    shown = vcat(lines[first_line:min(end, first_line + visible - 1)], footer)
    box = Tachikoma.center(area, width, height)
    for y in box.y:Tachikoma.bottom(box), x in box.x:Tachikoma.right(box)

        Tachikoma.set_char!(buf, x, y, ' ', text)
    end
    inner = Tachikoma.render(Tachikoma.Block(title = "Settings of $(display_name(editor.step)) $(proc.category) (this session)",
                                             border_style = Tachikoma.tstyle(:border_focus)), box, buf)
    for (i, (line, style)) in enumerate(shown)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        Tachikoma.set_string!(buf, inner.x + 1, y, line, style; max_x = Tachikoma.right(inner))
    end
    return nothing
end
