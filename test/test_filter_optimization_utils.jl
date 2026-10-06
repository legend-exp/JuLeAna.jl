# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Test
using LegendDataManagement, LegendDSP, LegendSpecFits, LegendHDF5IO
using TypedTables, PropDicts, StatsBase, Unitful, Random
using OffsetArrays
import Measurements
using Measurements: value as mvalue

include(joinpath(@__DIR__, "..", "src", "filter_optimization_utils.jl"))

@testset "filter optimization utils" begin
    @testset "constants" begin
        @test 2614.51u"keV" - 2 * ELECTRON_MASS_ENERGY ≈ 1592.51u"keV" atol = 0.01u"keV"
        @test 1592.51u"keV" + last(DEP_WINDOW) < 1620.74u"keV" - 5u"keV"
    end

    @testset "single_site_aoe_cut" begin
        rng = MersenneTwister(42)
        n_ss, n_ms = 20000, 8000
        e = fill(1000.0, n_ss + n_ms)
        aoe_true = vcat(1.0 .+ 0.01 .* randn(rng, n_ss), 0.85 .+ 0.05 .* randn(rng, n_ms))
        a = aoe_true .* e
        mask, report = single_site_aoe_cut(a, e; aoe_cut_sigma = 2.0)
        @test keys(report) == (:h, :f_fit, :μ, :σ, :cut_value, :n_sigma, :sf)
        @test report.μ ≈ 1.0 atol = 0.003
        @test report.σ ≈ 0.01 rtol = 0.2
        @test report.cut_value ≈ report.μ - 2.0 * report.σ
        @test count(mask[begin:n_ss]) / n_ss > 0.95
        @test count(mask[n_ss+1:end]) / n_ms < 0.1
        @test report.sf == count(mask) / length(mask)
        # the mask keeps the axes of the input
        omask, _ = single_site_aoe_cut(OffsetArray(a, -7), OffsetArray(e, -7); aoe_cut_sigma = 2.0)
        @test axes(omask) == axes(OffsetArray(a, -7))
        @test parent(omask) == mask
        @test_throws DimensionMismatch single_site_aoe_cut(a, e[begin:end-1]; aoe_cut_sigma = 2.0)
        @test_throws ArgumentError single_site_aoe_cut(a[begin:begin+49], e[begin:begin+49]; aoe_cut_sigma = 2.0)
    end

    @testset "crosscheck_warning" begin
        base = (shifts = (DEP = (shift = 0.10u"keV", σ = 1.0u"keV"), SEP = (shift = -0.20u"keV", σ = 1.2u"keV")),
                slow_mean_residual = -0.30)
        @test crosscheck_warning(base, base; max_shift_sigma = 0.5) == ""
        moved = merge(base, (shifts = merge(base.shifts, (DEP = (shift = 0.70u"keV", σ = 1.0u"keV"),)),))
        @test occursin("DEP", crosscheck_warning(base, moved; max_shift_sigma = 0.5))
        @test !occursin("SEP", crosscheck_warning(base, moved; max_shift_sigma = 0.5))
        within = merge(base, (shifts = merge(base.shifts, (DEP = (shift = 0.55u"keV", σ = 1.0u"keV"),)),))
        @test crosscheck_warning(base, within; max_shift_sigma = 0.5) == ""
        slow = merge(base, (slow_mean_residual = 0.40,))
        @test occursin("slow-pulse", crosscheck_warning(base, slow; max_shift_sigma = 0.5))
        missing_new = merge(base, (shifts = (SEP = base.shifts.SEP,),))
        @test occursin("DEP crosscheck missing at the new optimum", crosscheck_warning(base, missing_new; max_shift_sigma = 0.5))
        @test occursin("DEP crosscheck missing at the legacy optimum", crosscheck_warning(missing_new, base; max_shift_sigma = 0.5))
        nothing_checked = (shifts = NamedTuple(), slow_mean_residual = -0.30)
        @test crosscheck_warning(nothing_checked, nothing_checked; max_shift_sigma = 0.5) == ""
    end

    @testset "write_fltopt_tables" begin
        path = joinpath(mktempdir(), "fltopt_tables.lh5")
        evaluation = Table(scan = [:noise, :ft_scan, :lattice], rt = [5.0, 5.0, 5.5] .* u"µs",
            fwhm = [Measurements.measurement(NaN, NaN), Measurements.measurement(2.5, 0.1), Measurements.measurement(2.4, 0.1)] .* u"keV",
            status = ["ok", "ok", "fit failed"], converged = [true, true, false], n_events = [0, 5000, 4900])
        residuals = (residual = [0.1, -0.2], rise_time = [0.5, 0.7] .* u"µs")
        @test write_fltopt_tables(path, (; evaluation, residuals)) == path
        lh5open(path) do h
            ev = h["evaluation"]
            @test ev.scan[:] == ["noise", "ft_scan", "lattice"]
            @test collect(ev.rt) == [5.0, 5.0, 5.5] .* u"µs"
            @test isequal(collect(ev.fwhm), [NaN, 2.5, 2.4] .* u"keV")
            @test ev.status[:] == ["ok", "ok", "fit failed"]
            @test collect(ev.converged) == [true, true, false]
            @test collect(ev.n_events) == [0, 5000, 4900]
            @test collect(h["residuals"].rise_time) == [0.5, 0.7] .* u"µs"
        end
    end
end
