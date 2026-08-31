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
    inline for (planning_registry) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    inline for (review_registry) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

const filesystem = @import("filesystem.zig");
const shell = @import("shell.zig");
const search = @import("search.zig");
const git = @import("git.zig");
const web = @import("web.zig");
const review = @import("review.zig");
const core_session = @import("../core/session.zig");
const skill_loader = @import("skill_loader.zig");
const AgentMode = @import("../core/mode.zig").AgentMode;

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

pub const review_registry = blk: {
    @setEvalBranchQuota(10000);
    break :blk &[_]Tool{
        filesystem.read_file,
        filesystem.list_directory,
        shell.review_execute_shell,
        search.grep_search,
        git.git_status,
        git.git_diff,
        web.web_fetch,
        review.save_review_results,
        skill_loader.load_skill,
    };
};

pub fn registryForMode(mode: AgentMode) []const Tool {
    return switch (mode) {
        .build => registry,
        .planning => planning_registry,
        .review => review_registry,
    };
}

pub fn dispatchForMode(name: []const u8, mode: AgentMode) ?Tool {
    for (registryForMode(mode)) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

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

test "review registry permits checks and the report tool but not source writes" {
    var has_shell = false;
    var has_report = false;
    var has_write_file = false;
    var has_save_prd = false;
    for (review_registry) |tool| {
        has_shell = has_shell or std.mem.eql(u8, tool.name, "execute_shell");
        has_report = has_report or std.mem.eql(u8, tool.name, "save_review_results");
        has_write_file = has_write_file or std.mem.eql(u8, tool.name, "write_file");
        has_save_prd = has_save_prd or std.mem.eql(u8, tool.name, "save_prd");
    }
    try std.testing.expect(has_shell);
    try std.testing.expect(has_report);
    try std.testing.expect(!has_write_file);
    try std.testing.expect(!has_save_prd);
}

test "review shell is advertised as read-only while build shell is unrestricted" {
    const review_shell = dispatchForMode("execute_shell", .review).?;
    const build_shell = dispatchForMode("execute_shell", .build).?;
    try std.testing.expect(std.mem.indexOf(u8, review_shell.description, "read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_shell.description, "read-only") == null);
}

test "defineTool executes the handler with parsed JSON args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Params = struct {
        text: []const u8,
        count: i32 = 1,
    };
    const tool_def = defineTool("echo_tool", "Echoes text.", Params, struct {
        fn run(allocator: std.mem.Allocator, io: std.Io, params: Params) anyerror![]const u8 {
            _ = io;
            return std.fmt.allocPrint(allocator, "echo {d}: {s}", .{ params.count, params.text });
        }
    }.run);

    try std.testing.expectEqualStrings("echo_tool", tool_def.name);
    try std.testing.expectEqualStrings("Echoes text.", tool_def.description);

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"text\":\"hi\",\"count\":3}", .{});
    const result = try tool_def.execute(arena, std.testing.io, args);
    try std.testing.expectEqualStrings("echo 3: hi", result);
}

test "defineTool execution applies default values for omitted optional fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Params = struct {
        text: []const u8,
        count: i32 = 1,
    };
    const tool_def = defineTool("echo_tool", "Echoes text.", Params, struct {
        fn run(allocator: std.mem.Allocator, io: std.Io, params: Params) anyerror![]const u8 {
            _ = io;
            return std.fmt.allocPrint(allocator, "echo {d}: {s}", .{ params.count, params.text });
        }
    }.run);

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"text\":\"hi\"}", .{});
    const result = try tool_def.execute(arena, std.testing.io, args);
    try std.testing.expectEqualStrings("echo 1: hi", result);
}

test "dispatchForMode isolates tool allowlist per mode" {
    // Build can write, review and planning cannot.
    try std.testing.expect(dispatchForMode("write_file", .build) != null);
    try std.testing.expect(dispatchForMode("write_file", .review) == null);
    try std.testing.expect(dispatchForMode("write_file", .planning) == null);

    // save_prd only in planning.
    try std.testing.expect(dispatchForMode("save_prd", .planning) != null);
    try std.testing.expect(dispatchForMode("save_prd", .build) == null);
    try std.testing.expect(dispatchForMode("save_prd", .review) == null);

    // save_review_results only in review.
    try std.testing.expect(dispatchForMode("save_review_results", .review) != null);
    try std.testing.expect(dispatchForMode("save_review_results", .build) == null);
    try std.testing.expect(dispatchForMode("save_review_results", .planning) == null);

    // Common read tools available in all modes.
    try std.testing.expect(dispatchForMode("read_file", .build) != null);
    try std.testing.expect(dispatchForMode("read_file", .planning) != null);
    try std.testing.expect(dispatchForMode("read_file", .review) != null);

    // Shell only in build and review, not planning.
    try std.testing.expect(dispatchForMode("execute_shell", .build) != null);
    try std.testing.expect(dispatchForMode("execute_shell", .review) != null);
    try std.testing.expect(dispatchForMode("execute_shell", .planning) == null);

    try std.testing.expect(dispatchForMode("unknown_tool", .build) == null);
    try std.testing.expect(dispatchForMode("unknown_tool", .review) == null);
}

test "registryForMode returns the exact allowlist used for schemas and dispatch" {
    try std.testing.expectEqual(registry.len, registryForMode(.build).len);
    try std.testing.expectEqual(planning_registry.len, registryForMode(.planning).len);
    try std.testing.expectEqual(review_registry.len, registryForMode(.review).len);
}
