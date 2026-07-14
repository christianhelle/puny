const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const ExecuteShellParams = struct {
    command: []const u8,
    working_directory: ?[]const u8 = null,
};

fn executeShell(allocator: std.mem.Allocator, io: std.Io, params: ExecuteShellParams) ![]const u8 {
    const argv = if (@import("builtin").os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", params.command }
    else
        &[_][]const u8{ "sh", "-c", params.command };

    return helpers.runCommand(allocator, io, argv, params.working_directory);
}

pub const execute_shell = tools.defineTool(
    "execute_shell",
    "Execute a shell command and return stdout, stderr, and exit code.",
    ExecuteShellParams,
    executeShell,
);
