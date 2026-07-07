const std = @import("std");
const tools = @import("root.zig");

const GrepSearchParams = struct {
    query: []const u8,
    path: ?[]const u8 = null,
    case_sensitive: ?bool = null,
};

fn grepSearch(allocator: std.mem.Allocator, params: GrepSearchParams) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
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

    var child = std.process.Child.init(argv.items, allocator);
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
        return std.fmt.allocPrint(allocator, "ripgrep failed: {s}", .{stderr});
    }

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const writer = result.writer();

    if (stdout.len > 0) {
        try writer.writeAll(stdout);
    } else {
        try writer.writeAll("No matches found.");
    }

    allocator.free(stdout);
    return result.toOwnedSlice();
}

pub const grep_search = tools.defineTool(
    "grep_search",
    "Search file contents using ripgrep. Returns matching lines with file names and line numbers.",
    GrepSearchParams,
    grepSearch,
);
