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

/// File name prefix shared by every crash report.
pub const file_prefix = "puny_crash_";

/// Absolute path of the crash report for `session_id`. The returned slice is
/// owned by `allocator`.
pub fn reportPath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    session_id: []const u8,
) ![]const u8 {
    const dir = try crashDir(allocator, environ_map);
    defer allocator.free(dir);
    const name = try std.fmt.allocPrint(allocator, file_prefix ++ "{s}.md", .{session_id});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ dir, name });
}

test "reportPath names the file after the session id inside the crash dir" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    if (comptime builtin.os.tag == .windows) {
        try env.put("APPDATA", "C:/Users/test");
    } else {
        try env.put("XDG_CONFIG_HOME", "/tmp/test-xdg");
    }

    const dir = try crashDir(allocator, &env);
    defer allocator.free(dir);

    const path = try reportPath(allocator, &env, "8f14e45f-ceea-467a-9dc3-0f0e0b1e1e1e");
    defer allocator.free(path);

    try std.testing.expectEqualStrings(dir, std.fs.path.dirname(path).?);
    try std.testing.expectEqualStrings(
        "puny_crash_8f14e45f-ceea-467a-9dc3-0f0e0b1e1e1e.md",
        std.fs.path.basename(path),
    );
}
