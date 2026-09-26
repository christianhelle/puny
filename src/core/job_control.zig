const std = @import("std");
const builtin = @import("builtin");

/// Stops the process's job the way the terminal's suspend key (Ctrl+Z)
/// would, and returns once the shell continues it with `fg` or `bg`. Raw
/// mode turns the terminal's signal keys off, so input loops call this when
/// they read the suspend byte themselves. Windows has no job control, so
/// there it does nothing.
pub fn stop() void {
    if (builtin.os.tag == .windows) return;
    const on_continue = std.posix.Sigaction{
        .handler = .{ .handler = markContinued },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.CONT, &on_continue, null);
    continued.store(false, .release);
    // Signal the whole process group, as the terminal does, so commands
    // Puny is running stop and continue with it.
    std.posix.kill(0, .TSTP) catch return;
    // Another thread may take the signal, letting this one run on before the
    // job stops, so wait for the continue. A stop the kernel discards, as in
    // an orphaned process group, is never continued; give up after a second.
    // poll ignores a negative fd, so this is a portable 1 ms sleep; an empty
    // slice's pointer can make the kernel fail it with EFAULT.
    var nothing = [1]std.posix.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
    var waited_ms: usize = 0;
    while (!continued.load(.acquire) and waited_ms < 1000) : (waited_ms += 1) {
        _ = std.posix.poll(&nothing, 1) catch return;
    }
}

var continued: std.atomic.Value(bool) = .init(false);

fn markContinued(_: std.posix.SIG) callconv(.c) void {
    continued.store(true, .release);
}

test "stop suspends the job until it is continued" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;

    const fork_rc = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_rc));
    const pid: linux.pid_t = @intCast(fork_rc);
    if (pid == 0) {
        // A process group of its own keeps the stop away from the test runner.
        _ = linux.setpgid(0, 0);
        stop();
        linux.exit_group(0);
    }

    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, linux.W.UNTRACED);
    try std.testing.expect(linux.W.IFSTOPPED(status));
    try std.testing.expectEqual(linux.SIG.TSTP, linux.W.STOPSIG(status));

    _ = linux.kill(pid, .CONT);
    _ = linux.waitpid(pid, &status, 0);
    try std.testing.expect(linux.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(status));
}

test "stop holds a background thread until the job is continued" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer _ = linux.close(fds[0]);

    const fork_rc = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_rc));
    const pid: linux.pid_t = @intCast(fork_rc);
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        // The input monitor suspends from its own thread while the main
        // thread is blocked elsewhere.
        const Monitor = struct {
            fn run(fd: i32) void {
                stop();
                _ = linux.write(fd, "x", 1);
            }
        };
        const thread = std.Thread.spawn(.{}, Monitor.run, .{fds[1]}) catch linux.exit_group(1);
        thread.join();
        linux.exit_group(0);
    }
    _ = linux.close(fds[1]);

    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, linux.W.UNTRACED);
    try std.testing.expect(linux.W.IFSTOPPED(status));

    // Nothing after stop() may run while the job is stopped.
    var pfd = [1]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = try std.posix.poll(&pfd, 0);

    _ = linux.kill(pid, .CONT);
    _ = linux.waitpid(pid, &status, 0);
    try std.testing.expectEqual(@as(usize, 0), ready);
    try std.testing.expect(linux.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(status));
}
