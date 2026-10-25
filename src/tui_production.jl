# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    ProductionForm(; parent = <folder that holds the current production>, shell, home)

State of the form of the terminal user interface that collects a [`ProductionSpec`](@ref):
the text of each field, the yes/no choices, the rows of the lists of extra tier paths and of
parameter folders, the field under the cursor, the message of the last rejected input and the
progress of the creation. Keys are handled by [`JuLeAna.production_key!`](@ref), the form is
drawn by [`JuLeAna.render_production`](@ref).

`phase` is `:edit` while the form is filled in, `:creating` from the submit until the
controller has created and loaded the production (see [`JuLeAna.production_sync!`](@ref)), and
`:done` once it has. `shell` and `home` select the startup file that `set_default` writes
(see [`ProductionSpec`](@ref)).
"""
mutable struct ProductionForm
    name::String
    parent::String
    metadata_url::String
    checkout::Bool
    metadata_ref::String
    jldataprod_branch::String
    dataprod_branch::String
    tier_labels::Vector{String}
    tier_paths::Vector{String}
    pars::Vector{String}
    set_default::Bool
    copy_software::Bool
    shell::String
    home::String
    # index into `production_fields(form)`
    cursor::Int
    error::Union{Nothing,String}
    # the candidates listed by the last Tab on a path field, empty if none
    hint::String
    phase::Symbol
    # folder of the production being created
    path::Union{Nothing,String}
    # the controller has accepted the `CreateProduction` command
    accepted::Bool
    # number of answered commands at which the answer to the `CreateProduction` command arrives, 0 before the submit
    answer_at::Int
    log::Vector{String}
end

function ProductionForm(;
                        parent::AbstractString = haskey(ENV, "LEGEND_DATA_CONFIG") ? dirname(dirname(abspath(last(data_config_files())))) :
                                                 "", shell::AbstractString = basename(get(ENV, "SHELL", "")),
                        home::AbstractString = homedir())
    return ProductionForm("", parent, METADATA_URL, true, "", "main", "main", String[], String[], String[], false, true, shell, home, 1,
                          nothing, "", :edit, nothing, false, 0, String[])
end

"""
    JuLeAna.production_fields(form::ProductionForm)

