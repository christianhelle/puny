const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const Io = std.Io;
const job_control = @import("job_control.zig");
const test_support = @import("../testing/test_support.zig");
const TypeAhead = @import("type_ahead.zig").TypeAhead;
const input_bar = @import("../tui/input_bar.zig");
const terminal = @import("../tui/terminal.zig");
const sigint = @import("sigint.zig");

/// What the user typed while the monitor owned stdin.
pub var typed: TypeAhead = .init(std.heap.smp_allocator);

/// True while a chat loop keeps the monitor running across its requests.
var held: bool = false;

/// Stderr for the monitor's hints while a chat loop holds it.
var loop_stderr_buffer: [128]u8 = undefined;
var loop_stderr: Io.File.Writer = undefined;
/// Set while the monitor runs, so raw mode leaves output processing on.
var monitor_mode: bool = false;

/// Keeps the monitor and the input bar up until `endLoop`, across every
/// request and tool call in between. Without a terminal this does nothing and
/// each request falls back to its own monitor.
pub fn beginLoop(io: Io) void {
    if (held) return;
    loop_stderr = .init(.stderr(), io, &loop_stderr_buffer);
    start(io, &loop_stderr.interface) catch return;
    held = true;
    enterBar();
}

pub fn endLoop() void {
    if (!held) return;
    leaveBar();
    held = false;
    stop();
}

/// Starts watching for cancellation for one provider request. Inside a held
/// loop the monitor is already up, and a cancel pressed during a tool call
/// must survive to stop this request.
pub fn beginRequest(io: Io, stderr_writer: *Io.Writer) void {
    if (held) return;
    reset();
    start(io, stderr_writer) catch {};
}

pub fn endRequest() void {
    if (!held) stop();
}

/// Hands the terminal to something that reads the keyboard itself, such as a
/// question picker, until `unpause`.
pub fn pause() void {
    if (!held) return;
    leaveBar();
    stopMonitor();
}

pub fn unpause() void {
    if (!held) return;
    startMonitor() catch return;
    enterBar();
}

fn enterBar() void {
    const rows = terminal.terminalHeight() orelse return;
    const cols = terminal.terminalWidth() orelse return;
    {
        input_bar.screen_lock.lock();
        defer input_bar.screen_lock.unlock();
        input_bar.global.enter(rows, cols) catch {};
    }
    syncBar(false);
}

fn leaveBar() void {
    input_bar.screen_lock.lock();
    defer input_bar.screen_lock.unlock();
    input_bar.global.leave() catch {};
}

fn barWanted() bool {
    input_bar.screen_lock.lock();
    defer input_bar.screen_lock.unlock();
    return input_bar.global.wanted;
}

fn barActive() bool {
    input_bar.screen_lock.lock();
    defer input_bar.screen_lock.unlock();
    return input_bar.global.active;
}

/// Shows the current type-ahead state in the bar.
fn syncBar(hint: bool) void {
    if (!barActive()) return;
    var copy: [input_bar.InputBar.text_capacity]u8 = undefined;
    const view = typed.snapshot(&copy);
    input_bar.screen_lock.lock();
    defer input_bar.screen_lock.unlock();
    input_bar.global.draw(view.text, view.cursor, view.queued, hint) catch {};
}

/// Runs on the monitor's idle ticks: follows window resizes, and picks up
/// lines the chat loop took off the queue.
fn tick(first_esc_ts: ?Io.Timestamp) void {
    typed.settleEscape();
    if (!barWanted()) return;
    if (terminal.terminalHeight()) |rows| {
        if (terminal.terminalWidth()) |cols| {
            input_bar.screen_lock.lock();
            defer input_bar.screen_lock.unlock();
            const bar = &input_bar.global;
            if (!bar.active or rows != bar.rows or cols != bar.cols) bar.resize(rows, cols) catch {};
        }
    }
    syncBar(first_esc_ts != null);
}

/// Atomic flags shared between monitor thread and main thread.
var cancelled: std.atomic.Value(bool) = .{ .raw = false };
var running: std.atomic.Value(bool) = .{ .raw = false };
var monitor_thread: ?std.Thread = null;

