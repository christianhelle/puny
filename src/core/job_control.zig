const std = @import("std");
const builtin = @import("builtin");

/// Stops the process's job the way the terminal's suspend key (Ctrl+Z)
/// would, and returns once the shell continues it with `fg` or `bg`. Raw
/// mode turns the terminal's signal keys off, so input loops call this when
/// they read the suspend byte themselves. Windows has no job control, so
/// there it does nothing.
pub fn stop() void {
    if (builtin.os.tag == .windows) return;
    // Signal the whole process group, as the terminal does, so commands
    // Puny is running stop and continue with it.
    std.posix.kill(0, .TSTP) catch {};
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