Return the fields of `form` in the order of the cursor, as `(kind, row)` pairs: `row` is the
index into the list of a `:tier_label`, `:tier_path` or `:par` field and 0 for the others.
The branch fields are present only if the branches are checked out.
"""
function production_fields(form::ProductionForm)
    fields = Tuple{Symbol,Int}[(:name, 0), (:parent, 0), (:url, 0), (:checkout, 0)]
    form.checkout && push!(fields, (:metadata_ref, 0), (:jldataprod, 0), (:dataprod, 0))
    for i in eachindex(form.tier_labels)
        push!(fields, (:tier_label, i), (:tier_path, i))
    end
    push!(fields, (:add_tier, 0))
    for i in eachindex(form.pars)
        push!(fields, (:par, i))
    end
    push!(fields, (:add_par, 0), (:set_default, 0), (:copy_software, 0), (:create, 0))
    return fields
end

function production_text_kind(kind::Symbol)
    return kind in (:name, :parent, :url, :metadata_ref, :jldataprod, :dataprod, :tier_label, :tier_path, :par)
end
production_toggle_kind(kind::Symbol) = kind in (:checkout, :set_default, :copy_software)
production_path_kind(kind::Symbol) = kind in (:parent, :tier_path, :par)

# The text of a text field.
function production_text(form::ProductionForm, (kind, i)::Tuple{Symbol,Int})
    kind === :name && return form.name
    kind === :parent && return form.parent
    kind === :url && return form.metadata_url
    kind === :metadata_ref && return form.metadata_ref
    kind === :jldataprod && return form.jldataprod_branch
    kind === :dataprod && return form.dataprod_branch
    kind === :tier_label && return form.tier_labels[i]
    kind === :tier_path && return form.tier_paths[i]
    kind === :par && return form.pars[i]
    return throw(ArgumentError("production_text: $kind is not a text field"))
end

# Replace the text of a text field.
function production_set_text!(form::ProductionForm, (kind, i)::Tuple{Symbol,Int}, text::AbstractString)
    text = String(text)
    kind === :name ? (form.name = text) :
    kind === :parent ? (form.parent = text) :
    kind === :url ? (form.metadata_url = text) :
    kind === :metadata_ref ? (form.metadata_ref = text) :
    kind === :jldataprod ? (form.jldataprod_branch = text) :
    kind === :dataprod ? (form.dataprod_branch = text) :
    kind === :tier_label ? (form.tier_labels[i] = text) :
    kind === :tier_path ? (form.tier_paths[i] = text) :
    kind === :par ? (form.pars[i] = text) : throw(ArgumentError("production_set_text!: $kind is not a text field"))
    return nothing
end

# Flip the yes/no field `kind`.
function production_toggle!(form::ProductionForm, kind::Symbol)
    kind === :checkout ? (form.checkout = !form.checkout) :
    kind === :set_default ? (form.set_default = !form.set_default) : (form.copy_software = !form.copy_software)
    return nothing
end

# Add an empty row to the list of tier paths (`:tier`) or of parameter folders (`:par`) and
# put the cursor on it.
function production_add_row!(form::ProductionForm, list::Symbol)
    if list === :tier
        push!(form.tier_labels, "")
        push!(form.tier_paths, "")
    else
        push!(form.pars, "")
    end
    form.cursor = findfirst(==(list === :tier ? (:tier_label, length(form.tier_labels)) : (:par, length(form.pars))),
                            production_fields(form))
    return nothing
end

# Remove the list row under the cursor, if the cursor is on one.
function production_remove_row!(form::ProductionForm)
    kind, i = production_fields(form)[form.cursor]
    if kind in (:tier_label, :tier_path)
        deleteat!(form.tier_labels, i)
        deleteat!(form.tier_paths, i)
    elseif kind === :par
        deleteat!(form.pars, i)
    else
        return nothing
    end
    form.cursor = clamp(form.cursor, 1, length(production_fields(form)))
    return nothing
end

# The stripped text of a branch field, `nothing` if the branches are not checked out or the text is empty.
function production_branch(checkout, text)
    return checkout && !isempty(strip(text)) ? strip(text) : nothing
end

"""
    JuLeAna.production_spec(form::ProductionForm)

Return the [`ProductionSpec`](@ref) that `form` describes. Surrounding blanks of the text are
removed; the reference and the branches are `nothing` unless they are checked out and not
empty, and a tier row or parameter
row without any text is left out.
"""
function production_spec(form::ProductionForm)
    tiers = [strip(l) => strip(p) for (l, p) in zip(form.tier_labels, form.tier_paths) if !isempty(strip(l)) || !isempty(strip(p))]
    return ProductionSpec(; name = strip(form.name), parent = strip(form.parent), metadata_url = strip(form.metadata_url),
                          metadata_ref = production_branch(form.checkout, form.metadata_ref),
                          jldataprod_branch = production_branch(form.checkout, form.jldataprod_branch),
                          dataprod_branch = production_branch(form.checkout, form.dataprod_branch),
                          tier_paths = Pair{String,String}[String(l) => String(p) for (l, p) in tiers],
                          pars = String[strip(p) for p in form.pars if !isempty(strip(p))], form.set_default, form.copy_software,
                          form.shell, form.home)
end

# Check the spec of `form` and send `CreateProduction` for it; a problem becomes the error of the form.
function production_submit!(form::ProductionForm, send)
    try
        spec = production_spec(form)
        form.path = check_production(spec)
        form.phase, form.accepted, form.answer_at, form.error = :creating, false, 0, nothing
        empty!(form.log)
        send(CreateProduction(spec))
    catch e
        e isa ArgumentError || rethrow()
        form.error = e.msg
    end
    return nothing
end

"""
    JuLeAna.production_key!(form::ProductionForm, evt::Tachikoma.KeyEvent, send)

