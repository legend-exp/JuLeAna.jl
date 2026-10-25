# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    make_per_detector_remote()::String

A miniature remote root in a temporary directory whose production `dprod` stores a
per-detector tier: the `jlqcs` category `cal` has the period `p16` with the run
`r000` (files for `B00000C` of 100 bytes and `V01234A` of 200 bytes) and the run
`r001` (a `B00000C` file of 300 bytes and a README), and the period `p17` whose only
run holds a README. A `jldsp` period `p16` with filekey files is there too, so that
the two kinds of tier can be told apart. The files are plain bytes: planning and
copying never open them.
"""
function make_per_detector_remote()
    root = mktempdir()
    prod = joinpath(root, "dprod")
    mkpath(joinpath(prod, "legend-metadata"))
    write(joinpath(prod, "legend-metadata", "README.md"), "metadata\n")
    write(joinpath(prod, "config.json"), raw"""
    {"setups": {"l200": {"paths": {"metadata": "$_/legend-metadata/", "tier": "$_/generated/tier/"}}}}
    """)
    tier = joinpath(prod, "generated", "tier")
    qcs(period, run, detector, bytes) = begin
        path = joinpath(tier, "jlqcs", "cal", period, run,
                        "l200-$period-$run-cal-$detector-tier_jlqcs.lh5")
        mkpath(dirname(path))
        write(path, repeat("q", bytes))
    end
    qcs("p16", "r000", "B00000C", 100)
    qcs("p16", "r000", "V01234A", 200)
    qcs("p16", "r001", "B00000C", 300)
    write(joinpath(tier, "jlqcs", "cal", "p16", "r001", "README.txt"), "notes\n")
    mkpath(joinpath(tier, "jlqcs", "cal", "p17", "r000"))
    write(joinpath(tier, "jlqcs", "cal", "p17", "r000", "README.txt"), "no tier files\n")
    write_lh5_tier_det(joinpath(tier, "jldsp", "cal", "p16", "r000",
                                "l200-p16-r000-cal-20251107T191821Z-tier_jldsp.lh5");
                       groups = ["B00000C", "V01234A"], tier = "jldsp")
    root
end
