# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

const TUI_PAGES = ("Setup", "Graph", "Workers", "Progress", "Log", "Reports", "History", "Sync")
const SYNC_PAGE = length(TUI_PAGES)

# Colors of the letters of the logo title, in the order of the letters of `JuLeAna`.
const TITLE_COLORS = (Tachikoma.ColorRGB(0xcb, 0x3c, 0x33), Tachikoma.ColorRGB(0x38, 0x98, 0x26), Tachikoma.ColorRGB(0x95, 0x58, 0xb2))

# Keys shown on the bottom row, as `(key, description)` per page: Setup, Graph, Progress, Log, others.
const SETUP_HINTS = (("Tab", "pane"), ("Space", "toggle"), ("/", "filter"), ("s", "start"), ("x/X", "stop"), ("W", "workers"),
                     ("e", "settings"), ("w", "write"))
const GRAPH_HINTS = (("↑↓", "move"), ("Space", "select"), ("d", "add required"), ("h", "unselected"), ("v", "last run/disk"))
const PROGRESS_HINTS = (("↑↓ PgUp PgDn", "move"), ("Enter ←→", "fold"), ("Enter on step", "messages"), ("f", "follow"))
const PROGRESS_OPEN_HINTS = (("↑↓", "move"), ("PgUp PgDn", "scroll messages"), ("End", "newest"), ("Esc", "close"), ("f", "follow"))
const LOG_HINTS = (("↑↓ PgUp PgDn", "scroll"), ("End", "newest"), ("f", "follow"), ("l", "level"), ("/", "filter"))
const REPORTS_HINTS = (("↑↓", "move"), ("Enter", "open"), ("a", "all/run"), ("r", "reload"), ("Tab", "pane"))
const REPORTS_OPEN_HINTS = (("↑↓ PgUp PgDn", "scroll"), ("Esc", "close"))
const HISTORY_HINTS = (("↑↓←→", "move"), ("Enter", "open report"), ("r", "reload"), ("a", "all/selected runs"))
const HISTORY_OPEN_HINTS = REPORTS_OPEN_HINTS
const WORKERS_HINTS = (("Tab", "pane"), ("↑↓", "move"), ("s", "SLURM"), ("a", "add"), ("c/C", "cancel"), ("p", "postpone"),
                       ("o", "options"), ("e", "script"), ("r", "reload"))
const WORKERS_EDIT_HINTS = (("Ctrl-O", "save"), ("Esc", "close"))
const WORKERS_FORM_HINTS = (("↑↓", "option"), ("Enter", "edit/set"), ("Esc", "close"))
const PRODUCTION_HINTS = (("↑↓ Tab", "field"), ("Space", "toggle"), ("Ctrl-N", "add row"), ("Ctrl-D", "remove row"), ("Ctrl-O", "create"),
                          ("Esc", "close"))
const PRODUCTION_DONE_HINTS = (("any key", "continue"),)
const COMMON_HINTS = (("1-$(length(TUI_PAGES))", "page"), ("q", "quit"), ("?", "help"))

# Seconds a new warning or error stays in the status panel.
const ALERT_SECONDS = 10.0

# One line kept by a `MessageBuffer`.
const MessageEntry = NamedTuple{(:level, :record, :text),Tuple{LogLevel,Int,String}}

# Number of workers whose output a `MessageBuffer` keeps; beyond it, the worker with the
# oldest newest line is dropped.
const MESSAGE_BUFFER_WORKERS = 512

"""
    MessageBuffer(capacity::Integer = 1000; worker_capacity::Integer = 200)

Logger that keeps the last `capacity` lines of log messages and of captured terminal
output as text, for the terminal user interface. Each line has the log level of its
message and the number of its record: the lines of one log message share a record, each
line of captured output is a record of its own. Output lines containing `Warning:` or
`Error:` get the level `Warn` or `Error`, other output lines `Info`. Records below `Info`
and progress bar records of ProgressLogging are dropped. A message that is not a string
but can be shown as Markdown, such as a processor's report, is kept as that Markdown if it
has at most 20 lines, else as one line with its section heading, processor status and
length. A log message of a processing
step (inside the step's scope set by [`run_processing`](@ref)) is also kept with the step
in its `ProgressStore` (see [`step_messages`](@ref)). The newest warning or error, from
a log record or from an output line containing `Warning:` or `Error:`, is kept as the
alert of the buffer.

Output lines that Distributed relays from a worker (`From worker <pid>:`) are kept apart,
the last `worker_capacity` lines per worker without the prefix, so that the output of many
workers does not push out the other lines. Of the progress lines of
[`@debug_progress`](@ref), only the newest one of each description is kept. Relayed lines
containing `Warning:` or `Error:` are also kept with the other lines.

[`JuLeAna.message_lines`](@ref) returns the kept lines as text,
[`JuLeAna.message_entries`](@ref) with their levels and records, and
[`JuLeAna.worker_output`](@ref) the lines of a worker.
"""
mutable struct MessageBuffer <: AbstractLogger
    const lock::ReentrantLock
    const entries::Vector{MessageEntry}
    const capacity::Int
    # relayed output lines of each worker, by process ID
    const worker_entries::Dict{Int,Vector{MessageEntry}}
    const worker_capacity::Int
    # unfinished last line of each captured stream
    const partial::Dict{Symbol,String}
    alert::Union{Nothing,NamedTuple{(:level, :text, :time),Tuple{LogLevel,String,Float64}}}
    # number of the last record
    record::Int
end

