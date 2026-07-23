const std = @import("std");
const memory = @import("../memory.zig");

/// Reads `/proc/self/status` and returns resident (VmRSS) and private (VmData)
/// bytes for the current process.
pub fn getMemoryStats(allocator: std.mem.Allocator, io: std.Io) !memory.MemoryStats {
    _ = allocator;
    var buf: [16 * 1024]u8 = undefined;
    const data = try readFileToBuffer(io, "/proc/self/status", &buf);

    const rss_kb = try parseKbField(data, "VmRSS:");
    const data_kb = try parseKbField(data, "VmData:");

    return .{
        .resident = rss_kb * 1024,
        .private = data_kb * 1024,
    };
}

fn readFileToBuffer(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, buf);
    const reader = &file_reader.interface;
    var written: usize = 0;
    while (written < buf.len) {
        const bytes = reader.readSliceShort(buf[written..]) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
        };
        if (bytes == 0) break;
        written += bytes;
    }
    return buf[0..written];
}

fn parseKbField(data: []const u8, marker: []const u8) !u64 {
    const start = std.mem.indexOf(u8, data, marker) orelse return error.MissingProcField;
    const after_marker = data[start + marker.len ..];

    var i: usize = 0;
    while (i < after_marker.len and (after_marker[i] == ' ' or after_marker[i] == '\t')) : (i += 1) {}
    const num_start = after_marker[i..];

    var j: usize = 0;
    while (j < num_start.len and num_start[j] != ' ' and num_start[j] != '\t' and
        num_start[j] != '\n' and num_start[j] != '\r') : (j += 1)
    {}
    const num_str = num_start[0..j];

    return try std.fmt.parseInt(u64, num_str, 10);
}

test "getMemoryStats returns positive values on Linux" {
    const result = try getMemoryStats(std.testing.allocator, std.testing.io);
    try std.testing.expect(result.resident > 0);
    try std.testing.expect(result.private > 0);
}