/// Saved terminal state for restoration.
var saved_termios: if (is_windows) void else std.posix.termios = undefined;
var saved_console_mode: if (is_windows) u32 else void = undefined;
var saved_console_mode_valid: if (is_windows) bool else void = false;

/// Io handle for timestamps and sleeps. Set once before spawning the thread.
var global_io: Io = undefined;
/// Stderr writer from the caller, for printing hints that shouldn't
/// interleave with the AI stream on stdout.
var global_stderr: *Io.Writer = undefined;
/// Suspends the job when the monitor reads Ctrl+Z; tests substitute a fake.
var suspend_job: *const fn () void = suspendWithBar;

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

/// Returns true if a double-Escape cancellation has been triggered.
pub fn isCancelled() bool {
    return cancelled.load(.monotonic);
}

/// Resets cancellation flags. Call before starting a new turn.
pub fn reset() void {
    cancelled.store(false, .monotonic);
}

/// Marks the current operation as cancelled. Intended for tests and for
/// callers that need to trigger cancellation programmatically.
pub fn setCancelled() void {
    cancelled.store(true, .monotonic);
}

/// Start monitoring stdin for double-Escape. Takes an `io` handle for
/// timestamps and sleeps, plus a stderr writer for printing hints that
/// won't interleave with AI output on stdout. Saves terminal state,
/// switches to raw mode, and spawns a monitor thread.
pub fn start(io: Io, stderr_writer: *Io.Writer) !void {
    if (running.load(.monotonic)) return;
    global_io = io;
    global_stderr = stderr_writer;
    cancelled.store(false, .monotonic);
    try startMonitor();
}

fn startMonitor() !void {
    if (running.load(.monotonic)) return;
    running.store(true, .monotonic);
    errdefer running.store(false, .monotonic);
    monitor_mode = true;
    errdefer monitor_mode = false;
    try setRawMode(true);
    if (!is_windows) typed.setEraseIsCtrlH(eraseIsCtrlH());
    monitor_thread = try std.Thread.spawn(.{}, monitorThread, .{});
}

/// Stop the monitor thread, join it, and restore terminal state.
pub fn stop() void {
    if (!running.load(.monotonic)) return;
    stopMonitor();
    cancelled.store(false, .monotonic);
}

fn stopMonitor() void {
    if (!running.load(.monotonic)) return;
    running.store(false, .monotonic);
    if (monitor_thread) |t| {
        t.join();
        monitor_thread = null;
    }
    setRawMode(false) catch {};
    monitor_mode = false;
}

// ── Platform-specific: raw mode ──────────────────────────────────────

pub fn setRawMode(enable: bool) !void {
    if (is_windows) {
        return setRawModeWindows(enable);
    } else {
        return setRawModePosix(enable);
    }
}

/// Raw input settings for `base`. The monitor keeps output processing on,
/// because everything printed during a chat loop relies on it.
fn rawTermios(base: std.posix.termios, keep_output: bool) std.posix.termios {
    var raw = base;
    // cfmakeraw(3): put terminal into raw mode
    raw.iflag.IGNBRK = true;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = keep_output;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    return raw;
}

fn setRawModePosix(enable: bool) !void {
    const posix = std.posix;
    if (enable) {
        const current = try posix.tcgetattr(0);
        saved_termios = current;
        const raw = rawTermios(current, monitor_mode);
        try posix.tcsetattr(0, .NOW, raw);
    } else {
        posix.tcsetattr(0, .NOW, saved_termios) catch {};
    }
}

/// Suspends the job from a raw-mode input loop that read Ctrl+Z itself. The
/// terminal gets its saved mode back while the job is stopped, and raw mode
/// returns once the shell continues it.
pub fn suspendJob() void {
    setRawMode(false) catch {};
    job_control.stop();
    setRawMode(true) catch {};
}

/// Suspends from the monitor, giving the shell back a whole screen meanwhile.
fn suspendWithBar() void {
    suspendAround(suspendJob, enterBar);
}

/// One-shot runs and per-request monitors have no bar, and nothing would take
/// down one created here, so only a bar that was wanted comes back.
fn suspendAround(stop_job: *const fn () void, restore: *const fn () void) void {
    const had_bar = barWanted();
    leaveBar();
    stop_job();
    if (had_bar) restore();
}

