//! Tests for the skills registry module. Kept in a separate file so
//! `skills.zig` stays focused on the production implementation.
const std = @import("std");
const skills = @import("skills.zig");

const SkillRecord = skills.SkillRecord;
const Registry = skills.Registry;
const homeDir = skills.homeDir;
const recordMatchesTrigger = skills.recordMatchesTrigger;

fn writeSkillFile(io: std.Io, tmp: anytype, name: []const u8, frontmatter_name: []const u8, description_lines: []const []const u8, body: []const u8) !void {
    try tmp.dir.createDir(io, name, .default_dir);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    try lines.appendSlice(std.testing.allocator, "---\nname: ");
    try lines.appendSlice(std.testing.allocator, frontmatter_name);
    try lines.appendSlice(std.testing.allocator, "\ndescription: >\n");
    for (description_lines) |line| {
        try lines.appendSlice(std.testing.allocator, "  ");
        try lines.appendSlice(std.testing.allocator, line);
        try lines.appendSlice(std.testing.allocator, "\n");
    }
    try lines.appendSlice(std.testing.allocator, "---\n");
    try lines.appendSlice(std.testing.allocator, body);

    var skill_path_buf: [256]u8 = undefined;
    const skill_path = try std.fmt.bufPrint(&skill_path_buf, "{s}/SKILL.md", .{name});

    try tmp.dir.writeFile(io, .{ .sub_path = skill_path, .data = lines.items });
}

test "init creates empty registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.records.items.len);
    try std.testing.expect(!registry.fully_scanned);
}

test "lightScan discovers skill directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    try tmp.dir.createDir(std.testing.io, "other-skill", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-dir", .data = "" });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.lightScan(std.testing.io, base_path);

    try std.testing.expectEqual(@as(usize, 2), registry.records.items.len);

    var found_my = false;
    var found_other = false;
    for (registry.records.items) |r| {
        if (std.mem.eql(u8, r.name, "my-skill")) found_my = true;
        if (std.mem.eql(u8, r.name, "other-skill")) found_other = true;
        try std.testing.expect(r.description == null);
    }
    try std.testing.expect(found_my);
    try std.testing.expect(found_other);
}

test "lightScan handles missing directory gracefully" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.lightScan(std.testing.io, "/nonexistent/path/that/does/not/exist");
    try std.testing.expectEqual(@as(usize, 0), registry.records.items.len);
}

test "findByName returns correct record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "alpha", .default_dir);
    try tmp.dir.createDir(std.testing.io, "beta", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const found = registry.findByName("beta").?;
    try std.testing.expectEqualStrings("beta", found.name);
    try std.testing.expect(found.description == null);
}

test "findByName returns null for unknown name" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expect(registry.findByName("nope") == null);
}

test "fullScan populates descriptions from frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSkillFile(std.testing.io, tmp, "my-skill", "my-skill", &.{"Does something useful."}, "This is the skill content\nwith multiple lines.");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    try std.testing.expect(registry.fully_scanned);
    const record = registry.findByName("my-skill").?;
    try std.testing.expectEqualStrings("Does something useful.", record.description.?);
}

test "fullScan handles missing SKILL.md gracefully" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "empty-dir", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    try std.testing.expect(registry.fully_scanned);
    const record = registry.findByName("empty-dir").?;
    try std.testing.expect(record.description == null);
}

test "fullScan parses frontmatter with CRLF line endings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "win-skill", .default_dir);
    const content = "---\r\nname: win-skill\r\ndescription: >\r\n  Works on Windows\r\n  with CRLF endings\r\n---\r\nbody text\r\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "win-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    try std.testing.expect(registry.fully_scanned);
    const record = registry.findByName("win-skill").?;
    try std.testing.expectEqualStrings("Works on Windows with CRLF endings", record.description.?);
}

test "fullScan parses single-line description with CRLF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "simple", .default_dir);
    const content = "---\r\nname: simple\r\ndescription: A simple skill\r\n---\r\nbody\r\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "simple/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("simple").?;
    try std.testing.expectEqualStrings("A simple skill", record.description.?);
}

test "fullScan parses multi-line folded description" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSkillFile(std.testing.io, tmp, "alba-testing", "alba-testing", &.{
        "Expert knowledge of Alba, a class library for integration testing.",
        "Covers AlbaHost creation, Scenario-based HTTP testing.",
    }, "These are the instructions.");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("alba-testing").?;
    try std.testing.expectEqualStrings("Expert knowledge of Alba, a class library for integration testing. Covers AlbaHost creation, Scenario-based HTTP testing.", record.description.?);
}

