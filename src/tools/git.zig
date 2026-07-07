const std = @import("std");
const tools = @import("root.zig");

fn runGit(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    if (stdout.len == 0 and term == .Exited and term.Exited != 0) {
        allocator.free(stdout);
        return std.fmt.allocPrint(allocator, "git failed: {s}", .{stderr});
    }

    if (stdout.len == 0) {
        allocator.free(stdout);
        return "No output.";
    }

    return stdout;
}

const GitStatusParams = struct {
    path: ?[]const u8 = null,
};

fn gitStatus(allocator: std.mem.Allocator, params: GitStatusParams) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&[_][]const u8{ "git", "status", "--short", "--branch" });
    if (params.path) |path| {
        try argv.append(path);
    }
    return runGit(allocator, argv.items);
}

const GitDiffParams = struct {
    path: ?[]const u8 = null,
    staged: ?bool = null,
};

fn gitDiff(allocator: std.mem.Allocator, params: GitDiffParams) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&[_][]const u8{ "git", "diff" });
    if (params.staged) |staged| {
        if (staged) {
            try argv.append("--staged");
        }
    }
    if (params.path) |path| {
        try argv.append("--");
        try argv.append(path);
    }
    return runGit(allocator, argv.items);
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
