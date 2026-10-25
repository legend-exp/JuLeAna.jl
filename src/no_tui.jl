# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const EXIT_CODES = Dict(:finished => 0, :failed => 1, :stopped => 2)

# Text of the summary that `run_no_tui` logs at the end of a processing run.
function run_summary(snap, p)
    duration = canonicalize(round(snap.finished - snap.started, Second))
    counts = join(("$n $state" for (state, n) in pairs(p.counts) if n > 0), ", ")
    lines = ["Processing $(snap.outcome) after $duration", "Steps: " * (isempty(counts) ? "none" : counts)]
    for state in (:failed, :cancelled)
        steps = [step_label(e) for e in p.steps if e.state === state]
        isempty(steps) || push!(lines, "$(uppercasefirst(string(state))): " * join(steps, ", "))
    end
    isnothing(snap.last_error) || push!(lines, "Error: $(snap.last_error)")
    return join(lines, "\n")
end

# Wait for the processing run of `ctrl` with `waiter(ctrl)`; the first interrupt stops the
# run, the second stops it without waiting for the running items.
function wait_with_interrupts(ctrl::DataflowController; waiter = wait)
    interrupts = 0
    while true
        try
            waiter(ctrl)
            return nothing
        catch e
            e isa InterruptException || rethrow()
            snapshot(ctrl).state in (:running, :stopping) || continue
            interrupts += 1
            if interrupts == 1
                @warn "Stopping: running items finish, nothing new starts. Press Ctrl-C again to stop without waiting for them."
                dispatch!(ctrl, StopProcessing())
            else
                dispatch!(ctrl, StopProcessing(; force = true))
            end
        end
    end
end

"""
    run_no_tui(parsed_args::AbstractDict; processors = PROCESSORS, loader = setup_session,
        interval = 1, record_software = true, record_metadata = true)

Run all enabled processors of the session described by the parsed command line options
`parsed_args` without the terminal user interface and return the process exit code.

Set up the session with `loader(parsed_args)` (by default [`setup_session`](@ref), which
also starts the workers and the log files), start processing through a
[`DataflowController`](@ref) and show the progress bars of [`show_progress`](@ref),
updated every `interval` seconds, until the run ends. The first Ctrl-C stops the run
after the running items, a second one stops it without waiting for them (see
[`StopProcessing`](@ref)). Finally log a summary with the outcome, the duration, the
number of steps per state and the failed and cancelled steps. With `record_software` and
`record_metadata`, the run first records the software and the metadata in the production
(see [`DataflowController`](@ref)).

The exit code is `0` when the run finished, `1` when it failed or the session could not
be set up, and `2` when it was stopped.
"""
function run_no_tui(parsed_args::AbstractDict; processors::AbstractDict{Symbol} = PROCESSORS, loader = setup_session, interval::Real = 1,
                    record_software::Bool = true, record_metadata::Bool = true)
    ctrl = DataflowController(parsed_args; processors, loader, record_software, record_metadata)
    dispatch!(ctrl, LoadSession())
    wait(ctrl)
    snap = snapshot(ctrl)
    if snap.state !== :ready
        @error "Setting up the session failed: $(snap.last_error)"
        return 1
    end
    try
        dispatch!(ctrl, StartProcessing())
    catch e
        e isa ArgumentError || rethrow()
        @error "Processing could not start: $(e.msg)"
        return 1
    end
    # Ctrl-C raises an `InterruptException` instead of ending the process
    Base.exit_on_sigint(false)
    show_progress(() -> wait_with_interrupts(ctrl), ctrl.progress; interval)
    snap = snapshot(ctrl)
    p = progress(ctrl)
    summary = run_summary(snap, p)
    snap.outcome === :finished ? (@info summary) : (@warn summary)
    return EXIT_CODES[snap.outcome]
end
