const std = @import("std");

pub fn cleanupOldBackup(allocator: std.mem.Allocator, io: std.Io) void {
    const exe_path = std.process.executablePathAlloc(io, allocator) catch return;
    defer allocator.free(exe_path);
    const old_path = std.fmt.allocPrint(allocator, "{s}.old", .{exe_path}) catch return;
    defer allocator.free(old_path);
    std.Io.Dir.deleteFileAbsolute(io, old_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            var buf: [512]u8 = undefined;
            var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
            w.interface.print("warning: failed to remove old backup: {s}\n", .{@errorName(err)}) catch {};
            w.interface.flush() catch {};
        },
    };
}

pub fn archiveNameForTarget() []const u8 {
    const target = @import("builtin").target;
    const aarch = target.cpu.arch;
    const os = target.os.tag;
    if (aarch == .aarch64) {
        return switch (os) {
            .windows => "puny-windows-aarch64.zip",
            .linux => "puny-linux-aarch64.tar.gz",
            .macos => "puny-macos-aarch64.tar.gz",
            else => @compileError("unsupported OS for upgrade"),
        };
    } else if (aarch == .x86_64) {
        return switch (os) {
            .windows => "puny-windows-x86_64.zip",
            .linux => "puny-linux-x86_64.tar.gz",
            .macos => "puny-macos-x86_64.tar.gz",
            else => @compileError("unsupported OS for upgrade"),
        };
    }
    @compileError("unsupported CPU architecture for upgrade");
}

pub fn upgradeTempParent(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("TMPDIR")) |t| return try arena.dupe(u8, t);
    if (environ_map.get("TEMP")) |t| return try arena.dupe(u8, t);
    if (environ_map.get("TMP")) |t| return try arena.dupe(u8, t);
    if (comptime @import("builtin").os.tag == .windows) return try arena.dupe(u8, "C:\\Windows\\Temp");
    return try arena.dupe(u8, "/tmp");
}

test "upgradeTempParent prefers TMPDIR over TEMP and TMP" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/custom/tmp");
    try env.put("TEMP", "/other/temp");
    try env.put("TMP", "/third/tmp");

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/custom/tmp", result);
}

test "upgradeTempParent falls back to TEMP when TMPDIR is unset" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TEMP", "C:\\Temp");

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("C:\\Temp", result);
}

test "upgradeTempParent falls back to TMP when TEMP is unset" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TMP", "C:\\Windows\\Temp");

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("C:\\Windows\\Temp", result);
}

test "upgradeTempParent falls back to the platform default temp dir" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    const expected = if (@import("builtin").os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    try std.testing.expectEqualStrings(expected, result);
}