function MessageBuffer(capacity::Integer = 1000; worker_capacity::Integer = 200)
    capacity > 0 || throw(ArgumentError("MessageBuffer: capacity must be positive, got $capacity"))
    worker_capacity > 0 || throw(ArgumentError("MessageBuffer: worker_capacity must be positive, got $worker_capacity"))
    return MessageBuffer(ReentrantLock(), MessageEntry[], capacity, Dict{Int,Vector{MessageEntry}}(), worker_capacity,
                         Dict{Symbol,String}(), nothing, 0)
end

min_enabled_level(::MessageBuffer) = Logging.Info
shouldlog(::MessageBuffer, level, _module, group, id) = true
catch_exceptions(::MessageBuffer) = true

function push_line!(buf::MessageBuffer, level::LogLevel, record::Integer, line::AbstractString)
    push!(buf.entries, (; level, record, text = String(line)))
    length(buf.entries) > buf.capacity && deleteat!(buf.entries, 1:(length(buf.entries) - buf.capacity))
    return nothing
end

# Description of a progress line of `@debug_progress`, or `nothing` for another line.
progress_description(text::AbstractString) = (m = match(PROGRESS_LINE, text); isnothing(m) ? nothing : m[1])

function push_worker_line!(buf::MessageBuffer, pid::Int, level::LogLevel, record::Integer, line::AbstractString)
    lines = get!(Vector{MessageEntry}, buf.worker_entries, pid)
    desc = progress_description(line)
    if !isnothing(desc)
        prefix = "[ Progress: $desc "
        i = findfirst(e -> startswith(e.text, prefix) && progress_description(e.text) == desc, lines)
        isnothing(i) || deleteat!(lines, i)
    end
    push!(lines, (; level, record, text = String(line)))
    length(lines) > buf.worker_capacity && popfirst!(lines)
    if length(buf.worker_entries) > MESSAGE_BUFFER_WORKERS
        delete!(buf.worker_entries, argmin(p -> last(buf.worker_entries[p]).record, keys(buf.worker_entries)))
    end
    return nothing
end

# Markdown of a logged object, such as a processor's report, as kept by a `MessageBuffer`:
# up to 20 lines as they are; a longer text as one line with its first section heading,
# its processor status if it has one, and its length.
function markdown_summary(markdown::AbstractString)
    lines = split(chomp(markdown), '\n')
    length(lines) <= 20 && return join(lines, '\n')
    i_heading = something(findfirst(startswith("## "), lines), findfirst(startswith('#'), lines), Some(nothing))
    title = isnothing(i_heading) ? strip(first(lines)) : strip(lstrip(lines[i_heading], '#'))
    i_status = findfirst(contains("Processor Status"), lines)
    m = isnothing(i_status) ? nothing : match(r"Success|Warning|Failure", join(lines[i_status:min(i_status + 3, end)], " "))
    return "$title: " * (isnothing(m) ? "" : "$(m.match), ") * "$(length(lines)) lines, full text in head.log"
end

function handle_message(buf::MessageBuffer, level, message, _module, group, id, file, line; kwargs...)
    message isa ProgressLogging.Progress && return nothing
    level < Logging.Info && return nothing
    text = message isa AbstractString ? String(message) : markdown_summary(log_text(message))
    for (key, value) in kwargs
        key === :exception && value isa Tuple{Exception,Any} && (value = sprint(showerror, first(value)))
        key === :exception && value isa Exception && (value = sprint(showerror, value))
        text *= "\n  $key = $value"
    end
    stamp = Dates.format(now(), dateformat"HH:MM:SS")
    @lock buf.lock begin
        record = (buf.record += 1)
        for (i, l) in enumerate(split(text, '\n'))
            push_line!(buf, LogLevel(level), record, i == 1 ? "$stamp $(rpad(string(level), 5)) $l" : "               $l")
        end
        level >= Logging.Warn && (buf.alert = (; level = LogLevel(level), text = first(split(text, '\n')), time = time()))
    end
    step = PROGRESS_STEP[]
    isnothing(step) || step_message!(step..., LogLevel(level), text)
    return nothing
end

"""
    JuLeAna.append_output!(buf::MessageBuffer, stream::Symbol, text::AbstractString)

Add `text` written to the captured output `stream` (`:stdout` or `:stderr`) to `buf`,
line by line; an unfinished last line waits for the rest of its text. A line relayed from
a worker goes to the lines of that worker (see [`JuLeAna.worker_output`](@ref)), and only
with `Warning:` or `Error:` also to the other lines.
"""
function append_output!(buf::MessageBuffer, stream::Symbol, text::AbstractString)
    @lock buf.lock begin
        pieces = split(get(buf.partial, stream, "") * text, '\n')
        buf.partial[stream] = pop!(pieces)
        for l in pieces
            l = rstrip(l, '\r')
            isempty(strip(l)) && continue
            m = match(r"(Warning|Error):\s*(.*)$", l)
            level = isnothing(m) ? Logging.Info : m[1] == "Error" ? Logging.Error : Logging.Warn
            record = (buf.record += 1)
            w = match(WORKERS_OUTPUT_LINE, l)
            if !isnothing(w)
                push_worker_line!(buf, parse(Int, w[1]), level, record, w[2])
                level >= Logging.Warn || continue
            end
            push_line!(buf, level, record, l)
            isnothing(m) || (buf.alert = (; level, text = String(m[2]), time = time()))
        end
    end
    return nothing
end

"""
    JuLeAna.worker_output(buf::MessageBuffer, pid::Integer)

Return a copy of the output lines kept in `buf` for the worker with process ID `pid`,
oldest first, as entries like those of [`JuLeAna.message_entries`](@ref) with the text
without the `From worker <pid>:` prefix.
"""
worker_output(buf::MessageBuffer, pid::Integer) = @lock buf.lock copy(get(buf.worker_entries, pid, MessageEntry[]))

