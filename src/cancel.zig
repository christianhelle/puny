const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const Io = std.Io;

/// Atomic flags shared between monitor thread and main thread.
var cancelled: std.atomic.Value(bool) = .{ .raw = false };
var first_esc_seen: std.atomic.Value(bool) = .{ .raw = false };
var running: std.atomic.Value(bool) = .{ .raw = false };
var monitor_thread: ?std.Thread = null;

/// Saved terminal state for restoration.
var saved_termios: if (is_windows) void else std.posix.termios = undefined;
var saved_termios_valid: if (is_windows) void else bool = false;
var saved_console_mode: if (is_windows) u32 else void = undefined;
var saved_console_mode_valid: if (is_windows) bool else void = false;

/// Io handle for timestamps and sleeps. Set once before spawning the thread.
var global_io: Io = undefined;
/// Stderr writer from the caller, for printing hints that shouldn't
/// interleave with the AI stream on stdout.
var global_stderr: *Io.Writer = undefined;

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

/// Returns true if a double-Escape cancellation has been triggered.
pub fn isCancelled() bool {
    return cancelled.load(.monotonic);
}

/// Resets cancellation flags. Call before starting a new turn.
pub fn reset() void {
    cancelled.store(false, .monotonic);
    first_esc_seen.store(false, .monotonic);
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
    first_esc_seen.store(false, .monotonic);
    running.store(true, .monotonic);
    errdefer running.store(false, .monotonic);
    try setRawMode(true);
    monitor_thread = try std.Thread.spawn(.{}, monitorThread, .{});
}

/// Stop the monitor thread, join it, and restore terminal state.
pub fn stop() void {
    if (!running.load(.monotonic)) return;
    running.store(false, .monotonic);
    if (monitor_thread) |t| {
        t.join();
        monitor_thread = null;
    }
    restoreConsole();
    cancelled.store(false, .monotonic);
    first_esc_seen.store(false, .monotonic);
}

/// Restore console mode unconditionally, even if cancel is not running.
/// This ensures clean console state before launching the model picker,
/// recovering from cases where a previous `stop()` restore failed silently.
/// Windows-only: ConPTY pipe disconnection race with zigzag terminal setup.
pub fn restoreConsole() void {
    if (is_windows) {
        if (saved_console_mode_valid) {
            const hStdin = getStdinHandle();
            if (windows.SetConsoleMode(hStdin, saved_console_mode) != .FALSE) {
                saved_console_mode_valid = false;
            }
        }
    } else {
        if (saved_termios_valid) {
            setRawMode(false) catch {};
        }
    }
}

// ── Platform-specific: raw mode ──────────────────────────────────────

fn setRawMode(enable: bool) !void {
    if (is_windows) {
        return setRawModeWindows(enable);
    } else {
        return setRawModePosix(enable);
    }
}

fn setRawModePosix(enable: bool) !void {
    const posix = std.posix;
    if (enable) {
        var raw = try posix.tcgetattr(0);
        saved_termios = raw;
        saved_termios_valid = true;
        // cfmakeraw(3): put terminal into raw mode
        raw.iflag.IGNBRK = true;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(0, .NOW, &raw);
    } else {
        posix.tcsetattr(0, .NOW, &saved_termios) catch {};
    }
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
        const rc = posix.poll(&pfd, 50) catch |err| switch (err) {
            error.InvalidDesc, error.Unsupported => break,
        };
        if (rc == 0) continue;
        if (pfd[0].revents & posix.POLL.IN == 0) continue;

        const n = posix.read(0, &buf, 1) catch break;
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
                        first_esc_seen.store(false, .monotonic);
                    }
                }
            }
        } else {
            global_io.sleep(.{ .nanoseconds = @as(i96, @intCast(50 * std.time.ns_per_ms)) }, .awake) catch {};
        }
    }
}

// ── Escape detection logic ───────────────────────────────────────────

fn handleKeyByte(byte: u8, first_esc_ts: *?Io.Timestamp) void {
    if (byte == 0x1b) {
        handleFirstEscape(first_esc_ts);
    } else {
        first_esc_ts.* = null;
        first_esc_seen.store(false, .monotonic);
    }
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
    first_esc_seen.store(true, .monotonic);
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
