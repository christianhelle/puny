const std = @import("std");

/// Formats a token count: exact below 10,000, one-decimal `k` notation at
/// 10,000 and above. Writes into `buf` (which must be large enough) and
/// returns a slice of it.
pub fn formatTokens(buf: []u8, n: i64) []const u8 {
    const abs_n: u64 = @intCast(@abs(n));
    if (abs_n < 10_000) {
        return std.fmt.bufPrint(buf, "{d}", .{abs_n}) catch buf[0..0];
    }
    const value: f64 = @floatFromInt(abs_n);
    return std.fmt.bufPrint(buf, "{d:.1}k", .{value / 1000.0}) catch buf[0..0];
}

test "formatTokens prints exact numbers below ten thousand" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatTokens(&buf, 0));
    try std.testing.expectEqualStrings("999", formatTokens(&buf, 999));
    try std.testing.expectEqualStrings("9999", formatTokens(&buf, 9999));
}

test "formatTokens uses k notation at ten thousand and above" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("10.0k", formatTokens(&buf, 10000));
    try std.testing.expectEqualStrings("12.0k", formatTokens(&buf, 12000));
    try std.testing.expectEqualStrings("12.4k", formatTokens(&buf, 12400));
    try std.testing.expectEqualStrings("12.5k", formatTokens(&buf, 12500));
}

test "formatTokens prints absolute value for negative numbers" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1234", formatTokens(&buf, -1234));
    try std.testing.expectEqualStrings("12.4k", formatTokens(&buf, -12400));
}
