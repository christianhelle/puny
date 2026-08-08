const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const GitStatusParams = struct {
    path: ?[]const u8 = null,
};

fn gitStatus(allocator: std.mem.Allocator, io: std.Io, params: GitStatusParams) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &[_][]const u8{ "git", "status", "--short", "--branch" });
    if (params.path) |path| {
        try argv.append(allocator, path);
    }
    return helpers.runCommandTimed(allocator, io, argv.items, null, helpers.run_command_timeout_ns) catch |err| switch (err) {
        error.TimedOut => std.fmt.allocPrint(allocator, "Tool git_status timed out after {d} seconds.", .{@divTrunc(helpers.run_command_timeout_ns, std.time.ns_per_s)}),
        else => return err,
    };
}

const GitDiffParams = struct {
    path: ?[]const u8 = null,
    staged: ?bool = null,
};

fn gitDiff(allocator: std.mem.Allocator, io: std.Io, params: GitDiffParams) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &[_][]const u8{ "git", "diff" });
    if (params.staged) |staged| {
        if (staged) {
            try argv.append(allocator, "--staged");
        }
    }
    if (params.path) |path| {
        try argv.append(allocator, "--");
        try argv.append(allocator, path);
    }
    return helpers.runCommandTimed(allocator, io, argv.items, null, helpers.run_command_timeout_ns) catch |err| switch (err) {
        error.TimedOut => std.fmt.allocPrint(allocator, "Tool git_diff timed out after {d} seconds.", .{@divTrunc(helpers.run_command_timeout_ns, std.time.ns_per_s)}),
        else => return err,
    };
}

pub const git_status = tools.defineTool(
    "git_status",
    "Run git status --short --branch to see repository state.",
    GitStatusParams,
    gitStatus,
);

pub const git_diff = tools.defineTool(
    "git_diff",
    "Run git diff to see changes. Optionally show staged changes.",
    GitDiffParams,
    gitDiff,
);

test "git_status reports the current branch and untracked files" {
    const path = "puny-test-git-probe.txt";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};

    var f = try cwd.createFile(std.testing.io, path, .{});
    f.close(std.testing.io);

    const output = try gitStatus(std.testing.allocator, std.testing.io, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "## ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, path) != null);
}

test "git_status accepts a path argument" {
    const output = try gitStatus(std.testing.allocator, std.testing.io, .{ .path = "src" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "## ") != null);
}

test "git_diff runs and returns output" {
    const output = try gitDiff(std.testing.allocator, std.testing.io, .{});
    defer std.testing.allocator.free(output);
    _ = output;
}

test "git_diff accepts staged and path arguments" {
    const output = try gitDiff(std.testing.allocator, std.testing.io, .{ .staged = false, .path = "src" });
    defer std.testing.allocator.free(output);
    _ = output;
}