test "loadContent returns body without frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: >\n  A test skill\n---\n\nThis is the skill body\nwith multiple lines.\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const body = try registry.loadContent(std.testing.io, "my-skill", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("\n\nThis is the skill body\nwith multiple lines.\n", body);
}

test "loadContent returns full file when no frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "plain", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain/SKILL.md", .data = "Just plain text\nno frontmatter" });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const body = try registry.loadContent(std.testing.io, "plain", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("Just plain text\nno frontmatter", body);
}

test "loadContent returns error for unknown skill" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const body = registry.loadContent(std.testing.io, "nonexistent", std.testing.allocator);
    try std.testing.expectError(error.SkillNotFound, body);
}

test "buildListing shows names only before fullScan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "alpha", .default_dir);
    try tmp.dir.createDir(std.testing.io, "beta", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const listing = try registry.buildListing(std.testing.allocator);
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "<available_skills>") != null);
}

test "homeDir returns HOME from environ map" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/testuser");

    const result = try homeDir(std.testing.allocator, &env);
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("/home/testuser", result.?);
}

test "homeDir returns USERPROFILE if HOME not set" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\test");

    const result = try homeDir(std.testing.allocator, &env);
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("C:\\Users\\test", result.?);
}

test "homeDir returns null when no home vars set" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const result = try homeDir(std.testing.allocator, &env);
    try std.testing.expect(result == null);
}

test "buildListing includes descriptions after fullScan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: >\n  Does something useful\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const listing = try registry.buildListing(std.testing.allocator);
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "Does something useful") != null);
}

test "fullScan populates triggers from frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: A skill\ntriggers: do the thing, run the thing\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("my-skill").?;
    try std.testing.expect(record.triggers != null);
    try std.testing.expectEqual(@as(usize, 2), record.triggers.?.len);
    try std.testing.expectEqualStrings("do the thing", record.triggers.?[0]);
    try std.testing.expectEqualStrings("run the thing", record.triggers.?[1]);
}

test "fullScan populates disable_model_invocation from frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "manual-skill", .default_dir);
    const content = "---\nname: manual-skill\ndescription: Manual only\ndisable-model-invocation: true\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manual-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const record = registry.findByName("manual-skill").?;
    try std.testing.expect(record.disable_model_invocation);
}

test "findTriggeredSkill matches directory name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "grill-me", .default_dir);
    try tmp.dir.createDir(std.testing.io, "other-skill", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const matched = registry.findTriggeredSkill("can you grill me on this");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("grill-me", matched.?);
}

test "findTriggeredSkill matches trigger phrase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "my-skill", .default_dir);
    const content = "---\nname: my-skill\ndescription: Does stuff\ntriggers: do the thing, run it\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my-skill/SKILL.md", .data = content });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const matched = registry.findTriggeredSkill("please do the thing now");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("my-skill", matched.?);
}

test "findTriggeredSkill skips disabled skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "manual-skill", .default_dir);
    const content = "---\nname: manual-skill\ndescription: Manual\ndisable-model-invocation: true\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manual-skill/SKILL.md", .data = content });

    try tmp.dir.createDir(std.testing.io, "auto-skill", .default_dir);
    const content2 = "---\nname: auto-skill\ndescription: Auto\n---\nbody";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auto-skill/SKILL.md", .data = content2 });

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);
    try registry.fullScan(std.testing.io);

    const matched = registry.findTriggeredSkill("please use auto-skill");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("auto-skill", matched.?);
}

test "findTriggeredSkill returns null when no match" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const matched = registry.findTriggeredSkill("hello world");
    try std.testing.expect(matched == null);
}

test "findTriggeredSkill matches a hyphenated directory name in prose" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "write-a-skill", .default_dir);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.lightScan(std.testing.io, base_path);

    const matched = registry.findTriggeredSkill("help me write a skill");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("write-a-skill", matched.?);
}

test "recordMatchesTrigger matches whole words only" {
    var trigger_list = [_][]const u8{ "do it", "run now" };
    const record = SkillRecord{
        .name = "test-skill",
        .description = "",
        .dir_path = "/tmp/skills/test-skill",
        .triggers = trigger_list[0..],
        .disable_model_invocation = false,
    };
    try std.testing.expect(recordMatchesTrigger(&record, "please do it please"));
    try std.testing.expect(recordMatchesTrigger(&record, "run now!"));
    try std.testing.expect(!recordMatchesTrigger(&record, "undo it now"));
    try std.testing.expect(!recordMatchesTrigger(&record, "do"));
}
