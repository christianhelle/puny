const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");
const core_session = @import("../core/session.zig");

const ExecuteShellParams = struct {
    command: []const u8,
    working_directory: ?[]const u8 = null,
    timeout_seconds: ?i64 = null,
};

fn isBlockedReviewCommand(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, ">") != null) return true;
    if (std.mem.indexOf(u8, command, "tee") != null) return true;

    const blocked_substrings = [_][]const u8{
        "rm ",
        "rm\t",
        "mv ",
        "mv\t",
        "cp ",
        "cp\t",
        "mkdir",
        "rmdir",
        "touch ",
        "touch\t",
        "chmod",
        "chown",
        "truncate",
        "dd ",
        "dd\t",
        "mkfs",
        "sudo",
        "ln ",
        "ln\t",
        "git commit",
        "git reset",
        "git checkout",
        "git switch",
        "git push",
        "git pull",
        "git merge",
        "git rebase",
        "git add",
        "git rm",
        "git mv",
        "git restore",
        "git clean",
        "git stash",
        "git revert",
        "git cherry-pick",
        "git tag",
        "git branch -d",
        "git branch --delete",
        "git config",
        "sed -i",
    };
    for (blocked_substrings) |needle| {
        if (std.mem.indexOf(u8, command, needle) != null) return true;
    }
    return false;
}

fn executeShell(allocator: std.mem.Allocator, io: std.Io, params: ExecuteShellParams) ![]const u8 {
    if (core_session.isWriteBlocked() and isBlockedReviewCommand(params.command)) {
        return std.fmt.allocPrint(
            allocator,
            "Review mode: shell command blocked. Only read-only inspections and build checks are allowed.",
            .{},
        );
    }

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

pub const review_execute_shell = tools.defineTool(
    "execute_shell",
    "Execute a read-only shell command for inspections and build checks; mutating commands are blocked.",
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

test "execute_shell reports the exit code when there is no output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = "true" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDOUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR") == null);
}

test "execute_shell honors a generous model-supplied timeout" {
    const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = "echo quick", .timeout_seconds = 60 });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "quick") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 0") != null);
}

test "execute_shell runs the command in the given working directory" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const dir_name = "puny-test-shell-workdir";
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, dir_name);
    defer cwd.deleteDir(std.testing.io, dir_name) catch {};

    const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = "pwd", .working_directory = dir_name });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, dir_name));
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 0") != null);
}

test "execute_shell propagates errors for a missing working directory" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectError(
        error.FileNotFound,
        executeShell(std.testing.allocator, std.testing.io, .{ .command = "echo x", .working_directory = "puny-test-shell-missing-dir" }),
    );
}

test "execute_shell blocks mutating commands in review mode" {
    core_session.setWriteBlocked(true);
    defer core_session.setWriteBlocked(false);

    const blocked = [_][]const u8{
        "rm foo.txt",
        "echo hi > file.txt",
        "git commit -m 'x'",
        "git reset --hard HEAD",
        "mv a b",
        "cp a b",
        "mkdir newdir",
        "git checkout main",
        "git push origin main",
        "sudo rm -rf /",
        "echo hi | tee file.txt",
        "sed -i s/foo/bar/ file.txt",
    };
    for (blocked) |cmd| {
        const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = cmd });
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, output, "Review mode:"));
    }
}

test "execute_shell allows read-only checks in review mode" {
    core_session.setWriteBlocked(true);
    defer core_session.setWriteBlocked(false);

    const allowed = [_][]const u8{
        "echo hello from shell",
        "git status",
        "git diff --stat",
    };
    for (allowed) |cmd| {
        const output = try executeShell(std.testing.allocator, std.testing.io, .{ .command = cmd });
        defer std.testing.allocator.free(output);
        // Allowed commands should not be blocked; they either succeed or fail due to missing tool but not due to review block.
        if (std.mem.startsWith(u8, output, "Review mode:")) {
            std.debug.print("allowed command was blocked: {s}\noutput: {s}\n", .{ cmd, output });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(std.mem.startsWith(u8, output, "Exit code:"));
    }
}
