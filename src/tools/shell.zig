const std = @import("std");
const tools = @import("root.zig");

const ExecuteShellParams = struct {
    command: []const u8,
    working_directory: ?[]const u8 = null,
};

fn executeShell(allocator: std.mem.Allocator, params: ExecuteShellParams) ![]const u8 {
    const argv = if (@import("builtin").os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", params.command }
    else
        &[_][]const u8{ "sh", "-c", params.command };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (params.working_directory) |cwd| {
        child.cwd = cwd;
    }

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const writer = result.writer();

    switch (term) {
        .Exited => |code| try writer.print("Exit code: {d}\n", .{code}),
        else => try writer.print("Terminated: {}\n", .{term}),
    }

    if (stdout.len > 0) {
        try writer.print("STDOUT:\n{s}\n", .{stdout});
    }
    if (stderr.len > 0) {
        try writer.print("STDERR:\n{s}\n", .{stderr});
    }

    allocator.free(stdout);
    return result.toOwnedSlice();
}

pub const execute_shell = tools.defineTool(
    "execute_shell",
    "Execute a shell command and return stdout, stderr, and exit code.",
    ExecuteShellParams,
    executeShell,
);
