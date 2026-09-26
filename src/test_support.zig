const std = @import("std");
const builtin = @import("builtin");

/// Test double for `std.Io` that records every `sleep` duration instead of
/// sleeping, so retry backoff wiring can be asserted without real delays.
/// File deletes performed while cleaning up failed attempts are a no-op.
pub const RecordingIo = struct {
    allocator: std.mem.Allocator,
    sleeps: std.ArrayList(i96) = .empty,
    vtable: std.Io.VTable = undefined,
    io: std.Io = undefined,

    pub fn init(self: *RecordingIo, allocator: std.mem.Allocator) void {
        self.* = .{ .allocator = allocator };
        self.vtable.sleep = &recordSleep;
        self.vtable.now = &dummyNow;
        self.vtable.dirDeleteFile = &noopDirDeleteFile;
        self.io = .{ .userdata = self, .vtable = &self.vtable };
    }

    pub fn deinit(self: *RecordingIo) void {
        self.sleeps.deinit(self.allocator);
    }

    fn recordSleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *RecordingIo = @ptrCast(@alignCast(userdata.?));
        if (timeout == .duration) {
            self.sleeps.append(self.allocator, timeout.duration.raw.nanoseconds) catch unreachable;
        }
    }

    fn dummyNow(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        _ = userdata;
        _ = clock;
        return .{ .nanoseconds = 0 };
    }

    fn noopDirDeleteFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8) std.Io.Dir.DeleteFileError!void {
        _ = userdata;
        _ = dir;
        _ = sub_path;
    }
};

/// Runs `suspendFn` in a forked child and checks that it stops the child with
/// SIGTSTP, then returns once the child is continued. The child leads its own
/// process group, which keeps the stop away from the test runner, and reads
/// stdin from /dev/null so no terminal is touched. Linux only.
pub fn expectSuspends(comptime suspendFn: fn () void) !void {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;

    const fork_rc = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_rc));
    const pid: linux.pid_t = @intCast(fork_rc);
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        _ = linux.dup2(@intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0)), 0);
        suspendFn();
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
