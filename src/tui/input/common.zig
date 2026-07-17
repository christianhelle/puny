const std = @import("std");
const prompt_history = @import("../../prompts/history.zig");
const terminal = @import("../terminal.zig");

pub const ReadLineResult = union(enum) {
    submitted: []const u8,
    cancelled,
    interrupted,
    eof,
};

pub fn readLineCanonical(
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

pub fn appendAndEcho(byte: u8, line_alloc: *std.Io.Writer.Allocating, stdout_writer: *std.Io.Writer) !void {
    try line_alloc.writer.writeByte(byte);
    try stdout_writer.writeByte(byte);
    try stdout_writer.flush();
}

pub fn backspace(line_alloc: *std.Io.Writer.Allocating, stdout_writer: *std.Io.Writer) !void {
    const written = line_alloc.written();
    if (written.len == 0) return;
    line_alloc.shrinkRetainingCapacity(written.len - 1);
    try stdout_writer.writeAll(terminal.backspace_echo);
    try stdout_writer.flush();
}

pub fn historyPrevious(
    line_alloc: *std.Io.Writer.Allocating,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
) !void {
    const h = history orelse return;
    const current = line_alloc.written();
    const replacement = h.previous(current) orelse h.currentDraft() orelse return;
    try replaceLine(replacement, line_alloc, stdout_writer);
}

pub fn historyNext(
    line_alloc: *std.Io.Writer.Allocating,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
) !void {
    const h = history orelse return;
    const replacement = h.next() orelse h.currentDraft() orelse return;
    try replaceLine(replacement, line_alloc, stdout_writer);
}

pub fn replaceLine(
    text: []const u8,
    line_alloc: *std.Io.Writer.Allocating,
    stdout_writer: *std.Io.Writer,
) !void {
    line_alloc.clearRetainingCapacity();
    try line_alloc.writer.writeAll(text);

    try stdout_writer.writeAll(terminal.move_to_line_start);
    try stdout_writer.writeAll(terminal.clear_to_end_of_line);
    try stdout_writer.print("Prompt: {s}", .{text});
    try stdout_writer.flush();
}

test "replaceLine updates line_alloc and redraws prompt" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try line_alloc.writer.writeAll("old");
    try replaceLine("new", &line_alloc, &out.writer);

    try std.testing.expectEqualStrings("new", line_alloc.written());
    try std.testing.expectEqualStrings(
        terminal.move_to_line_start ++ terminal.clear_to_end_of_line ++ "Prompt: new",
        out.written(),
    );
}

test "historyPrevious and historyNext navigate entries" {
    const allocator = std.testing.allocator;
    var history = prompt_history.History.init(allocator, "");
    defer history.deinit();
    try history.add("first");
    try history.add("second");

    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try historyPrevious(&line_alloc, &out.writer, &history);
    try std.testing.expectEqualStrings("second", line_alloc.written());

    try historyPrevious(&line_alloc, &out.writer, &history);
    try std.testing.expectEqualStrings("first", line_alloc.written());

    try historyNext(&line_alloc, &out.writer, &history);
    try std.testing.expectEqualStrings("second", line_alloc.written());
}
