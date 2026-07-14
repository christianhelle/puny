const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

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
