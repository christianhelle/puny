const std = @import("std");

const first_prompt_limit = 1024;

/// Truncates a first prompt preview to `first_prompt_limit` bytes without
/// splitting a UTF-8 code point. Prompts already within the limit are copied
/// unchanged.
pub fn truncateFirstPrompt(arena: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    var end = @min(prompt.len, first_prompt_limit);
    // Never cut a UTF-8 code point in half: if the limit lands on a
    // continuation byte, back up to the nearest leading byte so the truncated
    // slice stays valid. Prompts already within the limit are untouched.
    while (end < prompt.len and end > 0 and (prompt[end] & 0xC0) == 0x80) {
        end -= 1;
    }
    return arena.dupe(u8, prompt[0..end]);
}

/// A session id must be a non-empty path-safe component that is neither "."
/// nor "..", so a corrupted index can never direct file access outside the
/// sessions directory.
pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |c| {
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

test "truncateFirstPrompt stays within the limit and on a UTF-8 boundary" {
    const arena = std.testing.allocator;

    // Prompt within the limit is returned unchanged.
    const short = "hello";
    const short_out = try truncateFirstPrompt(arena, short);
    defer arena.free(short_out);
    try std.testing.expectEqualStrings(short, short_out);

    // A plain truncation keeps exactly first_prompt_limit bytes.
    const ascii = try std.fmt.allocPrint(arena, "{s}", .{"a" ** (first_prompt_limit + 10)});
    defer arena.free(ascii);
    const ascii_out = try truncateFirstPrompt(arena, ascii);
    defer arena.free(ascii_out);
    try std.testing.expectEqual(@as(usize, first_prompt_limit), ascii_out.len);

    // When the limit lands inside a multi-byte code point, back up to the
    // preceding boundary. The euro sign is 3 bytes (E2 82 AC).
    const long = try std.fmt.allocPrint(arena, "{s}\xE2\x82\xAC{s}", .{ "b" ** (first_prompt_limit - 1), "ccc" });
    defer arena.free(long);
    const long_out = try truncateFirstPrompt(arena, long);
    defer arena.free(long_out);
    try std.testing.expectEqual(@as(usize, first_prompt_limit - 1), long_out.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long_out));
}

test "isValidSessionId accepts path-safe ids" {
    try std.testing.expect(isValidSessionId("abc"));
    try std.testing.expect(isValidSessionId("a-b_c.d"));
    try std.testing.expect(isValidSessionId("9f8e7d6c"));
}

test "isValidSessionId rejects empty, dot, and path components" {
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("."));
    try std.testing.expect(!isValidSessionId(".."));
    try std.testing.expect(!isValidSessionId("a/b"));
    try std.testing.expect(!isValidSessionId("a\\b"));
    try std.testing.expect(!isValidSessionId("../etc"));
}

test "truncateFirstPrompt returns a prompt ending exactly at the limit unchanged" {
    const arena = std.testing.allocator;
    const prompt = try std.fmt.allocPrint(arena, "{s}", .{"c" ** first_prompt_limit});
    defer arena.free(prompt);
    const out = try truncateFirstPrompt(arena, prompt);
    defer arena.free(out);
    try std.testing.expectEqual(@as(usize, first_prompt_limit), out.len);
    try std.testing.expectEqualStrings(prompt, out);
}

test "truncateFirstPrompt returns an empty prompt unchanged" {
    const arena = std.testing.allocator;
    const out = try truncateFirstPrompt(arena, "");
    defer arena.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "truncateFirstPrompt keeps a multi-byte code point ending exactly at the limit" {
    const arena = std.testing.allocator;
    const prompt = try std.fmt.allocPrint(arena, "{s}\xE2\x82\xAC", .{"d" ** (first_prompt_limit - 3)});
    defer arena.free(prompt);
    const out = try truncateFirstPrompt(arena, prompt);
    defer arena.free(out);
    try std.testing.expectEqual(@as(usize, first_prompt_limit), out.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "isValidSessionId accepts dot-prefixed, unicode, and single-character ids" {
    try std.testing.expect(isValidSessionId(".hidden"));
    try std.testing.expect(isValidSessionId("..x"));
    try std.testing.expect(isValidSessionId("x"));
    try std.testing.expect(isValidSessionId("sessión"));
    try std.testing.expect(isValidSessionId("session:with:colons"));
}