/// True when the terminal's erase character, saved when raw mode was last
/// enabled, is ^H. Backspace then sends 0x08 itself, so 0x08 cannot mean
/// Ctrl+Backspace.
pub fn eraseIsCtrlH() bool {
    if (is_windows) return false;
    return saved_termios.cc[@backingInt(std.posix.V.ERASE)] == 0x08;
}

fn setRawModeWindows(enable: bool) !void {
    const hStdin = getStdinHandle();
    if (enable) {
        var mode: windows.DWORD = undefined;
        if (windows.GetConsoleMode(hStdin, &mode) == .FALSE) return error.Unexpected;
        saved_console_mode = mode;
        saved_console_mode_valid = true;
        mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
        mode |= ENABLE_WINDOW_INPUT;
        if (windows.SetConsoleMode(hStdin, mode) == .FALSE) return error.Unexpected;
    } else {
        if (saved_console_mode_valid) {
            if (windows.SetConsoleMode(hStdin, saved_console_mode) == .FALSE) {}
        }
    }
}

// ── Platform-specific: monitor thread ────────────────────────────────

fn monitorThread() void {
    if (is_windows) {
        monitorThreadWindows();
    } else {
        monitorThreadPosix();
    }
}

fn monitorThreadPosix() void {
    const posix = std.posix;
    var buf: [1]u8 = undefined;
    var first_esc_ts: ?Io.Timestamp = null;

    while (running.load(.monotonic)) {
        var pfd = [1]posix.pollfd{
            .{ .fd = 0, .events = posix.POLL.IN, .revents = undefined },
        };
        const rc = posix.poll(&pfd, 50) catch break;
        if (rc == 0) {
            tick(first_esc_ts);
            continue;
        }
        if (pfd[0].revents & posix.POLL.IN == 0) continue;

        const n = posix.read(0, buf[0..]) catch break;
        if (n == 0) break;

        handleKeyByte(buf[0], &first_esc_ts);
    }
}

fn monitorThreadWindows() void {
    const hStdin = getStdinHandle();
    var first_esc_ts: ?Io.Timestamp = null;

    while (running.load(.monotonic)) {
        var events_avail: windows.DWORD = 0;
        if (windows.GetNumberOfConsoleInputEvents(hStdin, &events_avail) == .FALSE) break;

        if (events_avail > 0) {
            var record: windows.INPUT_RECORD = undefined;
            var events_read: windows.DWORD = 0;
            if (windows.ReadConsoleInputW(hStdin, &record, 1, &events_read) == .FALSE) break;
            if (events_read > 0 and
                record.EventType == windows.KEY_EVENT)
            {
                const bKeyDown = record.Event.KeyEvent.bKeyDown;
                if (bKeyDown != .FALSE) {
                    const vk = record.Event.KeyEvent.wVirtualKeyCode;
                    if (vk == windows.VK_ESCAPE) {
                        handleFirstEscape(&first_esc_ts);
                    } else {
                        first_esc_ts = null;
                        const modifiers = record.Event.KeyEvent.dwControlKeyState;
                        const ctrl = modifiers & (windows.LEFT_CTRL_PRESSED | windows.RIGHT_CTRL_PRESSED) != 0;
                        if (ctrl and record.Event.KeyEvent.uChar.UnicodeChar == 0x03) handleInterrupt();
                        typed.feedWindowsKey(.{
                            .virtual_key = vk,
                            .char = record.Event.KeyEvent.uChar.UnicodeChar,
                            .ctrl = ctrl,
                            .alt = modifiers & (windows.LEFT_ALT_PRESSED | windows.RIGHT_ALT_PRESSED) != 0,
                        });
                    }
                    syncBar(first_esc_ts != null);
                }
            }
        } else {
            tick(first_esc_ts);
            global_io.sleep(.{ .nanoseconds = @as(i96, @intCast(50 * std.time.ns_per_ms)) }, .awake) catch {};
        }
    }
}

// ── Escape detection logic ───────────────────────────────────────────

