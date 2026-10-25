# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Settings of the run modes that the editor shows: name in `SetRunmodeSettings` and
# `ControllerSnapshot.runmode_settings`, run mode and label. `local_n` is a number, the others
# are lists of strings.
const RUNMODE_SETTINGS = ((:local_n, :local, "workers (n)"), (:local_julia_settings, :local, "julia_settings"),
                          (:slurm_flags, :slurm, "flags"), (:slurm_julia_settings, :slurm, "julia_settings"))

"""
    RunmodeEditor()

State of the overlay that edits the settings of the run modes on the Setup page: the cursor
row, the text being typed (`nothing` when no value is edited), whether that text is a new
entry of a list, and the error of the last typed value.
"""
mutable struct RunmodeEditor
    cursor::Int
    text::Union{Nothing,String}
    adding::Bool
    error::Union{Nothing,String}
end

RunmodeEditor() = RunmodeEditor(1, nothing, false, nothing)

# Rows of the editor as `(name, i)`: `i == 0` is the number `local_n` or the heading of a list, and
# `i > 0` the `i`-th entry of that list.
function runmode_rows(settings)
    return [(name, i) for (name, _, _) in RUNMODE_SETTINGS for i in 0:(name === :local_n ? 0 : length(getproperty(settings, name)))]
end

"""
    JuLeAna.runmode_key!(editor::RunmodeEditor, evt::Tachikoma.KeyEvent, snap, send)

Handle the key `evt` in the run mode editor and return `:close` when the editor closes,
`true` otherwise; the editor uses every key. Up and Down move. Enter edits the value or
entry under the cursor, and on the heading of a list adds an entry; `a` adds an entry to
the list under the cursor and `d` deletes the entry under the cursor. While a text is typed,
Enter sends it as [`SetRunmodeSettings`](@ref) once it is valid (a positive integer for
`local_n`, a text that is not empty for an entry of a list) and Escape drops it; otherwise
Escape closes the editor.
"""
function runmode_key!(editor::RunmodeEditor, evt::Tachikoma.KeyEvent, snap, send)
    (isnothing(snap) || isnothing(snap.runmode_settings)) && return :close
    settings = snap.runmode_settings
    rows = runmode_rows(settings)
    editor.cursor = clamp(editor.cursor, 1, length(rows))
    name, i = rows[editor.cursor]
    key, char = evt.key, evt.char
    if !isnothing(editor.text)
        if key == :enter
            try
                if name === :local_n
                    n = tryparse(Int, strip(editor.text))
                    (isnothing(n) || n <= 0) && throw(ArgumentError("expected a positive integer, got `$(strip(editor.text))`"))
                    send(SetRunmodeSettings(; local_n = n))
                else
                    entry = String(strip(editor.text))
                    isempty(entry) && throw(ArgumentError("an entry must not be empty (d deletes the entry)"))
                    entries = copy(getproperty(settings, name))
                    editor.adding ? push!(entries, entry) : (entries[i] = entry)
                    send(SetRunmodeSettings(; (name => entries,)...))
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
        editor.cursor = clamp(editor.cursor + (key == :up ? -1 : 1), 1, length(rows))
    elseif name === :local_n && key == :enter
        editor.text, editor.adding = string(settings.local_n), false
    elseif name !== :local_n && ((key == :char && char == 'a') || (key == :enter && i == 0))
        editor.text, editor.adding = "", true
    elseif name !== :local_n && key == :enter
        editor.text, editor.adding = getproperty(settings, name)[i], false
    elseif name !== :local_n && i > 0 && key == :char && char == 'd'
        entries = deleteat!(copy(getproperty(settings, name)), i)
        send(SetRunmodeSettings(; (name => entries,)...))
    end
    return true
end

"""
    JuLeAna.render_runmode(editor::RunmodeEditor, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the run mode editor as a box in the middle of `area`: the settings of the `local` and
the `slurm` run mode, with the number of workers on one row and each list as a heading
with one row per entry; the text being typed and the last error below.
"""
function render_runmode(editor::RunmodeEditor, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    (isnothing(snap) || isnothing(snap.runmode_settings)) && return nothing
    settings = snap.runmode_settings
    lines = Tuple{String,Any}[]
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    highlight, error_style = Tachikoma.tstyle(:accent, bold = true), Tachikoma.tstyle(:error, bold = true)
    group = nothing
    for (n, (name, i)) in enumerate(runmode_rows(settings))
        _, mode, label = only(filter(s -> first(s) === name, RUNMODE_SETTINGS))
        if mode !== group
            group = mode
            push!(lines, (string(mode), Tachikoma.tstyle(:primary, bold = true)))
        end
        entries = name === :local_n ? nothing : getproperty(settings, name)
        line = name === :local_n ? "  $label = $(settings.local_n)" :
               i == 0 ? "  $label" * (isempty(entries) ? "  (none)" : "") : "    - $(entries[i])"
        push!(lines, (line, n == editor.cursor ? highlight : i == 0 ? text : dim))
    end
    push!(lines, ("", text))
    isnothing(editor.text) || push!(lines, ((editor.adding ? "new entry: " : "new value: ") * editor.text * "▏", highlight))
    isnothing(editor.error) || push!(lines, (editor.error, error_style))
    push!(lines, ("Enter: edit   a: add entry   d: delete entry   Esc: back", dim))

    width = min(area.width, max(50, maximum(l -> textwidth(first(l)), lines) + 4))
    height = min(area.height, length(lines) + 2)
    box = Tachikoma.center(area, width, height)
    for y in box.y:Tachikoma.bottom(box), x in box.x:Tachikoma.right(box)

        Tachikoma.set_char!(buf, x, y, ' ', text)
    end
    inner = Tachikoma.render(Tachikoma.Block(title = "Run mode settings (this session)", border_style = Tachikoma.tstyle(:border_focus)),
                             box, buf)
    for (i, (line, style)) in enumerate(lines)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        Tachikoma.set_string!(buf, inner.x + 1, y, line, style; max_x = Tachikoma.right(inner))
    end
    return nothing
end