Handle the key `evt` in the new-production form and return `:close` when the form closes,
`:finished` when a key ends the display of the created production, `true` otherwise: the form
uses every key. `send(cmd)` sends a controller command.

- Up, Down and Shift-Tab move between the fields. Tab on a path field (parent folder, tier
  path, parameter folder) completes the text with [`JuLeAna.complete_path`](@ref) and lists
  the folders that remain; when there is nothing left to complete it moves to the next field.
- Printable characters and Backspace edit the text field under the cursor.
- Space or Enter flips a yes/no field. Enter on a text field moves to the next field.
- Ctrl-N, or Enter on a `[+]` field, adds a row to the list under the cursor (extra tier
  paths, parameter folders) and Ctrl-D or Delete removes the row under the cursor.
- Ctrl-O, or Enter on the `[ Create ]` field, checks the input with
  [`JuLeAna.check_production`](@ref) and sends [`CreateProduction`](@ref) for it. A problem is
  shown in the form and nothing is sent.
- Escape closes the form.

While the production is created no key does anything. Once it is created and loaded, any key
returns `:finished`.
"""
function production_key!(form::ProductionForm, evt::Tachikoma.KeyEvent, send)
    evt.action == Tachikoma.key_release && return true
    form.phase === :creating && return true
    form.phase === :done && return :finished
    fields = production_fields(form)
    form.cursor = clamp(form.cursor, 1, length(fields))
    field = fields[form.cursor]
    kind, key, char = field[1], evt.key, evt.char
    form.error, form.hint = nothing, ""
    if key == :escape
        return :close
    elseif key == :up
        form.cursor = max(1, form.cursor - 1)
    elseif key == :down
        form.cursor = min(length(fields), form.cursor + 1)
    elseif key == :tab && production_path_kind(kind) && production_complete!(form, field)
    elseif key == :tab || key == :backtab
        form.cursor = mod1(form.cursor + (key == :tab ? 1 : -1), length(fields))
    elseif key == :ctrl && char == 'o'
        production_submit!(form, send)
    elseif key == :ctrl && char == 'n'
        kind in (:tier_label, :tier_path, :add_tier) ? production_add_row!(form, :tier) :
        kind in (:par, :add_par) && production_add_row!(form, :par)
    elseif (key == :ctrl && char == 'd') || key == :delete
        production_remove_row!(form)
    elseif key == :enter && kind === :create
        production_submit!(form, send)
    elseif key == :enter && kind === :add_tier
        production_add_row!(form, :tier)
    elseif key == :enter && kind === :add_par
        production_add_row!(form, :par)
    elseif production_toggle_kind(kind) && (key == :enter || (key == :char && char == ' '))
        production_toggle!(form, kind)
    elseif key == :enter
        form.cursor = min(length(fields), form.cursor + 1)
    elseif production_text_kind(kind) && key == :backspace
        production_set_text!(form, field, chop(production_text(form, field)))
    elseif production_text_kind(kind) && key == :char && isprint(char)
        production_set_text!(form, field, production_text(form, field) * char)
    end
    return true
end

"""
    JuLeAna.complete_path(text; home = homedir())