"""
    JuLeAna.message_lines(buf::MessageBuffer)

Return a copy of the lines kept in `buf`, oldest first.
"""
message_lines(buf::MessageBuffer) = @lock buf.lock [e.text for e in buf.entries]

"""
    JuLeAna.message_entries(buf::MessageBuffer)

Return a copy of the entries kept in `buf`, oldest first: named tuples with the fields
`level` (a `Logging.LogLevel`), `record` (the number of the log message or output line
the line belongs to) and `text` (the line as shown).
"""
message_entries(buf::MessageBuffer) = @lock buf.lock copy(buf.entries)

"""
    mutable struct JuLeAnaTUI <: Tachikoma.Model

State of the terminal user interface opened by [`JuLeAna.run_tui`](@ref).

`JuLeAnaTUI(ctrl::DataflowController, messages::MessageBuffer = MessageBuffer())` shows
the dataflow of `ctrl`. Controller commands run one after another in a background task,
in the order they were sent, and state reads run in background tasks of the interface's
`Tachikoma.TaskQueue`, so the interface never waits for the controller; the latest
state read from it is kept in the fields `snap`, `progress`, `busy` and `step_msgs` (the
messages of the step open on the Progress page, with the step's key).

A left click on a page's tab opens the page; other mouse events go to the visible page.

Keys: the visible page gets each key first (see [`JuLeAna.setup_key!`](@ref) for the
Setup page, [`JuLeAna.graph_key!`](@ref) for the Graph page,
[`JuLeAna.progress_key!`](@ref) for the Progress page and [`JuLeAna.log_key!`](@ref) for the Log page, [`JuLeAna.reports_key!`](@ref) for the Reports page and [`JuLeAna.history_key!`](@ref) for the History page and [`JuLeAna.workers_key!`](@ref) for the Workers page); otherwise `1` to `8` switch pages and `q`
or Ctrl-C quits. While processing runs, or the Sync page has unsaved marks or a running transfer, quitting asks first: `s` stops processing after
the running items and quits when the run has ended, `w` saves the sync selection and quits, `q` quits at once, ending the run and the workers connected to this
process, interrupting the transfer and discarding the unsaved selection, and `c` or Escape keeps the interface open. The dialog lists only the keys that apply.

`JuLeAnaTUI(ctrl, messages; splash_seconds = 1.5)` shows a startup screen with the logo,
the version and the link to the documentation in place of the page when the interface
starts, until the session has loaded (or loading failed) and `splash_seconds` have passed; any key
ends it and is not passed on. `?` opens a panel that lists the keys of the visible page;
Escape, `?` or `q` closes it. The Setup page's filter and the kwargs editor receive `?` as text.

`N` on the Setup page opens the [`JuLeAna.ProductionForm`](@ref) for a new data production.

The form replaces the visible page and takes every key (see [`JuLeAna.production_key!`](@ref)).
It is also open when the interface starts without a session: when the parsed
options have no `config` or `new_production` is set, `start!` does not load a session.

Page 8 shows the `JuLeAna.Sync` screen. It is created when the tab is first shown and starts connecting to the host then.

The field `timing` is the [`JuLeAna.InterfaceTiming`](@ref) that records the times of the
`view` and `Tachikoma.update!` calls; once a session is loaded it appends a row every 10
seconds to `interface_timing.tsv` in the log folder.
"""
mutable struct JuLeAnaTUI <: Tachikoma.Model
    const ctrl::DataflowController
    const messages::MessageBuffer
    const queue::Tachikoma.TaskQueue
    const commands::Channel{ControllerCommand}
    const setup::SetupPage
    const graph_page::GraphPage
    const progress_page::ProgressPage
    const log_page::LogPage
    const reports_page::ReportsPage
    const history_page::HistoryPage
    const workers_page::WorkersPage
    const tabs::Tachikoma.TabBar
    # commands sent and not yet answered, and commands answered so far
    pending::Int
    answered::Int
    page::Int
    quit::Bool
    # `:quit` while the quit dialog is open
    dialog::Union{Nothing,Symbol}
    quit_after_stop::Bool
    refreshing::Bool
    timer::Union{Nothing,Tachikoma.CancelToken}
    snap::Any
    progress::Any
    busy::Vector{BusyItem}
    step_msgs::NamedTuple{(:key, :messages),Tuple{Any,Vector{StepMessage}}}
    command_error::Union{Nothing,String}
    # number of `:tick` events, which advances the spinner
    ticks::Int
    # whether the startup screen is on, when `start!` ran, and whether the key help is open
    splash::Bool
    started_at::Float64
    help::Bool
    # the open new-production form, which replaces the visible page
    production::Union{Nothing,ProductionForm}
    # the Sync page, created on the first visit of the Sync tab, the settings it starts from and how it reaches a host
    sync::Union{Nothing,SyncPage}
    const sync_settings::Union{Nothing,SyncSettings}
    const sync_host::Any
    # minimum seconds of the startup screen
    const splash_seconds::Float64
    # frame, `update!` and garbage collection times, see `InterfaceTiming`
    const timing::InterfaceTiming
end

# Tab bar of the pages, each tab labeled with its number and name.
function tab_bar()
    return Tachikoma.TabBar([[Tachikoma.Span(string(i), Tachikoma.tstyle(:warning)), Tachikoma.Span(" " * name, Tachikoma.tstyle(:text))]
                             for (i, name) in pairs(TUI_PAGES)]; focused = true,
                            tab_style = Tachikoma.TabBarStyle(; decoration = Tachikoma.BoxTabs(; box = Tachikoma.BOX_ROUNDED),
                                                              active = Tachikoma.tstyle(:accent, bold = true),
                                                              inactive = Tachikoma.tstyle(:text_dim)))
