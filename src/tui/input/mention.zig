const std = @import("std");
const line_editor = @import("./line_editor.zig");
const file_picker = @import("../file_picker.zig");

/// Builds a file-mention string ("@path") for insertion into the prompt.
pub fn buildMention(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '@');
    try out.appendSlice(allocator, path);
    return out.toOwnedSlice(allocator);
}

/// Opens the searchable file picker and, when the user selects a path,
/// inserts the resulting "@path" mention into the editor buffer.
pub fn insertMention(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *line_editor.LineEditor,
) !void {
    const path = (try file_picker.pickFile(allocator, io)) orelse {
        // The picker erased its own overlay; restore the prompt line. The
        // success path redraws via appendSlice, so only cancellation needs it.
        try editor.redraw();
        return;
    };
    const mention = try buildMention(allocator, path);
    defer allocator.free(mention);
    try editor.appendSlice(mention);
}

test "buildMention prefixes the path with @" {
    const out = try buildMention(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@src/main.zig", out);
}

test "buildMention preserves an empty path" {
    const out = try buildMention(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@", out);
}
