const std = @import("std");
const core_session = @import("core/session.zig");
const upgrade = @import("upgrade.zig");
const version = @import("version.zig");

pub const flag_file_name = "update-available";

/// Environment variable that marks the detached update-check child process.
pub const check_env_var = "PUNY_UPDATE_CHECK";

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

fn availableUpdateIfNewerInstalled(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    installed: []const u8,
) !?[]u8 {
    const latest = try availableUpdate(io, allocator, environ_map) orelse return null;
    if (isNewer(installed, latest)) return latest;
    allocator.free(latest);
    try clearFlag(io, allocator, environ_map);
    return null;
}

/// Reads the available version from the flag file only when it is newer than
/// the installed binary. Clears a stale flag and returns null otherwise. The
/// returned slice is owned by `allocator`.
pub fn availableUpdateIfNewer(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    return availableUpdateIfNewerInstalled(io, allocator, environ_map, version.version);
}

/// Prints the exit notice pointing at the upgrade command.
pub fn printUpdateNotice(writer: *std.Io.Writer, latest_ver: []const u8) !void {
    try writer.print(
        "A new version of puny is available: v{s}. Run `puny --upgrade` to update.\n",
        .{latest_ver},
    );
}

/// Result of an update check.
pub const CheckOutcome = enum {
    /// A newer version was found and recorded in the flag file.
    update_available,
    /// The installed version is current.
    up_to_date,
};

fn runCheckWithLatestInstalled(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    installed: []const u8,
    available: []const u8,
) !CheckOutcome {
    if (isNewer(installed, available)) {
        try writeFlagIfNewer(io, allocator, environ_map, installed, available);
        return .update_available;
    }
    try clearFlag(io, allocator, environ_map);
    return .up_to_date;
}

/// Writes or clears the flag based on whether `available` is newer than the
/// installed version, returning the outcome.
pub fn runCheckWithLatest(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    available: []const u8,
) !CheckOutcome {
    return runCheckWithLatestInstalled(io, allocator, environ_map, version.version, available);
}

/// Update check that fetches the latest release and records it in the flag file
/// when newer. Errors are propagated to the caller; the detached child process
/// spawn ignores stderr and the exit code, so failures stay silent there.
pub fn runCheck(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !CheckOutcome {
    const available = try upgrade.latestReleaseVersion(allocator, io);
    defer allocator.free(available);
    return try runCheckWithLatest(io, allocator, environ_map, available);
}

/// Spawns a detached `puny` child process that runs the update check. The child
/// is marked with `PUNY_UPDATE_CHECK=1` in its environment so it knows to run
/// the check and exit quietly. Returns immediately; errors are swallowed so
/// startup is never blocked.
pub fn spawnBackgroundCheck(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) void {
    const exe_path = std.process.executablePathAlloc(io, allocator) catch return;
    defer allocator.free(exe_path);

    // The spawn replaces the child environment entirely, so clone the parent's
    // map and add the marker that turns the child into an update check.
    var child_env = environ_map.clone(allocator) catch return;
    defer child_env.deinit();
    child_env.put(check_env_var, "1") catch return;

    _ = std.process.spawn(io, .{
        .argv = &[_][]const u8{exe_path},
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {};
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

test "availableUpdateIfNewer returns the stored version when it is newer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "2.0.0");

    const available = try availableUpdateIfNewerInstalled(std.testing.io, allocator, &env, "1.0.0");
    defer allocator.free(available.?);
    try std.testing.expectEqualStrings("2.0.0", available.?);
}

test "availableUpdateIfNewer returns null and clears the flag when equal or older" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "2.0.0");
    try std.testing.expect((try availableUpdateIfNewerInstalled(std.testing.io, allocator, &env, "2.0.0")) == null);
    try std.testing.expect((try availableUpdate(std.testing.io, allocator, &env)) == null);

    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "2.0.0");
    try std.testing.expect((try availableUpdateIfNewerInstalled(std.testing.io, allocator, &env, "3.0.0")) == null);
    try std.testing.expect((try availableUpdate(std.testing.io, allocator, &env)) == null);
}

test "availableUpdateIfNewer returns null when no flag exists" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    const available = try availableUpdateIfNewerInstalled(std.testing.io, allocator, &env, "1.0.0");
    try std.testing.expect(available == null);
}

test "printUpdateNotice announces the new version and the upgrade command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var output = std.Io.Writer.Allocating.init(arena_state.allocator());
    defer output.deinit();

    try printUpdateNotice(&output.writer, "2.1.0");
    const text = output.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "2.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "puny --upgrade") != null);
}

test "printUpdateNotice mentions a new version is available" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var output = std.Io.Writer.Allocating.init(arena_state.allocator());
    defer output.deinit();

    try printUpdateNotice(&output.writer, "1.2.3");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "new version") != null);
}

test "runCheckWithLatest writes the flag when the latest is newer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    const outcome = try runCheckWithLatestInstalled(std.testing.io, allocator, &env, "1.0.0", "99.0.0");
    try std.testing.expectEqual(CheckOutcome.update_available, outcome);

    const available = (try availableUpdate(std.testing.io, allocator, &env)).?;
    defer allocator.free(available);
    try std.testing.expectEqualStrings("99.0.0", available);
}

test "runCheckWithLatest clears the flag when the latest is not newer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    // A stale flag from a previous run.
    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "2.0.0");

    const outcome = try runCheckWithLatestInstalled(std.testing.io, allocator, &env, "1.0.0", "0.0.1");
    try std.testing.expectEqual(CheckOutcome.up_to_date, outcome);

    try std.testing.expect((try availableUpdate(std.testing.io, allocator, &env)) == null);
}

test "runCheckWithLatest treats an unparseable installed version as up to date" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try setFlagBaseDir(tmp, &env);

    // A stale flag from a previous run.
    try writeFlagIfNewer(std.testing.io, allocator, &env, "1.0.0", "2.0.0");

    const outcome = try runCheckWithLatestInstalled(std.testing.io, allocator, &env, "unknown", "99.0.0");
    try std.testing.expectEqual(CheckOutcome.up_to_date, outcome);

    try std.testing.expect((try availableUpdate(std.testing.io, allocator, &env)) == null);
}

test "spawnBackgroundCheck marks the child with the update check env var" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUNY_UPDATE_CHECK", "1");

    const value = env.get(check_env_var);
    try std.testing.expectEqualStrings("1", value.?);
}
