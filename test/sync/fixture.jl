# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using HDF5

# One group per detector, the k-th holding 100k samples: `<detector>/<tier>/waveform`, or `<tier>/<detector>/waveform` with `tier_first`.
function write_lh5(path, groups; tier = "jldsp", tier_first = false)
    mkpath(dirname(path))
    h5open(path, "w") do f
        top = tier_first ? create_group(f, tier) : f
        tier_first && (attrs(top)["origin"] = "fixture")
        for (k, name) in enumerate(groups)
            g = create_group(top, name)
            (tier_first ? g : create_group(g, tier))["waveform"] = collect(Int32, 1:(100k))
        end
    end
    return path
end

# A remote root with the production `test`: `jlevt` files, HDF5 `jldsp` and `jlpks` files (r001 lacks `aux`) and `jlqcs` per-detector files.
function make_remote()
    root = mktempdir()
    prod = joinpath(root, "test")
    tier = joinpath(prod, "generated", "tier")
    put(path, text) = write(joinpath(mkpath(dirname(path)), basename(path)), text)
    put(joinpath(prod, "legend-metadata", "README.md"), "metadata\n")
    put(joinpath(prod, "config.json"),
        raw"""{"setups": {"l200": {"paths": {"metadata": "$_/legend-metadata/", "tier": "$_/generated/tier/"}}}}""")
    file(name, run, key) = joinpath(tier, name, "cal", "p18", run, "l200-p18-$run-cal-$key-tier_$name.lh5")
    stamps = ("20251107T191821Z", "20251107T192416Z")
    for (key, n) in zip(stamps, (100, 200))
        put(joinpath(tier, "jlevt", "phy", "p18", "r000", "l200-p18-r000-phy-$key-tier_jlevt.lh5"), "e"^n)
    end
    for (name, tier_first) in (("jldsp", false), ("jlpks", true)),
        (run, key, groups) in (("r000", stamps[1], ["B00000C", "V01234A", "aux"]), ("r000", stamps[2], ["B00000C", "V01234A", "aux"]),
                               ("r001", "20251108T101010Z", ["B00000C", "V01234A"]))

        write_lh5(file(name, run, key), groups; tier = name, tier_first)
    end
    for (run, detector, n) in (("r000", "B00000C", 100), ("r000", "V01234A", 200), ("r001", "B00000C", 300))
        put(file("jlqcs", run, detector), "q"^n)
    end
    return root
end
