const std = @import("std");
const tools = @import("root.zig");
const skills = @import("../skills/skills.zig");
const ToolContext = tools.ToolContext;

const LoadSkillParams = struct {
    skill_name: []const u8,
};

fn loadSkill(ctx: *ToolContext, params: LoadSkillParams) ![]const u8 {
    const reg = ctx.skills;

    const record = reg.findByName(params.skill_name) orelse
        return try std.fmt.allocPrint(ctx.allocator, "Unknown skill: {s}. Use /skills to list available skills.", .{params.skill_name});

    if (record.disable_model_invocation)
        return try std.fmt.allocPrint(ctx.allocator, "Skill '{s}' is not available for model invocation. Use /{s} to load it manually.", .{ params.skill_name, params.skill_name });

    const content = reg.loadContent(ctx.io, params.skill_name, ctx.allocator) catch |err|
        return try std.fmt.allocPrint(ctx.allocator, "Error loading skill '{s}': {}", .{ params.skill_name, err });

    ctx.enqueuePendingSkill(params.skill_name, content);
    return try std.fmt.allocPrint(ctx.allocator, "Skill '{s}' loaded.", .{params.skill_name});
}

pub const load_skill = tools.defineTool(
    "load_skill",
    "Load a skill by name. The <available_skills> block in the system prompt lists available skills. Use this when the user's request matches a skill's purpose.",
    LoadSkillParams,
    loadSkill,
);

test "load_skill enqueues pending skill through the context registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "grill-me", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "grill-me/SKILL.md", .data = "---\nname: grill-me\ndescription: Test skill\n---\nbody text" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = skills.Registry.init(arena);
    defer registry.deinit();
    const base_path = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    var ctx = tools.ToolContext.init(arena, std.testing.io, &registry);
    defer ctx.deinit();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"skill_name\":\"grill-me\"}", .{});
    const result = try load_skill.execute(&ctx, args);
    try std.testing.expect(std.mem.indexOf(u8, result, "grill-me") != null);

    const pending = ctx.takePendingSkill(arena).?;
    try std.testing.expectEqualStrings("grill-me", pending.name);
    try std.testing.expectEqualStrings("\nbody text", pending.content);
}
