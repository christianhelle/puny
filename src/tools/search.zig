const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const GrepSearchParams = struct {
    query: []const u8,
    path: ?[]const u8 = null,
    case_sensitive: ?bool = null,
};

fn grepSearch(allocator: std.mem.Allocator, io: std.Io, params: GrepSearchParams) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

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

    return helpers.runCommandTimed(allocator, io, argv.items, null, helpers.run_command_timeout_ns) catch |err| switch (err) {
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

fn ripgrepAvailable(io: std.Io) bool {
    const result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &[_][]const u8{"rg"},
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer std.heap.page_allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "grepSearch propagates the failure when ripgrep is unavailable" {
    if (ripgrepAvailable(std.testing.io)) return error.SkipZigTest;

    // Spawning a missing executable fails with FileNotFound (ENOENT).
    try std.testing.expectError(
        error.FileNotFound,
        grepSearch(std.testing.allocator, std.testing.io, .{ .query = "needle", .path = "/tmp" }),
    );
}

test "grepSearch runs ripgrep and returns matching lines" {
    if (!ripgrepAvailable(std.testing.io)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "needle.txt", .data = "line one\nneedle here\nline three" });
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const output = try grepSearch(std.testing.allocator, std.testing.io, .{ .query = "needle", .path = base_path });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "needle.txt:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "needle here") != null);
}

test "grepSearch passes --ignore-case when case_sensitive is false" {
    if (!ripgrepAvailable(std.testing.io)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "case.txt", .data = "MixedCase token" });
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const output = try grepSearch(std.testing.allocator, std.testing.io, .{ .query = "mixedcase", .path = base_path, .case_sensitive = false });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "case.txt:1") != null);

    // The same query without --ignore-case must not match.
    const strict = try grepSearch(std.testing.allocator, std.testing.io, .{ .query = "mixedcase", .path = base_path, .case_sensitive = true });
    defer std.testing.allocator.free(strict);
    try std.testing.expect(std.mem.indexOf(u8, strict, "case.txt") == null);
}
