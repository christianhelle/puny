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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try writeFile(std.testing.allocator, std.testing.io, .{ .path = "test.txt", .content = "hello world" });
    try std.testing.expectEqualStrings("File written successfully.", result);

    const content = try readFile(std.testing.allocator, std.testing.io, .{ .path = "test.txt" });
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);
}

test "readFile errors on a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.FileNotFound, readFile(std.testing.allocator, std.testing.io, .{ .path = "missing.txt" }));
}

test "readFile respects the size limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try writeFile(std.testing.allocator, std.testing.io, .{ .path = "big.txt", .content = "x" ** (1024 * 1024 + 1) });
    try std.testing.expectError(error.StreamTooLong, readFile(std.testing.allocator, std.testing.io, .{ .path = "big.txt" }));
}

test "listDirectory returns directory entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try writeFile(std.testing.allocator, std.testing.io, .{ .path = "a.txt", .content = "a" });
    _ = try writeFile(std.testing.allocator, std.testing.io, .{ .path = "b.txt", .content = "b" });

    const listing = try listDirectory(std.testing.allocator, std.testing.io, .{ .path = "." });
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "b.txt") != null);
}

test "writeFile is blocked in planning mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    core_session.setWriteBlocked(true);
    defer core_session.setWriteBlocked(false);

    const result = try writeFile(std.testing.allocator, std.testing.io, .{ .path = "blocked.txt", .content = "nope" });
    try std.testing.expect(std.mem.indexOf(u8, result, "Write blocked") != null);
    // The file must not exist.
    try std.testing.expectError(error.FileNotFound, readFile(std.testing.allocator, std.testing.io, .{ .path = "blocked.txt" }));
}
