const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");
const core_session = @import("../core/session.zig");
const ToolContext = tools.ToolContext;

const ReadFileParams = struct {
    path: []const u8,
};

fn readFile(ctx: *ToolContext, params: ReadFileParams) ![]const u8 {
    return helpers.readFileAlloc(ctx.allocator, ctx.io, params.path, 1024 * 1024);
}

const WriteFileParams = struct {
    path: []const u8,
    content: []const u8,
};

fn writeFile(ctx: *ToolContext, params: WriteFileParams) ![]const u8 {
    if (core_session.isWriteBlocked()) {
        return "Write blocked: app is in planning mode. Exit planning mode with /build or use save_prd to save the PRD.";
    }
    try helpers.writeFile(ctx.io, params.path, params.content);
    return "File written successfully.";
}

const ListDirectoryParams = struct {
    path: []const u8,
};

fn listDirectory(ctx: *ToolContext, params: ListDirectoryParams) ![]const u8 {
    return helpers.listDirectory(ctx.allocator, ctx.io, params.path);
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
