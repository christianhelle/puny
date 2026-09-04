const std = @import("std");

/// Test double for `std.Io` that records every `sleep` duration instead of
/// sleeping, so retry backoff wiring can be asserted without real delays.
pub const RecordingIo = struct {
    allocator: std.mem.Allocator,
    sleeps: std.ArrayList(i96) = .empty,
    vtable: std.Io.VTable = undefined,
    io: std.Io = undefined,

    pub fn init(self: *RecordingIo, allocator: std.mem.Allocator) void {
        self.* = .{ .allocator = allocator };
        self.vtable.sleep = &recordSleep;
        self.vtable.now = &dummyNow;
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
};
