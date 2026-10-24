# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Test
using JuLeAna.LegendDataManagement: DataRun
using JuLeAna.Measurements: ±, value as mvalue
using JuLeAna.PropDicts: PropDict
import JuLeAna.Makie

@testset "PMT calibration" begin
    @testset "parameter file names" begin
        @test JuLeAna.pmtcal_outkey(DataRun(24), 1) == "r024"
        @test JuLeAna.pmtcal_outkey(DataRun(24), 2) == "r024_after_voltage_change"
        @test JuLeAna.pmtcal_outkey(DataRun(24), 3) == "r024_after_voltage_change_2"
        @test JuLeAna.pmtcal_suffix("r024", DataRun(24)) == ""
        @test JuLeAna.pmtcal_suffix("r024_after_voltage_change", DataRun(24)) == "_after_voltage_change"
    end

    @testset "fit keyword arguments" begin
        kwargs = JuLeAna.pmtcal_fit_kwargs(PropDict(:hist_range => [0, 100], :bin_width => 1.0))
        @test kwargs.hist_range === (0, 100) && kwargs.bin_width == 1.0
    end

    quality = PropDict(:max_chi2_dof => 5.0, :max_μ1_err => 0.5, :μ1_range => [5, 55], :min_n_1 => 500)
    fit_result(; μ1 = 17.0 ± 0.1, chi2 = 90.0, converged = true, n_1 = 20_000.0 ± 200) = (μ1 = μ1, σ1 = 6.0 ± 0.1, τ = 3.0 ± 0.1,
                                                                                          n_exp = 3_000.0 ± 50, n_1 = n_1, r2 = 0.1 ± 0.01,
                                                                                          x_min = 4.0,
                                                                                          gof = (converged = converged, pvalue = 0.5,
                                                                                                 chi2 = chi2, dof = 90))

    @testset "fit status" begin
        @test JuLeAna.pmtcal_fit_status(fit_result(), quality) === :ok
        @test JuLeAna.pmtcal_fit_status(fit_result(; converged = false), quality) === :bad_fit
        @test JuLeAna.pmtcal_fit_status(fit_result(; chi2 = 900.0), quality) === :bad_fit
        @test JuLeAna.pmtcal_fit_status(fit_result(; μ1 = 17.0 ± 1.0), quality) === :bad_fit
        @test JuLeAna.pmtcal_fit_status(fit_result(; μ1 = 4.0 ± 0.1), quality) === :bad_fit
        @test JuLeAna.pmtcal_fit_status(fit_result(; n_1 = 100.0 ± 10), quality) === :bad_fit
    end

    @testset "parameters" begin
        ok = JuLeAna.pmtcal_result(fit_result(), :ok, :pulse_height)
        @test ok.cal.func == "1/17.0 * pulse_height * 1e" && ok.fit.status == "ok" && mvalue(ok.fit.μ1) == 17.0
        bad = JuLeAna.pmtcal_result(fit_result(; chi2 = 900.0), :bad_fit, :pulse_height)
        @test bad.cal.func == "NaN * pulse_height * 1e" && bad.fit.status == "bad_fit"
        failed = JuLeAna.pmtcal_failed_result(:pulse_height, "fit_failed")
        @test failed.cal.func == "NaN * pulse_height * 1e" && isnan(failed.fit.μ1) && failed.fit.status == "fit_failed"
        @test keys(failed.fit) == keys(ok.fit)
        @test isnothing(JuLeAna.pmtcal_read_pars(joinpath(mktempdir(), "r000.yaml")))
    end

    @testset "1 p.e. position plot" begin
        chinfo = [(detector = Symbol("PMT$i"), location = loc)
                  for (i, loc) in zip(101:106, (:pillbox, :pillbox, :floor, :floor, :wall, :wall))]
        pars(det, μ, status) = PropDict(det => PropDict(:pulse_height => PropDict(:fit => PropDict(:μ1 => μ, :status => status))))
        pars_db = merge(pars(:PMT101, 17.0 ± 0.1, "ok"), pars(:PMT102, 16.0 ± 0.2, "ok"), pars(:PMT103, 4.5 ± 0.5, "bad_fit"),
                        pars(:PMT104, NaN, "fit_failed"), pars(:PMT105, 18.0 ± 0.1, "ok"))
        before = merge(pars(:PMT101, 20.0 ± 0.1, "ok"), pars(:PMT105, 21.0 ± 0.1, "ok"))
        @test JuLeAna._pmt_status(pars_db, :PMT101, :pulse_height) == "ok"
        @test JuLeAna._pmt_status(pars_db, :PMT106, :pulse_height) == "missing"
        @test JuLeAna.pmt_spe_mu1_overview("p22-r024", chinfo, pars_db, :pulse_height) isa Makie.Figure
        @test JuLeAna.pmt_spe_mu1_overview("p22-r024", chinfo, pars_db, :pulse_height; before) isa Makie.Figure
        # PMTs without a fit report get an empty panel
        @test JuLeAna.pmt_spe_grid("p22-r024", chinfo, Dict{Symbol,Any}(), pars_db, :pulse_height) isa Makie.Figure
    end

    @testset "missing results" begin
        chinfo = [(detector = :PMT101, usability = :on), (detector = :PMT102, usability = :on)]
        calibration_config = PropDict(:default => PropDict(:energy_types => PropDict(:pulse_height => PropDict(:qc => "true"))))
        pars_db = PropDict(:PMT101 => PropDict(:pulse_height => PropDict(:fit => PropDict(:status => "ok"),
                                                                         :cal => PropDict(:func => "1/17.0 * pulse_height * 1e"))))
        filled = JuLeAna.pmtcal_fill_missing(pars_db, chinfo, calibration_config)
        @test filled.PMT101.pulse_height.cal.func == "1/17.0 * pulse_height * 1e"
        @test filled.PMT102.pulse_height.cal.func == "NaN * pulse_height * 1e" && filled.PMT102.pulse_height.fit.status == "fit_failed"
    end
end
