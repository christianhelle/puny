const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");
const ToolContext = tools.ToolContext;

const GrepSearchParams = struct {
    query: []const u8,
    path: ?[]const u8 = null,
    case_sensitive: ?bool = null,
};

fn grepSearch(ctx: *ToolContext, params: GrepSearchParams) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);

    try argv.append(ctx.allocator, "rg");
    try argv.append(ctx.allocator, "--line-number");
    try argv.append(ctx.allocator, "--with-filename");

    if (params.case_sensitive) |case_sensitive| {
        if (!case_sensitive) {
            try argv.append(ctx.allocator, "--ignore-case");
        }
    }

    try argv.append(ctx.allocator, params.query);

    if (params.path) |path| {
        try argv.append(ctx.allocator, path);
    } else {
        try argv.append(ctx.allocator, ".");
    }

    return helpers.runCommand(ctx.allocator, ctx.io, argv.items, null);
}

pub const grep_search = tools.defineTool(
    "grep_search",
    "Search file contents using ripgrep. Returns matching lines with file names and line numbers.",
    GrepSearchParams,
    grepSearch,
);
