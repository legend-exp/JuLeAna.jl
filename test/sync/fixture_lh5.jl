# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using HDF5

"""
    write_lh5(path; groups = ["B00000C", "V01234A", "aux"], scale = 1, inner = "jldsp")

Write a small HDF5 file shaped like a per-detector LEGEND tier file: one
top-level group per name, each holding `<inner>/waveform`, an `Int32` vector
whose length is `100 * k * scale` for the k-th group, and a `unit` attribute.
Returns `path`.
"""
function write_lh5(path::AbstractString; groups = ["B00000C", "V01234A", "aux"],
                   scale::Integer = 1, inner::AbstractString = "jldsp")
    mkpath(dirname(path))
    h5open(path, "w") do f
        for (k, name) in enumerate(groups)
            g = create_group(f, name)
            attrs(g)["unit"] = "keV"
            inner_group = create_group(g, inner)
            inner_group["waveform"] = collect(Int32, 1:(100 * k * scale))
        end
    end
    path
end

"""
    write_stub_julia(path)::String

Write an executable stand-in for the Julia of a host that has no helper
environment yet: it answers `--version` and, when asked to add packages with
`--project=DIR`, writes a `Project.toml` listing HDF5 and ParallelProcessingTools
in `DIR`. Returns `path`.
"""
function write_stub_julia(path::AbstractString)
    write(path, raw"""
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "julia version 9.9.9"; exit 0; fi
    for arg in "$@"; do
        case "$arg" in --project=*) project="${arg#--project=}";; esac
    done
    printf '[deps]\nHDF5 = "f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f"\nParallelProcessingTools = "8e8a01fc-6193-5ca1-a2f1-20776dae4199"\n' > "$project/Project.toml"
    """)
    chmod(path, 0o755)
    path
end

"""
    write_lh5_tier_det(path; groups = ["B00000C", "V01234A", "aux"], scale = 1,
                       tier = "jldsp", tier_attributes = Dict("origin" => "fixture", "revision" => 7))

Write a small HDF5 file in the `<tier>/<detector>` layout: one top-level group
`tier` carrying `tier_attributes`, and below it one group per name holding a
`waveform` dataset (an `Int32` vector of length `100 * k * scale` for the k-th
group) and a `unit` attribute. Returns `path`.
"""
function write_lh5_tier_det(path::AbstractString; groups = ["B00000C", "V01234A", "aux"],
                            scale::Integer = 1, tier::AbstractString = "jldsp",
                            tier_attributes = Dict("origin" => "fixture", "revision" => 7))
    mkpath(dirname(path))
    h5open(path, "w") do f
        t = create_group(f, tier)
        for (name, value) in tier_attributes
            attrs(t)[name] = value
        end
        for (k, name) in enumerate(groups)
            g = create_group(t, name)
            attrs(g)["unit"] = "keV"
            g["waveform"] = collect(Int32, 1:(100 * k * scale))
        end
    end
    path
end
