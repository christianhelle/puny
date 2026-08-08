const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const ExecuteShellParams = struct {
    command: []const u8,
    working_directory: ?[]const u8 = null,
    timeout_seconds: ?i64 = null,
};

fn executeShell(allocator: std.mem.Allocator, io: std.Io, params: ExecuteShellParams) ![]const u8 {
    const argv = if (@import("builtin").os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", params.command }
    else
        &[_][]const u8{ "sh", "-c", params.command };

    const timeout_ns = helpers.resolveTimeoutSeconds(params.timeout_seconds, helpers.execute_shell_timeout_ns);
    return helpers.runCommandTimed(allocator, io, argv, params.working_directory, timeout_ns) catch |err| switch (err) {
        error.TimedOut => std.fmt.allocPrint(
            allocator,
            "Tool execute_shell timed out after {d} seconds. If the command legitimately needs more time, retry with a larger timeout_seconds (max 300).",
            .{@divTrunc(timeout_ns, std.time.ns_per_s)},
        ),
        else => return err,
    };
}

pub const execute_shell = tools.defineTool(
    "execute_shell",
    "Execute a shell command and return stdout, stderr, and exit code.",
    ExecuteShellParams,
    executeShell,
);

test "execute_shell runs a command and returns its output" {
    const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = "echo hello from shell" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello from shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 0") != null);
}

test "execute_shell reports a failing command exit code" {
    const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = "exit 5" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 5") != null);
}

test "execute_shell captures stderr" {
    const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = "echo problem >&2" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "problem") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
}
