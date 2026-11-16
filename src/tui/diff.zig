const std = @import("std");

/// Splits `text` on '\n', stripping a trailing '\r' from each line and
/// dropping the empty piece after a final newline. Slices point into `text`.
pub fn splitLines(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        var line = text[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try lines.append(allocator, line);
        start = end + 1;
    }
    return lines.toOwnedSlice(allocator);
}

test "splitLines splits on newlines" {
    const lines = try splitLines(std.testing.allocator, "a\nb\nc");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("c", lines[2]);
}

test "splitLines drops the empty piece after a trailing newline" {
    const lines = try splitLines(std.testing.allocator, "a\nb\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "splitLines keeps interior blank lines" {
    const lines = try splitLines(std.testing.allocator, "a\n\nb\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("", lines[1]);
}

test "splitLines strips carriage returns" {
    const lines = try splitLines(std.testing.allocator, "a\r\nb\r\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
}

test "splitLines of empty text has no lines" {
    const lines = try splitLines(std.testing.allocator, "");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}
