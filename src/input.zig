const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("cancel.zig");
const sigint = @import("sigint.zig");
const terminal = @import("terminal.zig");

pub const ReadLineResult = union(enum) {
    submitted: []const u8,
    cancelled,
    interrupted,
    eof,
};

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

pub fn readLine(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !ReadLineResult {
    line_alloc.clearRetainingCapacity();

    try stdout_writer.print("\n\nPrompt: ", .{});
    try stdout_writer.flush();

    cancel.setRawMode(true) catch {
        // Terminal does not support raw mode (e.g., piped stdin). Fall back
        // to canonical single-line input; Esc cancellation is unavailable.
        return try readLineCanonical(io, stdout_writer, line_alloc, stdin_buffer);
    };
    defer cancel.setRawMode(false) catch {};

    if (builtin.os.tag == .windows) {
        return try readLineWindows(io, stdout_writer, line_alloc);
    } else {
        return try readLinePosix(io, stdout_writer, line_alloc);
    }
}

fn readLineCanonical(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !ReadLineResult {
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    const bytes_read = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {
            try stdout_writer.print("\nInput too long (max {d} bytes).\n", .{stdin_buffer.len});
            return .eof;
        },
        else => return err,
    };
    if (bytes_read == 0) return .eof;

    const raw_message = line_alloc.written();
    const result = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r')
        raw_message[0 .. raw_message.len - 1]
    else
        raw_message;
    return .{ .submitted = result };
}

/// Reads a single line from stdin in canonical mode without printing a prompt.
/// Returns the trimmed line, or null on EOF/empty input.
pub fn readLineSimple(
    io: std.Io,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !?[]const u8 {
    line_alloc.clearRetainingCapacity();

    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    const bytes_read = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {
            return line_alloc.written();
        },
        else => return err,
    };
    if (bytes_read == 0) return null;

    const raw_message = line_alloc.written();
    const result = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r')
        raw_message[0 .. raw_message.len - 1]
    else
        raw_message;
    return result;
}

fn readLinePosix(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
) !ReadLineResult {
    const posix = std.posix;
    var first_esc_ts: ?std.Io.Timestamp = null;
    var buf: [1]u8 = undefined;

    while (true) {
        const n = posix.read(0, &buf) catch return error.ReadFailed;
        if (n == 0) return .eof;

        const byte = buf[0];
        switch (byte) {
            '\r', '\n' => {
                first_esc_ts = null;
                return .{ .submitted = line_alloc.written() };
            },
            terminal.control.bs, terminal.control.del => {
                first_esc_ts = null;
                try backspace(line_alloc, stdout_writer);
            },
            terminal.control.etx => {
                sigint.trigger();
                return .interrupted;
            },
            terminal.control.eot => {
                first_esc_ts = null;
                return .cancelled;
            },
            terminal.control.esc => {
                // Try to interpret an escape sequence (arrow keys, etc.).
                // If nothing follows within a short window, treat as Esc.
                if (try readByteWithTimeout(terminal.escape_sequence_timeout_ms)) |next| {
                    first_esc_ts = null;
                    if (next == terminal.csi_leader) {
                        // CSI sequence: consume parameter bytes and the final byte.
                        while (true) {
                            const param = try readByteWithTimeout(terminal.escape_sequence_timeout_ms) orelse break;
                            if (!std.ascii.isDigit(param) and param != ';') break;
                        }
                        continue;
                    }
                    // Not a recognized escape sequence; inject the byte as input.
                    try appendAndEcho(next, line_alloc, stdout_writer);
                    continue;
                }

                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) return .cancelled;
                }
                first_esc_ts = now;
            },
            else => if (terminal.isIgnoredControlByte(byte)) {
                first_esc_ts = null;
            } else {
                first_esc_ts = null;
                try appendAndEcho(byte, line_alloc, stdout_writer);
            },
        }
    }
}

fn readByteWithTimeout(timeout_ms: i32) !?u8 {
    const posix = std.posix;
    var pfd = [1]posix.pollfd{
        .{ .fd = 0, .events = posix.POLL.IN, .revents = undefined },
    };
    const rc = posix.poll(&pfd, timeout_ms) catch return error.ReadFailed;
    if (rc == 0) return null;
    if (pfd[0].revents & posix.POLL.IN == 0) return null;
    var buf: [1]u8 = undefined;
    const n = posix.read(0, &buf) catch return error.ReadFailed;
    if (n == 0) return null;
    return buf[0];
}

fn readLineWindows(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
) !ReadLineResult {
    if (comptime builtin.os.tag != .windows) unreachable;

    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
    const hStdin = windows.GetStdHandle(STD_INPUT_HANDLE);
    var first_esc_ts: ?std.Io.Timestamp = null;

    while (true) {
        var record: windows.INPUT_RECORD = undefined;
        var events_read: windows.DWORD = 0;
        if (windows.ReadConsoleInputW(hStdin, &record, 1, &events_read) == .FALSE) return error.ReadFailed;
        if (events_read == 0) continue;
        if (record.EventType != windows.KEY_EVENT) continue;
        if (record.Event.KeyEvent.bKeyDown == .FALSE) continue;

        const key_event = record.Event.KeyEvent;
        const vk = key_event.wVirtualKeyCode;
        const ctrl = (key_event.dwControlKeyState & (windows.LEFT_CTRL_PRESSED | windows.RIGHT_CTRL_PRESSED)) != 0;

        switch (vk) {
            windows.VK_RETURN => {
                first_esc_ts = null;
                return .{ .submitted = line_alloc.written() };
            },
            windows.VK_BACK => {
                first_esc_ts = null;
                try backspace(line_alloc, stdout_writer);
            },
            windows.VK_ESCAPE => {
                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) return .cancelled;
                }
                first_esc_ts = now;
            },
            else => {
                first_esc_ts = null;
                const ch = key_event.uChar.UnicodeChar;
                if (ch == 3 and ctrl) {
                    sigint.trigger();
                    return .interrupted;
                }
                if (ch >= 32 and ch < 127) {
                    try appendAndEcho(@intCast(ch), line_alloc, stdout_writer);
                }
            },
        }
    }
}

fn appendAndEcho(byte: u8, line_alloc: *std.Io.Writer.Allocating, stdout_writer: *std.Io.Writer) !void {
    try line_alloc.writer.writeByte(byte);
    try stdout_writer.writeByte(byte);
    try stdout_writer.flush();
}

fn backspace(line_alloc: *std.Io.Writer.Allocating, stdout_writer: *std.Io.Writer) !void {
    const written = line_alloc.written();
    if (written.len == 0) return;
    line_alloc.shrinkRetainingCapacity(written.len - 1);
    try stdout_writer.writeAll(terminal.backspace_echo);
    try stdout_writer.flush();
}

const windows = if (builtin.os.tag == .windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;

    pub const VK_RETURN: u16 = 0x0D;
    pub const VK_BACK: u16 = 0x08;
    pub const VK_ESCAPE: u16 = 0x1B;
    pub const KEY_EVENT: u16 = 0x0001;
    pub const LEFT_CTRL_PRESSED: DWORD = 0x0008;
    pub const RIGHT_CTRL_PRESSED: DWORD = 0x0004;

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
    pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: *INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) BOOL;
} else void{};