fn handleKeyByte(byte: u8, first_esc_ts: *?Io.Timestamp) void {
    typed.feed(byte);
    if (byte == 0x1b) {
        handleFirstEscape(first_esc_ts);
    } else {
        first_esc_ts.* = null;
        if (byte == 0x03) handleInterrupt();
        // Raw mode turns the terminal's suspend key off, so Ctrl+Z (0x1a)
        // stops the job here instead.
        if (byte == 0x1a) suspend_job();
    }
    syncBar(first_esc_ts.* != null);
}

/// Raw mode turns the terminal's interrupt key off, so Ctrl+C is read here and
/// acts as the signal would, stopping the work under way as well.
fn handleInterrupt() void {
    sigint.trigger();
    cancelled.store(true, .monotonic);
}

fn handleFirstEscape(first_esc_ts: *?Io.Timestamp) void {
    const now = Io.Timestamp.now(global_io, .awake);

    if (first_esc_ts.*) |first| {
        const elapsed = first.durationTo(now).nanoseconds;
        if (elapsed >= 0 and elapsed <= double_tap_window_ns) {
            cancelled.store(true, .monotonic);
            return;
        }
    }
    first_esc_ts.* = now;
    // With a bar up, `syncBar` shows the hint there.
    if (barActive()) return;
    global_stderr.print("\x1b[2m\n\n(Press Esc again to cancel)\n\x1b[0m\n", .{}) catch {};
    global_stderr.flush() catch {};
}

// ── Windows extern declarations ──────────────────────────────────────

const windows = if (is_windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;

    pub const VK_ESCAPE: u16 = 0x1B;
    pub const KEY_EVENT: u16 = 0x0001;
    pub const LEFT_CTRL_PRESSED: DWORD = 0x0008;
    pub const RIGHT_CTRL_PRESSED: DWORD = 0x0004;
    pub const RIGHT_ALT_PRESSED: DWORD = 0x0001;
    pub const LEFT_ALT_PRESSED: DWORD = 0x0002;

    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: BOOL,
        wRepeatCount: u16,
        wVirtualKeyCode: u16,
        wVirtualScanCode: u16,
        uChar: extern union {
            UnicodeChar: u16,
            AsciiChar: u8,
        },
        dwControlKeyState: DWORD,
    };

    pub const INPUT_RECORD = extern struct {
        EventType: u16,
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
        },
    };

    pub extern "kernel32" fn GetStdHandle(dwStdHandle: DWORD) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetNumberOfConsoleInputEvents(hConsoleInput: HANDLE, lpNumberOfEvents: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: *INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) BOOL;
} else void{};

fn getStdinHandle() windows.HANDLE {
    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
    return windows.GetStdHandle(STD_INPUT_HANDLE);
}

const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;
const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
const ENABLE_WINDOW_INPUT: u32 = 0x0008;

test "reset clears a pending cancellation" {
    reset();
    try std.testing.expect(!isCancelled());
    setCancelled();
    try std.testing.expect(isCancelled());
    reset();
    try std.testing.expect(!isCancelled());
}

test "setCancelled marks the operation as cancelled" {
    reset();
    setCancelled();
    try std.testing.expect(isCancelled());
    reset();
}

test "start returns immediately when the monitor is already running" {
    reset();
    running.store(true, .monotonic);
    defer running.store(false, .monotonic);

    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();

    try start(std.testing.io, &stderr_alloc.writer);
    try std.testing.expect(running.load(.monotonic));
}

test "stop without a monitor thread clears the cancelled flag" {
    reset();
    cancelled.store(true, .monotonic);
    running.store(true, .monotonic);
    defer running.store(false, .monotonic);
    monitor_thread = null;
    // When fd 0 is a TTY, restoring the saved termios must not corrupt the
    // caller's terminal, so save the current state before stopping.
    if (!is_windows) {
        saved_termios = std.posix.tcgetattr(0) catch std.mem.zeroes(std.posix.termios);
    }

    stop();

    try std.testing.expect(!running.load(.monotonic));
    try std.testing.expect(!isCancelled());
}

test "start and stop round-trip when a terminal is available" {
    reset();
    running.store(false, .monotonic);

    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();

    // On a machine with a TTY on fd 0 raw mode succeeds and the monitor
    // thread is spawned; stop() must restore the terminal. Without a TTY
    // start() fails and the running flag is rolled back by the errdefer.
    if (start(std.testing.io, &stderr_alloc.writer)) |_| {
        stop();
        try std.testing.expect(!running.load(.monotonic));
    } else |_| {
        try std.testing.expect(!running.load(.monotonic));
    }
    try std.testing.expect(!isCancelled());
}

