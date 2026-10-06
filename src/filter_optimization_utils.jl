# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Shared per-detector flow of process_filter_optimization and p_process_filter_optimization.

# The Tl-208 SEP and DEP lie one and two electron masses below the FEP.
const ELECTRON_MASS_ENERGY = 510.999u"keV"

# DEP fit window below and above the line: the Bi-212 FEP at 1620.7 keV, 28 keV above the DEP,
# stays outside.
const DEP_WINDOW = (15.0u"keV", 12.0u"keV")

const DEP_PEAKNAME = :Tl208DEP_Bi212FEP
const SEP_PEAKNAME = :Tl208SEP
