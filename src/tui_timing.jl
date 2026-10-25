# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    JuLeAna.TIMING_COLUMNS

Column names of the file `interface_timing.tsv`, in order: UTC time of the end of the
window, controller state, number of frames, frame gap median, 95th percentile and maximum,
`view` time 95th percentile and maximum, `update!` time 95th percentile and maximum, number
of key presses, key-to-redraw latency median, 95th percentile and maximum, garbage
collections in the window (count, time, longest pause), the longest `update!` for key,
mouse and task events, the event kind or task id of the slowest `update!`, the length of the
window in seconds, `threadid:threadpool` of the thread that draws, the page shown during the
slowest `view` and, for each page shown, `page:frames:mean view time` separated by spaces.
Times are in milliseconds; `NA` marks a statistic without measurements.
"""
const TIMING_COLUMNS = ("utc", "state", "frames", "gap_p50_ms", "gap_p95_ms", "gap_max_ms", "view_p95_ms", "view_max_ms", "update_p95_ms",
                        "update_max_ms", "keys", "key_p50_ms", "key_p95_ms", "key_max_ms", "gc_count", "gc_time_ms", "gc_max_pause_ms",
                        "update_key_max_ms", "update_mouse_max_ms", "update_task_max_ms", "slowest_update", "window_s", "view_thread",
                        "view_max_page", "page_views")

# Kinds of events handled by `Tachikoma.update!`, the slot of each in the per-kind maxima.
const TIMING_KINDS = (:key, :mouse, :task, :other)

"""
    JuLeAna.InterfaceTiming(; window_seconds = 10, clock = time_ns, utc = () -> now(UTC), capacity = 8192, pages = 16)

Recorder of how responsive the terminal interface is, one window of `window_seconds` at a
time. It keeps, in fixed-size buffers of `capacity` entries per kind of measurement
(measurements beyond that are counted but not stored):

- the interval between the starts of consecutive `view` calls (frame gaps),
- the time spent in each `view` call and in each `Tachikoma.update!` call, with the
  maximum per event kind (key, mouse, task) and the kind or task id of the slowest call,
- per page `1:pages`, the number of `view` calls and the time spent in them, and the page of
  the slowest `view` call,
- the key-to-redraw latency: from the start of the `update!` call for a key press to the
  end of the next `view` call. It does not include the time a key waited in the terminal
  input before the application loop read it; that shows up as a long frame gap,
- the number of garbage collections, the time spent in them and the longest pause, from
  `Base.gc_num()`,
- the thread and thread pool of the first `view` call.

The functions [`JuLeAna.timing_view_begin!`](@ref), [`JuLeAna.timing_view_end!`](@ref),
[`JuLeAna.timing_update_begin!`](@ref) and [`JuLeAna.timing_update_end!`](@ref) feed the
recorder; each takes one time reading and writes into the buffers without allocating.
[`JuLeAna.timing_flush!`](@ref) closes the window.

`clock` returns the time in nanoseconds and `utc` the wall-clock time of a row; both can be
replaced to feed synthetic times.
"""
mutable struct InterfaceTiming
    const clock::Any
    const utc::Any
    const window_ns::UInt64
    # serializes the appends to the timing file
    const lock::ReentrantLock
    const frame_gaps::Vector{UInt64}
    const view_times::Vector{UInt64}
    const update_times::Vector{UInt64}
    const key_latencies::Vector{UInt64}
    # start times of the key presses not yet followed by the end of a `view`
    const pending_keys::Vector{UInt64}
    # longest `update!` per kind, in the order of `TIMING_KINDS`
    const update_max::Vector{UInt64}
    # number of `view` calls and time spent in them per page
    const page_frames::Vector{Int}
    const page_view_ns::Vector{UInt64}
    # numbers of measurements in the window, including those beyond the buffers
    n_frames::Int
    n_gaps::Int
    n_views::Int
    n_updates::Int
    n_keys::Int
    n_pending::Int
    # start of the latest `view` call, 0 before the first
    view_start::UInt64
    # start of the previous `view` call, 0 before the second
    previous_view_start::UInt64
    window_start::UInt64
    slowest_update_ns::UInt64
    slowest_update::Symbol
    slowest_view_ns::UInt64
    # page of the slowest `view` call, 0 if none
    slowest_view_page::Int
    gc_start::Base.GC_Num
    # `(threadid, threadpool)` of the first `view` call
    view_thread::Union{Nothing,Tuple{Int,Symbol}}
end

function InterfaceTiming(; window_seconds::Real = 10, clock = time_ns, utc = () -> now(UTC), capacity::Integer = 8192, pages::Integer = 16)
    window_seconds > 0 || throw(ArgumentError("InterfaceTiming: window_seconds must be positive, got $window_seconds"))
    capacity > 0 || throw(ArgumentError("InterfaceTiming: capacity must be positive, got $capacity"))
    pages > 0 || throw(ArgumentError("InterfaceTiming: pages must be positive, got $pages"))
    return InterfaceTiming(clock, utc, round(UInt64, 1e9 * window_seconds), ReentrantLock(), zeros(UInt64, capacity),
                           zeros(UInt64, capacity), zeros(UInt64, capacity), zeros(UInt64, capacity), zeros(UInt64, 256),
                           zeros(UInt64, length(TIMING_KINDS)), zeros(Int, pages), zeros(UInt64, pages), 0, 0, 0, 0, 0, 0, 0, 0, clock(), 0,
                           :none, 0, 0, Base.gc_num(), nothing)
end

timing_kind(::Tachikoma.KeyEvent) = 1
timing_kind(::Tachikoma.MouseEvent) = 2
timing_kind(::Tachikoma.TaskEvent) = 3
timing_kind(::Any) = 4

timing_label(evt) = TIMING_KINDS[timing_kind(evt)]
timing_label(evt::Tachikoma.TaskEvent) = evt.id

# Store `x` at position `n + 1` of `buffer` unless it is full; return the new count.
function timing_push!(buffer::Vector{UInt64}, n::Int, x::UInt64)
    n < length(buffer) && (buffer[n + 1] = x)
    return n + 1
end

"""
    JuLeAna.timing_view_begin!(t::InterfaceTiming)

