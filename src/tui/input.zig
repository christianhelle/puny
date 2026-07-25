const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");
const common = @import("input/common.zig");
const posix = @import("input/posix.zig");
const prompt_history = @import("../prompts/history.zig");
const terminal = @import("terminal.zig");
const windows_impl = @import("input/windows.zig");

pub const ReadLineResult = common.ReadLineResult;

pub fn readLine(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_buffer: *std.ArrayList(u8),
    cursor: *usize,
    stdin_buffer: []u8,
    history: ?*prompt_history.History,
    allocator: std.mem.Allocator,
) !ReadLineResult {
    line_buffer.clearRetainingCapacity();
    cursor.* = 0;
    if (history) |h| h.resetNavigation();

    try stdout_writer.print("\n\nPrompt: ", .{});
    try stdout_writer.writeAll(terminal.save_cursor);
    try stdout_writer.flush();

    cancel.setRawMode(true) catch {
        return try common.readLineCanonical(io, stdout_writer, line_buffer, stdin_buffer, allocator);
    };
    defer cancel.setRawMode(false) catch {};

    if (builtin.os.tag == .windows) {
        return try windows_impl.readLineWindows(io, stdout_writer, line_buffer, cursor, history, allocator);
    } else {
        return try posix.readLinePosix(io, stdout_writer, line_buffer, cursor, history, allocator);
    }
}

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
