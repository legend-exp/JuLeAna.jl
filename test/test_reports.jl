# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Test
using Dates: DateTime

const OK_REPORT = """
# Main Log
Time of processing: 2026-09-29T16:13:00.147
Total Processing time: 12 seconds

| Detector | Status | Filter Type | Error |
|:---|:---|:---|:---|
| V01 | <span style="color:green">Success</span> | trap | - |
| V02 | <span style="color:green">Success</span> | cusp | - |
"""

const WARNING_REPORT = """
# Main Log
Date of processing: 2026-10-02T08:30:15Z

| Processor Status |
|:---|
| <span style="color:yellow">Warning</span> |

| Detector | Status | Filter Type | Error |
|:---|:---|:---|:---|
| V01 | <span style="color:green">Success</span> | trap | - |
| V02 | <span style="color:yellow">Warning</span> | trap | - |
"""

const FAILED_DSP_REPORT = """
# Main Log
Time of processing: 2026-10-01T10:00:00

| Filekey | Status | Failed Detectors |
|:---|:---|:---|
| l200-p03-r001-cal-20230101T000000Z | <span style="color:red">Failure</span> | ["V03", "V04"] |
| l200-p03-r001-cal-20230101T010000Z | <span style="color:green">Success</span> | - |
"""

const FAILED_FIT_REPORT = """
# Main Log
Date of processing: 2026-10-03T12:00:00Z

| Processor Status |
|:---|
| <span style="color:red">Failure</span> |

| Detector | Status | Filter Type | Error |
|:---|:---|:---|:---|
| V02 | <span style="color:red">Failure</span> | trap | fit failed |
| V03 | <span style="color:red">Failure</span> | cusp | fit failed |
| V05 | <span style="color:green">Success</span> | trap | - |
"""

const PARTITION_FAILED_REPORT = """
Date of processing: 2026-10-04T00:00:00Z

| Detector | Status | Partition | Error |
|:---|:---|:---|:---|
| V02 | <span style="color:red">Failure</span> | 1 | no peaks |
"""

# every file and folder below `dir`
function tree(dir)
    return sort!([relpath(joinpath(root, name), dir) for (root, dirs, files) in walkdir(dir) for name in [dirs; files]])
end

function write_report(jlrep, process, level, period, run, category, text)
    path = JuLeAna.report_path(jlrep, process, level, period, run, category)
    mkpath(dirname(path))
    write(path, text)
    return path
end

