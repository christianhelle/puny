/// C0 control character byte values (0x00-0x1F) and DEL (0x7F).
///
/// Names follow the standard ASCII abbreviations so the code reads like a
/// terminal reference table instead of raw hex.
const std = @import("std");

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
pub fn writeWithCRLF(writer: *std.Io.Writer, text: []const u8) !void {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl_idx| {
        if (nl_idx > 0 and rest[nl_idx - 1] == '\r') {
            try writer.print("{s}", .{rest[0 .. nl_idx + 1]});
            rest = rest[nl_idx + 1 ..];
        } else {
            try writer.print("{s}\r\n", .{rest[0..nl_idx]});
            rest = rest[nl_idx + 1 ..];
        }
    }
    if (rest.len > 0) try writer.print("{s}", .{rest});
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
