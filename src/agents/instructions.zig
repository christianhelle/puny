const std = @import("std");

pub const LoadResult = struct {
    filename: []const u8,
    content: []const u8,
};

const candidate_files = [_][]const u8{
    "AGENTS.md",
    "CLAUDE.md",
    ".cursorrules",
    ".windsurfrules",
    ".github/copilot-instructions.md",
};

/// Scans the given directory for coding agent instruction files in priority order.
/// Returns the content of the first file found, or null if none exist.
/// Caller owns the returned memory (both filename and content).
pub fn load(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) !?LoadResult {
    for (candidate_files) |rel_path| {
        const full_path = try std.fs.path.join(allocator, &.{ repo_root, rel_path });
        defer allocator.free(full_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.IsDir => continue,
            error.AccessDenied => continue,
            else => |e| return e,
        };

        return LoadResult{
            .filename = try allocator.dupe(u8, rel_path),
            .content = content,
        };
    }
    return null;
}

test "load returns null when no instruction files exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try load(std.testing.allocator, std.testing.io, &tmp.sub_path);
    try std.testing.expect(result == null);
}

test "load finds AGENTS.md with highest priority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "agents content" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CLAUDE.md", .data = "claude content" });

    const result = (try load(std.testing.allocator, std.testing.io, &tmp.sub_path)).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("AGENTS.md", result.filename);
    try std.testing.expectEqualStrings("agents content", result.content);
}

test "load falls back to CLAUDE.md when AGENTS.md missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CLAUDE.md", .data = "claude content" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".cursorrules", .data = "cursor content" });

    const result = (try load(std.testing.allocator, std.testing.io, &tmp.sub_path)).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("CLAUDE.md", result.filename);
    try std.testing.expectEqualStrings("claude content", result.content);
}

test "load skips directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, ".github", .default_dir);

    // Only CLAUDE.md exists (AGENTS.md is a dir)
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CLAUDE.md", .data = "claude content" });

    const result = (try load(std.testing.allocator, std.testing.io, &tmp.sub_path)).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("CLAUDE.md", result.filename);
    try std.testing.expectEqualStrings("claude content", result.content);
}

test "load finds copilot-instructions.md inside .github" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, ".github", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".github/copilot-instructions.md", .data = "copilot instructions" });

    const result = (try load(std.testing.allocator, std.testing.io, &tmp.sub_path)).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings(".github/copilot-instructions.md", result.filename);
    try std.testing.expectEqualStrings("copilot instructions", result.content);
}

test "load reads multi-line content correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const multiline = "Line 1\nLine 2\nLine 3\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = multiline });

    const result = (try load(std.testing.allocator, std.testing.io, &tmp.sub_path)).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("AGENTS.md", result.filename);
    try std.testing.expectEqualStrings(multiline, result.content);
}
