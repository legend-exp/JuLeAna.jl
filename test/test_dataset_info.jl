# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Dates: DateTime
using LegendDataManagement: DataPeriod, DataRun
using Test

# `legend_test_setup`, `legend_test_data` and `TEST_DIRS`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

@testset "dataset info" begin
    l200 = legend_test_data(legend_test_setup(mktempdir(), TEST_DIRS))
    p2, p16 = DataPeriod.((2, 16))
    summary = JuLeAna.dataset_summary(l200)
    # the LegendTestData runinfo has 26 runs in p02, p03, p13 and p16
    @test length(summary) == 26
    run = summary[(p2, DataRun(6))]
    @test [c.category for c in run] == [:phy, :cal]
    @test [c.nkeys for c in run] == [4, 4]
    @test run[1].livetime == 10000.0 && isnan(run[2].livetime)
    @test [c.start for c in run] == [DateTime(2022, 7, 2), DateTime(2022, 7, 1)]
    @test all(c -> c.analysis, run)
    # categories without file keys are left out
    @test [c.category for c in summary[(p16, DataRun(6))]] == [:phy, :cal, :pzc, :fft]
    @test [c.analysis for c in summary[(p16, DataRun(6))]] == [false, false, true, true]

    totals = JuLeAna.period_summary(summary, p2)
    @test [t.category for t in totals] == [:phy, :cal]
    @test [(t.nruns, t.nkeys, t.nanalysis) for t in totals] == [(8, 32, 8), (8, 32, 8)]
    @test totals[1].livetime == 80000.0 && isnan(totals[2].livetime)
    @test [t.start for t in totals] == [DateTime(2022, 1, 2), DateTime(2022, 1, 1)]
    # known livetimes are summed, unknown ones skipped
    p16_totals = JuLeAna.period_summary(summary, p16)
    @test [(t.category, t.nruns) for t in p16_totals] == [(:phy, 1), (:cal, 2), (:pzc, 2), (:fft, 3), (:ssc, 2)]
    @test only(t.livetime for t in p16_totals if t.category === :ssc) == 840.0
    @test only(t.nanalysis for t in p16_totals if t.category === :cal) == 0
    @test isempty(JuLeAna.period_summary(summary, DataPeriod(99)))
end
