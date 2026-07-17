const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");
const common = @import("input/common.zig");
const posix = @import("input/posix.zig");
const prompt_history = @import("../prompts/history.zig");
const windows_impl = @import("input/windows.zig");

pub const ReadLineResult = common.ReadLineResult;

pub fn readLine(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
    history: ?*prompt_history.History,
) !ReadLineResult {
    line_alloc.clearRetainingCapacity();
    if (history) |h| h.resetNavigation();

    try stdout_writer.print("\n\nPrompt: ", .{});
    try stdout_writer.flush();

    cancel.setRawMode(true) catch {
        // Terminal does not support raw mode (e.g., piped stdin). Fall back
        // to canonical single-line input; Esc cancellation is unavailable.
        return try common.readLineCanonical(io, stdout_writer, line_alloc, stdin_buffer);
    };
    defer cancel.setRawMode(false) catch {};

    if (builtin.os.tag == .windows) {
        return try windows_impl.readLineWindows(io, stdout_writer, line_alloc, history);
    } else {
        return try posix.readLinePosix(io, stdout_writer, line_alloc, history);
    }
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
