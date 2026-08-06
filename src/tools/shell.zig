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
