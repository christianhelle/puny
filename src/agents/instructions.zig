const std = @import("std");

pub const LoadResult = struct {
    filename: []const u8,
    content: []const u8,
};

const candidate_files = [_][]const u8{
    "AGENTS.md",
    ".github/copilot-instructions.md",
    "CLAUDE.md",
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

fn testLoad(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, file_pairs: []const struct { []const u8, []const u8 }) !?LoadResult {
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, repo_root) catch {};

    var tmp_dir = try cwd.createDirPathOpen(io, repo_root, .{});
    defer tmp_dir.close(io);

    for (file_pairs) |pair| {
        const sub_dir_path = pair[0];
        const data = pair[1];

        // Check if the path contains a directory component
        if (std.fs.path.dirname(sub_dir_path)) |dir_part| {
            if (dir_part.len > 0) {
                tmp_dir.createDir(io, dir_part, .default_dir) catch {};
            }
        }

        try tmp_dir.writeFile(io, .{ .sub_path = sub_dir_path, .data = data });
    }

    return load(allocator, io, repo_root);
}

test "load returns null when no instruction files exist" {
    const cwd = std.Io.Dir.cwd();
    const tmp_name = "zig-test-no-files";
    defer cwd.deleteTree(std.testing.io, tmp_name) catch {};

    const result = try load(std.testing.allocator, std.testing.io, tmp_name);
    try std.testing.expect(result == null);
}

test "load finds AGENTS.md with highest priority" {
    const result = (try testLoad(std.testing.allocator, std.testing.io, "zig-test-agents-priority", &.{
        .{ "AGENTS.md", "agents content" },
        .{ "CLAUDE.md", "claude content" },
    })).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("AGENTS.md", result.filename);
    try std.testing.expectEqualStrings("agents content", result.content);
}

test "load falls back to CLAUDE.md when AGENTS.md missing" {
    const result = (try testLoad(std.testing.allocator, std.testing.io, "zig-test-claude-fallback", &.{
        .{ "CLAUDE.md", "claude content" },
        .{ ".cursorrules", "cursor content" },
    })).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("CLAUDE.md", result.filename);
    try std.testing.expectEqualStrings("claude content", result.content);
}

test "load skips directories at candidate paths" {
    const cwd = std.Io.Dir.cwd();
    const tmp_name = "zig-test-skip-dir";
    defer cwd.deleteTree(std.testing.io, tmp_name) catch {};

    var tmp_dir = try cwd.createDirPathOpen(std.testing.io, tmp_name, .{});
    defer tmp_dir.close(std.testing.io);

    // AGENTS.md is a directory, not a file — load must skip it via error.IsDir
    try tmp_dir.createDir(std.testing.io, "AGENTS.md", .default_dir);

    // CLAUDE.md is a regular file and should be found
    try tmp_dir.writeFile(std.testing.io, .{ .sub_path = "CLAUDE.md", .data = "claude content" });

    const result = (try load(std.testing.allocator, std.testing.io, tmp_name)).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("CLAUDE.md", result.filename);
    try std.testing.expectEqualStrings("claude content", result.content);
}

test "load finds copilot-instructions.md inside .github" {
    const result = (try testLoad(std.testing.allocator, std.testing.io, "zig-test-copilot-github", &.{
        .{ ".github/copilot-instructions.md", "copilot instructions" },
    })).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings(".github/copilot-instructions.md", result.filename);
    try std.testing.expectEqualStrings("copilot instructions", result.content);
}

test "load reads multi-line content correctly" {
    const multiline = "Line 1\nLine 2\nLine 3\n";
    const result = (try testLoad(std.testing.allocator, std.testing.io, "zig-test-multiline", &.{
        .{ "AGENTS.md", multiline },
    })).?;
    defer std.testing.allocator.free(result.filename);
    defer std.testing.allocator.free(result.content);

    try std.testing.expectEqualStrings("AGENTS.md", result.filename);
    try std.testing.expectEqualStrings(multiline, result.content);
}