Complete the folder path `text` against the file system: return `(; text, candidates)` where
`candidates` are the names (with a trailing `/`) of the folders in the parent folder of
`text` whose names start with the last component of `text`, and `text` is the input extended
by the longest common prefix of the candidates. A leading `~` is replaced by `home`. Hidden
folders are candidates only if the last component starts with a `.`. A relative path, or a
parent folder that does not exist or cannot be read, has no candidates and `text` is
returned unchanged. Reads one folder and does not descend into any.
"""
function complete_path(text::AbstractString; home::AbstractString = homedir())
    expanded = text == "~" || startswith(text, "~/") ? home * text[2:end] : String(text)
    isabspath(expanded) || return (; text = String(text), candidates = String[])
    dir, prefix = endswith(expanded, '/') ? (expanded, "") : splitdir(expanded)
    names = try
        readdir(dir)
    catch e
        e isa Base.IOError || rethrow()
        return (; text = expanded, candidates = String[])
    end
    candidates = [n * "/"
                  for n in names if startswith(n, prefix) && (!startswith(n, ".") || startswith(prefix, ".")) && isdir(joinpath(dir, n))]
    isempty(candidates) && return (; text = expanded, candidates)
    common = first(candidates)
    for c in candidates
        common = join(first(p) for p in Iterators.takewhile(p -> p[1] == p[2], zip(common, c)))
    end
    return (; text = joinpath(dir, common), candidates)
end

# Tab on the path field `field`: extend its text and list the remaining candidates in the
# hint. Returns whether the text changed or candidates are listed, that is, whether Tab did
# something other than move on.
function production_complete!(form::ProductionForm, field)
    text = production_text(form, field)
    completed, candidates = complete_path(text; form.home)
    production_set_text!(form, field, completed)
    if length(candidates) > 1
        shown = first(candidates, 8)
        form.hint = join(shown, "  ") * (length(candidates) > length(shown) ? "  and $(length(candidates) - length(shown)) more" : "")
    end
    return completed != text || length(candidates) > 1
end

"""
    JuLeAna.production_answer!(form::ProductionForm, answered::Integer, error)

Take the answer to a command: when it is the answer to the [`CreateProduction`](@ref) command
of `form` (the `answered`-th answer, see the field `answer_at`), a rejection with the
exception `error` becomes the error of the form and its fields can be corrected, else the
command is accepted and the creation runs.
"""
function production_answer!(form::ProductionForm, answered::Integer, error)
    (form.phase === :creating && !form.accepted && answered == form.answer_at) || return nothing
    if error isa Exception
        form.phase, form.error = :edit, error isa ArgumentError ? error.msg : sprint(showerror, error)
    else
        form.accepted = true
    end
    return nothing
end

"""
    JuLeAna.production_sync!(form::ProductionForm, snap, lines)

Bring `form` in line with the controller snapshot `snap` and the `lines` of the creation log
(see [`JuLeAna.production_log`](@ref)). Once the command is accepted and the controller is no
longer `:loading`, the form is `:done` or, if the controller kept an error, back in `:edit`
with that error.
"""
function production_sync!(form::ProductionForm, snap, lines)
    (form.phase === :creating && form.accepted && !isnothing(snap)) || return nothing
    form.log = lines
    snap.state === :loading && return nothing
    if isnothing(snap.last_error)
        form.phase = :done
    else
        form.phase, form.error = :edit, snap.last_error
    end
    return nothing
end

# Label of the field `(kind, i)`.
function production_label(form::ProductionForm, (kind, i)::Tuple{Symbol,Int})
    kind === :name && return "Name"
    kind === :parent && return "Parent folder"
    kind === :url && return "Metadata URL"
    kind === :checkout && return "Check out metadata branches"
    kind === :metadata_ref && return "  legend-metadata branch or tag"
    kind === :jldataprod && return "  jldataprod branch"
    kind === :dataprod && return "  dataprod branch"
    kind === :tier_label && return "Tier path $i label"
    kind === :tier_path && return "  path"
    kind === :par && return "Parameter folder $i"
    kind === :add_tier && return "[+] extra tier path"
    kind === :add_par && return "[+] parameter folder to copy"
    if kind === :set_default
        rc = shell_rc_file(form.shell, form.home)
        return "Set as default in " * (isnothing(rc) ? "the shell startup file" : basename(rc))
    end
    kind === :copy_software && return "Copy the software into the production"
    return "[ Create ]"
end

"""
    JuLeAna.render_production(form::ProductionForm, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer; ticks = 0)

