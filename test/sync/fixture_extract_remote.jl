# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    make_extract_remote()::String

A miniature remote root in a temporary directory with real HDF5 tier files: the
production `xprod` holds two `jldsp` runs (three detector-like groups per file) and
one `jlevt` run (a single group named after the tier). It is separate from the
committed fixture so that the tests of the other modules keep their file counts.
"""
function make_extract_remote()
    root = mktempdir()
    prod = joinpath(root, "xprod")
    mkpath(joinpath(prod, "legend-metadata"))
    write(joinpath(prod, "legend-metadata", "README.md"), "metadata\n")
    write(joinpath(prod, "config.json"), raw"""
    {"setups": {"l200": {"paths": {"metadata": "$_/legend-metadata/", "tier": "$_/generated/tier/"}}}}
    """)
    tier = joinpath(prod, "generated", "tier")
    dsp(run, ts, scale) = write_lh5(joinpath(tier, "jldsp", "cal", "p18", run,
        "l200-p18-$run-cal-$ts-tier_jldsp.lh5"); scale)
    dsp("r000", "20251107T191821Z", 1)
    dsp("r000", "20251107T192416Z", 2)
    dsp("r001", "20251108T101010Z", 1)
    for ts in ("20251107T191821Z", "20251107T192416Z")
        write_lh5(joinpath(tier, "jlevt", "phy", "p18", "r000",
                           "l200-p18-r000-phy-$ts-tier_jlevt.lh5");
                  groups = ["jlevt"], inner = "tables")
    end
    root
end

"""
    make_tier_det_remote()::String

A miniature remote root in a temporary directory whose production `tprod` stores its
per-filekey tier files in the `<tier>/<detector>` layout: the `jlpks` period `p18`
has two runs (`r000` with two files and three detectors, `r001` with one file that
lacks `aux`), the period `p20` has a run whose second file lacks `V01234A`, the
period `p19` has a run without tier files, and the `jlevt` period `p18` has files
without a detector axis.
"""
function make_tier_det_remote()
    root = mktempdir()
    prod = joinpath(root, "tprod")
    mkpath(joinpath(prod, "legend-metadata"))
    write(joinpath(prod, "legend-metadata", "README.md"), "metadata\n")
    write(joinpath(prod, "config.json"), raw"""
    {"setups": {"l200": {"paths": {"metadata": "$_/legend-metadata/", "tier": "$_/generated/tier/"}}}}
    """)
    tier = joinpath(prod, "generated", "tier")
    pks(run, ts, scale, groups) = write_lh5_tier_det(
        joinpath(tier, "jlpks", "cal", "p18", run, "l200-p18-$run-cal-$ts-tier_jlpks.lh5");
        scale, groups, tier = "jlpks")
    pks("r000", "20251107T191821Z", 1, ["B00000C", "V01234A", "aux"])
    pks("r000", "20251107T192416Z", 2, ["B00000C", "V01234A", "aux"])
    pks("r001", "20251108T101010Z", 1, ["B00000C", "V01234A"])
    # A run whose second file lacks a detector that its first file has.
    pks20(ts, groups) = write_lh5_tier_det(
        joinpath(tier, "jlpks", "cal", "p20", "r002", "l200-p20-r002-cal-$ts-tier_jlpks.lh5");
        groups, tier = "jlpks")
    pks20("20251201T000000Z", ["B00000C", "V01234A"])
    pks20("20251201T000500Z", ["B00000C"])
    mkpath(joinpath(tier, "jlpks", "cal", "p19", "r000"))
    write(joinpath(tier, "jlpks", "cal", "p19", "r000", "README.txt"), "no tier files\n")
    for ts in ("20251107T191821Z", "20251107T192416Z")
        write_lh5(joinpath(tier, "jlevt", "phy", "p18", "r000", "l200-p18-r000-phy-$ts-tier_jlevt.lh5");
                  groups = ["jlevt"], inner = "tables")
    end
    root
end
