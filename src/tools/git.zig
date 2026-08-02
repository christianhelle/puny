const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");
const ToolContext = tools.ToolContext;

const GitStatusParams = struct {
    path: ?[]const u8 = null,
};

fn gitStatus(ctx: *ToolContext, params: GitStatusParams) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &[_][]const u8{ "git", "status", "--short", "--branch" });
    if (params.path) |path| {
        try argv.append(ctx.allocator, path);
    }
    return helpers.runCommand(ctx.allocator, ctx.io, argv.items, null);
}

const GitDiffParams = struct {
    path: ?[]const u8 = null,
    staged: ?bool = null,
};

fn gitDiff(ctx: *ToolContext, params: GitDiffParams) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &[_][]const u8{ "git", "diff" });
    if (params.staged) |staged| {
        if (staged) {
            try argv.append(ctx.allocator, "--staged");
        }
    }
    if (params.path) |path| {
        try argv.append(ctx.allocator, "--");
        try argv.append(ctx.allocator, path);
    }
    return helpers.runCommand(ctx.allocator, ctx.io, argv.items, null);
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