Draw the new-production form as a page filling `area`: one field per row with the label
at the left and the text or the yes/no value at the right, the field under the cursor
highlighted, scrolled to keep it in view; below them the first line of the error of the
last input, wrapped to at most three rows, and a line of keys. While the production is created, the lines of its log (the newest that fit)
replace the fields, and a finished creation shows the path of the production.
"""
function render_production(form::ProductionForm, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer; ticks::Integer = 0)
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    highlight, error_style = Tachikoma.tstyle(:accent, bold = true), Tachikoma.tstyle(:error, bold = true)
    for y in area.y:Tachikoma.bottom(area), x in area.x:Tachikoma.right(area)

        Tachikoma.set_char!(buf, x, y, ' ', text)
    end
    inner = Tachikoma.render(pane_block("New data production", true), area, buf)
    inner.height < 1 && return nothing
    put(y, spans) = y <= Tachikoma.bottom(inner) && put_spans!(buf, inner.x + 1, y, Tachikoma.right(inner), spans)
    if form.phase !== :edit
        done = form.phase === :done
        spinner = string(Tachikoma.SPINNER_BRAILLE[mod1(ticks, length(Tachikoma.SPINNER_BRAILLE))])
        put(inner.y,
            done ? [("Created and loaded $(form.path)", Tachikoma.tstyle(:success, bold = true))] :
            [(spinner * " ", Tachikoma.tstyle(:warning)), ("Creating $(form.path)", text)])
        put(inner.y + 1, [(done ? "Any key continues to the Setup page." : "", dim)])
        room = inner.height - 3
        shown = last(form.log, max(0, room))
        for (j, line) in enumerate(shown)
            put(inner.y + 2 + j, [(line, dim)])
        end
        return nothing
    end
    fields = production_fields(form)
    cursor = clamp(form.cursor, 1, length(fields))
    # the first line of the error, wrapped to at most three rows above the line of keys
    error_rows = isnothing(form.error) ? String[] :
                 first([join(c) for c in Iterators.partition(collect(first(split(form.error, '\n'))), max(1, inner.width - 2))], 3)
    visible = max(1, inner.height - 1 - max(1, length(error_rows)))
    top = clamp(cursor - visible ÷ 2, 1, max(1, length(fields) - visible + 1))
    label_width = maximum(f -> textwidth(production_label(form, f)), fields) + 2
    for (row, i) in enumerate(top:min(length(fields), top + visible - 1))
        field = fields[i]
        kind = field[1]
        focused = i == cursor
        label_style = focused ? highlight : text
        value = if production_text_kind(kind)
            [(production_text(form, field) * (focused ? "▏" : ""), Tachikoma.tstyle(:text_bright))]
        elseif production_toggle_kind(kind)
            yes = kind === :checkout ? form.checkout : kind === :set_default ? form.set_default : form.copy_software
            [(yes ? "yes" : "no", Tachikoma.tstyle(yes ? :success : :text_dim, bold = focused))]
        else
            Tuple{String,Tachikoma.Style}[]
        end
        label = production_text_kind(kind) || production_toggle_kind(kind) ? rpad(production_label(form, field), label_width) :
                production_label(form, field)
        put(inner.y + row - 1, vcat([((focused ? "> " : "  ") * label, label_style)], value))
    end
    isempty(error_rows) && !isempty(form.hint) && put(Tachikoma.bottom(inner) - 1, [(form.hint, dim)])
    for (j, line) in enumerate(error_rows)
        put(Tachikoma.bottom(inner) - length(error_rows) + j - 1, [(line, error_style)])
    end
    put(Tachikoma.bottom(inner), [("Tab complete path/next   Ctrl-O create   Ctrl-N/Ctrl-D add/remove row   Esc close", dim)])
    return nothing
end
