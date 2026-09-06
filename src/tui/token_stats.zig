const std = @import("std");
const ansi = @import("ansi.zig");

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

/// Formats a count exactly, grouping thousands with commas (`1,000,000`).
/// Use where the precise number matters and only its readability is at stake;
/// `formatTokens` is the compact alternative. Accepts any integer type so
/// callers never have to narrow a `usize` to fit. Writes into `buf` (which
/// must be large enough) and returns a slice of it.
pub fn formatGrouped(buf: []u8, n: anytype) []const u8 {
    var digits_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{@abs(n)}) catch return buf[0..0];

    const separators = (digits.len - 1) / 3;
    const total = @as(usize, @intFromBool(n < 0)) + digits.len + separators;
    if (total > buf.len) return buf[0..0];

    var i: usize = 0;
    if (n < 0) {
        buf[i] = '-';
        i += 1;
    }
    for (digits, 0..) |digit, d| {
        if (d > 0 and (digits.len - d) % 3 == 0) {
            buf[i] = ',';
            i += 1;
        }
        buf[i] = digit;
        i += 1;
    }
    return buf[0..i];
}

/// Prints the per-response token footer as a single dim line, e.g.
/// `⏱ tokens: in 140 | out 120 | total 260 (session 12.4k)`. Per-turn numbers
/// are prefixed with `~` when the turn used estimated (not provider-reported)
/// usage; the session total is an aggregate and carries no marker.
pub fn printTokenFooter(
    writer: *std.Io.Writer,
    turn_in: i64,
    turn_out: i64,
    turn_estimated: bool,
    session_total: i64,
) !void {
    const tilde = if (turn_estimated) "~" else "";
    var in_buf: [24]u8 = undefined;
    var out_buf: [24]u8 = undefined;
    var total_buf: [24]u8 = undefined;
    var session_buf: [24]u8 = undefined;
    try writer.print("\n{s}⏱ tokens: in {s}{s} | out {s}{s} | total {s}{s} (session {s}){s}\n", .{
        ansi.dim,
        tilde,
        formatTokens(&in_buf, turn_in),
        tilde,
        formatTokens(&out_buf, turn_out),
        tilde,
        formatTokens(&total_buf, turn_in + turn_out),
        formatTokens(&session_buf, session_total),
        ansi.reset,
    });
    try writer.flush();
}

test "formatGrouped separates thousands with commas" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatGrouped(&buf, 0));
    try std.testing.expectEqualStrings("999", formatGrouped(&buf, 999));
    try std.testing.expectEqualStrings("1,000", formatGrouped(&buf, 1000));
    try std.testing.expectEqualStrings("12,345", formatGrouped(&buf, 12345));
    try std.testing.expectEqualStrings("1,000,000", formatGrouped(&buf, 1_000_000));
}

test "formatGrouped accepts unsigned counts without narrowing them" {
    var buf: [32]u8 = undefined;
    const turns: usize = 12_345;
    try std.testing.expectEqualStrings("12,345", formatGrouped(&buf, turns));
    try std.testing.expectEqualStrings("18,446,744,073,709,551,615", formatGrouped(&buf, std.math.maxInt(u64)));
}

test "formatGrouped keeps the sign of negative counts" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("-1", formatGrouped(&buf, -1));
    try std.testing.expectEqualStrings("-1,234", formatGrouped(&buf, -1234));
}

test "formatGrouped groups the extremes of i64" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("9,223,372,036,854,775,807", formatGrouped(&buf, std.math.maxInt(i64)));
    try std.testing.expectEqualStrings("-9,223,372,036,854,775,808", formatGrouped(&buf, std.math.minInt(i64)));
}

test "formatGrouped yields an empty slice when the buffer is too small" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", formatGrouped(&buf, 1000));
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

test "printTokenFooter renders exact numbers on a single dim line" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try printTokenFooter(&out.writer, 140, 120, false, 1234);
    try std.testing.expectEqualStrings(
        "\n" ++ ansi.dim ++ "⏱ tokens: in 140 | out 120 | total 260 (session 1234)" ++ ansi.reset ++ "\n",
        out.written(),
    );
}

test "printTokenFooter prefixes tilde when the turn was estimated" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try printTokenFooter(&out.writer, 140, 120, true, 1234);
    try std.testing.expectEqualStrings(
        "\n" ++ ansi.dim ++ "⏱ tokens: in ~140 | out ~120 | total ~260 (session 1234)" ++ ansi.reset ++ "\n",
        out.written(),
    );
}

test "printTokenFooter renders session total in k notation" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try printTokenFooter(&out.writer, 140, 120, false, 12400);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "session 12.4k") != null);
}

test "printTokenFooter renders large turns in k notation" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try @call(.never_inline, printTokenFooter, .{ &out.writer, 10000, 23000, false, 90000 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "in 10.0k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "out 23.0k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "total 33.0k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "session 90.0k") != null);
}

test "formatTokens handles single digit and negative inputs" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1", formatTokens(&buf, 1));
    try std.testing.expectEqualStrings("1", formatTokens(&buf, -1));
    try std.testing.expectEqualStrings("9999", formatTokens(&buf, -9999));
}
