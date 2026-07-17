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
