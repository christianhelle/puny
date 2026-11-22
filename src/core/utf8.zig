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

/// Length of `bytes` without a code point its end cuts short, as when the
/// bytes after it were dropped. Bytes that were not valid UTF-8 to begin with
/// are left as they are.
pub fn completeLen(bytes: []const u8) usize {
    var lead = bytes.len;
    var looked: usize = 0;
    while (lead > 0 and looked < 4) : (looked += 1) {
        lead -= 1;
        if ((bytes[lead] & 0xC0) != 0x80) break;
    } else return bytes.len;
    const byte = bytes[lead];
    const sequence_len: usize =
        if (byte < 0xC0) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
    const end = if (lead + sequence_len > bytes.len) lead else bytes.len;
    std.debug.assert(end <= bytes.len);
    std.debug.assert(bytes.len - end < 4);
    return end;
}

test "completeLen keeps whole code points and drops a cut one" {
    const text = "a\u{00e9}\u{20ac}"; // 1 + 2 + 3 bytes
    try std.testing.expectEqual(@as(usize, 6), completeLen(text));
    try std.testing.expectEqual(@as(usize, 3), completeLen(text[0..5]));
    try std.testing.expectEqual(@as(usize, 3), completeLen(text[0..4]));
    try std.testing.expectEqual(@as(usize, 3), completeLen(text[0..3]));
    try std.testing.expectEqual(@as(usize, 1), completeLen(text[0..2]));
    try std.testing.expectEqual(@as(usize, 0), completeLen(""));
    try std.testing.expectEqual(@as(usize, 4), completeLen("\x80\x80\x80\x80"));
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
