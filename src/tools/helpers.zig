const std = @import("std");
const run_command = @import("run_command.zig");

pub const runCommand = run_command.runCommand;
pub const runCommandTimed = run_command.runCommandTimed;
pub const ownedSliceOrEmpty = run_command.ownedSliceOrEmpty;

pub const http = @import("http.zig");
pub const httpDownloadFile = http.httpDownloadFile;
pub const httpGet = http.httpGet;
pub const httpGetTimed = http.httpGetTimed;
pub const web_fetch_timeout_ns = http.web_fetch_timeout_ns;
pub const resolveTimeoutSeconds = http.resolveTimeoutSeconds;

pub fn dupeString(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_size: usize) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_size));
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try list.appendSlice(allocator, entry.name);
        try list.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&list, allocator);
}

/// Timeout applied to shell-backed tools that do not accept a model-supplied
/// timeout parameter (git_status, git_diff, grep_search).
pub const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;

/// Default timeout applied to execute_shell when the model does not provide
/// one. Generous for real work (builds, test suites) while still a hard bound
/// so the agent can never hang on a single command.
pub const execute_shell_timeout_ns: i96 = 120 * std.time.ns_per_s;

// ── Tests ────────────────────────────────────────────────────────────

test "dupeString returns an empty string without allocating" {
    try std.testing.expectEqualStrings("", try dupeString(std.testing.allocator, ""));
    const duped = try dupeString(std.testing.allocator, "hello");
    defer std.testing.allocator.free(duped);
    try std.testing.expectEqualStrings("hello", duped);
    try std.testing.expect(duped.ptr != "hello".ptr);
}

test "ownedSliceOrEmpty returns an empty string for an empty list" {
    var list: std.ArrayList(u8) = .empty;
    try std.testing.expectEqualStrings("", try ownedSliceOrEmpty(&list, std.testing.allocator));
}

test "ownedSliceOrEmpty takes ownership of a non-empty list" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "abc");
    const owned = try ownedSliceOrEmpty(&list, std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("abc", owned);
}

test "writeFile readFileAlloc and listDirectory round-trip" {
    const path = "puny-test-helpers-rt.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try writeFile(std.testing.io, path, "payload");
    const content = try readFileAlloc(std.testing.allocator, std.testing.io, path, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("payload", content);

    const listing = try listDirectory(std.testing.allocator, std.testing.io, ".");
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, path) != null);
}

test "readFileAlloc rejects content larger than the limit" {
    const path = "puny-test-helpers-big.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try writeFile(std.testing.io, path, "123456789");
    try std.testing.expectError(error.StreamTooLong, readFileAlloc(std.testing.allocator, std.testing.io, path, 4));
}

test "listDirectory returns an empty string for an empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(path);

    const listing = try listDirectory(std.testing.allocator, std.testing.io, path);
    defer std.testing.allocator.free(listing);
    try std.testing.expectEqualStrings("", listing);
}
