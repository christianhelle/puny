/// C0 control character byte values (0x00-0x1F) and DEL (0x7F).
///
/// Names follow the standard ASCII abbreviations so the code reads like a
/// terminal reference table instead of raw hex.
const std = @import("std");
const builtin = @import("builtin");

pub const control = struct {
    pub const nul: u8 = 0x00;
    pub const soh: u8 = 0x01;
    pub const stx: u8 = 0x02;
    pub const etx: u8 = 0x03; // Ctrl+C
    pub const eot: u8 = 0x04; // Ctrl+D
    pub const enq: u8 = 0x05;
    pub const ack: u8 = 0x06;
    pub const bel: u8 = 0x07;
    pub const bs: u8 = 0x08; // Backspace
    pub const ht: u8 = 0x09; // Tab
    pub const lf: u8 = 0x0a; // Line feed
    pub const vt: u8 = 0x0b;
    pub const ff: u8 = 0x0c;
    pub const cr: u8 = 0x0d; // Carriage return
    pub const so: u8 = 0x0e;
    pub const si: u8 = 0x0f;
    pub const dle: u8 = 0x10;
    pub const dc1: u8 = 0x11;
    pub const dc2: u8 = 0x12;
    pub const dc3: u8 = 0x13;
    pub const dc4: u8 = 0x14;
    pub const nak: u8 = 0x15;
    pub const syn: u8 = 0x16;
    pub const etb: u8 = 0x17;
    pub const can: u8 = 0x18;
    pub const em: u8 = 0x19;
    pub const sub: u8 = 0x1a;
    pub const esc: u8 = 0x1b; // Escape
    pub const fs: u8 = 0x1c;
    pub const gs: u8 = 0x1d;
    pub const rs: u8 = 0x1e;
    pub const us: u8 = 0x1f;
    pub const del: u8 = 0x7f; // Delete
};

/// Byte that begins a CSI escape sequence after ESC.
pub const csi_leader: u8 = '[';

/// Default timeout when waiting for the rest of an escape sequence.
pub const escape_sequence_timeout_ms = 50;

/// Characters sent to the terminal to erase the last displayed character.
pub const backspace_echo = "\x08 \x08";

/// Move the cursor to the start of the current line (CSI G).
pub const move_to_line_start = "\x1b[G";

/// Move the cursor up `n` lines without changing column (CSI A).
/// Use with `print(cursor_up, .{n})`.
pub const cursor_up = "\x1b[{d}A";

/// Move the cursor down `n` lines without changing column (CSI B).
/// Use with `print(cursor_down, .{n})`.
pub const cursor_down = "\x1b[{d}B";

/// Clear from the cursor to the end of the current line (CSI K).
pub const clear_to_end_of_line = "\x1b[K";

/// Clear the entire current line (CSI 2K).
pub const clear_line = "\x1b[2K";

/// Erase from cursor to end of display (CSI J).
pub const erase_display = "\x1b[J";

/// Returns true for C0 control characters that the prompt input loop ignores.
pub fn isIgnoredControlByte(byte: u8) bool {
    return switch (byte) {
        control.nul...control.stx,
        control.enq...control.bel,
        control.ht,
        control.vt...control.ff,
        control.so...control.sub,
        control.fs...control.us,
        => true,
        else => false,
    };
}

/// Print text to a writer, replacing bare `\n` with `\r\n` so the cursor
/// returns to column 0 in raw mode. Existing CRLF pairs are preserved.
/// Assumes `text` is a complete rendered blob: a trailing `\r` at the end of
/// one call is never combined with a leading `\n` from the next call.
pub fn writeWithCRLF(writer: *std.Io.Writer, text: []const u8) !void {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl_idx| {
        if (nl_idx > 0 and rest[nl_idx - 1] == '\r') {
            try writer.writeAll(rest[0 .. nl_idx + 1]);
            rest = rest[nl_idx + 1 ..];
        } else {
            try writer.writeAll(rest[0..nl_idx]);
            try writer.writeAll("\r\n");
            rest = rest[nl_idx + 1 ..];
        }
    }
    if (rest.len > 0) try writer.writeAll(rest);
}

test "writeWithCRLF replaces \\n with \\r\\n" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "Hello\nWorld\n");
    try std.testing.expectEqualStrings("Hello\r\nWorld\r\n", output.written());
}

test "writeWithCRLF passes text without newlines" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "Hello world");
    try std.testing.expectEqualStrings("Hello world", output.written());
}

test "writeWithCRLF handles empty text" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "");
    try std.testing.expectEqualStrings("", output.written());
}

test "writeWithCRLF handles multiple newlines" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "a\nb\nc\n");
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\n", output.written());
}

