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

/// Writes `available` into the flag file when it is newer than `installed`.
/// No-op when the available version is not newer.
pub fn writeFlagIfNewer(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    installed: []const u8,
    available: []const u8,
) !void {
    if (!isNewer(installed, available)) return;
    try writeFlag(io, allocator, environ_map, available);
}

fn writeFlag(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    available: []const u8,
) !void {
    const path = try flagPath(allocator, environ_map);
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);

    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, available);
}

/// Removes the flag file. A missing file is a no-op.
pub fn clearFlag(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !void {
    const path = try flagPath(allocator, environ_map);
    defer allocator.free(path);

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Reads the available version from the flag file, or null when no flag is
/// present. The returned slice is owned by `allocator`.
pub fn availableUpdate(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    const path = try flagPath(allocator, environ_map);
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(64),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
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

fn setFlagBaseDir(tmp: std.testing.TmpDir, env: *std.process.Environ.Map) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    if (comptime @import("builtin").os.tag == .windows) {
        try env.put("APPDATA", path_buf[0..n]);
    } else {
        try env.put("XDG_CONFIG_HOME", path_buf[0..n]);
    }
}

test "writeFlagIfNewer writes the flag with the new version" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "1.1.0");

    const path = try flagPath(allocator, &env);
    defer allocator.free(path);
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(64));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("1.1.0", content);
}

test "writeFlagIfNewer skips writing when not newer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.1.0", "1.0.0");

    const path = try flagPath(allocator, &env);
    defer allocator.free(path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(64)));
}

test "clearFlag removes the flag and tolerates a missing one" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "1.1.0");
    try clearFlag(std.testing.io, allocator, &env);

    const path = try flagPath(allocator, &env);
    defer allocator.free(path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(64)));

    // Clearing again is a no-op, not an error.
    try clearFlag(std.testing.io, allocator, &env);
}

test "availableUpdate reads the flag file content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "2.0.0");

    const available = try availableUpdate(std.testing.io, allocator, &env);
    defer allocator.free(available.?);
    try std.testing.expectEqualStrings("2.0.0", available.?);
}

test "availableUpdate returns null when the flag file is missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    const available = try availableUpdate(std.testing.io, allocator, &env);
    try std.testing.expect(available == null);
}
