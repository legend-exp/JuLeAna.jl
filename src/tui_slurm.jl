# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Options of the SLURM job that the form edits: long name, the short option SLURM also accepts
# for it (or `nothing`), label, and the pattern a value must match with its description.
const SLURM_FORM_OPTIONS = ((name = "partition", short = 'p', label = "partition", pattern = r"^\S+$", expected = "a name without spaces"),
                            (name = "time", short = 't', label = "time limit", pattern = r"^(\d+-)?\d+(:\d+){0,2}$",
                             expected = "minutes, hh:mm:ss or d-hh:mm:ss"),
                            (name = "nodes", short = 'N', label = "nodes", pattern = r"^[1-9]\d*$", expected = "a positive integer"),
                            (name = "ntasks-per-node", short = nothing, label = "workers per node", pattern = r"^[1-9]\d*$",
                             expected = "a positive integer"),
                            (name = "cpus-per-task", short = 'c', label = "threads per worker", pattern = r"^[1-9]\d*$",
                             expected = "a positive integer"),
                            (name = "mem", short = nothing, label = "memory per node", pattern = r"^\d+[KMGT]?B?$"i,
                             expected = "a size such as 30GB"))

"""
    SlurmForm()

State of the form on the Workers page that edits single options of the SLURM job, such as
the time limit and the number of nodes: the cursor row, the text being typed (`nothing` when
no value is edited) and the error of the last typed value.
"""
mutable struct SlurmForm
    cursor::Int
    text::Union{Nothing,String}
    error::Union{Nothing,String}
end

SlurmForm() = SlurmForm(1, nothing, nothing)

# The flag of `flags` that sets the option `opt` as `--name=value`, or `nothing`.
slurm_flag_index(flags, opt) = findfirst(f -> startswith(f, "--$(opt.name)="), flags)

# A flag of `flags` that sets the option `opt` in another form than `--name=value`, which the
# form does not change, or `nothing`.
function slurm_flag_conflict(flags, opt)
    return findfirst(f -> f == "--$(opt.name)" || (!isnothing(opt.short) && startswith(f, "-$(opt.short)")), flags)
end

"""
    JuLeAna.slurm_option(flags::AbstractVector{<:AbstractString}, name::AbstractString)

The value of the SLURM option `name` set as `--name=value` among `flags`, or `nothing`.
"""
function slurm_option(flags::AbstractVector{<:AbstractString}, name::AbstractString)
    opt = only(o for o in SLURM_FORM_OPTIONS if o.name == name)
    i = slurm_flag_index(flags, opt)
    return isnothing(i) ? nothing : String(chopprefix(flags[i], "--$name="))
end

"""
    JuLeAna.set_slurm_option(flags::AbstractVector{<:AbstractString}, name::AbstractString, value::AbstractString)

Return a copy of `flags` with the SLURM option `name` set to `value` as `--name=value`, in
place of a flag that set it before or else at the end. An empty `value` removes the option.
Throws an `ArgumentError` if `value` is not valid for the option, or if `flags` set the
option in another form, such as a short option.
"""
function set_slurm_option(flags::AbstractVector{<:AbstractString}, name::AbstractString, value::AbstractString)
    opt = only(o for o in SLURM_FORM_OPTIONS if o.name == name)
    conflict = slurm_flag_conflict(flags, opt)
    isnothing(conflict) ||
        throw(ArgumentError("the flag `$(flags[conflict])` sets $(opt.label); change it with `e` on the Run mode row of the Setup page"))
    isempty(value) || occursin(opt.pattern, value) || throw(ArgumentError("$(opt.label): expected $(opt.expected), got `$value`"))
    result = String.(flags)
    i = slurm_flag_index(result, opt)
    if isempty(value)
        isnothing(i) || deleteat!(result, i)
    elseif isnothing(i)
        push!(result, "--$name=$value")
    else
        result[i] = "--$name=$value"
    end
    return result
end

