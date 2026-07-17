const std = @import("std");
const build_info = @import("build_options");

pub const version = build_info.VERSION;
pub const git_commit = build_info.GIT_COMMIT;
pub const dirty = build_info.DIRTY;

pub fn format(buf: []u8) []const u8 {
    if (std.mem.eql(u8, git_commit, "unknown")) {
        return std.fmt.bufPrint(buf, "{s}", .{version}) catch version;
    }
    const suffix: []const u8 = if (dirty) "-dirty" else "";
    return std.fmt.bufPrint(buf, "{s} ({s}{s})", .{ version, git_commit, suffix }) catch version;
}

test "format includes version" {
    var buf: [256]u8 = undefined;
    const output = format(&buf);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, version));
}

test "format includes commit or unknown marker" {
    var buf: [256]u8 = undefined;
    const output = format(&buf);
    if (std.mem.eql(u8, git_commit, "unknown")) {
        try std.testing.expectEqualStrings(version, output);
    } else {
        try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "("));
        try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, ")"));
    }
}
