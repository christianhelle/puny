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
    return helpers.runCommand(allocator, io, argv.items, null);
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
    return helpers.runCommand(allocator, io, argv.items, null);
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