end

function JuLeAnaTUI(ctrl::DataflowController, messages::MessageBuffer = MessageBuffer(); splash_seconds::Real = 1.5,
                    sync_settings::Union{Nothing,SyncSettings} = nothing, sync_host = SSHHost)
    m = JuLeAnaTUI(ctrl, messages, Tachikoma.TaskQueue(), Channel{ControllerCommand}(Inf), SetupPage(), GraphPage(), ProgressPage(),
                   LogPage(), ReportsPage(), HistoryPage(), WorkersPage(), tab_bar(), 0, 0, 1, false, nothing, false, false, nothing,
                   nothing, nothing, BusyItem[], (; key = nothing, messages = StepMessage[]), nothing, 0, false, 0.0, false, nothing,
                   nothing, sync_settings, sync_host, splash_seconds, InterfaceTiming())
    errormonitor(Threads.@spawn run_commands(m))
    return m
end

# Dispatch the commands of `m` in order; each result comes back as a `:command` event.
function run_commands(m::JuLeAnaTUI)
    for cmd in m.commands
        result = try
            dispatch!(m.ctrl, cmd)
            nothing
        catch e
            e
        end
        wait(Tachikoma.spawn_task!(() -> result, m.queue, :command))
    end
end

Tachikoma.should_quit(m::JuLeAnaTUI) = m.quit
Tachikoma.task_queue(m::JuLeAnaTUI) = m.queue

"""
    JuLeAna.send_command!(m::JuLeAnaTUI, cmd::ControllerCommand)

Queue `cmd` for the controller of `m`; the commands are dispatched one after another in
a background task. A rejected command shows its error in the status panel.
"""
function send_command!(m::JuLeAnaTUI, cmd::ControllerCommand)
    m.pending += 1
    put!(m.commands, cmd)
    return nothing
end

# The messages of the step open on the Progress page; the field types are fixed, so that the
# result of a read has the same type for every step.
const StepMessages = @NamedTuple{key::Union{Nothing,ProgressKey}, messages::Vector{StepMessage}}

# Read the controller state in a background task, one read at a time. The read carries
# the number of commands answered when it started, so that a read older than an answer
# is recognized.
function refresh!(m::JuLeAnaTUI)
    m.refreshing && return nothing
    m.refreshing = true
    ctrl, answered, key = m.ctrl, m.answered, m.progress_page.open
    creating = !isnothing(m.production) && m.production.phase === :creating
    Tachikoma.spawn_task!(m.queue, :refresh) do
        messages = isnothing(key) ? StepMessage[] : step_messages(ctrl, key)
        check_idle!(ctrl)
        return (answered, snapshot(ctrl), progress(ctrl), busy_workers(ctrl), StepMessages((; key, messages)),
                creating ? production_log(ctrl) : String[])
    end
    return nothing
end

# Start the periodic reads of the controller state and show the startup screen. If no
# session is loaded, load one, or open the new-production form when there is no config to
# load or `new_production` is set.
function start!(m::JuLeAnaTUI)
    m.splash, m.started_at = true, time()
    m.timer = Tachikoma.spawn_timer!(m.queue, :tick, 0.5; repeat = true)
    if snapshot(m.ctrl).state === :idle
        if isnothing(get(m.ctrl.args, "config", nothing)) || get(m.ctrl.args, "new_production", false) === true
            m.production = ProductionForm()
        else
            send_command!(m, LoadSession())
        end
    end
    refresh!(m)
    return nothing
end

Tachikoma.init!(m::JuLeAnaTUI, ::Tachikoma.Terminal) = start!(m)

function Tachikoma.cleanup!(m::JuLeAnaTUI)
    isnothing(m.timer) || Tachikoma.cancel!(m.timer)
    close(m.commands)
    return nothing
end

processing(m::JuLeAnaTUI) = !isnothing(m.snap) && m.snap.state in (:running, :stopping)

function Tachikoma.update!(m::JuLeAnaTUI, evt::Tachikoma.TaskEvent)
    start = timing_update_begin!(m.timing, evt)
    try
        update_task!(m, evt)
    finally
        timing_update_end!(m.timing, start, evt)
    end
    return nothing
end

function update_task!(m::JuLeAnaTUI, evt::Tachikoma.TaskEvent)
    if startswith(String(evt.id), "sync:")
        isnothing(m.sync) && error("a sync task event arrived before the Sync page exists: $(evt.id)")
        sync_task!(m.sync, evt)
        return nothing
    end
    if evt.id === :tick
        m.ticks += 1
        m.splash = splash_active(m)
        refresh!(m)
        workers_sync!(m)
    elseif evt.id === :refresh
        m.refreshing = false
        evt.value isa Exception && throw(evt.value)
        answered, m.snap, m.progress, m.busy, m.step_msgs = evt.value
        # a read from before the last answer may miss its command: keep the page, read again
        if answered == m.answered
            sync_setup!(m.setup, m.snap; pending = m.pending > 0)
            isnothing(m.production) || production_sync!(m.production, m.snap, length(evt.value) > 5 ? evt.value[6] : String[])
        else
            refresh!(m)
        end
        # the pane switched to another step while the read ran
        m.step_msgs.key == m.progress_page.open || refresh!(m)
        m.splash = splash_active(m)
        m.quit_after_stop && !processing(m) && (m.quit = true)
        reports_sync!(m)
        history_sync!(m)
        dataset_sync!(m)
        choices_sync!(m)
    elseif evt.id === :dataset
        m.setup.dataset = evt.value
    elseif evt.id === :choices
        key, value = evt.value
        key == m.setup.choices_key && (m.setup.choices = value)
    elseif evt.id === :reports
        evt.value isa Exception && throw(evt.value)
        reports_result!(m.reports_page, evt.value)
        reports_sync!(m)
    elseif evt.id === :history
        evt.value isa Exception && throw(evt.value)
        history_result!(m.history_page, evt.value)
        history_sync!(m)
    elseif evt.id === :workers
        evt.value isa Exception && throw(evt.value)
        workers_result!(m.workers_page, evt.value)
        workers_sync!(m)
    elseif evt.id === :command
        m.pending -= 1
        m.answered += 1
        workers_stale!(m.workers_page)
        workers_sync!(m)
        m.command_error = evt.value isa Exception ? sprint(showerror, evt.value) : nothing
        isnothing(m.production) || production_answer!(m.production, m.answered, evt.value)
        refresh!(m)
    end
    return nothing
