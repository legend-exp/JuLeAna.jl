# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Dates: DateTime
using LegendDataManagement: DataPeriod, DataRun
using Test

@testset "processing history" begin
    p2 = DataPeriod(2)
    step(process, level, run, outcome, started, finished, counts) = (; process, level, category = :cal, period = p2, run, outcome, started,
                                                                     finished, done = counts[1], failed = counts[2], notrun = counts[3])
    first_run = (; started = DateTime(2026, 10, 15, 12, 0, 2), finished = DateTime(2026, 10, 15, 13, 1, 5), user = "someone",
                 host = "node1", outcome = :stopped, log_path = "/data/jllog/20261015T115958Z",
                 software = "JuLeAna 0.2.0 (abc1234, modified), Julia 1.12.7", metadata = "setup/metadata/2026-10-15T120000Z-def5678",
                 steps = [step(:process_dsp_cal, :run, DataRun(6), :done, DateTime(2026, 10, 15, 12, 0, 2),
                               DateTime(2026, 10, 15, 12, 3, 11), (12, 0, 0)),
                          step(:p_process_energy_cal, :partition, nothing, :stopped, nothing, nothing, (0, 0, 0))])
    second_run = (; started = DateTime(2026, 10, 16, 8, 0, 0), finished = DateTime(2026, 10, 16, 8, 30, 0), user = "someone",
                  host = "node1", outcome = :failed, log_path = "/data/jllog/20261016T080000Z", software = nothing, metadata = nothing,
                  steps = [step(:process_dsp_cal, :run, DataRun(7), :failed, DateTime(2026, 10, 16, 8, 0, 0),
                                DateTime(2026, 10, 16, 8, 30, 0), (3, 1, 2))])

    path = joinpath(mktempdir(), "jllog", "history.md")
    @test JuLeAna.read_history(path) == []
    JuLeAna.append_history(path, first_run)
    JuLeAna.append_history(path, second_run)
    text = read(path, String)
    @test startswith(text, "# Processing history\n\n## 2026-10-15 12:00:02 UTC, someone@node1: stopped\n")
    @test count("# Processing history", text) == 1
    @test occursin("Log folder: /data/jllog/20261015T115958Z  \nSoftware: JuLeAna 0.2.0 (abc1234, modified), Julia 1.12.7  \n" *
                   "Metadata: setup/metadata/2026-10-15T120000Z-def5678\n", text)
    @test occursin("Log folder: /data/jllog/20261016T080000Z\n\n", text)
    @test occursin("| process_dsp_cal | run | cal | p02 | r006 | done | 2026-10-15 12:00:02 | 2026-10-15 12:03:11 | 12/0/0 |", text)
    @test occursin("| p_process_energy_cal | partition | cal | p02 | – | stopped | – | – | 0/0/0 |", text)
    # the file reads back as written
    @test JuLeAna.read_history(path) == [first_run, second_run]

    # a line that does not follow the format names the file and the line
    bad = joinpath(mktempdir(), "history.md")
    write(bad, replace(text, "| 12/0/0 |" => "| 12/0 |"))
    @test_throws "line 12 of $bad does not follow the history format" JuLeAna.read_history(bad)
    write(bad, "some text\n")
    @test_throws "line 1 of $bad" JuLeAna.read_history(bad)
end

