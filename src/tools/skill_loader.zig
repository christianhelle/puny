const std = @import("std");
const tools = @import("root.zig");
const skills = @import("../skills/skills.zig");

const LoadSkillParams = struct {
    skill_name: []const u8,
};

fn loadSkill(allocator: std.mem.Allocator, io: std.Io, params: LoadSkillParams) ![]const u8 {
    const reg = skills.getGlobalRegistry() orelse
        return try std.fmt.allocPrint(allocator, "Error: skill registry not initialized", .{});

    const record = reg.findByName(params.skill_name) orelse
        return try std.fmt.allocPrint(allocator, "Unknown skill: {s}. Use /skills to list available skills.", .{params.skill_name});

    if (record.disable_model_invocation)
        return try std.fmt.allocPrint(allocator, "Skill '{s}' is not available for model invocation. Use /{s} to load it manually.", .{ params.skill_name, params.skill_name });

    return reg.loadContent(io, params.skill_name, allocator) catch |err|
        return try std.fmt.allocPrint(allocator, "Error loading skill '{s}': {}", .{ params.skill_name, err });
}

pub const load_skill = tools.defineTool(
    "load_skill",
    "Load a skill by name. The <available_skills> block in the system prompt lists available skills. Use this when the user's request matches a skill's purpose.",
    LoadSkillParams,
    loadSkill,
);