end

function Tachikoma.update!(m::JuLeAnaTUI, evt::Tachikoma.KeyEvent)
    start = timing_update_begin!(m.timing, evt)
    try
        update_key!(m, evt)
        reports_sync!(m)
        history_sync!(m)
        workers_sync!(m)
    finally
        timing_update_end!(m.timing, start, evt)
    end
    return nothing
end

function update_key!(m::JuLeAnaTUI, evt::Tachikoma.KeyEvent)
    ctrl_c = evt.key == :ctrl_c || (evt.key == :ctrl && evt.char == 'c')
    if splash_active(m)
        evt.action == Tachikoma.key_release || (m.splash = false)
        return nothing
    end
    m.splash = false
    if m.help
        if evt.action != Tachikoma.key_release && (evt.key == :escape || ctrl_c || (evt.key == :char && evt.char in ('?', 'q')))
            m.help = false
        end
        return nothing
    end
    if m.dialog === :quit
        if evt.key == :char && evt.char == 's' && processing(m)
            m.dialog, m.quit_after_stop = nothing, true
            m.snap.state === :running && send_command!(m, StopProcessing())
        elseif evt.key == :char && evt.char == 'w' && !isnothing(m.sync) && sync_dirty(m.sync)
            save!(m.sync)
            processing(m) || sync_pending(m) || (m.quit = true)
        elseif evt.key == :char && evt.char == 'q'
            m.quit = true
        elseif evt.key == :escape || (evt.key == :char && evt.char == 'c') || ctrl_c
            m.dialog = nothing
        end
        return nothing
    end
    if !isnothing(m.production) && !ctrl_c
        result = production_key!(m.production, evt, cmd -> send_command!(m, cmd))
        if m.production.phase === :creating && m.production.answer_at == 0
            m.production.answer_at = m.answered + m.pending
        end
        if result === :close
            m.production = nothing
        elseif result === :finished
            m.production, m.page = nothing, 1
        end
        return nothing
    end
    n = length(TUI_PAGES)
    if m.page == 1 && !ctrl_c && setup_key!(m.setup, evt, m.snap, cmd -> send_command!(m, cmd))
        if m.setup.new_production
            m.setup.new_production = false
            m.production = ProductionForm()
        end
        return nothing
    end
    m.page == 2 && !ctrl_c && graph_key!(m.graph_page, evt, m.snap, cmd -> send_command!(m, cmd)) && return nothing
    m.page == 3 && !ctrl_c && workers_key!(m.workers_page, evt, cmd -> send_command!(m, cmd); m.snap) && return nothing
    if m.page == 4 && !ctrl_c
        open = m.progress_page.open
        used = progress_key!(m.progress_page, evt, m.progress)
        m.progress_page.open == open || refresh!(m)
        used && return nothing
    end
    m.page == 5 && !ctrl_c && log_key!(m.log_page, evt, message_entries(m.messages)) && return nothing
    m.page == 6 && !ctrl_c && reports_key!(m.reports_page, evt) && return nothing
    m.page == 7 && !ctrl_c && history_key!(m.history_page, evt) && return nothing
    m.page == SYNC_PAGE && !ctrl_c && sync_key!(sync_page!(m), evt) && return nothing
    if ctrl_c || (evt.key == :char && evt.char == 'q')
        processing(m) || sync_pending(m) ? (m.dialog = :quit) : (m.quit = true)
    elseif evt.key == :char && evt.char == '?'
        m.help = true
    elseif evt.key == :char && evt.char == 'T'
        next_theme!()
    elseif evt.key == :char && '1' <= evt.char <= '0' + n
        show_page!(m, evt.char - '0')
    end
    return nothing
end

function Tachikoma.update!(m::JuLeAnaTUI, evt::Tachikoma.MouseEvent)
    start = timing_update_begin!(m.timing, evt)
    try
        update_mouse!(m, evt)
        reports_sync!(m)
        history_sync!(m)
        workers_sync!(m)
    finally
        timing_update_end!(m.timing, start, evt)
    end
    return nothing
end