Record the start of a `view` call in `t`: the gap since the start of the previous call and,
on the first call, the thread it runs on (also logged). Returns the start time.
"""
function timing_view_begin!(t::InterfaceTiming)
    now_ns = UInt64(t.clock())
    if t.view_start != 0
        t.n_gaps = timing_push!(t.frame_gaps, t.n_gaps, now_ns - t.view_start)
    end
    t.previous_view_start, t.view_start = t.view_start, now_ns
    if isnothing(t.view_thread)
        t.view_thread = (Threads.threadid(), Threads.threadpool())
        @info "The interface draws on thread $(t.view_thread[1]) of the $(t.view_thread[2]) pool"
    end
    return now_ns
end

"""
    JuLeAna.timing_view_end!(t::InterfaceTiming, snap; page = 0)

Record the end of a `view` call in `t` that showed the page `page` (0 for none): its
duration, per page if `page` is one of the pages of `t`, and the key-to-redraw latency of the
key presses since the previous call. When the window of `t` has elapsed, close it with
[`JuLeAna.timing_flush!`](@ref), using the controller state and log folder from the
controller snapshot `snap` (`nothing` before the first read); returns the row of the
window, else `nothing`.
"""
function timing_view_end!(t::InterfaceTiming, snap; page::Integer = 0)
    now_ns = UInt64(t.clock())
    elapsed = now_ns - t.view_start
    t.n_frames += 1
    t.n_views = timing_push!(t.view_times, t.n_views, elapsed)
    if checkbounds(Bool, t.page_frames, page)
        t.page_frames[page] += 1
        t.page_view_ns[page] += elapsed
    end
    if elapsed > t.slowest_view_ns
        t.slowest_view_ns, t.slowest_view_page = elapsed, page
    end
    for i in 1:min(t.n_pending, length(t.pending_keys))
        t.n_keys = timing_push!(t.key_latencies, t.n_keys, now_ns - t.pending_keys[i])
    end
    t.n_keys += max(t.n_pending - length(t.pending_keys), 0)
    t.n_pending = 0
    now_ns - t.window_start >= t.window_ns || return nothing
    return timing_flush!(t, isnothing(snap) ? :starting : snap.state, isnothing(snap) ? nothing : snap.log_path)
end

"""
    JuLeAna.timing_update_begin!(t::InterfaceTiming, evt)

Record the start of a `Tachikoma.update!` call for `evt` in `t`; the start of a key press
is kept until the end of the next `view`. Returns the start time, to pass to
[`JuLeAna.timing_update_end!`](@ref).
"""
function timing_update_begin!(t::InterfaceTiming, evt)
    now_ns = UInt64(t.clock())
    if evt isa Tachikoma.KeyEvent && evt.action != Tachikoma.key_release
        if t.n_pending < length(t.pending_keys)
            t.pending_keys[t.n_pending + 1] = now_ns
        end
        t.n_pending += 1
    end
    return now_ns
end

"""
    JuLeAna.timing_update_end!(t::InterfaceTiming, start::UInt64, evt)

