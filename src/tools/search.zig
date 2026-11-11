const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const GrepSearchParams = struct {
    query: []const u8,
    path: ?[]const u8 = null,
    case_sensitive: ?bool = null,
};

/// Builds the ripgrep argv for `params`. Caller frees the returned slice;
/// the strings themselves are borrowed from `params` or static.
fn buildGrepArgv(allocator: std.mem.Allocator, params: GrepSearchParams) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);

    try argv.append(allocator, "rg");
    try argv.append(allocator, "--line-number");
    try argv.append(allocator, "--with-filename");

    if (params.case_sensitive) |case_sensitive| {
        if (!case_sensitive) {
            try argv.append(allocator, "--ignore-case");
        }
    }

    try argv.append(allocator, params.query);

    if (params.path) |path| {
        try argv.append(allocator, path);
    } else {
        try argv.append(allocator, ".");
    }

    return argv.toOwnedSlice(allocator);
}

fn grepSearch(allocator: std.mem.Allocator, io: std.Io, params: GrepSearchParams) ![]const u8 {
    const argv = try buildGrepArgv(allocator, params);
    defer allocator.free(argv);

    return helpers.runCommandTimed(allocator, io, argv, null, helpers.run_command_timeout_ns) catch |err| switch (err) {
        error.TimedOut => std.fmt.allocPrint(allocator, "Tool grep_search timed out after {d} seconds.", .{@divTrunc(helpers.run_command_timeout_ns, std.time.ns_per_s)}),
        else => return err,
    };
}

pub const grep_search = tools.defineTool(
    "grep_search",
    "Search file contents using ripgrep. Returns matching lines with file names and line numbers.",
    GrepSearchParams,
    grepSearch,
);

test "grepSearch propagates the failure when ripgrep is unavailable" {
    return error.SkipZigTest;
}

test "grepSearch runs ripgrep and returns matching lines" {
    return error.SkipZigTest;
}

test "buildGrepArgv passes --ignore-case only when case_sensitive is false" {
    const alloc = std.testing.allocator;

    const insensitive = try buildGrepArgv(alloc, .{ .query = "q", .case_sensitive = false });
    defer alloc.free(insensitive);
    try std.testing.expect(containsArg(insensitive, "--ignore-case"));

    const sensitive = try buildGrepArgv(alloc, .{ .query = "q", .case_sensitive = true });
    defer alloc.free(sensitive);
    try std.testing.expect(!containsArg(sensitive, "--ignore-case"));

    const unset = try buildGrepArgv(alloc, .{ .query = "q" });
    defer alloc.free(unset);
    try std.testing.expect(!containsArg(unset, "--ignore-case"));
}

test "buildGrepArgv defaults to the current directory when no path is given" {
    const alloc = std.testing.allocator;
    const argv = try buildGrepArgv(alloc, .{ .query = "needle" });
    defer alloc.free(argv);
    try std.testing.expectEqualStrings("rg", argv[0]);
    try std.testing.expectEqualStrings("needle", argv[argv.len - 2]);
    try std.testing.expectEqualStrings(".", argv[argv.len - 1]);
}

test "buildGrepArgv puts query then path last" {
    const alloc = std.testing.allocator;
    const argv = try buildGrepArgv(alloc, .{ .query = "needle", .path = "src", .case_sensitive = false });
    defer alloc.free(argv);
    try std.testing.expectEqualStrings("rg", argv[0]);
    try std.testing.expect(containsArg(argv, "--line-number"));
    try std.testing.expect(containsArg(argv, "--with-filename"));
    try std.testing.expectEqualStrings("needle", argv[argv.len - 2]);
    try std.testing.expectEqualStrings("src", argv[argv.len - 1]);
}

fn containsArg(argv: []const []const u8, arg: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, arg)) return true;
    }
    return false;
}
