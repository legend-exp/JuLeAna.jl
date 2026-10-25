# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Dates: Day, Minute, Second, UTC, now
using Test

# Wait until `cond()` holds, at most `timeout` seconds.
function wait_until(cond; timeout = 30)
    t0 = time()
    while !cond()
        time() - t0 > timeout && return false
        sleep(0.05)
    end
    return true
end

process_alive(pid) = success(ignorestatus(`kill -0 $pid`))

state_of(mgr, id) = only(filter(a -> a.id == id, JuLeAna.allocations(mgr))).state

@testset "worker allocations" begin
    production = mktempdir()
    script_file = joinpath(production, "setup", "config", "startjlworkers.sh")

    withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
        @testset "local start script and allocations" begin
            mgr = JuLeAna.WorkerManager()
            @test_throws "no processing config is set" JuLeAna.start_script!(mgr)
            JuLeAna.set_worker_config!(mgr, ProcessingConfig(; processors = Dict(), p_processors = Dict(), local_n = 2))
            script = JuLeAna.start_script!(mgr)
            @test script.path == script_file
            @test read(script_file, String) == script.text
            @test occursin("xargs -n1 -P2", script.text) && occursin("elastic_worker", script.text)
            @test JuLeAna.start_script!(mgr) == script
            # a new config generates the script anew and keeps the previous file
            write(script_file, "edited")
            JuLeAna.set_worker_config!(mgr, ProcessingConfig(; processors = Dict(), p_processors = Dict(), local_n = 3))
            @test occursin("xargs -n1 -P3", JuLeAna.start_script!(mgr).text)
            @test read(script_file * ".bak", String) == "edited"

            # output and exit of the script
            JuLeAna.edit_start_script!(mgr, "echo out; echo err 1>&2")
            @test read(script_file, String) == "echo out; echo err 1>&2"
            ok = JuLeAna.add_workers!(mgr)
            @test ok.id == 1 && ok.backend === :local && isnothing(ok.job_name)
            @test wait_until(() -> state_of(mgr, 1) !== :running)
            a = only(JuLeAna.allocations(mgr))
            @test a.state === :ended && a.exit_code == 0 && !isnothing(a.finished)
            @test sort(a.output) == ["err", "out"]
            @test !haskey(only(JuLeAna.allocations(mgr; output = false)), :output)
            JuLeAna.edit_start_script!(mgr, "exit 3")
            JuLeAna.add_workers!(mgr)
            @test wait_until(() -> state_of(mgr, 2) !== :running)
            @test state_of(mgr, 2) === :failed && JuLeAna.allocations(mgr)[2].exit_code == 3

            # cancelling ends the whole process group of the script
            pidfile = joinpath(production, "child.pid")
            JuLeAna.edit_start_script!(mgr, "sleep 60 & echo \$! > $pidfile; echo started; wait")
            JuLeAna.add_workers!(mgr)
            @test wait_until(() -> isfile(pidfile) && !isempty(read(pidfile, String)))
            child = parse(Int, strip(read(pidfile, String)))
            @test process_alive(child)
            JuLeAna.cancel_allocation!(mgr, 3)
            @test state_of(mgr, 3) === :cancelled
            @test wait_until(() -> !process_alive(child))
            @test wait_until(() -> !isnothing(JuLeAna.allocations(mgr)[3].finished))
            @test state_of(mgr, 3) === :cancelled
            # cancelling an allocation that ended changes nothing
            JuLeAna.cancel_allocation!(mgr, 1)
            @test state_of(mgr, 1) === :ended
            @test_throws "there is no worker allocation 9" JuLeAna.cancel_allocation!(mgr, 9)

            rm(pidfile)
            JuLeAna.edit_start_script!(mgr, "sleep 60 & echo \$! > $pidfile; wait")
            JuLeAna.add_workers!(mgr)
            @test wait_until(() -> isfile(pidfile) && !isempty(read(pidfile, String)))
            child = parse(Int, strip(read(pidfile, String)))
            JuLeAna.cancel_all!(mgr)
            @test state_of(mgr, 4) === :cancelled
            @test wait_until(() -> !process_alive(child))
        end

        @testset "SLURM allocations" begin
            dir = mktempdir()
            # squeue lists jobs of this allocation, of another allocation of this process,
            # of another process and of another user's job name
            squeue = joinpath(dir, "squeue.sh")
            write(squeue, """
                echo "\$@" >> $dir/squeue.args
                echo "101 julia-$(getpid())-1"
                echo "102 julia-99999-1"
                echo "103 julia-$(getpid())-10"
                echo "104 interactive"
                """)
            scancel = joinpath(dir, "scancel.sh")
            write(scancel, "echo \"\$@\" >> $dir/scancel.args\n")
            sinfo = joinpath(dir, "sinfo.sh")
            write(sinfo, "echo \"sinfo \$@\"\n")
            mgr = JuLeAna.WorkerManager(; squeue = `bash $squeue`, scancel = `bash $scancel`, sinfo = `bash $sinfo`)
            JuLeAna.set_worker_config!(mgr,
                                       ProcessingConfig(; processors = Dict(), p_processors = Dict(), runmode = :slurm,
                                                        slurm_flags = ["--ntasks=2"]))
            text = JuLeAna.start_script!(mgr).text
            @test occursin(r"srun --job-name=julia-\d+-\d+", text)
            @test_throws "must contain `--job-name=julia-<n>-<m>`" JuLeAna.edit_start_script!(mgr, "srun sleep 60")
            @test JuLeAna.start_script!(mgr).text == text

            JuLeAna.edit_start_script!(mgr, "echo --job-name=julia-1-1; sleep 60")
            alloc = JuLeAna.add_workers!(mgr)
            @test alloc.job_name == "julia-$(getpid())-1"
            @test wait_until(() -> !isempty(JuLeAna.allocations(mgr)[1].output))
            @test only(JuLeAna.allocations(mgr)[1].output) == "--job-name=julia-$(getpid())-1"
            JuLeAna.update_job_ids!(mgr)
            @test JuLeAna.allocations(mgr)[1].job_ids == ["101"]
            @test occursin("-u $(get(ENV, "USER", ""))", read(joinpath(dir, "squeue.args"), String))
            JuLeAna.cancel_allocation!(mgr, 1)
            # only the job of the allocation is cancelled
            @test read(joinpath(dir, "scancel.args"), String) == "101\n"
            @test state_of(mgr, 1) === :cancelled
            @test wait_until(() -> !isnothing(JuLeAna.allocations(mgr)[1].finished))
            # the overview runs squeue and sinfo
            overview = JuLeAna.workers_overview(JuLeAna.WorkerManager(; squeue = `bash $squeue`, scancel = `bash $scancel`,
                                                                      sinfo = `bash $sinfo`))
            @test occursin("julia-99999-1", overview.slurm.queue) && overview.slurm.idle == "sinfo -t idle\n"
            @test overview.script == "ArgumentError: start_script!: no processing config is set"
            @test isempty(overview.allocations) && overview.workers == []
            overview = JuLeAna.workers_overview(mgr)
            @test overview.script.path == script_file && only(overview.allocations).job_ids == ["101"]
            # the overview has the same type with and without a start script and SLURM
            @test overview isa JuLeAna.WorkersOverview
            @test JuLeAna.workers_overview(JuLeAna.WorkerManager(; squeue = `juleana-no-such-command`)) isa JuLeAna.WorkersOverview
            @test JuLeAna.workers_overview(JuLeAna.WorkerManager(; squeue = `juleana-no-such-command`)).slurm === nothing
            # the next allocation gets its own job name
            @test JuLeAna.add_workers!(mgr).job_name == "julia-$(getpid())-2"
            JuLeAna.cancel_all!(mgr)
            @test state_of(mgr, 2) === :cancelled
        end

        @testset "idle cancel" begin
            mgr = JuLeAna.WorkerManager()
            cfg(minutes) = ProcessingConfig(; processors = Dict(), p_processors = Dict(), idle_timeout_minutes = minutes)
            @test isnothing(JuLeAna.idle_deadline(mgr; processing = false))
            JuLeAna.set_worker_config!(mgr, cfg(2))
            JuLeAna.edit_start_script!(mgr, "sleep 60")
            # no countdown without a running allocation
            @test isnothing(JuLeAna.idle_deadline(mgr; processing = false))
            alloc = JuLeAna.add_workers!(mgr)
            deadline = JuLeAna.idle_deadline(mgr; processing = false)
            @test deadline == alloc.started + Minute(2)
            @test isnothing(JuLeAna.idle_deadline(mgr; processing = true))
            @test !JuLeAna.check_idle!(mgr; processing = false, time = deadline - Second(1))
            @test !JuLeAna.check_idle!(mgr; processing = true, time = deadline + Minute(5))
            # activity restarts the countdown; an earlier time does not
            JuLeAna.mark_activity!(mgr, deadline)
            JuLeAna.mark_activity!(mgr, alloc.started)
            @test JuLeAna.idle_deadline(mgr; processing = false) == deadline + Minute(2)
            @test !JuLeAna.check_idle!(mgr; processing = false, time = deadline + Second(119))
            @test JuLeAna.check_idle!(mgr; processing = false, time = deadline + Minute(2))
            @test state_of(mgr, 1) === :cancelled
            @test isnothing(JuLeAna.idle_deadline(mgr; processing = false))
            # `0` never cancels
            JuLeAna.set_worker_config!(mgr, cfg(0))
            JuLeAna.edit_start_script!(mgr, "sleep 60")
            JuLeAna.add_workers!(mgr)
            @test isnothing(JuLeAna.idle_deadline(mgr; processing = false))
            @test !JuLeAna.check_idle!(mgr; processing = false, time = now(UTC) + Day(1))
            JuLeAna.cancel_all!(mgr)
        end
    end
end
