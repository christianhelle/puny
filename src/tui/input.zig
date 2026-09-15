const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");
const common = @import("input/common.zig");
const line_editor = @import("input/line_editor.zig");
const posix = @import("input/posix.zig");
const prompt_history = @import("../prompts/history.zig");
const prompts = @import("../prompts/prompts.zig");
const terminal = @import("terminal.zig");
const windows_impl = @import("input/windows.zig");

pub const ReadLineResult = common.ReadLineResult;

pub fn readLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
    history: ?*prompt_history.History,
) !ReadLineResult {
    line_alloc.clearRetainingCapacity();
    if (history) |h| h.resetNavigation();

    try stdout_writer.print("\n\n{s} ", .{prompts.prompt_text});
    try stdout_writer.flush();

    cancel.setRawMode(true) catch {
        // Terminal does not support raw mode (e.g., piped stdin). Fall back
        // to canonical single-line input; Esc cancellation is unavailable.
        return try common.readLineCanonical(io, stdout_writer, line_alloc, stdin_buffer);
    };
    defer cancel.setRawMode(false) catch {};

    var editor = line_editor.LineEditor.init(line_alloc, stdout_writer, history, terminal.terminalWidth());
    if (builtin.os.tag == .windows) {
        return try windows_impl.readLineWindows(allocator, io, &editor);
    } else {
        return try posix.readLinePosix(allocator, io, &editor);
    }
}

/// Reads a single line from stdin without printing a prompt, echoing input
/// itself in raw mode. Some terminals (Warp's ConPTY on Windows) never deliver
/// a line to a canonical-mode console read, so canonical input is only the
/// fallback when raw mode is unavailable (e.g., piped stdin).
/// Returns the line, or null on EOF, cancel, or interrupt.
pub fn readLineSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !?[]const u8 {
    line_alloc.clearRetainingCapacity();

    cancel.setRawMode(true) catch {
        return try readLineSimpleCanonical(io, line_alloc, stdin_buffer);
    };
    defer cancel.setRawMode(false) catch {};

    var editor = line_editor.LineEditor.init(line_alloc, stdout_writer, null, null);
    editor.mentions_enabled = false;
    const result = if (builtin.os.tag == .windows)
        try windows_impl.readLineWindows(allocator, io, &editor)
    else
        try posix.readLinePosix(allocator, io, &editor);

    return switch (result) {
        .submitted => |text| {
            try stdout_writer.writeAll("\r\n");
            try stdout_writer.flush();
            return text;
        },
        .cancelled, .interrupted, .eof => null,
    };
}

fn readLineSimpleCanonical(
    io: std.Io,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !?[]const u8 {
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
