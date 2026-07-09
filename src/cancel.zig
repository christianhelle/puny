const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

/// Atomic flags shared between monitor thread and main thread.
var cancelled: std.atomic.Value(bool) = .{ .raw = false };
var first_esc_seen: std.atomic.Value(bool) = .{ .raw = false };
var running: std.atomic.Value(bool) = .{ .raw = false };

/// Platform-specific saved terminal state.
var saved_termios: if (is_windows) void else std.posix.termios = .{};
var saved_console_mode: if (is_windows) u32 else void = undefined;

/// Handle to the monitor thread, if running.
var monitor_thread: ?std.Thread = null;

const double_tap_window_ns: u64 = 500 * std.time.ns_per_ms;

/// Returns true if a double-Escape cancellation has been triggered.
pub fn isCancelled() bool {
    return cancelled.load(.monotonic);
}

/// Returns true if the first Escape of a potential double-tap was seen.
pub fn isFirstEscSeen() bool {
    return first_esc_seen.load(.monotonic);
}

/// Resets cancellation flags. Call before starting a new turn.
pub fn reset() void {
    cancelled.store(false, .monotonic);
    first_esc_seen.store(false, .monotonic);
}

/// Start monitoring stdin for double-Escape. Saves terminal state,
/// switches to raw mode, and spawns a monitor thread.
pub fn start() !void {
    if (running.load(.monotonic)) return;
    cancelled.store(false, .monotonic);
    first_esc_seen.store(false, .monotonic);
    running.store(true, .monotonic);
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
    setRawMode(false) catch {};
    cancelled.store(false, .monotonic);
    first_esc_seen.store(false, .monotonic);
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
        var raw: posix.termios = undefined;
        try posix.tcgetattr(0, &raw);
        saved_termios = raw;
        // cfmakeraw equivalent
        raw.iflag &= ~@as(std.os.linux.IFLAG, @bitCast(@as(u31, @bitCast(std.posix.IGNBRK | std.posix.BRKINT | std.posix.PARMRK | std.posix.ISTRIP | std.posix.INLCR | std.posix.IGNCR | std.posix.ICRNL | std.posix.IXON))));
        raw.oflag &= ~@as(std.os.linux.OFLAG, @bitCast(@as(u31, @bitCast(std.posix.OPOST))));
        raw.lflag &= ~@as(std.os.linux.LFLAG, @bitCast(@as(u31, @bitCast(std.posix.ECHO | std.posix.ECHONL | std.posix.ICANON | std.posix.ISIG | std.posix.IEXTEN))));
        raw.cflag &= ~@as(std.os.linux.CFLAG, @bitCast(@as(u31, @bitCast(std.posix.CSIZE | std.posix.PARENB))));
        raw.cflag |= @as(std.os.linux.CFLAG, @bitCast(@as(u31, @bitCast(std.posix.CS8))));
        raw.cc[posix.VMIN] = 1;
        raw.cc[posix.VTIME] = 0;
        try posix.tcsetattr(0, .NOW, &raw);
    } else {
        posix.tcsetattr(0, .NOW, &saved_termios) catch {};
    }
}

fn setRawModeWindows(enable: bool) !void {
    const windows = std.os.windows;
    const hStdin = windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    if (hStdin == windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
    if (enable) {
        var mode: windows.DWORD = undefined;
        if (windows.GetConsoleMode(hStdin, &mode) == 0) return error.Unexpected;
        saved_console_mode = mode;
        // Disable line input, echo, processed input — enable window input
        mode &= ~@as(windows.DWORD, windows.ENABLE_LINE_INPUT | windows.ENABLE_ECHO_INPUT | windows.ENABLE_PROCESSED_INPUT);
        mode |= windows.ENABLE_WINDOW_INPUT;
        if (windows.SetConsoleMode(hStdin, mode) == 0) return error.Unexpected;
    } else {
        if (windows.SetConsoleMode(hStdin, saved_console_mode) == 0) {}
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
    var first_esc_ts: ?u64 = null;

    while (running.load(.monotonic)) {
        var pfd = [1]posix.pollfd{
            .{ .fd = 0, .events = posix.POLL.IN, .revents = undefined },
        };
        const rc = posix.poll(&pfd, 50) catch |err| switch (err) {
            error.InvalidDesc, error.Unsupported => break,
        };
        if (rc == 0) continue; // timeout
        if (pfd[0].revents & posix.POLL.IN == 0) continue;

        const n = posix.read(0, &buf, 1) catch break;
        if (n == 0) break;

        handleKeyByte(buf[0], &first_esc_ts);
    }
    _ = posix.write(2, "\n" ++ ansi_hint_clear) catch {};
}

fn monitorThreadWindows() void {
    const windows = std.os.windows;
    const hStdin = windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    var first_esc_ts: ?u64 = null;

    while (running.load(.monotonic)) {
        var events_avail: windows.DWORD = 0;
        if (windows.PeekConsoleInputW(hStdin, null, 0, &events_avail) == 0) break;

        if (events_avail > 0) {
            var record: windows.INPUT_RECORD = undefined;
            var events_read: windows.DWORD = 0;
            if (windows.ReadConsoleInputW(hStdin, &record, 1, &events_read) == 0) break;
            if (events_read > 0 and
                record.EventType == windows.KEY_EVENT and
                record.Event.KeyEvent.bKeyDown)
            {
                if (record.Event.KeyEvent.wVirtualKeyCode == windows.VK_ESCAPE) {
                    handleFirstEscape(&first_esc_ts);
                } else {
                    first_esc_ts = null;
                }
            }
        } else {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }
}

// ── Escape detection logic ───────────────────────────────────────────

fn handleKeyByte(byte: u8, first_esc_ts: *?u64) void {
    if (byte == 0x1b) {
        handleFirstEscape(first_esc_ts);
    } else {
        first_esc_ts.* = null;
        first_esc_seen.store(false, .monotonic);
    }
}

fn handleFirstEscape(first_esc_ts: *?u64) void {
    const now = std.time.nanoTimestamp();
    const abs_now: u64 = @intCast(@as(u64, @bitCast(now)));

    if (first_esc_ts.*) |first| {
        if (abs_now -% first <= double_tap_window_ns) {
            cancelled.store(true, .monotonic);
            printStderr(ansi_cancelled);
            return;
        }
    }
    first_esc_ts.* = abs_now;
    first_esc_seen.store(true, .monotonic);
    printStderr(ansi_hint);
}

fn printStderr(msg: []const u8) void {
    if (is_windows) {
        const windows = std.os.windows;
        const hStderr = windows.GetStdHandle(windows.STD_ERROR_HANDLE);
        if (hStderr == windows.INVALID_HANDLE_VALUE) return;
        var written: windows.DWORD = 0;
        _ = windows.WriteFile(hStderr, msg.ptr, @intCast(msg.len), &written, null);
    } else {
        _ = std.posix.write(2, msg) catch {};
    }
}

const ansi_hint = "\x1b[2m(press Esc again to cancel)\x1b[0m\n";
const ansi_cancelled = "\x1b[2mCancelled.\x1b[0m\n";
const ansi_hint_clear = "\x1b[1A\x1b[K";
