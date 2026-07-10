const std = @import("std");

pub fn readLine(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !?[]const u8 {
    line_alloc.clearRetainingCapacity();

    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    try stdout_writer.print("\n\nPrompt: ", .{});
    try stdout_writer.flush();

    const bytes_read = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {
            try stdout_writer.print("\nInput too long (max {d} bytes).\n", .{stdin_buffer.len});
            return null;
        },
        else => return err,
    };
    if (bytes_read == 0) return null;

    const raw_message = line_alloc.written();
    return if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r')
        raw_message[0 .. raw_message.len - 1]
    else
        raw_message;
}
