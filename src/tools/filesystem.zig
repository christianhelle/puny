const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");
const core_session = @import("../core/session.zig");

const ReadFileParams = struct {
    path: []const u8,
};

fn readFile(allocator: std.mem.Allocator, io: std.Io, params: ReadFileParams) ![]const u8 {
    return helpers.readFileAlloc(allocator, io, params.path, 1024 * 1024);
}

const WriteFileParams = struct {
    path: []const u8,
    content: []const u8,
};

fn writeFile(allocator: std.mem.Allocator, io: std.Io, params: WriteFileParams) ![]const u8 {
    if (core_session.isWriteBlocked()) {
        return "Write blocked: app is in planning mode. Exit planning mode with /build or use save_prd to save the PRD.";
    }
    _ = allocator;
    try helpers.writeFile(io, params.path, params.content);
    return "File written successfully.";
}

const ListDirectoryParams = struct {
    path: []const u8,
};

fn listDirectory(allocator: std.mem.Allocator, io: std.Io, params: ListDirectoryParams) ![]const u8 {
    return helpers.listDirectory(allocator, io, params.path);
}

pub const read_file = tools.defineTool(
    "read_file",
    "Read the contents of a file at the given path.",
    ReadFileParams,
    readFile,
);

pub const write_file = tools.defineTool(
    "write_file",
    "Write content to a file at the given path. Overwrites existing files.",
    WriteFileParams,
    writeFile,
);

pub const list_directory = tools.defineTool(
    "list_directory",
    "List the names of files and directories at the given path.",
    ListDirectoryParams,
    listDirectory,
);

test "writeFile and readFile round-trip content" {
    const path = "puny-test-fs-roundtrip.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try writeFile(std.testing.allocator, std.testing.io, .{ .path = path, .content = "hello world" });
    try std.testing.expectEqualStrings("File written successfully.", result);

    const content = try readFile(std.testing.allocator, std.testing.io, .{ .path = path });
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);
}

test "readFile errors on a missing file" {
    const path = "puny-test-fs-missing.txt";
    // Remove any stale file from a prior run so the assertion cannot be
    // affected by leftover state in the CWD.
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try std.testing.expectError(error.FileNotFound, readFile(std.testing.allocator, std.testing.io, .{ .path = path }));
}

test "readFile respects the size limit" {
    const path = "puny-test-fs-big.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    // Allocate the oversized payload at runtime: a 1 MiB+ compile-time string
    // literal would bloat the test binary and slow down compilation.
    var big = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    _ = try writeFile(std.testing.allocator, std.testing.io, .{ .path = path, .content = big });
    try std.testing.expectError(error.StreamTooLong, readFile(std.testing.allocator, std.testing.io, .{ .path = path }));
}

test "listDirectory returns directory entries" {
    const path_a = "puny-test-fs-list-a.txt";
    const path_b = "puny-test-fs-list-b.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path_a) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path_b) catch {};

    _ = try writeFile(std.testing.allocator, std.testing.io, .{ .path = path_a, .content = "a" });
    _ = try writeFile(std.testing.allocator, std.testing.io, .{ .path = path_b, .content = "b" });

    const listing = try listDirectory(std.testing.allocator, std.testing.io, .{ .path = "." });
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, path_a) != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, path_b) != null);
}

test "writeFile is blocked in planning mode" {
    const path = "puny-test-fs-blocked.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    core_session.setWriteBlocked(true);
    defer core_session.setWriteBlocked(false);

    const result = try writeFile(std.testing.allocator, std.testing.io, .{ .path = path, .content = "nope" });
    try std.testing.expect(std.mem.indexOf(u8, result, "Write blocked") != null);
    // The file must not exist.
    try std.testing.expectError(error.FileNotFound, readFile(std.testing.allocator, std.testing.io, .{ .path = path }));
}
