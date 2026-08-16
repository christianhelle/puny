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

/// Returns true when typing '@' at the current cursor position should open
/// the file-mention picker. Mentions are recognized at the start of the line
/// or immediately after whitespace.
pub fn isTrigger(line: []const u8) bool {
    return line.len == 0 or std.ascii.isWhitespace(line[line.len - 1]);
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
    defer allocator.free(path);
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

test "buildMention prefixes a path when called out of line" {
    const out = try @call(.never_inline, buildMention, .{std.testing.allocator, "docs/api.md"});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@docs/api.md", out);
}

test "isTrigger true at start of line or after whitespace" {
    try std.testing.expect(isTrigger(""));
    try std.testing.expect(isTrigger("hello "));
    try std.testing.expect(isTrigger("hello\t"));
}

test "isTrigger false after non-whitespace" {
    try std.testing.expect(!isTrigger("hello"));
    try std.testing.expect(!isTrigger("a@b"));
    try std.testing.expect(!isTrigger("user@example.com"));
}
