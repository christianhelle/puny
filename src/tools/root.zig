const std = @import("std");

pub const schema = @import("schema.zig");
const helpers = @import("helpers.zig");

pub const Tool = schema.Tool;
pub const dupeString = helpers.dupeString;
pub const ownedSliceOrEmpty = helpers.ownedSliceOrEmpty;

pub fn defineTool(
    comptime name: []const u8,
    comptime description: []const u8,
    comptime Params: type,
    comptime handler: fn (allocator: std.mem.Allocator, io: std.Io, params: Params) anyerror![]const u8,
) Tool {
    const Schema = schema.ToolDefinition(name, description, Params);

    return .{
        .name = name,
        .description = description,
        .schema = Schema.schema,
        .execute = struct {
            pub fn exec(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]const u8 {
                const parsed = try std.json.parseFromValue(Params, allocator, args, .{});
                defer parsed.deinit();
                return handler(allocator, io, parsed.value);
            }
        }.exec,
    };
}

pub fn dispatch(name: []const u8) ?Tool {
    inline for (registry) |tool| {
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
    try std.testing.expect(dispatch("unknown_tool") == null);
}