function update_mouse!(m::JuLeAnaTUI, evt::Tachikoma.MouseEvent)
    if isnothing(m.dialog) && !m.help && isnothing(m.production) && !splash_active(m)
        if Tachikoma.handle_mouse!(m.tabs, evt) === :changed
            show_page!(m, m.tabs.active)
            return nothing
        end
        m.page == 1 && setup_mouse!(m.setup, evt, m.snap, cmd -> send_command!(m, cmd))
        m.page == 2 && graph_mouse!(m.graph_page, evt, m.snap)
        m.page == 3 && workers_mouse!(m.workers_page, evt)
        if m.page == 4
            open = m.progress_page.open
            progress_mouse!(m.progress_page, evt, m.progress)
            m.progress_page.open == open || refresh!(m)
        end
        m.page == 5 && log_mouse!(m.log_page, evt, message_entries(m.messages))
        m.page == 6 && reports_mouse!(m.reports_page, evt)
        m.page == 7 && history_mouse!(m.history_page, evt)
        m.page == SYNC_PAGE && sync_mouse!(sync_page!(m), evt)
    end
    return nothing
end

# Queue a read of the reports if the Reports page is visible and its data is out of date,
# and carry out the queued requests of the page in background tasks.
function reports_sync!(m::JuLeAnaTUI)
    page, ctrl = m.reports_page, m.ctrl
    m.page == 6 && reports_visit!(page, m.snap)
    for request in take_requests!(page)
        Tachikoma.spawn_task!(() -> read_reports(ctrl, request), m.queue, :reports)
    end
    return nothing
end

# Queue a read of the workers overview if the Workers page is visible and the latest read is
# older than five seconds, and carry out the queued requests of the page in background tasks.
function workers_sync!(m::JuLeAnaTUI)
    page, ctrl = m.workers_page, m.ctrl
    m.page == 3 && workers_visit!(page)
    for request in take_requests!(page)
        Tachikoma.spawn_task!(() -> read_workers_page(ctrl, request), m.queue, :workers)
    end
    return nothing
end

# Queue a read of the history grid if the History page, or the Graph page with the state on
# disk, is visible and the grid is out of date, and carry out the queued requests of the
# History page in background tasks.
function history_sync!(m::JuLeAnaTUI)
    page, ctrl = m.history_page, m.ctrl
    (m.page == 7 || (m.page == 2 && m.graph_page.disk)) && history_visit!(page, m.snap)
    for request in take_requests!(page)
        Tachikoma.spawn_task!(() -> read_history_page(ctrl, request), m.queue, :history)
    end
    return nothing
end

# Read the runinfo of a newly loaded session in a background task; the value is the
# summary or the message of the read error.
function dataset_sync!(m::JuLeAnaTUI)
    page, ctrl = m.setup, m.ctrl
    if m.snap.state in (:idle, :loading)
        page.dataset, page.dataset_requested = nothing, false
    elseif !page.dataset_requested
        page.dataset_requested = true
        Tachikoma.spawn_task!(m.queue, :dataset) do
            try
                dataset_summary(ctrl)
            catch e
                @error "Reading the runinfo failed" exception = (e, catch_backtrace())
                first(split(sprint(showerror, e), '\n'))
            end
        end
    end
    return nothing
end

# Rows of the status panel under the tabs: its border and two lines.
const STATUS_HEIGHT = 4

function format_duration(seconds::Real)
    return (s = round(Int, seconds); join(lpad.((s ÷ 3600, (s % 3600) ÷ 60, s % 60), 2, '0'), ":"))
end

# Spans of the first line of the status panel: spinner while the controller works, the
# controller state, the last run, the workers and the countdown to the cancel of idle worker
# allocations on the left, separated by dots; on the right a rejected command, else the latest
# alert, else the error of the last load or run.
function status_spans(m::JuLeAnaTUI)
    sep = ("  ·  ", Tachikoma.tstyle(:border))
    snap = m.snap
    state = isnothing(snap) ? :starting : snap.state
    state_style = state === :ready ? Tachikoma.tstyle(:success, bold = true) :
                  state === :running ? Tachikoma.tstyle(:accent, bold = true) : Tachikoma.tstyle(:warning, bold = true)
    left = Tuple{String,Tachikoma.Style}[]
    state in (:loading, :running, :stopping) &&
        push!(left, (string(Tachikoma.SPINNER_BRAILLE[mod1(m.ticks, length(Tachikoma.SPINNER_BRAILLE))]) * " ", state_style))
    push!(left, (uppercase(string(state)), state_style))
    if !isnothing(snap)
        if !isnothing(snap.outcome)
            outcome_color = snap.outcome === :finished ? :success : snap.outcome === :failed ? :error : :warning
            push!(left, sep, ("last run: ", Tachikoma.tstyle(:text)), (string(snap.outcome), Tachikoma.tstyle(outcome_color, bold = true)))
        end
        abandoned = count(b -> b.abandoned, m.busy)
        push!(left, sep, ("workers $(snap.nworkers)", Tachikoma.tstyle(:primary, bold = true)))
        isempty(m.busy) || push!(left, (", $(length(m.busy)) busy", Tachikoma.tstyle(:secondary, bold = true)))
        abandoned > 0 && push!(left, (", $abandoned abandoned", Tachikoma.tstyle(:warning)))
        if !isnothing(snap.idle_deadline)
            # the countdown to the cancel of idle worker allocations
            left_s = max(0, (snap.idle_deadline - now(UTC)) / Millisecond(1000))
            push!(left, (", idle cancel in $(format_duration(left_s))", Tachikoma.tstyle(left_s < 300 ? :warning : :text_dim)))
        end
    end
    right = Tuple{String,Tachikoma.Style}[]
    if !isnothing(m.command_error)
        push!(right, (first(split(m.command_error, '\n')), Tachikoma.tstyle(:error, bold = true)))
    else
        alert = @lock m.messages.lock m.messages.alert
        if !isnothing(alert) && time() - alert.time < ALERT_SECONDS
            style = alert.level >= Logging.Error ? Tachikoma.tstyle(:error, bold = true) : Tachikoma.tstyle(:warning)
            push!(right, (alert.text, style))
        elseif !isnothing(snap) && !isnothing(snap.last_error)
            # stays until the next load or run, so that a failed load does not look like a hang
            push!(right, (first(split(snap.last_error, '\n')), Tachikoma.tstyle(:error, bold = true)))
        end
    end
    return left, right