Record the end of a `Tachikoma.update!` call for `evt` that started at `start` in `t`.
"""
function timing_update_end!(t::InterfaceTiming, start::UInt64, evt)
    elapsed = UInt64(t.clock()) - start
    t.n_updates = timing_push!(t.update_times, t.n_updates, elapsed)
    k = timing_kind(evt)
    elapsed > t.update_max[k] && (t.update_max[k] = elapsed)
    if elapsed > t.slowest_update_ns
        t.slowest_update_ns, t.slowest_update = elapsed, timing_label(evt)
    end
    return nothing
end

# Median, 95th percentile and maximum, in milliseconds, of the first `n` entries of `buffer`
# (sorted in place); `NaN` if there are none.
function timing_stats(buffer::Vector{UInt64}, n::Int)
    n = min(n, length(buffer))
    n == 0 && return (NaN, NaN, NaN)
    sample = view(buffer, 1:n)
    sort!(sample)
    return (quantile(sample, 0.5; sorted = true) / 1e6, quantile(sample, 0.95; sorted = true) / 1e6, Float64(last(sample)) / 1e6)
end

timing_field(x::Real) = isnan(x) ? "NA" : string(round(x; digits = 3))

"""
    JuLeAna.timing_flush!(t::InterfaceTiming, state, log_path)

Close the window of `t`: format its statistics as one tab-separated row (see
[`JuLeAna.TIMING_COLUMNS`](@ref) for the columns), start a new window and return the row.
`state` is the state of the controller. If `log_path` is a folder name, the row is
appended to `interface_timing.tsv` in it by a separate task, preceded by the header if the
file does not exist; the caller never waits for the file. With `log_path = nothing` or `""`
nothing is written.

Frame gaps, `view` times and `update!` times are in milliseconds. The garbage collector
counts and time are those of the window. `gc_max_pause_ms` is the longest pause of the
window if it exceeds all earlier pauses of the process, else an upper bound: the lesser of
the longest earlier pause and the time spent in garbage collection in the window.
"""
function timing_flush!(t::InterfaceTiming, state, log_path)
    now_ns = UInt64(t.clock())
    gc = Base.gc_num()
    gc_count = gc.pause - t.gc_start.pause
    gc_ns = gc.total_time - t.gc_start.total_time
    gc_max_ns = gc_count == 0 ? 0 : gc.max_pause > t.gc_start.max_pause ? gc.max_pause : min(gc.max_pause, gc_ns)
    gap = timing_stats(t.frame_gaps, t.n_gaps)
    view_ = timing_stats(t.view_times, t.n_views)
    update = timing_stats(t.update_times, t.n_updates)
    key = timing_stats(t.key_latencies, t.n_keys)
    thread = isnothing(t.view_thread) ? "NA" : "$(t.view_thread[1]):$(t.view_thread[2])"
    pages = join(("$p:$n:$(timing_field(t.page_view_ns[p] / n / 1e6))" for (p, n) in pairs(t.page_frames) if n > 0), ' ')
    row = join((Dates.format(t.utc(), dateformat"yyyy-mm-ddTHH:MM:SS"), state, t.n_frames, timing_field(gap[1]), timing_field(gap[2]),
                timing_field(gap[3]), timing_field(view_[2]), timing_field(view_[3]), timing_field(update[2]), timing_field(update[3]),
                t.n_keys, timing_field(key[1]), timing_field(key[2]), timing_field(key[3]), gc_count, timing_field(gc_ns / 1e6),
                timing_field(gc_max_ns / 1e6), timing_field(t.update_max[1] / 1e6), timing_field(t.update_max[2] / 1e6),
                timing_field(t.update_max[3] / 1e6), t.slowest_update, timing_field((now_ns - t.window_start) / 1e9), thread,
                t.slowest_view_page == 0 ? "NA" : t.slowest_view_page, isempty(pages) ? "NA" : pages), '\t')
    t.n_frames = t.n_gaps = t.n_views = t.n_updates = t.n_keys = 0
    fill!(t.update_max, 0)
    fill!(t.page_frames, 0)
    fill!(t.page_view_ns, 0)
    t.slowest_update_ns, t.slowest_update = 0, :none
    t.slowest_view_ns, t.slowest_view_page = 0, 0
    t.window_start, t.gc_start = now_ns, gc
    if !isnothing(log_path) && !isempty(log_path)
        path = joinpath(log_path, "interface_timing.tsv")
        errormonitor(Threads.@spawn @lock t.lock begin
                         header = !isfile(path)
                         open(path, "a") do io
                             header && println(io, join(TIMING_COLUMNS, '\t'))
                             println(io, row)
                         end
                     end)
    end
    return row
end
