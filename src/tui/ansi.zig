const std = @import("std");

pub const reset = "\x1b[0m";
pub const dim = "\x1b[2m";
pub const bright = "\x1b[1;37m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const cyan = "\x1b[36m";
pub const bold_start = "\x1b[1m";
pub const bold_end = "\x1b[22m";

test "ansi constants are well-formed escape sequences" {
    try std.testing.expectEqualStrings("\x1b[0m", reset);
    try std.testing.expectEqualStrings("\x1b[2m", dim);
    try std.testing.expectEqualStrings("\x1b[1;37m", bright);
    try std.testing.expectEqualStrings("\x1b[32m", green);
    try std.testing.expectEqualStrings("\x1b[33m", yellow);
    try std.testing.expectEqualStrings("\x1b[36m", cyan);
    try std.testing.expectEqualStrings("\x1b[1m", bold_start);
    try std.testing.expectEqualStrings("\x1b[22m", bold_end);
}

test "ansi constants begin with escape and end with m" {
    const all = [_][]const u8{ reset, dim, bright, green, yellow, cyan, bold_start, bold_end };
    for (all) |seq| {
        try std.testing.expect(seq.len >= 3);
        try std.testing.expect(seq[0] == 0x1b);
        try std.testing.expect(seq[1] == '[');
        try std.testing.expect(seq[seq.len - 1] == 'm');
    }
}
