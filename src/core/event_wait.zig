const std = @import("std");
const builtin = @import("builtin");

/// Waits up to `timeout_ns` on the awake clock for `event` to be set.
/// `Event.waitTimeout` reports any early wake as a timeout, including a
/// signal handler running on this thread, like the one `job_control.stop`
/// installs for SIGCONT. This keeps waiting until the deadline really passes.
pub fn waitTimeout(event: *std.Io.Event, io: std.Io, timeout_ns: i96) std.Io.Event.WaitTimeoutError!void {
    const deadline = (std.Io.Timeout{ .duration = .{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake,
    } }).toDeadline(io);
    while (true) {
        event.waitTimeout(io, deadline) catch |err| switch (err) {
            error.Timeout => if (deadline.toDurationFromNow(io).?.raw.nanoseconds > 0) continue else return err,
            else => return err,
        };
        return;
    }
}

test "waitTimeout keeps waiting when a signal handler interrupts it" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    const io = std.testing.io;

    const Handler = struct {
        fn ignore(_: std.posix.SIG) callconv(.c) void {}
    };
    const act = std.posix.Sigaction{
        .handler = .{ .handler = Handler.ignore },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR2, &act, &previous);
    defer std.posix.sigaction(.USR2, &previous, null);

    var event: std.Io.Event = .unset;
    const Setter = struct {
        fn run(waiter: linux.pid_t, ev: *std.Io.Event, set_io: std.Io) void {
            var nothing = [1]std.posix.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = std.posix.poll(&nothing, 20) catch {};
            _ = linux.tgkill(linux.getpid(), waiter, .USR2);
            _ = std.posix.poll(&nothing, 50) catch {};
            ev.set(set_io);
        }
    };
    const thread = try std.Thread.spawn(.{}, Setter.run, .{ linux.gettid(), &event, io });
    defer thread.join();

    try waitTimeout(&event, io, 5 * std.time.ns_per_s);
}

test "waitTimeout reports a timeout once the deadline passes" {
    var event: std.Io.Event = .unset;
    try std.testing.expectError(error.Timeout, waitTimeout(&event, std.testing.io, 10 * std.time.ns_per_ms));
}