"""
    JuLeAna.slurm_form_key!(form::SlurmForm, evt::Tachikoma.KeyEvent, snap, send)

Handle the key `evt` in the SLURM form and return `:close` when the form closes, `true`
otherwise; the form uses every key. Up and Down move, Enter edits the option under the
cursor. While a value is typed, Enter sends the flags with the new value as
[`SetRunmodeSettings`](@ref) once it is valid, an empty value removes the option, and Escape
drops the text; otherwise Escape closes the form.
"""
function slurm_form_key!(form::SlurmForm, evt::Tachikoma.KeyEvent, snap, send)
    (isnothing(snap) || isnothing(snap.runmode_settings)) && return :close
    flags = snap.runmode_settings.slurm_flags
    form.cursor = clamp(form.cursor, 1, length(SLURM_FORM_OPTIONS))
    opt = SLURM_FORM_OPTIONS[form.cursor]
    key, char = evt.key, evt.char
    if !isnothing(form.text)
        if key == :enter
            try
                send(SetRunmodeSettings(; slurm_flags = set_slurm_option(flags, opt.name, strip(form.text))))
                form.text, form.error = nothing, nothing
            catch e
                e isa ArgumentError || rethrow()
                form.error = e.msg
            end
        elseif key == :escape
            form.text, form.error = nothing, nothing
        elseif key == :backspace
            form.text = chop(form.text)
        elseif key == :char && isprint(char)
            form.text *= char
        end
        return true
    end
    if key == :escape
        return :close
    elseif key in (:up, :down)
        form.cursor = clamp(form.cursor + (key == :up ? -1 : 1), 1, length(SLURM_FORM_OPTIONS))
        form.error = nothing
    elseif key == :enter
        form.text = something(slurm_option(flags, opt.name), "")
    end
    return true
end

"""
    JuLeAna.render_slurm_form(form::SlurmForm, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the SLURM form as a box in the middle of `area`: one row per option with its value or
`not set`, the other SLURM flags, the text being typed and the last error.
"""
function render_slurm_form(form::SlurmForm, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    (isnothing(snap) || isnothing(snap.runmode_settings)) && return nothing
    flags = snap.runmode_settings.slurm_flags
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    highlight, error_style = Tachikoma.tstyle(:accent, bold = true), Tachikoma.tstyle(:error, bold = true)
    label_width = maximum(o -> textwidth(o.label), SLURM_FORM_OPTIONS)
    lines = Tuple{String,Any}[]
    for (n, opt) in enumerate(SLURM_FORM_OPTIONS)
        value = slurm_option(flags, opt.name)
        conflict = slurm_flag_conflict(flags, opt)
        shown = !isnothing(conflict) ? "set by $(flags[conflict])" : something(value, "not set")
        style = n == form.cursor ? highlight : isnothing(value) ? dim : text
        push!(lines, ("  " * rpad(opt.label, label_width) * "  " * shown, style))
    end
    shown = Set(something(slurm_flag_index(flags, o), 0) for o in SLURM_FORM_OPTIONS)
    others = [f for (i, f) in pairs(flags) if !(i in shown)]
    push!(lines, ("", text), ("other flags: " * (isempty(others) ? "none" : join(others, " ")), dim))
    push!(lines, ("New allocations use these settings; `w` on the Setup page writes them to the config.", dim))
    push!(lines, ("", text))
    isnothing(form.text) || push!(lines, ("new value: " * form.text * "▏", highlight))
    isnothing(form.error) || push!(lines, (form.error, error_style))
    push!(lines, (isnothing(form.text) ? "Enter: edit   Esc: close" : "Enter: set (empty: remove)   Esc: drop", dim))

    width = min(area.width, max(50, maximum(l -> textwidth(first(l)), lines) + 4))
    height = min(area.height, length(lines) + 2)
    box = Tachikoma.center(area, width, height)
    for y in box.y:Tachikoma.bottom(box), x in box.x:Tachikoma.right(box)

        Tachikoma.set_char!(buf, x, y, ' ', text)
    end
    inner = Tachikoma.render(Tachikoma.Block(title = "SLURM settings (this session)", border_style = Tachikoma.tstyle(:border_focus)), box,
                             buf)
    for (i, (line, style)) in enumerate(lines)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        Tachikoma.set_string!(buf, inner.x + 1, y, line, style; max_x = Tachikoma.right(inner))
    end
    return nothing
end
