const std = @import("std");
const core_session = @import("core/session.zig");

pub const flag_file_name = "update-available";

/// Absolute path to the update-available flag file, inside the puny config
/// directory. The returned slice is owned by `allocator`.
pub fn flagPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = try core_session.configPunyDir(allocator, environ_map);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, flag_file_name });
}

/// Returns true when `available` is a newer semantic version than `installed`.
/// Unparseable versions compare as "not newer".
pub fn isNewer(installed: []const u8, available: []const u8) bool {
    const installed_ver = std.SemanticVersion.parse(installed) catch return false;
    const available_ver = std.SemanticVersion.parse(available) catch return false;
    return installed_ver.order(available_ver) == .lt;
}

test "isNewer is true when the available version is newer" {
    try std.testing.expect(isNewer("1.0.0", "1.1.0"));
    try std.testing.expect(isNewer("1.0.0", "2.0.0"));
}

test "isNewer is false when the available version is older or equal" {
    try std.testing.expect(!isNewer("1.1.0", "1.0.0"));
    try std.testing.expect(!isNewer("1.0.0", "1.0.0"));
}

test "isNewer is false when either version cannot be parsed" {
    try std.testing.expect(!isNewer("not-a-version", "1.0.0"));
    try std.testing.expect(!isNewer("1.0.0", "not-a-version"));
}

test "flagPath joins the puny config dir with the flag file name" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    if (comptime @import("builtin").os.tag == .windows) {
        try env.put("APPDATA", "C:\\Users\\test\\AppData\\Roaming");
        const path = try flagPath(allocator, &env);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("C:\\Users\\test\\AppData\\Roaming\\puny\\update-available", path);
    } else {
        try env.put("XDG_CONFIG_HOME", "/tmp/test-xdg");
        const path = try flagPath(allocator, &env);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("/tmp/test-xdg/puny/update-available", path);
    }
}