@testset "history grid" begin
    p2, p3 = DataPeriod(2), DataPeriod(3)
    r6, r7, r0 = DataRun(6), DataRun(7), DataRun(0)
    t(h) = DateTime(2026, 10, 15, h)
    processors = [(; name = :process_dsp_cal, level = :run, category = :cal),
                  (; name = :p_process_energy_cal, level = :partition, category = :cal)]
    period_runs = [p2 => [r6, r7], p3 => [r0]]
    report(period, run, state, date) = (; period, run, path = "/rep/$period-$(something(run, "")).md", state, date)
    overview = [(; name = "dsp_cal", level = :run, category = "cal",
                 reports = [report("p02", "r006", :ok, t(10)), report("p02", "r007", :warning, t(10)), report("p03", "r000", :ok, nothing),
                            report("p09", "r000", :ok, t(10))]),
                (; name = "energy", level = :partition, category = "cal", reports = [report("p02", nothing, :ok, t(10))])]
    step(process, level, period, run, outcome, started, finished) = (; process, level, category = :cal, period, run, outcome, started,
                                                                     finished, done = 0, failed = 0, notrun = 0)
    history = [(; started = t(11), finished = t(13), user = "u", host = "h", outcome = :failed, log_path = "/log/a", software = nothing,
                steps = [step(:process_dsp_cal, :run, p2, r6, :failed, t(11), t(12)),
                         step(:process_dsp_cal, :run, p2, r7, :failed, t(9), t(9)),
                         step(:process_dsp_cal, :run, p3, r0, :stopped, t(11), t(12)),
                         step(:p_process_energy_cal, :partition, p2, nothing, :cancelled, nothing, nothing),
                         step(:p_process_energy_cal, :partition, p3, nothing, :stopped, nothing, nothing)]),
               (; started = t(14), finished = t(15), user = "u", host = "h", outcome = :finished, log_path = "/log/b", software = nothing,
                steps = [step(:process_dsp_cal, :run, p3, r0, :done, t(14), t(15))])]

    grid = JuLeAna.history_grid(processors, period_runs, overview, history)
    @test grid.periods == [(; period = p2, runs = [r6, r7]), (; period = p3, runs = [r0])]
    @test [(r.process, r.level, r.category) for r in grid.rows] ==
          [(:process_dsp_cal, :run, :cal), (:p_process_energy_cal, :partition, :cal)]
    dsp, energy = grid.rows
    # a failed step after the report replaces it
    @test dsp.cells[(p2, r6)] == (; state = :failed, date = t(12), source = :history, path = "/log/a")
    # a step before the report does not
    @test dsp.cells[(p2, r7)] == (; state = :warning, date = t(10), source = :report, path = "/rep/p02-r007.md")
    # an undated report is replaced; a later done step does not change the cell
    @test dsp.cells[(p3, r0)] == (; state = :stopped, date = t(12), source = :history, path = "/log/a")
    # reports of periods not in the grid are ignored
    @test length(dsp.cells) == 3
    # a step that never started keeps the report and fills a cell without one
    @test energy.cells[(p2, nothing)].source == :report
    @test energy.cells[(p3, nothing)] == (; state = :stopped, date = t(13), source = :history, path = "/log/a")
    @test JuLeAna.history_grid(processors, period_runs, [], []).rows[1].cells == Dict()

    # the state on disk of a processor over a selection of runs
    @test JuLeAna.disk_counts(dsp, period_runs) == (; ok = 0, warning = 1, failed = 1, missing = 1, total = 3)
    @test JuLeAna.disk_counts(dsp, [p2 => [r7]]) == (; ok = 0, warning = 1, failed = 0, missing = 0, total = 1)
    @test JuLeAna.disk_counts(energy, Dict(p2 => [r6, r7], p3 => [r0])) == (; ok = 1, warning = 0, failed = 0, missing = 1, total = 2)
    @test JuLeAna.disk_state(JuLeAna.disk_counts(dsp, period_runs)) === :failed
    @test JuLeAna.disk_state(JuLeAna.disk_counts(dsp, [p2 => [r7], p3 => [r0]])) === :missing
    @test JuLeAna.disk_state(JuLeAna.disk_counts(dsp, [p2 => [r7]])) === :warning
    @test JuLeAna.disk_state(JuLeAna.disk_counts(energy, [p2 => [r6]])) === :ok
    @test isnothing(JuLeAna.disk_state(JuLeAna.disk_counts(dsp, [p2 => DataRun[]])))
end