@testset "reports" begin
    jlrep = mktempdir()
    ok = write_report(jlrep, :process_energy_calibration_cal, :run, "p03", "r001", :cal, OK_REPORT)
    warn = write_report(jlrep, :process_energy_calibration_cal, :run, "p03", "r002", :cal, WARNING_REPORT)
    failed = write_report(jlrep, :process_energy_calibration_cal, :run, "p03", "r004", :cal, FAILED_FIT_REPORT)
    dsp = write_report(jlrep, :process_dsp_cal, :run, "p03", "r001", :cal, FAILED_DSP_REPORT)
    part = write_report(jlrep, :p_process_aoe_cut_cal, :partition, "p03", nothing, :cal, PARTITION_FAILED_REPORT)
    # not a report of the naming scheme
    stray = joinpath(dirname(ok), "notes.md")
    write(stray, "# notes\n")
    stray_other = joinpath(dirname(ok), "l200-p03-r001-cal-extra.md")
    write(stray_other, "| Detector | Status |\n|:---|:---|\n| V01 | Failure |\n")
    mkpath(joinpath(jlrep, "rreport", "cal", "p03", "r003"))
    before = tree(jlrep)

    @testset "report_path" begin
        @test JuLeAna.report_path("/j", :process_energy_calibration_cal, :run, "p03", "r001", :cal) ==
              "/j/rreport/cal/p03/r001/l200-p03-r001-cal-energy_calibration.md"
        @test JuLeAna.report_path("/j", :p_process_aoe_cut_cal, :partition, "p03", nothing, :phy; setup = "l201") ==
              "/j/preport/p03/phy/l201-p03-phy-aoe_cut.md"
        @test_throws "report level must be :run or :partition" JuLeAna.report_path("/j", :process_x, :event, "p03", "r001", :cal)
        @test !ispath("/j")
    end

    @testset "read_report" begin
        r = JuLeAna.read_report(ok)
        @test r.path == ok
        @test r.state == :ok
        @test r.date == DateTime(2026, 9, 29, 16, 13, 0, 147)
        @test (r.n_entries, r.n_failed, r.n_warnings) == (2, 0, 0)
        @test isempty(r.failures)

        r = JuLeAna.read_report(warn)
        @test r.state == :warning
        @test r.date == DateTime(2026, 10, 2, 8, 30, 15)
        @test (r.n_entries, r.n_failed, r.n_warnings) == (2, 0, 1)

        r = JuLeAna.read_report(failed)
        @test r.state == :failed
        @test (r.n_entries, r.n_failed) == (3, 2)
        @test r.failures == [("V02 (trap)", "fit failed"), ("V03 (cusp)", "fit failed")]

        r = JuLeAna.read_report(dsp)
        @test r.state == :failed
        @test (r.n_entries, r.n_failed) == (2, 1)
        @test r.failures == [("V03", ""), ("V04", "")]

        r = JuLeAna.read_report(part)
        @test r.failures == [("V02 (1)", "no peaks")]

        r = JuLeAna.read_report(joinpath(jlrep, "absent.md"))
        @test r.state == :missing
        @test isnothing(r.date)
        @test (r.n_entries, r.n_failed, r.n_warnings) == (0, 0, 0)

        # state from the entries when a file has no header or no tables
        r = JuLeAna.read_report(stray)
        @test r.state == :ok
        @test isnothing(r.date)
        r = JuLeAna.read_report(stray_other)
        @test r.state == :failed

        bad = joinpath(mktempdir(), "bad.md")
        write(bad, "| Processor Status |\n|:---|\n| Unknown |\n")
        @test_throws "unknown processor status \"Unknown\"" JuLeAna.read_report(bad)
    end

    specs = [(; name = :process_energy_calibration_cal, level = :run, category = :cal),
             (; name = :process_dsp_cal, level = :run, category = :cal),
             (; name = :p_process_aoe_cut_cal, level = :partition, category = :cal)]
    period_runs = ["p03" => ["r001", "r002", "r003", "r004"], "p04" => ["r001"]]

    @testset "report_index" begin
        rows = JuLeAna.report_index(jlrep, specs, period_runs)
        @test length(rows) == 4 * 2 + 2 + 2
        energy = filter(r -> r.process == :process_energy_calibration_cal, rows)
        @test [(r.period, r.run, r.state) for r in energy] ==
              [("p03", "r001", :ok), ("p03", "r002", :warning), ("p03", "r003", :missing), ("p03", "r004", :failed),
               ("p04", "r001", :missing)]
        @test energy[1].path == ok
        @test energy[2].date == DateTime(2026, 10, 2, 8, 30, 15)
        @test energy[4].n_failed == 2
        partition = filter(r -> r.level == :partition, rows)
        @test [(r.period, r.run, r.state) for r in partition] == [("p03", nothing, :failed), ("p04", nothing, :missing)]
        @test partition[1].path == part
    end

    @testset "failure_summary" begin
        rows = JuLeAna.report_index(jlrep, specs, period_runs)
        summary = JuLeAna.failure_summary(rows)
        @test [s.process for s in summary] == [:process_energy_calibration_cal, :process_dsp_cal, :p_process_aoe_cut_cal]
        energy = summary[1].detectors
        @test energy == [(; detector = "V02", labels = ["p03-r004"], errors = ["fit failed"]),
                         (; detector = "V03", labels = ["p03-r004"], errors = ["fit failed"])]
        @test summary[2].detectors == [(; detector = "V03", labels = ["p03-r001"], errors = String[]),
                                       (; detector = "V04", labels = ["p03-r001"], errors = String[])]
        @test summary[3].detectors == [(; detector = "V02", labels = ["p03"], errors = ["no peaks"])]
        @test only(JuLeAna.failure_summary(JuLeAna.report_index(jlrep, specs[1:1], ["p03" => ["r001"]]))).detectors == []
        @test isempty(JuLeAna.failure_summary([]))
    end

    @testset "report_overview" begin
        overview = JuLeAna.report_overview(jlrep)
        @test [(o.level, o.name, o.category) for o in overview] ==
              [(:run, "dsp_cal", "cal"), (:run, "energy_calibration", "cal"), (:run, "extra", "cal"), (:partition, "aoe_cut", "cal")]
        energy = overview[2]
        @test energy.nreports == 3
        @test energy.counts == (; ok = 1, warning = 1, failed = 1)
        @test energy.last_date == DateTime(2026, 10, 3, 12)
        @test energy.latest_path == failed
        @test [(r.period, r.run, r.state) for r in energy.reports] ==
              [("p03", "r001", :ok), ("p03", "r002", :warning), ("p03", "r004", :failed)]
        @test overview[1].counts == (; ok = 0, warning = 0, failed = 1)
        @test overview[3].counts == (; ok = 0, warning = 0, failed = 1)
        @test isnothing(overview[3].last_date) && isnothing(overview[3].latest_path)
        @test overview[4].reports == [(; period = "p03", run = nothing, path = part, state = :failed, date = DateTime(2026, 10, 4))]
        @test JuLeAna.report_overview(mktempdir()) == []
        # ranked processors first, the others by name; the level comes first
        ranked = [(; name = :process_dsp_cal, level = :run, rank = 5), (; name = :process_energy_calibration_cal, level = :run, rank = 2),
                  (; name = :p_process_aoe_cut_cal, level = :partition, rank = 1)]
        by_rank = JuLeAna.report_overview(jlrep; processors = ranked)
        @test [(o.level, o.name) for o in by_rank] ==
              [(:run, "energy_calibration"), (:run, "dsp_cal"), (:run, "extra"), (:partition, "aoe_cut")]
        # a processor of the other level with the same name does not rank the report
        other = [(; name = :p_process_dsp_cal, level = :partition, rank = 1)]
        @test [o.name for o in JuLeAna.report_overview(jlrep; processors = other)] == ["dsp_cal", "energy_calibration", "extra", "aoe_cut"]
    end

    @testset "no file system changes" begin
        @test tree(jlrep) == before
        empty = mktempdir()
        JuLeAna.report_index(empty, specs, ["p09" => ["r001", "r002"]])
        JuLeAna.report_overview(empty)
        JuLeAna.report_path(empty, :process_dsp_cal, :run, "p09", "r001", :cal)
        @test isempty(tree(empty))
    end

    @testset "report_name matches the report each processor writes" begin
        dir = joinpath(dirname(pathof(JuLeAna)), "processors")
        for name in keys(JuLeAna.PROCESSORS)
            source = read(joinpath(dir, "$name.jl"), String)
            # the peak splitting processors write the report named by `report_name` in `split_peaks`
            occursin("split_peaks(", source) && (@test occursin(":$name", source); continue)
            written = [m.captures[1] for m in eachmatch(r"get_[rp]reportfilename\([^,]+,[^,]+,\s*:(\w+)\)", source)]
            @test length(written) == 1
            @test JuLeAna.report_name(name) == only(written)
        end
        @test JuLeAna.report_name(:process_dsp_cal) == "dsp_cal"
        @test JuLeAna.report_name(:p_process_energy_cal) == "energy"
        @test JuLeAna.report_name(:process_peak_split_cal) == "peak_split"
        @test JuLeAna.report_name(:process_peak_split_phy) == "peak_split_phy"
        @test occursin("Symbol(report_name(process_name))", read(joinpath(dir, "peak_split.jl"), String))
    end
end
