using Pkg

# Remove stale LegendJuliaRegistry cache to avoid rebase failures on CI
legend_reg = joinpath(first(DEPOT_PATH), "registries", "LegendJuliaRegistry")
if isdir(legend_reg)
    rm(legend_reg; recursive = true)
end

pkg"registry add General https://github.com/legend-exp/LegendJuliaRegistry.git"
