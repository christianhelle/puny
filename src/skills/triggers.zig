const std = @import("std");

/// Returns true when `text` contains `word` as a whole word. A hyphenated
/// `word` (e.g. `grill-me`) also matches when its hyphens are replaced by
/// spaces, so prose like "grill me" triggers a `grill-me` skill.
pub fn textContainsWord(text: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    if (wordAtBoundary(text, word)) return true;
    if (std.mem.indexOfScalar(u8, word, '-') != null and word.len <= 128) {
        var normalized_buf: [128]u8 = undefined;
        const normalized = normalizeHyphensToSpaces(&normalized_buf, word);
        if (wordAtBoundary(text, normalized)) return true;
    }
    return false;
}

fn wordAtBoundary(text: []const u8, word: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, word)) |match_pos| {
        if (match_pos > 0 and std.ascii.isAlphanumeric(text[match_pos - 1])) {
            search_from = match_pos + 1;
            continue;
        }
        const end = match_pos + word.len;
        if (end < text.len and std.ascii.isAlphanumeric(text[end])) {
            search_from = match_pos + 1;
            continue;
        }
        return true;
    }
    return false;
}

fn normalizeHyphensToSpaces(buf: *[128]u8, word: []const u8) []const u8 {
    for (word, 0..) |byte, i| {
        buf[i] = if (byte == '-') ' ' else byte;
    }
    return buf[0..word.len];
}

test "textContainsWord matches whole words" {
    try std.testing.expect(textContainsWord("hello world", "hello"));
    try std.testing.expect(textContainsWord("hello world", "world"));
    try std.testing.expect(!textContainsWord("hello world", "worl"));
    try std.testing.expect(!textContainsWord("hello world", "ello"));
    try std.testing.expect(textContainsWord("foo-bar baz", "foo-bar"));
    try std.testing.expect(!textContainsWord("hello", ""));
}

test "textContainsWord finds a later valid occurrence after a rejected one" {
    // The first "do it" sits inside "undo" (alphanumeric on its left); the
    // later standalone "do it" must still match.
    try std.testing.expect(textContainsWord("undo it, then do it", "do it"));
    try std.testing.expect(textContainsWord("do itty, do it", "do it"));
    try std.testing.expect(!textContainsWord("undo it", "do it"));
}

test "normalizeHyphensToSpaces converts hyphens for trigger matching" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("foo bar", normalizeHyphensToSpaces(&buf, "foo-bar"));
    try std.testing.expectEqualStrings("a b c", normalizeHyphensToSpaces(&buf, "a-b-c"));
    try std.testing.expectEqualStrings("plain", normalizeHyphensToSpaces(&buf, "plain"));
}
