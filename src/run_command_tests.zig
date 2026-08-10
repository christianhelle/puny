//! Slow runCommand/runCommandTimed tests, run only as part of the regression
//! suite (`zig build test-regression`) so that `zig build test` stays fast.
const std = @import("std");
const run_command = @import("tools/run_command.zig");

test "runCommandTimed returns output for a command that finishes within the deadline" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    const output = try run_command.runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "hello"));
}

fn fullStderrArgv() []const []const u8 {
    return if (@import("builtin").os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-Command", "1..20000 | ForEach-Object { [Console]::Error.WriteLine(\"stderr line $_\"); Write-Output \"stdout line $_\" }" }
    else
        &.{ "sh", "-c", "i=0; while [ $i -lt 20000 ]; do echo \"stderr line $i\" >&2; echo \"stdout line $i\"; i=$((i+1)); done" };
}

test "runCommand drains a full stderr pipe without deadlocking stdout" {
    // A child that writes more than one pipe buffer's worth to stderr while
    // also keeping stdout active would deadlock a sequential stdout-then-
    // stderr drain: the child blocks on the full stderr pipe and can never
    // close stdout, so the parent never sees EOF. The concurrent drain must
    // let the command complete.
    const output = try run_command.runCommand(std.testing.allocator, std.testing.io, fullStderrArgv(), null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stderr line 19999") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stdout line 19999") != null);
}

test "runCommandTimed drains a full stderr pipe without deadlocking stdout" {
    // The same scenario through the timed path, which drives
    // runCommandInArena; the timeout bounds the test if a regression
    // reintroduces the deadlock.
    const output = try run_command.runCommandTimed(std.testing.allocator, std.testing.io, fullStderrArgv(), null, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stderr line 19999") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stdout line 19999") != null);
}

test "runCommandTimed returns TimedOut and terminates a command that never exits" {
    const before = run_command.test_run_command_worker_detached;
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-Command", "while ($true) { 'x'; Start-Sleep -Milliseconds 10 }" }
    else
        &.{ "sh", "-c", "while true; do echo x; sleep 0.01; done" };

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const result = run_command.runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 200 * std.time.ns_per_ms);
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.nanoseconds;

    try std.testing.expectError(error.TimedOut, result);
    // The worker must have been joined, not abandoned: the hung child was
    // terminated in-process rather than left running in the background.
    try std.testing.expectEqual(before, run_command.test_run_command_worker_detached);
    // Must return long before the child could ever finish on its own.
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}

test "runCommand formats exit code and stdout" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    const output = try run_command.runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
}

test "runCommand reports a non-zero exit code" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "exit 3" }
    else
        &.{ "sh", "-c", "exit 3" };
    const output = try run_command.runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 3") != null);
}

test "runCommand captures stderr" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo oops 1>&2" }
    else
        &.{ "sh", "-c", "echo oops >&2" };
    const output = try run_command.runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "oops") != null);
}
