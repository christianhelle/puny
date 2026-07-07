const std = @import("std");
const tools = @import("root.zig");

const ReadFileParams = struct {
    path: []const u8,
};

fn readFile(allocator: std.mem.Allocator, params: ReadFileParams) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, params.path, 1024 * 1024);
}

const WriteFileParams = struct {
    path: []const u8,
    content: []const u8,
};

fn writeFile(allocator: std.mem.Allocator, params: WriteFileParams) ![]const u8 {
    _ = allocator;
    const file = try std.fs.cwd().createFile(params.path, .{});
    defer file.close();
    try file.writeAll(params.content);
    return "File written successfully.";
}

const ListDirectoryParams = struct {
    path: []const u8,
};

fn listDirectory(allocator: std.mem.Allocator, params: ListDirectoryParams) ![]const u8 {
    var dir = try std.fs.cwd().openDir(params.path, .{ .iterate = true });
    defer dir.close();

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    const writer = list.writer();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        try writer.print("{s}\n", .{entry.name});
    }

    return list.toOwnedSlice();
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

test "write and read file" {
    const allocator = std.testing.allocator;
    const path = ".puny_test_file.txt";
    const content = "hello from puny";

    const write_result = try write_file.execute(allocator, .{
        .object = try std.json.ObjectMap.init(allocator, &.{
            .{ "path", .{ .string = path } },
            .{ "content", .{ .string = content } },
        }, &.{}),
    });
    defer allocator.free(write_result);
    try std.testing.expectEqualStrings("File written successfully.", write_result);

    const read_result = try read_file.execute(allocator, .{
        .object = try std.json.ObjectMap.init(allocator, &.{
            .{ "path", .{ .string = path } },
        }, &.{}),
    });
    defer allocator.free(read_result);
    try std.testing.expectEqualStrings(content, read_result);

    try std.fs.cwd().deleteFile(path);
}
