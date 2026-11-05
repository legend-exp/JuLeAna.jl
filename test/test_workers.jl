# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using JuLeAna
using Dates: Day, Minute, Second, UTC, now
using Distributed: addprocs, myid, remotecall_fetch, rmprocs
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
            @test occursin("seq 2", script.text) && occursin("elastic_worker", script.text) && occursin("\n      kill 0\n", script.text)
            # only the user can read the cluster cookie in the script
            @test filemode(script_file) & 0o777 == 0o700
            @test JuLeAna.start_script!(mgr) == script
            # a new config generates the script anew and keeps the previous file
            write(script_file, "edited")
            JuLeAna.set_worker_config!(mgr, ProcessingConfig(; processors = Dict(), p_processors = Dict(), local_n = 3))
            @test occursin("seq 3", JuLeAna.start_script!(mgr).text)
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
            @test occursin("--job-name=julia-$(getpid())-0", text)
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

        @testset "restart loop" begin
            # every slot runs the command again whenever it ends, while the heartbeat file is recent
            dir = mktempdir()
            runs, out, heartbeat = joinpath(dir, "runs"), joinpath(dir, "out"), joinpath(dir, "alive")
            touch(heartbeat)
            loop = run(pipeline(detach(`bash -c $(JuLeAna.restart_loop(2, "echo \$slot >> $runs; sleep 0.1", heartbeat, "echo stop", 0, 5))`);
                                stdout = out); wait = false)
            @test wait_until(() -> isfile(runs) && all(slot -> count(==(slot), readlines(runs)) >= 3, ("1", "2")))
            # the loop leads its own process group
            ccall(:kill, Cint, (Cint, Cint), -getpid(loop), 15)
            wait(loop)
            @test occursin("Worker slot 1: the worker ended after 0 s\n", read(out, String)) && !occursin("stop", read(out, String))
            # with a heartbeat file older than five minutes, or none, each slot runs `stop` after its worker ends and ends
            run(`touch -t 202001010000 $heartbeat`)
            out = read(`bash -c $(JuLeAna.restart_loop(2, "true", heartbeat, "echo stop", 0, 5))`, String)
            @test count(==("stop"), split(out, '\n')) == 2
            @test occursin("JuLeAna has not touched $heartbeat for 5 minutes: ending the allocation", out)
            rm(heartbeat)
            @test count(==("stop"),
                        split(read(`bash -c $(JuLeAna.restart_loop(2, "true", heartbeat, "echo stop", 0, 5))`, String), '\n')) == 2
        end

        @testset "SLURM start script" begin
            flags = ["--time=02:00:00", "--mem-bind=local", "--threads-per-core=1", "--cpu-bind=cores", "--nodes=1",
                     "--ntasks-per-node=4", "--cpus-per-task=2", "--mem=480GB"]
            slurm_config(; kw...) = ProcessingConfig(; processors = Dict(), p_processors = Dict(), runmode = :slurm, slurm_flags = flags,
                                                     kw...)
            text = JuLeAna.worker_start_script(slurm_config(; log_path = "/logs"))
            sbatch_line = only(filter(startswith("sbatch "), split(text, '\n')))
            @test startswith(sbatch_line, "sbatch --wait \"\$job_name\" '--time=02:00:00' --mem-bind=local")
            @test occursin("\njob_name=--job-name=julia-$(getpid())-0\n", text)
            @test occursin("\ntrap 'scancel --user=\"\$USER\" --name=\"\${job_name#--job-name=}\"' TERM\n", text)
            @test !occursin("--cpu-bind", sbatch_line) && endswith(sbatch_line, "--mem=480GB --output=\"\$output\" <<'JOB' &")
            @test occursin("output=/logs/julia-workers-\$\$.out", text) && occursin("seq 4", text)
            # each worker is a job step with the CPUs of a task, the binding flags and no memory of its own
            step = "srun --nodes=1 --ntasks=1 --exact --cpus-per-task=2 --mem=0 --mem-bind=local --cpu-bind=cores "
            @test occursin(step, text) && occursin("elastic_worker", text) && occursin("\n      scancel \"\$SLURM_JOB_ID\"\n", text)
            # a slot waits 30 s before it starts a new worker and ends the job without the heartbeat for 5 minutes, both set in the config
            @test occursin("\n    sleep 30\n", text) && occursin(" -mmin -5 ", text)
            other = JuLeAna.worker_start_script(slurm_config(; worker_restart_delay_seconds = 7, worker_heartbeat_timeout_minutes = 3))
            @test occursin("\n    sleep 7\n", other) && occursin(" -mmin -3 ", other)
            # fixed memory: the memory of the node divided by its workers
            @test occursin("--mem=122880M --mem-bind", JuLeAna.worker_start_script(slurm_config(; slurm_worker_memory = :fixed)))
            flags = ["--ntasks=2"]
            @test_throws "`worker_memory: fixed` needs `--mem` or `--mem-per-cpu`" JuLeAna.worker_start_script(slurm_config(;
                                                                                                                            slurm_worker_memory = :fixed))
            flags = ["--ntasks=2", "--cpu-bind", "cores"]
            @test_throws "as `--cpu-bind=<value>`" JuLeAna.worker_start_script(slurm_config())

            # the script with fake `sbatch`, `srun` and `scancel`: the batch script runs here, and every
            # step ends after a moment and is started again
            bin, logs = mktempdir(), mktempdir()
            write(joinpath(bin, "sbatch"), """
                #!/bin/bash
                echo "\$@" > $bin/sbatch.args
                for a in "\$@"; do case \$a in --output=*) out=\${a#--output=};; esac; done
                echo "Submitted batch job 7"
                bash > "\$out" 2>&1
                """)
            write(joinpath(bin, "srun"), "#!/bin/bash\necho \"srun \${*:1:5}\"\nsleep 0.5\n")
            write(joinpath(bin, "scancel"), "#!/bin/bash\necho \"\$@\" >> $bin/scancel.args\n")
            foreach(name -> chmod(joinpath(bin, name), 0o755), ("sbatch", "srun", "scancel"))
            flags = ["--ntasks=2", "--cpus-per-task=2"]
            # `squeue` lists no job, so only the script itself can cancel it
            mgr = JuLeAna.WorkerManager(; squeue = `true`)
            JuLeAna.set_worker_config!(mgr, slurm_config(; log_path = logs, worker_restart_delay_seconds = 0))
            withenv("PATH" => "$bin:$(ENV["PATH"])") do
                return JuLeAna.add_workers!(mgr)
            end
            output() = only(JuLeAna.allocations(mgr)).output
            @test wait_until(() -> count(==("srun --nodes=1 --ntasks=1 --exact --cpus-per-task=2 --mem=0"), output()) >= 4)
            @test first(output()) == "Submitted batch job 7"
            @test any(l -> occursin(r"^Worker slot [12]: the worker ended after \d s$", l), output())
            # the allocation started the heartbeat of this process, which the script checks
            @test isfile(JuLeAna.heartbeat_file()) && occursin(JuLeAna.heartbeat_file(), JuLeAna.start_script!(mgr).text)
            sbatch_args = read(joinpath(bin, "sbatch.args"), String)
            @test startswith(sbatch_args,
                             "--wait --job-name=julia-$(getpid())-1 --ntasks=2 --cpus-per-task=2 --output=$logs/julia-workers-")
            JuLeAna.cancel_allocation!(mgr, 1)
            @test state_of(mgr, 1) === :cancelled
            @test wait_until(() -> isfile(joinpath(bin, "scancel.args")))
            @test read(joinpath(bin, "scancel.args"), String) == "--user=$(get(ENV, "USER", "")) --name=julia-$(getpid())-1\n"
        end

        @testset "job steps" begin
            dir = mktempdir()
            acct = joinpath(dir, "acct.txt")
            write(acct, """
                4711|vipc1|RUNNING|0:0|00:05:00|
                4711.batch|vipc1|RUNNING|0:0|00:05:00|
                4711.extern|vipc1|RUNNING|0:0|00:05:00|
                4711.0|vipc1|RUNNING|0:0|00:05:00|
                4711.1|vipc1|OUT_OF_MEMORY|0:125|00:00:03|36812K
                4711.2|vipc2|CANCELLED by 2027|0:9|00:01:00|2.5G
                """)
            stat = joinpath(dir, "stat.txt")
            # as `sstat` prints it on viper, with an invalid CPU time of the `extern` step
            write(stat, """
                4711.extern|||213503982334-14:25:51
                4711.batch|4K|8K|00:00:00
                4711.0|1048576K|2097152K|00:10:00
                """)
            write(joinpath(dir, "sacct.sh"), "echo \"\$@\" >> $dir/sacct.args; cat $acct\n")
            write(joinpath(dir, "sstat.sh"), "echo \"\$@\" >> $dir/sstat.args; cat $stat\n")
            mgr = JuLeAna.WorkerManager(; sacct = `bash $dir/sacct.sh`, sstat = `bash $dir/sstat.sh`)
            # a SLURM allocation whose job runs, as `update_job_ids!` leaves it
            alloc = JuLeAna.WorkerAllocation(1, :slurm, "julia-1-1", now(UTC), nothing, :running, nothing, nothing, ["4711"], String[])
            push!(mgr.allocations, alloc)
            JuLeAna.update_steps!(mgr; at = 100)
            # the CPUs over the last minute only from the second query on
            @test mgr.steps["4711"] == [(; id = "4711.0", node = "vipc1", state = "RUNNING", exit_code = "0:0", elapsed = "00:05:00",
                                         rss = 2^30, max_rss = 2^31, cpu_load = nothing, cpu_mean = 2.0),
                                        (; id = "4711.1", node = "vipc1", state = "OUT_OF_MEMORY", exit_code = "0:125", elapsed = "00:00:03",
                                         rss = nothing, max_rss = 36812 * 1024, cpu_load = nothing, cpu_mean = nothing),
                                        (; id = "4711.2", node = "vipc2", state = "CANCELLED", exit_code = "0:9", elapsed = "00:01:00",
                                         rss = nothing, max_rss = round(Int, 2.5 * 2^30), cpu_load = nothing, cpu_mean = nothing)]
            @test occursin("--jobs=4711 ", read(joinpath(dir, "sacct.args"), String))
            @test occursin("--allsteps --jobs=4711 ", read(joinpath(dir, "sstat.args"), String))
            # no new query within ten seconds
            JuLeAna.update_steps!(mgr; at = 105)
            @test countlines(joinpath(dir, "sacct.args")) == 1
            write(acct, "4711.0|vipc1|RUNNING|0:0|00:05:30|\n")
            write(stat, "4711.0|1048576K|2097152K|00:10:45\n")
            JuLeAna.update_steps!(mgr; at = 130)
            @test only(mgr.steps["4711"]).cpu_load ≈ 1.5 && only(mgr.steps["4711"]).cpu_mean ≈ 645 / 330
            # since the query at 130, the oldest of the last minute
            write(stat, "4711.0|1048576K|2097152K|00:11:30\n")
            JuLeAna.update_steps!(mgr; at = 175)
            @test only(mgr.steps["4711"]).cpu_load ≈ 1.0
            # after the end of the allocation only `sacct`, until no step runs any more
            alloc.state = :ended
            JuLeAna.update_steps!(mgr; at = 190)
            @test countlines(joinpath(dir, "sacct.args")) == 4 && countlines(joinpath(dir, "sstat.args")) == 3
            @test only(mgr.steps["4711"]).cpu_load === nothing && only(mgr.steps["4711"]).cpu_mean === nothing && isempty(mgr.cpu_samples)
            write(acct, "4711.0|vipc1|COMPLETED|0:0|00:05:30|3G\n")
            JuLeAna.update_steps!(mgr; at = 210)
            @test only(mgr.steps["4711"]).state == "COMPLETED" && only(mgr.steps["4711"]).max_rss == 3 * 2^30
            JuLeAna.update_steps!(mgr; at = 230)
            @test countlines(joinpath(dir, "sacct.args")) == 5
            @test JuLeAna.slurm_bytes("12") == 12 && JuLeAna.slurm_bytes("") === nothing
            @test_throws "unexpected memory size \"12Q\"" JuLeAna.slurm_bytes("12Q")
            @test JuLeAna.slurm_seconds("02:18.007") ≈ 138.007 && JuLeAna.slurm_seconds("01:02:03") == 3723
            @test JuLeAna.slurm_seconds("1-01:02:03") == 90123 && JuLeAna.slurm_seconds("") === nothing
            @test_throws "unexpected duration \"INVALID\"" JuLeAna.slurm_seconds("INVALID")
        end

        @testset "worker attributes" begin
            # a plain worker process answers before it loads JuLeAna
            mgr = JuLeAna.WorkerManager(; squeue = `juleana-no-such-command`)
            pid = only(addprocs(1))
            try
                @test wait_until(() -> only(JuLeAna.workers_overview(mgr).workers).attributes isa JuLeAna.WorkerAttributes; timeout = 60)
                a = only(JuLeAna.workers_overview(mgr).workers).attributes
                @test a.host == gethostname() && a.os_pid == remotecall_fetch(getpid, pid) && a.os_pid != getpid()
                @test a.threads >= 1 && a.memory > 0 && a.job == get(ENV, "SLURM_JOB_ID", "")
            finally
                rmprocs(pid)
            end
        end

        @testset "ending workers" begin
            @test_throws "is the main process" JuLeAna.kill_worker(myid())
            @test_throws "the attributes of worker 99001 are not known" JuLeAna.kill_worker(99001)
            dir = mktempdir()
            scancel = `bash -c "echo \"\$*\" >> $dir/scancel.args" scancel`
            attributes(; kw...) = (; host = "vipc1", os_pid = 1, threads = 2, memory = 2^30, job = "4711", step = "3", tasks = "1",
                                   cpus = "2",
                                   gpus = "", kw...)
            try
                # the only task of its SLURM job step: the step is cancelled
                JuLeAna.WORKER_ATTRIBUTES[99001] = attributes()
                JuLeAna.kill_worker(99001; scancel)
                @test read(joinpath(dir, "scancel.args"), String) == "--signal=KILL 4711.3\n"
                # one of several tasks of a step on another host cannot be ended
                JuLeAna.WORKER_ATTRIBUTES[99002] = attributes(; tasks = "64")
                @test_throws "worker 99002 runs on vipc1, not as the only task of a SLURM job step" JuLeAna.kill_worker(99002; scancel)
                # a process on this host, also in the job step of this process, is killed directly
                for env in (Dict{String,String}(), Dict("SLURM_JOB_ID" => "4711", "SLURM_STEP_ID" => "3"))
                    process = run(`sleep 60`; wait = false)
                    JuLeAna.WORKER_ATTRIBUTES[99003] = attributes(; host = gethostname(), os_pid = getpid(process),
                                                                  job = get(env, "SLURM_JOB_ID", ""))
                    withenv(env...) do
                        return JuLeAna.kill_worker(99003; scancel)
                    end
                    wait(process)
                    @test process.termsignal == 9
                end
                @test countlines(joinpath(dir, "scancel.args")) == 1
                # whether a worker ended with its SLURM job: any state of the job but `RUNNING`
                state = joinpath(dir, "state")
                squeue = `bash -c "echo \"\$*\" >> $dir/squeue.args; cat $state" squeue`
                @test !JuLeAna.worker_job_ended(99004; squeue)
                JuLeAna.WORKER_ATTRIBUTES[99004] = attributes(; job = "")
                @test !JuLeAna.worker_job_ended(99004; squeue) && !isfile(joinpath(dir, "squeue.args"))
                JuLeAna.WORKER_ATTRIBUTES[99004] = attributes()
                for (text, ended) in (("RUNNING\n", false), ("TIMEOUT\n", true), ("COMPLETING\n", true), ("", false))
                    write(state, text)
                    @test JuLeAna.worker_job_ended(99004; squeue) == ended
                end
                @test readline(joinpath(dir, "squeue.args")) == "--noheader --states=all --jobs=4711 --format=%T"
                # no state when `squeue` fails or is missing
                @test !JuLeAna.worker_job_ended(99004; squeue = `bash -c "exit 1"`)
                @test !JuLeAna.worker_job_ended(99004; squeue = `$dir/no-squeue`)
            finally
                foreach(pid -> delete!(JuLeAna.WORKER_ATTRIBUTES, pid), (99001, 99002, 99003, 99004))
            end
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
