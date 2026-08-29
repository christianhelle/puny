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

test "runCommandTimed kills a grandchild that keeps the pipes open" {
    // A timed-out child that spawned a grandchild inheriting the stdout pipe
    // would keep the drain blocked unless the process-group kill reaches the
    // whole tree. The call must still return within the grace period and must
    // not abandon the worker.
    // On Windows the grandchild is spawned with -NoNewWindow so it is a direct
    // child (CreateProcess parenting) that the taskkill /T tree kill reliably
    // reaches; plain Start-Process goes through ShellExecuteEx, opens its own
    // console window, and can orphan the grandchild from the kill. The
    // grandchild loop is silent so the shared console is not spammed, but it
    // keeps the inherited stdout pipe open to exercise the pipe-drain path.
    const before = run_command.test_run_command_worker_detached;
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-Command", "Start-Process powershell -NoNewWindow -ArgumentList '-NoProfile','-Command','while ($true) { Start-Sleep -Milliseconds 10 }'; while ($true) { Start-Sleep -Milliseconds 10 }" }
    else
        &.{ "sh", "-c", "sh -c 'while true; do echo x; sleep 0.01; done' & while true; do sleep 0.01; done" };

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const result = run_command.runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 200 * std.time.ns_per_ms);
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.nanoseconds;

    try std.testing.expectError(error.TimedOut, result);
    try std.testing.expectEqual(before, run_command.test_run_command_worker_detached);
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}

test "runCommandTimed times out on a lingering grandchild after the parent exits" {
    // The parent exits 0 immediately, but a backgrounded grandchild holds the
    // inherited stdout pipe open. The drain cannot see EOF, so the call must
    // time out, kill the whole process group (including the grandchild), and
    // return without abandoning the worker.
    // Skipped on Windows: a grandchild can only inherit the pipe through the
    // parent, and once the parent exits it is orphaned, so `taskkill /T` (the
    // tree kill killProcessTree relies on) can no longer reach it and the
    // worker has to be abandoned. The parent-stays-alive variant is covered
    // by the previous test.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const before = run_command.test_run_command_worker_detached;
    const argv: []const []const u8 = &.{ "sh", "-c", "(sleep 60 &); exit 0" };

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const result = run_command.runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 200 * std.time.ns_per_ms);
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.nanoseconds;

    try std.testing.expectError(error.TimedOut, result);
    try std.testing.expectEqual(before, run_command.test_run_command_worker_detached);
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}
