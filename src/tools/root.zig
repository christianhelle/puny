const std = @import("std");

pub const schema = @import("schema.zig");
const context = @import("context.zig");
const helpers = @import("helpers.zig");

pub const Tool = schema.Tool;
pub const ToolContext = context.ToolContext;
pub const dupeString = helpers.dupeString;
pub const ownedSliceOrEmpty = helpers.ownedSliceOrEmpty;

pub fn defineTool(
    comptime name: []const u8,
    comptime description: []const u8,
    comptime Params: type,
    comptime handler: fn (ctx: *ToolContext, params: Params) anyerror![]const u8,
) Tool {
    const Schema = schema.ToolDefinition(name, description, Params);

    return .{
        .name = name,
        .description = description,
        .schema = Schema.schema,
        .execute = struct {
            pub fn exec(ctx: *ToolContext, args: std.json.Value) ![]const u8 {
                const parsed = try std.json.parseFromValue(Params, ctx.allocator, args, .{});
                defer parsed.deinit();
                return handler(ctx, parsed.value);
            }
        }.exec,
    };
}

pub fn dispatch(name: []const u8) ?Tool {
    inline for (registry) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    inline for (planning_registry) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

const filesystem = @import("filesystem.zig");
const shell = @import("shell.zig");
const search = @import("search.zig");
const git = @import("git.zig");
const web = @import("web.zig");
const core_session = @import("../core/session.zig");
const skill_loader = @import("skill_loader.zig");

pub const registry = blk: {
    @setEvalBranchQuota(10000);
    break :blk &[_]Tool{
        filesystem.read_file,
        filesystem.write_file,
        filesystem.list_directory,
        shell.execute_shell,
        search.grep_search,
        git.git_status,
        git.git_diff,
        web.web_fetch,
        skill_loader.load_skill,
    };
};

pub const planning_registry = blk: {
    @setEvalBranchQuota(10000);
    break :blk &[_]Tool{
        filesystem.read_file,
        filesystem.list_directory,
        search.grep_search,
        web.web_fetch,
        git.git_status,
        git.git_diff,
        core_session.save_prd_tool,
        skill_loader.load_skill,
    };
};

test "dispatch returns known tools" {
    try std.testing.expect(dispatch("read_file") != null);
    try std.testing.expect(dispatch("write_file") != null);
    try std.testing.expect(dispatch("list_directory") != null);
    try std.testing.expect(dispatch("execute_shell") != null);
    try std.testing.expect(dispatch("grep_search") != null);
    try std.testing.expect(dispatch("git_status") != null);
    try std.testing.expect(dispatch("git_diff") != null);
    try std.testing.expect(dispatch("web_fetch") != null);
    try std.testing.expect(dispatch("save_prd") != null);
    try std.testing.expect(dispatch("load_skill") != null);
    try std.testing.expect(dispatch("unknown_tool") == null);
}

test "read_file executes through ToolContext" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "hello world" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var skill_registry = @import("../skills/skills.zig").Registry.init(arena);
    defer skill_registry.deinit();

    var ctx = ToolContext.init(arena, std.testing.io, &skill_registry);
    defer ctx.deinit();

    const file_path = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "hello.txt" });
    var args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"PLACEHOLDER\"}", .{});
    args.object.put(arena, "path", .{ .string = file_path }) catch unreachable;

    const tool = dispatch("read_file") orelse unreachable;
    const result = try tool.execute(&ctx, args);
    try std.testing.expectEqualStrings("hello world", result);
}
