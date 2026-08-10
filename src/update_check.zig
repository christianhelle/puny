const std = @import("std");

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