test "double escape within the window cancels" {
    reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;

    var first_esc_ts: ?Io.Timestamp = null;
    handleKeyByte(0x1b, &first_esc_ts);
    try std.testing.expect(!isCancelled());
    try std.testing.expect(first_esc_ts != null);

    // Second escape arrives immediately, well inside the 500ms window.
    handleKeyByte(0x1b, &first_esc_ts);
    try std.testing.expect(isCancelled());
    reset();
}

test "non-escape input resets the pending first escape" {
    reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;

    var first_esc_ts: ?Io.Timestamp = null;
    handleKeyByte(0x1b, &first_esc_ts);
    try std.testing.expect(first_esc_ts != null);

    // Any other key discards the pending escape; a later escape starts fresh.
    handleKeyByte('x', &first_esc_ts);
    try std.testing.expect(first_esc_ts == null);
    handleKeyByte(0x1b, &first_esc_ts);
    try std.testing.expect(first_esc_ts != null);
    try std.testing.expect(!isCancelled());
}

test "first escape prints the press-esc-again hint" {
    reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;

    var first_esc_ts: ?Io.Timestamp = null;
    handleKeyByte(0x1b, &first_esc_ts);
    try std.testing.expect(std.mem.indexOf(u8, stderr_alloc.written(), "Press Esc again to cancel") != null);
    reset();
}

test "eraseIsCtrlH reports whether the saved erase character is ^H" {
    if (is_windows) return std.testing.expect(!eraseIsCtrlH());
    const original = saved_termios;
    defer saved_termios = original;
    saved_termios = std.mem.zeroes(std.posix.termios);

    saved_termios.cc[@backingInt(std.posix.V.ERASE)] = 0x08;
    try std.testing.expect(eraseIsCtrlH());
    saved_termios.cc[@backingInt(std.posix.V.ERASE)] = 0x7f;
    try std.testing.expect(!eraseIsCtrlH());
}

test "Ctrl+Z while a response streams suspends the job without cancelling" {
    reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;
    const FakeSuspend = struct {
        var count: usize = 0;
        fn suspendJob() void {
            count += 1;
        }
    };
    const original = suspend_job;
    defer suspend_job = original;
    suspend_job = FakeSuspend.suspendJob;

    var first_esc_ts: ?Io.Timestamp = null;
    handleKeyByte(0x1a, &first_esc_ts);

    try std.testing.expectEqual(@as(usize, 1), FakeSuspend.count);
    try std.testing.expect(!isCancelled());
}

