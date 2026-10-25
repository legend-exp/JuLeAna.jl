# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    JuLeAna.@using_packages

Load the exported names of the packages JuLeAna works with into the calling module, e.g.
the REPL, as `using` does: the LEGEND packages with `LDMUtils`, ParallelProcessingTools,
CairoMakie with the names of Makie, LegendMakie, and the packages for units, tables,
measurements and timing, with `mvalue` and `muncert` for the value and uncertainty of a
`Measurement`.

The packages are loaded from JuLeAna, so they need not be in the active environment.
Names that two packages both export, such as `fit`, must be qualified, e.g. `StatsBase.fit`.

# Examples
```julia
using JuLeAna
JuLeAna.@using_packages
channelinfo(l200, filekey)
```
"""
macro using_packages()
    return esc(Expr(:toplevel,
                    :(using JuLeAna.LegendHDF5IO, JuLeAna.LegendDSP, JuLeAna.LegendSpecFits, JuLeAna.LegendDataTypes,
                            JuLeAna.LegendDataManagement, JuLeAna.LDMUtils, JuLeAna.LegendEventAnalysis, JuLeAna.IntervalSets,
                            JuLeAna.PropertyFunctions, JuLeAna.TypedTables, JuLeAna.PropDicts, JuLeAna.StatsBase, JuLeAna.Unitful,
                            JuLeAna.UnitfulAtomic, JuLeAna.Format, JuLeAna.LaTeXStrings, JuLeAna.Printf, JuLeAna.Measures, JuLeAna.Dates,
                            JuLeAna.Measurements, JuLeAna.Distributed, JuLeAna.ProgressMeter, JuLeAna.TimerOutputs,
                            JuLeAna.ParallelProcessingTools, JuLeAna.CairoMakie, JuLeAna.LegendMakie),
                    :(using JuLeAna.Measurements: value as mvalue, uncertainty as muncert)))
end
