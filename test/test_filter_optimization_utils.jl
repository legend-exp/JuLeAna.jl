# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using Test
using LegendDataManagement, LegendDSP, LegendSpecFits, LegendHDF5IO
using TypedTables, PropDicts, StatsBase, Unitful, Random
using OffsetArrays
using Logging
import Measurements
import LegendMakie, Makie
using Measurements: value as mvalue

using JuLeAna
using JuLeAna: evaluate_optimum, fit_fep_peak, flat_top_edge, limit_peak_waveforms, optimize_channel_filter,
               run_filter_optimization_channel, snap_seed, write_fltopt_tables

@testset "filter optimization utils" begin
    @testset "write_fltopt_tables" begin
        path = joinpath(mktempdir(), "fltopt_tables.lh5")
        evaluation = Table(scan = [:noise, :ft_scan, :lattice], rt = [5.0, 5.0, 5.5] .* u"µs",
            fwhm = [Measurements.measurement(NaN, NaN), Measurements.measurement(2.5, 0.1), Measurements.measurement(2.4, 0.1)] .* u"keV",
            status = ["ok", "ok", "fit failed"], converged = [true, true, false], n_events = [0, 5000, 4900])
        residuals = (residual = [0.1, -0.2], qdrift = [0.5, 0.7])
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
            @test collect(h["residuals"].qdrift) == [0.5, 0.7]
        end
    end

    @testset "write_fltopt_tables with empty columns" begin
        path = joinpath(mktempdir(), "empty.lh5")
        write_fltopt_tables(path, (residuals = (residual = Float64[], qdrift = Float64[]),))
        lh5open(path) do h
            @test length(h["residuals"].residual) == 0
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

    @testset "fit_fep_peak" begin
        rng = MersenneTwister(1)
        σ = 1.0
        peak = 2614.51u"keV"
        window = (35.0u"keV", 30.0u"keV")
        e_cal = vcat(ustrip(u"keV", peak) .+ σ .* randn(rng, 20000), 2580.0 .+ 65.0 .* rand(rng, 4000)) .* u"keV"
        fit = fit_fep_peak(e_cal, peak, window; containment = 0.9)
        @test fit.μ ≈ peak atol = 0.05u"keV"
        @test fit.σ ≈ σ * u"keV" rtol = 0.05
        @test fit.fwhm ≈ 2.355 * σ * u"keV" rtol = 0.05
        @test fit.w90 ≈ 3.29 * σ * u"keV" rtol = 0.1
        @test fit.n_events == count(e -> peak - first(window) < e < peak + last(window), e_cal)
        @test fit.f_fit(ustrip(u"keV", peak)) > 0
        @test fit.report.h === fit.h
        @test fit.report.f_fit(ustrip(u"keV", peak)) == fit.f_fit(ustrip(u"keV", peak))
        @test_throws "Only 50 events" fit_fep_peak(e_cal[begin:begin+49], peak, window; containment = 0.9)
    end

    @testset "evaluate_optimum" begin
        # stand-in energies: the stub returns them regardless of the filter times
        LegendDSP.dsp_energy_rtft(prep::NamedTuple{(:energies,)}, config::Nothing, rt::Unitful.Time, ft::Unitful.Time, flt::Symbol) = prep.energies
        rng = MersenneTwister(5)
        n = 4000
        fep = (prep = (energies = 200000.0 .+ 80.0 .* randn(rng, n),), qdrift = 1.0 .+ rand(rng, n))
        opt_config = PropDict(:peak => 2614.51u"keV", :left_window_size => 35.0u"keV", :right_window_size => 30.0u"keV",
            :containment => 0.9, :apply_ctc => false)
        flt_config = PropDict(:min_e_fep => 80000.0, :max_e_fep => 480000.0, :rel_cut_fit_e_fep => 0.5, :nbins_e_fep => 200)
        ev = evaluate_optimum(fep, nothing, opt_config, flt_config, :trap, 4.0u"µs", 2.0u"µs")
        @test keys(ev) == (:fep_row, :fit, :residuals, :ctc_report)
        @test isnothing(ev.ctc_report)
        @test ev.fit.μ ≈ 2614.51u"keV" atol = 0.5u"keV"
        @test keys(ev.residuals) == (:residual, :qdrift, :slow_mean)
        # slow_mean is the mean residual of the 5% of events with the highest qdrift
        top = ev.residuals.qdrift .>= quantile(ev.residuals.qdrift, 0.95)
        @test ev.residuals.slow_mean == mean(ev.residuals.residual[top])
        few = (prep = (energies = fep.prep.energies[1:50],), qdrift = fep.qdrift[1:50])
        @test_throws "at least 100 required" evaluate_optimum(few, nothing, opt_config, flt_config, :trap, 4.0u"µs", 2.0u"µs")
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

    @testset "lattice search with realizable flat tops" begin
        # CUSP-like setting: odd filter length in samples, so only odd flat-top sample counts are applied as requested
        dt, flt_length = 0.128u"µs", 38.0u"µs"
        feasible(rt, ft) = ft < flt_length && realized_flattop(ft, flt_length, dt, :cusp) == ft
        @test feasible(9dt, 0.0u"µs" + 9dt) && !feasible(12dt, 12dt)
        rtb, ftb = (1.0u"µs", 16.0u"µs"), (1.0u"µs", 4.0u"µs")
        # a seed at a flat top that is applied one sample longer moves to the sample below
        rt, ft = snap_seed(5.0u"µs", 12dt, rtb, ftb, dt, feasible, :cusp)
        @test ft == 11dt && feasible(rt, ft)
        rt, ft = snap_seed(5.0u"µs", 13dt, rtb, ftb, dt, feasible, :cusp)
        @test ft == 13dt

        # the width of the stand-in line is smallest at rt = 5.0 µs, ft = 21 samples
        z = randn(MersenneTwister(11), 3000)
        f_energy(rt, ft) = 200000.0 .+ 80.0 .* (1 + 0.05 * ((rt - 5.0u"µs") / 1.0u"µs")^2 + 0.05 * ((ft - 21dt) / 1.0u"µs")^2) .* z
        evaluated = Tuple{typeof(1.0u"µs"), typeof(1.0u"µs")}[]
        lk = ReentrantLock()
        f_recorded = function (rt, ft)
            lock(() -> push!(evaluated, (uconvert(u"µs", rt), uconvert(u"µs", ft))), lk)
            f_energy(rt, ft)
        end
        # the flat-top step is a power of two samples: odd steps would make every flat-top move infeasible
        result, report = optimize_rtft(f_recorded, ones(length(z)), 4.0u"µs", 13dt; rt_bounds = rtb, ft_bounds = ftb, feasible,
            step0 = (0.5u"µs", 4dt), lattice = dt, max_evals = 80, peak = 2614.51u"keV", window = (35.0u"keV", 30.0u"keV"),
            min_e = 80000.0, max_e = 480000.0, rel_cut_fit = 0.5, n_bins = 200, apply_ctc = false)
        @test result.converged
        @test feasible(result.rt, result.ft)
        @test all(((rt, ft),) -> feasible(rt, ft), evaluated)
        @test allunique(evaluated)
        @test abs(result.ft - 21dt) <= 2dt
        @test abs(result.rt - 5.0u"µs") <= 0.5u"µs"
        @test result.n_evals < 80
    end

    @testset "flat_top_edge" begin
        lattice = 0.128u"µs"
        range = (10lattice, 40lattice)
        @test flat_top_edge(40lattice, range, lattice) == :upper
        @test flat_top_edge(10lattice, range, lattice) == :lower
        @test flat_top_edge(25lattice, range, lattice) === nothing
        # one sample inside the grid is not on the edge
        @test flat_top_edge(39lattice, range, lattice) === nothing
        # equality at lattice precision, in other units and with rounding noise
        @test flat_top_edge(uconvert(u"ns", 40lattice) * (1 + 1e-12), range, lattice) == :upper
        @test flat_top_edge(5.0u"µs", (1.0u"µs", 5.0u"µs"), 0.1u"µs") == :upper
    end

    @testset "failing steps are named" begin
        run_channel(f_load) = run_filter_optimization_channel(f_load, [:trap], nothing, PropDict(:joint_search => true, :ctc_rel_uncertainty => 0.1,
            :peakname => "Tl208FEP"), 500.0u"µs",
            nothing; detector = "V00000A", f_title = (label, flt) -> label, f_save = (fig, name) -> nothing, f_tablepath = flt -> "")
        err = try
            with_logger(NullLogger()) do
                run_channel(name -> error("no data"))
            end
        catch e
            e
        end
        @test err isa JuLeAna.ProcessStepError
        @test err.name == "Tl208FEP data loader"
        @test occursin("no data", sprint(showerror, err))
    end

    @testset "config validation" begin
        # the keys are checked before any data is loaded
        run_channel(opt_config) = run_filter_optimization_channel(name -> error("no data"), [:trap], nothing, opt_config, 500.0u"µs",
            nothing; detector = "V00000A", f_title = (label, flt) -> label, f_save = (fig, name) -> nothing, f_tablepath = flt -> "")
        valid = PropDict(:joint_search => true, :ctc_rel_uncertainty => 0.1)
        @test_throws "joint_search must be a Bool" run_channel(merge(valid, PropDict(:joint_search => "false")))
        @test_throws "joint_search must be a Bool" run_channel(merge(valid, PropDict(:joint_search => 0)))
        @test_throws "ctc_rel_uncertainty must be a Real" run_channel(merge(valid, PropDict(:ctc_rel_uncertainty => "0.1")))
        @test_throws "joint_search must be a Bool, got PropDicts.MissingProperty" run_channel(PropDict(:ctc_rel_uncertainty => 0.1))
        @test_throws "ctc_rel_uncertainty must be a Real, got PropDicts.MissingProperty" run_channel(PropDict(:joint_search => false))
    end

    @testset "driver entry points" begin
        @test hasmethod(optimize_channel_filter, Tuple{NamedTuple, Symbol, DSPConfig, PropDict, typeof(1.0u"µs")}, (:detector, :f_title, :f_save, :f_tablepath))
        @test hasmethod(run_filter_optimization_channel, Tuple{Function, Vector{Union{Int, Symbol}}, DSPConfig, PropDict, typeof(1.0u"µs"), Function}, (:detector, :f_title, :f_save, :f_tablepath))
    end
end
