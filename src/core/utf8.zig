const std = @import("std");

/// Returns the longest prefix of `bytes` that is at most `max_len` bytes long
/// and does not end inside a UTF-8 code point. Text cut for a size limit
/// stays valid UTF-8 as long as the input was.
pub fn prefix(bytes: []const u8, max_len: usize) []const u8 {
    if (bytes.len <= max_len) return bytes;
    var end = max_len;
    // A continuation byte at `end` means the code point starting before it
    // would be split, so back up to that code point's leading byte.
    while (end > 0 and (bytes[end] & 0xC0) == 0x80) end -= 1;
    std.debug.assert(end <= max_len);
    std.debug.assert(end == 0 or (bytes[end] & 0xC0) != 0x80);
    return bytes[0..end];
}

test "prefix returns input within the limit unchanged" {
    try std.testing.expectEqualStrings("abc", prefix("abc", 3));
    try std.testing.expectEqualStrings("abc", prefix("abc", 10));
    try std.testing.expectEqualStrings("", prefix("", 0));
}

test "prefix cuts ASCII at the limit" {
    try std.testing.expectEqualStrings("ab", prefix("abcdef", 2));
    try std.testing.expectEqualStrings("", prefix("abcdef", 0));
}

test "prefix never splits a multi-byte code point" {
    const text = "a\u{00e9}\u{20ac}"; // 1 + 2 + 3 bytes
    try std.testing.expectEqualStrings("a", prefix(text, 1));
    try std.testing.expectEqualStrings("a", prefix(text, 2));
    try std.testing.expectEqualStrings("a\u{00e9}", prefix(text, 3));
    try std.testing.expectEqualStrings("a\u{00e9}", prefix(text, 5));
    try std.testing.expectEqualStrings(text, prefix(text, 6));
}
