const std = @import("std");

pub const schema = @import("schema.zig");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: *const fn (allocator: std.mem.Allocator) std.mem.Allocator.Error!std.json.Value,
    execute: *const fn (allocator: std.mem.Allocator, args: std.json.Value) anyerror![]const u8,
};

pub fn defineTool(
    comptime name: []const u8,
    comptime description: []const u8,
    comptime Params: type,
    comptime handler: fn (allocator: std.mem.Allocator, params: Params) anyerror![]const u8,
) Tool {
    const Schema = schema.ToolDefinition(name, description, Params);

    return .{
        .name = name,
        .description = description,
        .schema = Schema.schema,
        .execute = struct {
            pub fn exec(allocator: std.mem.Allocator, args: std.json.Value) ![]const u8 {
                const parsed = try std.json.parseFromValue(Params, allocator, args, .{});
                defer parsed.deinit();
                return handler(allocator, parsed.value);
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