end

# Draw the status panel into `area`: a box with the spans of `status_spans` on the first line
# and, once a processing run started, a bar over the second line with the progress and the
# elapsed time of the run.
function render_status(m::JuLeAnaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    inner = Tachikoma.render(Tachikoma.Block(; border_style = Tachikoma.tstyle(:border)), area, buf)
    (inner.width < 1 || inner.height < 1) && return nothing
    x_max = Tachikoma.right(inner)
    left, right = status_spans(m)
    used = inner.x + 1 + sum(s -> textwidth(first(s)), left; init = 0)
    room = x_max - used - 3
    if !isempty(right) && room >= 8
        text = first(only(right))
        text = textwidth(text) <= room ? text : first(text, room - 1) * "…"
        put_spans!(buf, x_max - textwidth(text), inner.y, x_max, [(text, last(only(right)))])
    end
    put_spans!(buf, inner.x + 1, inner.y, min(x_max, used), left)
    inner.height >= 2 || return nothing
    snap = m.snap
    line = Tachikoma.Rect(inner.x + 1, inner.y + 1, max(0, inner.width - 2), 1)
    if isnothing(snap) || isnothing(snap.started) || isnothing(m.progress)
        Tachikoma.set_string!(buf, line.x, line.y, "No processing run in this session.", Tachikoma.tstyle(:text_dim); max_x = x_max)
    else
        elapsed = format_duration((something(snap.finished, now(UTC)) - snap.started) / Millisecond(1000))
        label = "$(round(Int, 100 * m.progress.fraction))%   $elapsed"
        color = snap.state in (:running, :stopping) ? :accent :
                snap.outcome === :finished ? :success : snap.outcome === :failed ? :error : :warning
        Tachikoma.render(Tachikoma.Gauge(m.progress.fraction; label, filled_style = Tachikoma.tstyle(color)), line, buf)
    end
    return nothing
end

# Draw the frame of the screen into `area` and return the area inside it: a rounded box
# whose title `JuLeAna` has one logo color per letter, with `LEGEND-200` on the right.
function render_frame(area, buf)
    title = "JuLeAna"
    block = Tachikoma.Block(; title = " "^textwidth(title), title_right = "LEGEND-200", title_right_style = Tachikoma.tstyle(:text_dim),
                            border_style = Tachikoma.tstyle(:border))
    inner = Tachikoma.render(block, area, buf)
    area.width > 4 || return inner
    # the block pads the title with `title_padding` cells on each side
    x = area.x + 1 + 2 * block.title_padding
    for (i, letter) in enumerate(title)
        Tachikoma.set_string!(buf, x + i - 1, area.y, string(letter),
                              Tachikoma.Style(; fg = TITLE_COLORS[mod1(i, length(TITLE_COLORS))], bold = true))
    end
    return inner
end

function Tachikoma.view(m::JuLeAnaTUI, f::Tachikoma.Frame)
    timing_view_begin!(m.timing)
    draw_interface!(m, f)
    timing_view_end!(m.timing, m.snap; m.page)
    return nothing
end

function draw_interface!(m::JuLeAnaTUI, f::Tachikoma.Frame)
    tabs = m.tabs
    tabs.active = m.page
    tab_h = Tachikoma.tab_height(tabs.tab_style.decoration)
    layout = Tachikoma.Layout(Tachikoma.Vertical,
                              [Tachikoma.Fixed(tab_h), Tachikoma.Fixed(STATUS_HEIGHT), Tachikoma.Fill(), Tachikoma.Fixed(1)])
    tab_area, status_area, body_area, keys_area = Tachikoma.split_layout(layout, render_frame(f.area, f.buffer))

    Tachikoma.render(tabs, tab_area, f.buffer)
    render_corner_logo(m, tab_area, f.buffer)
    if splash_active(m)
        # the startup screen also takes the rows of the status panel
        render_splash(m, Tachikoma.Rect(body_area.x, status_area.y, body_area.width, body_area.height + status_area.height), f.buffer)
    elseif !isnothing(m.production)
        render_production(m.production, m.snap, body_area, f.buffer; ticks = m.ticks)
    elseif m.page == 1
        render_setup(m.setup, m.snap, body_area, f.buffer)
    elseif m.page == 2
        render_graph(m.graph_page, m.snap, m.progress, body_area, f.buffer; grid = m.graph_page.disk ? m.history_page.grid : nothing)
    elseif m.page == 3
        render_workers(m.workers_page, m.snap, m.busy, m.messages, body_area, f.buffer)
    elseif m.page == 4
        render_progress(m.progress_page, m.progress, m.busy, m.step_msgs, body_area, f.buffer)
    elseif m.page == 5
        render_log(m.log_page, message_entries(m.messages), body_area, f.buffer; capacity = m.messages.capacity,
                   log_path = isnothing(m.snap) ? nothing : m.snap.log_path)
    elseif m.page == 6
        render_reports(m.reports_page, body_area, f.buffer)
    elseif m.page == 7
        render_history(m.history_page, body_area, f.buffer)
    elseif m.page == SYNC_PAGE
        draw_sync!(m, body_area, f.buffer)
    end
    splash_active(m) || render_status(m, status_area, f.buffer)
    sync_hint_bar = m.page == SYNC_PAGE ? sync_bar(m) : ((), false)
    hints = (!isnothing(m.production) ?
             (m.production.phase === :done ? PRODUCTION_DONE_HINTS : m.production.phase === :creating ? () : PRODUCTION_HINTS) :
             m.page == 1 ? SETUP_HINTS :
             m.page == 2 ? GRAPH_HINTS :
             m.page == 3 ?
             (!isnothing(m.workers_page.form) ? WORKERS_FORM_HINTS : isnothing(m.workers_page.editor) ? WORKERS_HINTS : WORKERS_EDIT_HINTS) :
             m.page == 4 ? (isnothing(m.progress_page.open) ? PROGRESS_HINTS : PROGRESS_OPEN_HINTS) :
             m.page == 5 ? LOG_HINTS :
             m.page == 6 ? (isnothing(m.reports_page.viewer_path) ? REPORTS_HINTS : REPORTS_OPEN_HINTS) :
             m.page == 7 ? (isnothing(m.history_page.viewer_path) ? HISTORY_HINTS : HISTORY_OPEN_HINTS) :
             m.page == SYNC_PAGE ? first(sync_hint_bar) : ())
    spans = Tuple{String,Tachikoma.Style}[]
    # `q` closes an open report instead of quitting and is text in the editor
    for (key, description) in (hints...,
                               (!isnothing(m.production) || m.page == SYNC_PAGE && last(sync_hint_bar) ||
                                m.page == 3 && (!isnothing(m.workers_page.editor) || !isnothing(m.workers_page.form)) ||
                                m.page == 6 && !isnothing(m.reports_page.viewer_path) ||
                                m.page == 7 && !isnothing(m.history_page.viewer_path) ? () : COMMON_HINTS)...)
        push!(spans, (" " * key, Tachikoma.tstyle(:warning, bold = true)), (" " * description * " ", Tachikoma.tstyle(:text_dim)))
    end
    put_spans!(f.buffer, keys_area.x, keys_area.y, Tachikoma.right(keys_area), spans)

    m.help && render_help(m, f.area, f.buffer)
    if m.dialog === :quit
        modal = Tachikoma.Modal(; title = processing(m) ? "Processing runs" : "Quit", message = quit_message(m), confirm_label = "",
                                cancel_label = "")
        Tachikoma.render(modal, f.area, f.buffer)
    end
    return nothing
end

"""
    JuLeAna.run_tui(parsed_args::AbstractDict; processors = PROCESSORS, loader)

Open the terminal user interface with the pages Setup, Graph, Workers, Progress, Log, Reports, History and Sync on
a [`DataflowController`](@ref) for the parsed command line options `parsed_args`, as
returned by [`JuLeAna.parse_commandline`](@ref). Returns `nothing` when the user quits.

The interface opens at once and loads the session in the background with
`loader(parsed_args)`. The default loader is [`setup_session`](@ref) without terminal
output and without starting workers: it reads the config and the LEGEND data and builds
the dependency graph. Log
messages of this process and the output of its workers are kept in a
[`JuLeAna.MessageBuffer`](@ref) instead of being printed; the newest warning or error is shown
in the status panel, and the error of a failed load stays there. This process also writes
its log file as in [`setup_session`](@ref). The previous global logger is restored when
the interface closes, and every worker allocation started from the interface is
cancelled (see [`CancelAll`](@ref)). A startup screen with the logo is shown until the session has loaded;
`?` lists the keys of the visible page. See [`JuLeAna.JuLeAnaTUI`](@ref) for the keys.
The log file records the thread setup (`Interface threads`) after the session has loaded.
"""
function run_tui(parsed_args::AbstractDict; processors::AbstractDict{Symbol} = PROCESSORS,
                 loader = args -> setup_session(args; console = false, start_workers = false))
    theme = tui_theme(something(get(parsed_args, "theme", nothing), load_theme_name()))
    messages = MessageBuffer()
    # The log file exists only once the session has loaded: log the thread setup then.
    default_threads, interactive_threads = Threads.nthreads(:default), Threads.nthreads(:interactive)
    loop_thread, loop_pool = Threads.threadid(), Threads.threadpool()
    function load(args)
        session = loader(args)
        # `setup_session` installs the file logger; keep the messages for the interface too
        global_logger() === messages || global_logger(TeeLogger(global_logger(), messages))
        @info "Interface threads" default_threads interactive_threads loop_thread loop_pool
        return session
    end
    ctrl = DataflowController(parsed_args; processors, loader = load)
    # a logger made before the interface writes to the terminal and would garble it
    previous = global_logger(messages)
    try
        run_app(JuLeAnaTUI(ctrl, messages), messages; theme)
    finally
        global_logger(previous)
        # allocations run in their own process groups and would outlive this process
        dispatch!(ctrl, CancelAll())
    end
    return nothing
end

# Run the interface loop on `m` with `theme`; the output of this process goes to `messages`.
# `kwargs` are passed on to `Tachikoma.app`.
function run_app(m::JuLeAnaTUI, messages::MessageBuffer; theme::Tachikoma.Theme = tui_theme(load_theme_name()), kwargs...)
    return with_theme(theme) do
        return Tachikoma.app(m; on_stdout = text -> append_output!(messages, :stdout, text),
                             on_stderr = text -> append_output!(messages, :stderr, text), kwargs...)
    end
end

# Call `f()` with `theme` as the active Tachikoma theme and restore the previous theme afterwards.
function with_theme(f, theme::Tachikoma.Theme)
    previous = Tachikoma.theme()
    Tachikoma.set_theme!(theme)
    try
        return f()
    finally
        Tachikoma.set_theme!(previous)
    end
end
