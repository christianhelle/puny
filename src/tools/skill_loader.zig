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

    const content = reg.loadContent(io, params.skill_name, allocator) catch |err|
        return try std.fmt.allocPrint(allocator, "Error loading skill '{s}': {}", .{ params.skill_name, err });

    skills.setPendingSkill(params.skill_name, content, allocator);
    return try std.fmt.allocPrint(allocator, "Skill '{s}' loaded.", .{params.skill_name});
}

pub const load_skill = tools.defineTool(
    "load_skill",
    "Load a skill by name. The <available_skills> block in the system prompt lists available skills. Use this when the user's request matches a skill's purpose.",
    LoadSkillParams,
    loadSkill,
);

// The global registry cannot be set back to null (setGlobalRegistry takes a
// *Registry), so tests that install a registry restore it to this process-
// lifetime stand-in instead of the null initial state.
var test_backup_registry: skills.Registry = .{
    .allocator = std.heap.page_allocator,
    .records = .empty,
    .fully_scanned = false,
};

test "loadSkill reports when the skill registry is not initialized" {
    // Runs before any test installs a registry; the global starts null.
    if (skills.getGlobalRegistry() != null) return error.SkipZigTest;

    const output = try loadSkill(std.testing.allocator, std.testing.io, .{ .skill_name = "any" });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("Error: skill registry not initialized", output);
}

test "setGlobalRegistry and getGlobalRegistry round trip" {
    var registry = skills.Registry.init(std.testing.allocator);
    defer registry.deinit();

    skills.setGlobalRegistry(&registry);
    try std.testing.expect(skills.getGlobalRegistry() == &registry);
    defer skills.setGlobalRegistry(&test_backup_registry);
}

test "loadSkill reports an unknown skill name" {
    const previous = skills.getGlobalRegistry();
    defer if (previous) |p| skills.setGlobalRegistry(p);

    var registry = skills.Registry.init(std.testing.allocator);
    defer registry.deinit();
    skills.setGlobalRegistry(&registry);

    const output = try loadSkill(std.testing.allocator, std.testing.io, .{ .skill_name = "missing-skill" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Unknown skill: missing-skill"));
}

test "loadSkill refuses skills that disable model invocation" {
    const previous = skills.getGlobalRegistry();
    defer if (previous) |p| skills.setGlobalRegistry(p);

    // The record strings are static literals: registry.deinit must not run.
    const record = skills.SkillRecord{
        .name = "manual-only",
        .description = null,
        .dir_path = "/nonexistent",
        .triggers = null,
        .disable_model_invocation = true,
    };
    var registry = skills.Registry.init(std.testing.allocator);
    try registry.records.append(std.testing.allocator, record);
    // The record strings are static literals; only the array buffer is freed.
    defer registry.records.deinit(std.testing.allocator);
    skills.setGlobalRegistry(&registry);

    const output = try loadSkill(std.testing.allocator, std.testing.io, .{ .skill_name = "manual-only" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "not available for model invocation"));
}

test "loadSkill reports a load failure for a skill without content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "empty-skill", .default_dir);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const previous = skills.getGlobalRegistry();
    defer if (previous) |p| skills.setGlobalRegistry(p);

    var registry = skills.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    skills.setGlobalRegistry(&registry);

    const output = try loadSkill(std.testing.allocator, std.testing.io, .{ .skill_name = "empty-skill" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Error loading skill 'empty-skill'"));
}

test "loadSkill queues the skill content for the next turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = "---\nname: my-skill\ndescription: Demo\n---\nskill body here" });
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const previous = skills.getGlobalRegistry();
    defer if (previous) |p| skills.setGlobalRegistry(p);

    var registry = skills.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    skills.setGlobalRegistry(&registry);

    // page_allocator: setPendingSkill retains dupes in the global queue, which
    // outlives the test; std.testing.allocator would flag them as leaks.
    const output = try loadSkill(std.heap.page_allocator, std.testing.io, .{ .skill_name = "my-skill" });
    defer std.heap.page_allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Skill 'my-skill' loaded."));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const pending = skills.takePendingSkill(arena_state.allocator()).?;
    try std.testing.expectEqualStrings("my-skill", pending.name);
    try std.testing.expectEqualStrings("\nskill body here", pending.content);
    try std.testing.expect(skills.takePendingSkill(arena_state.allocator()) == null);
}
