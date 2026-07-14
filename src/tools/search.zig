const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const GrepSearchParams = struct {
    query: []const u8,
    path: ?[]const u8 = null,
    case_sensitive: ?bool = null,
};

fn grepSearch(allocator: std.mem.Allocator, io: std.Io, params: GrepSearchParams) ![]const u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("rg");
    try argv.append("--line-number");
    try argv.append("--with-filename");

    if (params.case_sensitive) |case_sensitive| {
        if (!case_sensitive) {
            try argv.append("--ignore-case");
        }
    }

    try argv.append(params.query);

    if (params.path) |path| {
        try argv.append(path);
    } else {
        try argv.append(".");
    }

    return helpers.runCommand(allocator, io, argv.items, null);
}

pub const grep_search = tools.defineTool(
    "grep_search",
    "Search file contents using ripgrep. Returns matching lines with file names and line numbers.",
    GrepSearchParams,
    grepSearch,
);
