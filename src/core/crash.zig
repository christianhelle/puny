//! Crash report capture and submission.
//!
//! A run that fails writes a markdown report into the puny config directory.
//! The next interactive startup finds it and offers to file it as a GitHub
//! issue.

const std = @import("std");
const builtin = @import("builtin");
const core_session = @import("session.zig");

/// Directory holding pending crash reports, inside the puny config directory.
/// The returned slice is owned by `allocator`.
pub fn crashDir(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = try core_session.configPunyDir(allocator, environ_map);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "crashes" });
}

test "crashDir places reports under the puny config dir" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    if (comptime builtin.os.tag == .windows) {
        try env.put("APPDATA", "C:\\Users\\test\\AppData\\Roaming");
        const dir = try crashDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("C:\\Users\\test\\AppData\\Roaming\\puny\\crashes", dir);
    } else {
        try env.put("XDG_CONFIG_HOME", "/tmp/test-xdg");
        const dir = try crashDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("/tmp/test-xdg/puny/crashes", dir);
    }
}