test "writeWithCRLF preserves existing CRLF" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "a\r\nb");
    try std.testing.expectEqualStrings("a\r\nb", output.written());
}

test "writeWithCRLF converts a leading newline" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "\nabc");
    try std.testing.expectEqualStrings("\r\nabc", output.written());
}

test "writeWithCRLF converts a lone newline" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "\n");
    try std.testing.expectEqualStrings("\r\n", output.written());
}

test "writeWithCRLF converts consecutive newlines" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "a\n\nb");
    try std.testing.expectEqualStrings("a\r\n\r\nb", output.written());
}

test "writeWithCRLF leaves lone carriage returns untouched" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeWithCRLF(&output.writer, "a\rb\nc");
    try std.testing.expectEqualStrings("a\rb\r\nc", output.written());
}

test "isIgnoredControlByte accepts ignored C0 ranges" {
    const ignored = [_]u8{
        control.nul, control.soh, control.stx, control.enq, control.ack,
        control.bel, control.ht,  control.vt,  control.ff,  control.so,
        control.dle, control.sub, control.fs,  control.us,
    };
    for (ignored) |b| {
        try std.testing.expect(isIgnoredControlByte(b));
    }
}

test "isIgnoredControlByte rejects meaningful control bytes" {
    const not_ignored = [_]u8{
        control.etx, control.eot, control.bs, control.lf, control.cr,
        control.esc, control.del, ' ',        'a',        '~',
        0xff,
    };
    for (not_ignored) |b| {
        try std.testing.expect(!isIgnoredControlByte(b));
    }
}

test "control byte constants match the ASCII table" {
    try std.testing.expectEqual(@as(u8, 0x1b), control.esc);
    try std.testing.expectEqual(@as(u8, 0x0d), control.cr);
    try std.testing.expectEqual(@as(u8, 0x0a), control.lf);
    try std.testing.expectEqual(@as(u8, 0x09), control.ht);
    try std.testing.expectEqual(@as(u8, 0x7f), control.del);
    try std.testing.expectEqual(@as(u8, 0x03), control.etx);
    try std.testing.expectEqual(@as(u8, 0x04), control.eot);
    try std.testing.expectEqual(@as(u8, '['), csi_leader);
    try std.testing.expectEqualStrings("\x08 \x08", backspace_echo);
}

/// Terminal window width in columns, when it can be determined.
pub fn terminalWidth() ?usize {
    if (comptime builtin.os.tag == .windows) {
        return windowsTerminalWidth();
    }
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return null;
    }
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    if (comptime builtin.os.tag == .linux) {
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
    } else {
        if (rc != 0) return null;
    }
    return if (ws.col > 0) ws.col else null;
}

fn windowsTerminalWidth() ?usize {
    const h = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (windows.GetConsoleScreenBufferInfo(h, &info) == .FALSE) return null;
    const w: i32 = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
    return if (w > 0) @intCast(w) else null;
}

/// Terminal window height in rows, when it can be determined.
pub fn terminalHeight() ?usize {
    if (comptime builtin.os.tag == .windows) {
        return windowsTerminalHeight();
    }
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return null;
    }
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    if (comptime builtin.os.tag == .linux) {
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
    } else {
        if (rc != 0) return null;
    }
    return if (ws.row > 0) ws.row else null;
}

fn windowsTerminalHeight() ?usize {
    const h = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (windows.GetConsoleScreenBufferInfo(h, &info) == .FALSE) return null;
    const rows: i32 = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
    return if (rows > 0) @intCast(rows) else null;
}

/// Request code for TIOCGWINSZ, per-OS.
const TIOCGWINSZ: c_int = switch (builtin.os.tag) {
    .linux => 0x5413,
    .macos => 0x40087468,
    else => 0,
};

const windows = if (builtin.os.tag == .windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const HANDLE = std.os.windows.HANDLE;
    pub const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

    pub const COORD = extern struct {
        X: i16,
        Y: i16,
    };

    pub const SMALL_RECT = extern struct {
        Left: i16,
        Top: i16,
        Right: i16,
        Bottom: i16,
    };

    pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };

    pub extern "kernel32" fn GetStdHandle(dwStdHandle: u32) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
} else void{};

test "terminalWidth returns a positive width or null" {
    const w = terminalWidth();
    if (w) |width| {
        try std.testing.expect(width >= 1);
    }
}

test "terminalHeight returns a positive height or null" {
    const h = terminalHeight();
    if (h) |height| {
        try std.testing.expect(height >= 1);
    }
}

test "writeWithCRLF converts a trailing newline when called out of line" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try @call(.never_inline, writeWithCRLF, .{ &output.writer, "one\ntwo\n" });
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", output.written());
}
