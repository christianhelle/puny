const std = @import("std");
const build_info = @import("build_options");

pub const version = build_info.VERSION;
pub const git_commit = build_info.GIT_COMMIT;
pub const dirty = build_info.DIRTY;

/// Identifies this client to HTTP servers puny talks to.
pub const user_agent = "puny/" ++ version;

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

test "format falls back to the bare version when the buffer is too small" {
    var small: [4]u8 = undefined;
    const output = format(&small);
    try std.testing.expectEqualStrings(version, output);
}

test "format includes the git commit when known" {
    if (std.mem.eql(u8, git_commit, "unknown")) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    const output = format(&buf);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, git_commit));
}

test "format appends the dirty marker when the worktree is dirty" {
    if (std.mem.eql(u8, git_commit, "unknown") or !dirty) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    const output = format(&buf);
    try std.testing.expect(std.mem.endsWith(u8, output, "-dirty)"));
}

test "user_agent names puny and its version" {
    try std.testing.expect(std.mem.startsWith(u8, user_agent, "puny/"));
    try std.testing.expectEqualStrings(version, user_agent["puny/".len..]);
}