test "keys typed while a response streams reach the type-ahead buffer" {
    reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try typed.takeAll(arena_state.allocator());

    var first_esc_ts: ?Io.Timestamp = null;
    for ("next step\r") |byte| handleKeyByte(byte, &first_esc_ts);

    const lines = try typed.takeLines(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("next step", lines[0]);
    try std.testing.expect(!isCancelled());
}

test "double escape still cancels and adds no typed text" {
    reset();
    defer reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try typed.takeAll(arena_state.allocator());

    var first_esc_ts: ?Io.Timestamp = null;
    handleKeyByte(0x1b, &first_esc_ts);
    handleKeyByte(0x1b, &first_esc_ts);

    try std.testing.expect(isCancelled());
    try std.testing.expectEqualStrings("", try typed.takeAll(arena_state.allocator()));
}

test "Ctrl+Z suspends without adding typed text" {
    reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;
    const FakeSuspend = struct {
        var count: usize = 0;
        fn suspendJob() void {
            count += 1;
        }
    };
    const original = suspend_job;
    defer suspend_job = original;
    suspend_job = FakeSuspend.suspendJob;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try typed.takeAll(arena_state.allocator());

    var first_esc_ts: ?Io.Timestamp = null;
    handleKeyByte(0x1a, &first_esc_ts);

    try std.testing.expectEqual(@as(usize, 1), FakeSuspend.count);
    try std.testing.expectEqualStrings("", try typed.takeAll(arena_state.allocator()));
}

test "the monitor keeps output processing on and the prompt turns it off" {
    if (is_windows) return;
    var base = std.mem.zeroes(std.posix.termios);
    base.oflag.OPOST = true;
    base.lflag.ICANON = true;

    const monitor = rawTermios(base, true);
    try std.testing.expect(monitor.oflag.OPOST);
    try std.testing.expect(!monitor.lflag.ICANON);

    const prompt = rawTermios(base, false);
    try std.testing.expect(!prompt.oflag.OPOST);
}

const BarFixture = struct {
    out: std.Io.Writer.Allocating,
    saved: input_bar.InputBar,

    fn init(self: *BarFixture) !void {
        self.out = .init(std.testing.allocator);
        self.saved = input_bar.global;
        input_bar.global = .{ .out = &self.out.writer };
        try input_bar.global.enter(24, 80);
        self.out.clearRetainingCapacity();
    }

    fn deinit(self: *BarFixture) void {
        input_bar.global = self.saved;
        self.out.deinit();
    }
};

test "a request inside a held loop leaves a pending cancel and the monitor alone" {
    reset();
    defer reset();
    held = true;
    defer held = false;
    running.store(true, .monotonic);
    defer running.store(false, .monotonic);
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();

    setCancelled();
    beginRequest(std.testing.io, &stderr_alloc.writer);
    try std.testing.expect(isCancelled());

    endRequest();
    try std.testing.expect(running.load(.monotonic));
    try std.testing.expect(isCancelled());
}

test "typing shows up in the bar" {
    reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try typed.takeAll(arena_state.allocator());
    var fixture: BarFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var first_esc_ts: ?Io.Timestamp = null;
    for ("hi") |byte| handleKeyByte(byte, &first_esc_ts);
    _ = try typed.takeAll(arena_state.allocator());

    try std.testing.expect(std.mem.indexOf(u8, fixture.out.written(), "> hi") != null);
}

test "the Esc hint goes to the bar instead of over the stream" {
    reset();
    defer reset();
    var stderr_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_alloc.deinit();
    global_io = std.testing.io;
    global_stderr = &stderr_alloc.writer;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try typed.takeAll(arena_state.allocator());
    var fixture: BarFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var first_esc_ts: ?Io.Timestamp = null;
    handleKeyByte(0x1b, &first_esc_ts);
    _ = try typed.takeAll(arena_state.allocator());

    try std.testing.expectEqualStrings("", stderr_alloc.written());
    try std.testing.expect(std.mem.indexOf(u8, fixture.out.written(), "Press Esc again to cancel") != null);
}

test "pausing a held loop takes the bar down" {
    held = true;
    defer held = false;
    running.store(false, .monotonic);
    var fixture: BarFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    pause();

    try std.testing.expect(!input_bar.global.active);
    try std.testing.expect(std.mem.indexOf(u8, fixture.out.written(), "\x1b[r") != null);
}

test "suspendJob stops the job and returns once it is continued" {
    try test_support.expectSuspends(suspendJob);
}

test "Ctrl+C interrupts while the monitor holds the keyboard" {
    global_io = std.testing.io;
    reset();
    sigint.clear();
    defer {
        reset();
        sigint.clear();
    }
    var first_esc_ts: ?Io.Timestamp = null;

    handleKeyByte(0x03, &first_esc_ts);

    try std.testing.expect(sigint.isTriggered());
    try std.testing.expect(isCancelled());
}

const FakeRestore = struct {
    var stopped: usize = 0;
    var restored: usize = 0;
    fn stop() void {
        stopped += 1;
    }
    fn restore() void {
        restored += 1;
    }
};

test "suspending brings the bar back only if one was wanted" {
    const saved = input_bar.global;
    defer input_bar.global = saved;
    input_bar.global = .{};
    FakeRestore.stopped = 0;
    FakeRestore.restored = 0;

    suspendAround(FakeRestore.stop, FakeRestore.restore);
    try std.testing.expectEqual(@as(usize, 1), FakeRestore.stopped);
    try std.testing.expectEqual(@as(usize, 0), FakeRestore.restored);

    input_bar.global.wanted = true;
    suspendAround(FakeRestore.stop, FakeRestore.restore);
    try std.testing.expectEqual(@as(usize, 1), FakeRestore.restored);
}
