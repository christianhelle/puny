const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");
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
    if (ctx.isWriteBlocked()) {
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

test "write_file is blocked when context write_blocked is set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var skill_registry = @import("../skills/skills.zig").Registry.init(arena);
    defer skill_registry.deinit();

    var ctx = tools.ToolContext.init(arena, std.testing.io, &skill_registry);
    defer ctx.deinit();
    ctx.write_blocked = true;

    const target = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "blocked.txt" });
    var args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"PLACEHOLDER\",\"content\":\"nope\"}", .{});
    args.object.put(arena, "path", .{ .string = target }) catch unreachable;

    const result = try write_file.execute(&ctx, args);
    try std.testing.expect(std.mem.indexOf(u8, result, "Write blocked") != null);

    var file = std.Io.Dir.cwd().openFile(std.testing.io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => return, // blocked: file must not exist
        else => return err,
    };
    file.close(std.testing.io);
    return error.TestUnexpectedResult; // file was written despite block
}

test "write_file writes when context allows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var skill_registry = @import("../skills/skills.zig").Registry.init(arena);
    defer skill_registry.deinit();

    var ctx = tools.ToolContext.init(arena, std.testing.io, &skill_registry);
    defer ctx.deinit();

    const target = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "written.txt" });
    var args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"PLACEHOLDER\",\"content\":\"hello\"}", .{});
    args.object.put(arena, "path", .{ .string = target }) catch unreachable;

    const result = try write_file.execute(&ctx, args);
    try std.testing.expectEqualStrings("File written successfully.", result);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, target, arena, std.Io.Limit.limited(1024));
    try std.testing.expectEqualStrings("hello", content);
}
