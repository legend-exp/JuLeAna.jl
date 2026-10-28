# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Test
using LegendDataManagement, LegendDSP, LegendSpecFits, LegendHDF5IO
using TypedTables, PropDicts, StatsBase, Unitful, Random
using OffsetArrays
using Logging
import Measurements
import LegendMakie, Makie
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
        # without a FEP fit the other peaks and the slow-pulse residual have no scale and are not compared
        failed_fep = (shifts = NamedTuple(), slow_mean_residual = NaN,
                      rows = ((peak = "FEP", status = "failed: BoundsError"), (peak = "DEP", status = "ok"), (peak = "SEP", status = "ok")))
        @test crosscheck_warning(failed_fep, base; max_shift_sigma = 0.5) == "FEP fit failed (legacy)"
        @test crosscheck_warning(base, failed_fep; max_shift_sigma = 0.5) == "FEP fit failed (new)"
        @test crosscheck_warning(failed_fep, failed_fep; max_shift_sigma = 0.5) == "FEP fit failed (legacy, new)"
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

    @testset "write_fltopt_tables with empty columns" begin
        path = joinpath(mktempdir(), "empty.lh5")
        write_fltopt_tables(path, (residuals = (residual = Float64[], rise_time = typeof(1.0u"µs")[]),))
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
        @test fit.report.h === fit.h
        @test fit.report.f_fit(ustrip(u"keV", line)) == fit.f_fit(ustrip(u"keV", line))
        @test_throws ArgumentError fit_crosscheck_peak(e_cal[begin:begin+49], line, DEP_WINDOW; containment = 0.9)
    end

    @testset "try_fit_crosscheck_peak" begin
        rng = MersenneTwister(1)
        line = 1592.51u"keV"
        e_cal = (ustrip(u"keV", line) .+ randn(rng, 5000)) .* u"keV"
        fit, status = try_fit_crosscheck_peak(e_cal, line, DEP_WINDOW; containment = 0.9)
        @test status == "ok"
        @test fit.μ ≈ line atol = 0.1u"keV"
        # an ArgumentError is recorded and logged with the exception and the context
        fit, status = @test_logs (:warn, r"Crosscheck fit of the peak at 1592.51 keV failed \(DEP\)") try_fit_crosscheck_peak(
            e_cal[begin:begin+49], line, DEP_WINDOW; containment = 0.9, context = " (DEP)")
        @test isnothing(fit) && startswith(status, "failed: ArgumentError")
        # so is every other exception: two narrow lines make the fit throw a BoundsError
        spikes = (ustrip(u"keV", line) .+ vcat(zeros(100), ones(100)) .+ 1e-3 .* randn(MersenneTwister(3), 200)) .* u"keV"
        fit, status = @test_logs (:warn, r"Crosscheck fit of the peak at 1592.51 keV failed") try_fit_crosscheck_peak(spikes, line, DEP_WINDOW; containment = 0.9)
        @test isnothing(fit) && startswith(status, "failed: BoundsError")
        # a MethodError of the call itself is recorded too
        fit, status = @test_logs (:warn, r"failed") try_fit_crosscheck_peak(ustrip.(u"keV", e_cal), line, DEP_WINDOW; containment = 0.9)
        @test isnothing(fit) && startswith(status, "failed: MethodError")
    end

    @testset "crosscheck_peak_figure" begin
        rng = MersenneTwister(1)
        line = 1592.51u"keV"
        e_cal = (ustrip(u"keV", line) .+ randn(rng, 5000)) .* u"keV"
        check = (name = :DEP, e_cal = e_cal, line = line, window = DEP_WINDOW)
        fit, status = try_fit_crosscheck_peak(e_cal, line, DEP_WINDOW; containment = 0.9)
        @test crosscheck_peak_figure(check, fit, status; title = "fit") isa Makie.Figure
        # failed fits show the window histogram and the error text, also without any event in the window
        for e in (e_cal[begin:begin+49], typeof(line)[])
            failed = merge(check, (e_cal = e,))
            fit, status = with_logger(NullLogger()) do
                try_fit_crosscheck_peak(e, line, DEP_WINDOW; containment = 0.9)
            end
            fig = crosscheck_peak_figure(failed, fit, status; title = "failed")
            @test fig isa Makie.Figure
            ax = only(filter(x -> x isa Makie.Axis, fig.content))
            @test any(p -> p isa Makie.Text && occursin("failed: ArgumentError: Only", only(p.text[])), ax.scene.plots)
        end
    end

    @testset "crosscheck_optimum records failed fits" begin
        # stand-in energies: the stub returns them regardless of the filter times
        LegendDSP.dsp_energy_rtft(prep::NamedTuple{(:energies,)}, config::Nothing, rt::Unitful.Time, ft::Unitful.Time, flt::Symbol) = prep.energies
        rng = MersenneTwister(5)
        keV_per_adc = 2614.51 / 200000
        adc(e_keV) = e_keV / keV_per_adc
        n = 4000
        qdrift = 1.0 .+ rand(rng, n)
        sets = (fep = (prep = (energies = 200000.0 .+ 80.0 .* randn(rng, n),), qdrift = qdrift),
                dep = (prep = (energies = adc(1592.51) .+ 80.0 .* randn(rng, 600),), qdrift = qdrift[1:600]),
                sep = (prep = (energies = adc(2103.51) .+ adc(3.0) .* vcat(zeros(150), ones(150)) .+ 1e-3 .* randn(rng, 300),), qdrift = qdrift[1:300]))
        pulse = (t10 = fill(1.0u"µs", n), t90 = 1.0u"µs" .+ rand(rng, n) .* u"µs")
        opt_config = PropDict(:peak => 2614.51u"keV", :left_window_size => 35.0u"keV", :right_window_size => 30.0u"keV",
            :containment => 0.9, :apply_ctc => false)
        flt_config = PropDict(:min_e_fep => 80000.0, :max_e_fep => 480000.0, :rel_cut_fit_e_fep => 0.5, :nbins_e_fep => 200)
        cc = @test_logs (:warn, r"Crosscheck fit of the peak at 2103.51\d* keV failed \(SEP of trap at rt = 4.0 .s, ft = 2.0 .s\)") match_mode = :any crosscheck_optimum(
            sets, pulse, ones(n), nothing, opt_config, flt_config, :trap, 4.0u"µs", 2.0u"µs")
        @test map(r -> r.peak, cc.rows) == ["FEP", "DEP", "SEP"]
        @test map(r -> r.status == "ok", cc.rows) == [true, true, false]
        @test startswith(cc.rows[3].status, "failed: ")
        @test isnan(cc.rows[3].μ) && cc.rows[3].n_events == 0
        @test keys(cc.fits) == (:FEP, :DEP)
        @test keys(cc.shifts) == (:DEP,)
        @test map(c -> c.name, cc.checks) == [:FEP, :DEP, :SEP]
        @test isfinite(cc.slow_mean_residual)
        @test occursin("SEP fit failed (legacy, new)", crosscheck_warning(cc, cc; max_shift_sigma = 0.5))
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
