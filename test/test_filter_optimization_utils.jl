# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Test
using LegendDataManagement, LegendDSP, LegendSpecFits, LegendHDF5IO
using TypedTables, PropDicts, StatsBase, Unitful, Random
using OffsetArrays
import Measurements
using Measurements: value as mvalue

# stand-in for the logging helper of src/log_texts.jl
truncate_error(e::Exception, max_length::Int = 1000) = first(sprint(showerror, e), max_length)

include(joinpath(@__DIR__, "..", "src", "filter_optimization_utils.jl"))

@testset "filter optimization utils" begin
    @testset "constants" begin
        @test 2614.51u"keV" - 2 * ELECTRON_MASS_ENERGY ≈ 1592.51u"keV" atol = 0.01u"keV"
        @test 1592.51u"keV" + last(DEP_WINDOW) < 1620.74u"keV" - 5u"keV"
    end

    @testset "crosscheck_warning" begin
        base = (shifts = (DEP = (shift = 0.10u"keV", σ = 1.0u"keV"), SEP = (shift = -0.20u"keV", σ = 1.2u"keV")),
                rows = ((peak = "FEP", status = "ok"), (peak = "DEP", status = "ok"), (peak = "SEP", status = "ok")),
                slow_mean_residual = -0.30)
        @test crosscheck_warning(base, base; max_shift_sigma = 0.5) == ""
        # |0.70| > |0.10| + 0.5 * 1.0
        grown = merge(base, (shifts = merge(base.shifts, (DEP = (shift = 0.70u"keV", σ = 1.0u"keV"),)),))
        @test occursin("DEP shift grew", crosscheck_warning(base, grown; max_shift_sigma = 0.5))
        @test !occursin("SEP", crosscheck_warning(base, grown; max_shift_sigma = 0.5))
        # an improvement of the same size is not flagged
        @test crosscheck_warning(grown, base; max_shift_sigma = 0.5) == ""
        # a sign change without growth is not flagged: |-0.55| <= |0.10| + 0.5
        flipped = merge(base, (shifts = merge(base.shifts, (DEP = (shift = -0.55u"keV", σ = 1.0u"keV"),)),))
        @test crosscheck_warning(base, flipped; max_shift_sigma = 0.5) == ""
        slow = merge(base, (slow_mean_residual = -0.90,))
        @test occursin("slow-pulse residual grew", crosscheck_warning(base, slow; max_shift_sigma = 0.5))
        @test crosscheck_warning(slow, base; max_shift_sigma = 0.5) == ""
        slow_flip = merge(base, (slow_mean_residual = 0.40,))
        @test crosscheck_warning(base, slow_flip; max_shift_sigma = 0.5) == ""
        missing_new = merge(base, (shifts = (SEP = base.shifts.SEP,),))
        @test occursin("DEP crosscheck missing at the new optimum", crosscheck_warning(base, missing_new; max_shift_sigma = 0.5))
        @test occursin("DEP crosscheck missing at the legacy optimum", crosscheck_warning(missing_new, base; max_shift_sigma = 0.5))
        nan_shift = merge(base, (shifts = merge(base.shifts, (DEP = (shift = NaN * u"keV", σ = 1.0u"keV"),)),))
        @test occursin("DEP new shift not finite", crosscheck_warning(base, nan_shift; max_shift_sigma = 0.5))
        @test occursin("DEP legacy shift not finite", crosscheck_warning(nan_shift, base; max_shift_sigma = 0.5))
        nan_sigma = merge(base, (shifts = merge(base.shifts, (DEP = (shift = 0.10u"keV", σ = NaN * u"keV"),)),))
        @test occursin("DEP new σ not finite", crosscheck_warning(base, nan_sigma; max_shift_sigma = 0.5))
        nan_slow = merge(base, (slow_mean_residual = NaN,))
        @test occursin("slow-pulse residual not finite", crosscheck_warning(base, nan_slow; max_shift_sigma = 0.5))
        @test occursin("slow-pulse residual not finite", crosscheck_warning(nan_slow, base; max_shift_sigma = 0.5))
        nothing_checked = (shifts = NamedTuple(), rows = ((peak = "FEP", status = "ok"),), slow_mean_residual = -0.30)
        @test crosscheck_warning(nothing_checked, nothing_checked; max_shift_sigma = 0.5) == ""
        # failed fits are reported from the table rows, also when the peak has no shift at either optimum
        failed_dep = (shifts = (SEP = base.shifts.SEP,), slow_mean_residual = -0.30,
                      rows = ((peak = "FEP", status = "ok"), (peak = "DEP", status = "failed: too few events"), (peak = "SEP", status = "ok")))
        @test crosscheck_warning(failed_dep, failed_dep; max_shift_sigma = 0.5) == "DEP fit failed (legacy, new)"
        # a fit that fails at one optimum is reported once, with that optimum
        @test crosscheck_warning(base, failed_dep; max_shift_sigma = 0.5) == "DEP fit failed (new)"
        @test crosscheck_warning(failed_dep, base; max_shift_sigma = 0.5) == "DEP fit failed (legacy)"
        failed_sep = merge(base, (rows = ((peak = "FEP", status = "ok"), (peak = "SEP", status = "failed: x")),))
        @test crosscheck_warning(base, failed_sep; max_shift_sigma = 0.5) == "SEP fit failed (new)"
        both = crosscheck_warning(failed_dep, failed_sep; max_shift_sigma = 0.5)
        @test occursin("DEP fit failed (legacy)", both) && occursin("SEP fit failed (new)", both)
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
            # String columns are read with col[:] because collect fails on LH5 string arrays.
            @test ev.scan[:] == ["noise", "ft_scan", "lattice"]
            @test collect(ev.rt) == [5.0, 5.0, 5.5] .* u"µs"
            @test isequal(collect(ev.fwhm), [NaN, 2.5, 2.4] .* u"keV")
            @test ev.status[:] == ["ok", "ok", "fit failed"]
            @test collect(ev.converged) == [true, true, false]
            @test collect(ev.n_events) == [0, 5000, 4900]
            @test collect(h["residuals"].rise_time) == [0.5, 0.7] .* u"µs"
        end
    end

    @testset "limit_peak_waveforms" begin
        data = (waveform_presummed = collect(1:10), waveform_windowed = collect(11:20), presum_rate = fill(4, 10))
        kept = limit_peak_waveforms(data, :Tl208FEP, 20, MersenneTwister(1))
        @test kept == (wvfs_pre = collect(1:10), wvfs_wdw = collect(11:20), presum_rate = fill(4, 10))
        reduced = @test_logs (:warn, r"exceed 4") limit_peak_waveforms(data, :Tl208FEP, 4, MersenneTwister(1))
        @test length(reduced.wvfs_pre) == 4
        @test allunique(reduced.wvfs_pre)
        @test issorted(reduced.wvfs_pre)
        @test reduced.wvfs_wdw == reduced.wvfs_pre .+ 10
        # the same seed selects the same events
        again = @test_logs (:warn, r"exceed 4") limit_peak_waveforms(data, :Tl208FEP, 4, MersenneTwister(1))
        @test again == reduced
        # the selection draws from all events, not only the first max_wvfs
        big = (waveform_presummed = collect(1:1000), waveform_windowed = collect(1:1000), presum_rate = fill(4, 1000))
        sel = @test_logs (:warn, r"exceed 500") limit_peak_waveforms(big, :Tl208FEP, 500, MersenneTwister(7)).wvfs_pre
        @test allunique(sel)
        @test minimum(sel) <= 10 && maximum(sel) >= 990
        @test count(>(500), sel) > 200
        # generic indices
        odata = (waveform_presummed = OffsetArray(collect(1:10), -3), waveform_windowed = OffsetArray(collect(11:20), -3), presum_rate = OffsetArray(fill(4, 10), -3))
        osel = @test_logs (:warn, r"exceed 4") limit_peak_waveforms(odata, :Tl208FEP, 4, MersenneTwister(1))
        @test allunique(osel.wvfs_pre) && all(in(1:10), osel.wvfs_pre)
    end

    @testset "fit_crosscheck_peak" begin
        rng = MersenneTwister(1)
        σ = 1.0
        line = 1592.51u"keV"
        e_cal = vcat(ustrip(u"keV", line) .+ σ .* randn(rng, 20000), 1570.0 .+ 45.0 .* rand(rng, 4000)) .* u"keV"
        fit = fit_crosscheck_peak(e_cal, line, DEP_WINDOW; containment = 0.9)
        @test fit.μ ≈ line atol = 0.05u"keV"
        @test fit.σ ≈ σ * u"keV" rtol = 0.05
        @test fit.fwhm ≈ 2.355 * σ * u"keV" rtol = 0.05
        @test fit.w90 ≈ 3.29 * σ * u"keV" rtol = 0.1
        @test fit.n_events == count(e -> line - first(DEP_WINDOW) < e < line + last(DEP_WINDOW), e_cal)
        @test fit.f_fit(ustrip(u"keV", line)) > 0
        @test_throws ArgumentError fit_crosscheck_peak(e_cal[begin:begin+49], line, DEP_WINDOW; containment = 0.9)
    end

    @testset "try_fit_crosscheck_peak" begin
        rng = MersenneTwister(1)
        line = 1592.51u"keV"
        e_cal = (ustrip(u"keV", line) .+ randn(rng, 5000)) .* u"keV"
        fit, status = try_fit_crosscheck_peak(e_cal, line, DEP_WINDOW; containment = 0.9)
        @test status == "ok"
        @test fit.μ ≈ line atol = 0.1u"keV"
        # a fit failure is recorded
        fit, status = try_fit_crosscheck_peak(e_cal[begin:begin+49], line, DEP_WINDOW; containment = 0.9)
        @test isnothing(fit) && startswith(status, "failed: ")
        # anything else propagates
        @test_throws MethodError try_fit_crosscheck_peak(ustrip.(u"keV", e_cal), line, DEP_WINDOW; containment = 0.9)
    end

    @testset "snap_seed" begin
        lattice = 0.3u"µs"
        rtb, ftb = (0.5u"µs", 3.0u"µs"), (0.5u"µs", 3.0u"µs")
        always(rt, ft) = true
        # the lattice does not divide the grid ends: bounds snap inward to 0.6 and 3.0 µs
        rt, ft = snap_seed(0.5u"µs", 3.0u"µs", rtb, ftb, lattice, always, :trap)
        @test rt ≈ 0.6u"µs" && ft ≈ 3.0u"µs"
        rt, ft = snap_seed(0.1u"µs", 9.0u"µs", rtb, ftb, lattice, always, :trap)
        @test rt ≈ 0.6u"µs" && ft ≈ 3.0u"µs"
        rt, ft = snap_seed(1.04u"µs", 1.4u"µs", rtb, ftb, lattice, always, :trap)
        @test rt ≈ 0.9u"µs" && ft ≈ 1.5u"µs"
        # infeasible seed: ft is lowered by lattice steps until rt + ft/2 <= 1.5 µs
        rt, ft = snap_seed(0.9u"µs", 3.0u"µs", rtb, ftb, lattice, (rt, ft) -> rt + ft / 2 <= 1.5u"µs", :trap)
        @test rt ≈ 0.9u"µs" && ft ≈ 1.2u"µs"
        @test_throws "Filter trap: no feasible seed" snap_seed(0.9u"µs", 3.0u"µs", rtb, ftb, lattice, (rt, ft) -> false, :trap)
        @test_throws "no lattice point inside the bounds" snap_seed(0.9u"µs", 1.0u"µs", rtb, (0.4u"µs", 0.5u"µs"), lattice, always, :trap)
    end

    @testset "config validation" begin
        # the keys are checked before any data is loaded
        run_channel(opt_config) = run_filter_optimization_channel(name -> error("no data"), [:trap], nothing, opt_config, 500.0u"µs",
            nothing, 100.0u"ns", "test"; f_title = (label, flt) -> label, f_save = (fig, name) -> nothing, f_tablepath = flt -> "")
        valid = PropDict(:joint_search => true, :ctc_rel_uncertainty => 0.1)
        @test_throws "joint_search must be a Bool" run_channel(merge(valid, PropDict(:joint_search => "false")))
        @test_throws "joint_search must be a Bool" run_channel(merge(valid, PropDict(:joint_search => 0)))
        @test_throws "ctc_rel_uncertainty must be a Real" run_channel(merge(valid, PropDict(:ctc_rel_uncertainty => "0.1")))
        @test_throws "joint_search must be a Bool, got PropDicts.MissingProperty" run_channel(PropDict(:ctc_rel_uncertainty => 0.1))
        @test_throws "ctc_rel_uncertainty must be a Real, got PropDicts.MissingProperty" run_channel(PropDict(:joint_search => false))
    end

    @testset "driver entry points" begin
        @test hasmethod(optimize_channel_filter, Tuple{NamedTuple, NamedTuple, Symbol, DSPConfig, PropDict, typeof(1.0u"µs"), typeof(1.0u"ns"), String}, (:f_title, :f_save, :f_tablepath))
        @test hasmethod(run_filter_optimization_channel, Tuple{Function, Vector{Union{Int, Symbol}}, DSPConfig, PropDict, typeof(1.0u"µs"), Function, typeof(1.0u"ns"), String}, (:f_title, :f_save, :f_tablepath))
    end
end
