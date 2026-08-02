const std = @import("std");
const tools = @import("root.zig");
const skills = @import("../skills/skills.zig");
const ToolContext = tools.ToolContext;

const LoadSkillParams = struct {
    skill_name: []const u8,
};

fn loadSkill(ctx: *ToolContext, params: LoadSkillParams) ![]const u8 {
    const reg = skills.getGlobalRegistry() orelse
        return try std.fmt.allocPrint(ctx.allocator, "Error: skill registry not initialized", .{});

    const record = reg.findByName(params.skill_name) orelse
        return try std.fmt.allocPrint(ctx.allocator, "Unknown skill: {s}. Use /skills to list available skills.", .{params.skill_name});

    if (record.disable_model_invocation)
        return try std.fmt.allocPrint(ctx.allocator, "Skill '{s}' is not available for model invocation. Use /{s} to load it manually.", .{ params.skill_name, params.skill_name });

    const content = reg.loadContent(ctx.io, params.skill_name, ctx.allocator) catch |err|
        return try std.fmt.allocPrint(ctx.allocator, "Error loading skill '{s}': {}", .{ params.skill_name, err });

    skills.setPendingSkill(params.skill_name, content, ctx.allocator);
    return try std.fmt.allocPrint(ctx.allocator, "Skill '{s}' loaded.", .{params.skill_name});
}

pub const load_skill = tools.defineTool(
    "load_skill",
    "Load a skill by name. The <available_skills> block in the system prompt lists available skills. Use this when the user's request matches a skill's purpose.",
    LoadSkillParams,
    loadSkill,
);
