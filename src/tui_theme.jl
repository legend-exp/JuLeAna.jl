# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

# Colors of btop's night-owl theme as the nearest colors of the 256-color palette: text
# `#d6deeb`, title and bright text white, borders and dim text gray, the focused border
# and the accent `#addb67`, primary blue `#82aaff`, secondary purple `#c792ea`, success
# `#22da6e`, warning `#ffeb95` and error `#ef5350`.
const NIGHT_OWL_THEME = Tachikoma.Theme("night-owl", Tachikoma.Color256(233),  # bg
                                        Tachikoma.Color256(240),  # border
                                        Tachikoma.Color256(149),  # border_focus
                                        Tachikoma.Color256(254),  # text
                                        Tachikoma.Color256(242),  # text_dim
                                        Tachikoma.Color256(255),  # text_bright
                                        Tachikoma.Color256(111),  # primary
                                        Tachikoma.Color256(176),  # secondary
                                        Tachikoma.Color256(149),  # accent
                                        Tachikoma.Color256(41),   # success
                                        Tachikoma.Color256(222),  # warning
                                        Tachikoma.Color256(203),  # error
                                        Tachikoma.Color256(255)  # title
                                        )

# Colors of the interface, from the colors of the logo (red `#cb3c33`, green `#389826`,
# purple `#9558b2`): `border` and `secondary` muted purple, `border_focus`, `primary` and
# `success` green, `accent` light purple for the cursor and running items, `title` salmon
# red, `error` pure red so that the two reds differ; text and warning as in Tachikoma's
# default theme.
const JULEANA_THEME = Tachikoma.Theme("juleana", Tachikoma.Color256(234),  # bg
                                      Tachikoma.Color256(96),   # border
                                      Tachikoma.Color256(77),   # border_focus
                                      Tachikoma.Color256(252),  # text
                                      Tachikoma.Color256(242),  # text_dim
                                      Tachikoma.Color256(159),  # text_bright
                                      Tachikoma.Color256(71),   # primary
                                      Tachikoma.Color256(133),  # secondary
                                      Tachikoma.Color256(140),  # accent
                                      Tachikoma.Color256(77),   # success
                                      Tachikoma.Color256(214),  # warning
                                      Tachikoma.Color256(196),  # error
                                      Tachikoma.Color256(167)   # title
                                      )

"""
    JuLeAna.TUI_THEMES

The themes of the interface, in the order in which `T` cycles through them: `night-owl`
(the default), `juleana` and the themes of Tachikoma.
"""
const TUI_THEMES = (NIGHT_OWL_THEME, JULEANA_THEME, Tachikoma.ALL_THEMES...)

const DEFAULT_THEME_NAME = "night-owl"

"""
    JuLeAna.tui_theme(name::AbstractString)

The theme of [`JuLeAna.TUI_THEMES`](@ref) called `name`. Throws an `ArgumentError` that
lists the names for an unknown one.
"""
function tui_theme(name::AbstractString)
    i = findfirst(t -> t.name == name, TUI_THEMES)
    isnothing(i) && throw(ArgumentError("unknown theme `$name`; the themes are " * join((t.name for t in TUI_THEMES), ", ")))
    return TUI_THEMES[i]
end

"""
    JuLeAna.theme_preference_path()

The file that keeps the name of the theme chosen with `T`: `prefs/JuLeAna/theme` in the
first Julia depot.
"""
theme_preference_path() = joinpath(first(DEPOT_PATH), "prefs", "JuLeAna", "theme")

"""
    JuLeAna.load_theme_name(path::AbstractString = JuLeAna.theme_preference_path())

The name of the theme saved in `path`, or `night-owl` when nothing is saved. A saved name
that is not a theme of [`JuLeAna.TUI_THEMES`](@ref) is logged as a warning and replaced by
`night-owl`.
"""
function load_theme_name(path::AbstractString = theme_preference_path())
    isfile(path) || return DEFAULT_THEME_NAME
    name = strip(read(path, String))
    any(t -> t.name == name, TUI_THEMES) && return String(name)
    @warn "The saved theme `$name` in $path is unknown; using `$DEFAULT_THEME_NAME`"
    return DEFAULT_THEME_NAME
end

"""
    JuLeAna.next_theme!(path::AbstractString = JuLeAna.theme_preference_path())

Switch the interface to the theme after the active one in [`JuLeAna.TUI_THEMES`](@ref) and
save its name in `path` for the next start. Returns the new theme. A failed save is logged
as a warning; the theme is switched anyway.
"""
function next_theme!(path::AbstractString = theme_preference_path())
    i = something(findfirst(t -> t.name == Tachikoma.theme().name, TUI_THEMES), 0)
    theme = TUI_THEMES[mod1(i + 1, length(TUI_THEMES))]
    Tachikoma.set_theme!(theme)
    try
        mkpath(dirname(path))
        write(path, theme.name)
    catch e
        e isa SystemError || e isa Base.IOError || rethrow()
        @warn "Could not save the theme `$(theme.name)` in $path" exception = e
    end
    @info "Theme: $(theme.name)"
    return theme
end
