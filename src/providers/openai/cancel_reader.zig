const std = @import("std");
const cancel = @import("../../core/cancel.zig");

pub const CancelableReader = struct {
    inner: *std.Io.Reader,
    reader: std.Io.Reader,

    pub fn init(inner: *std.Io.Reader, buffer: []u8) CancelableReader {
        return .{
            .inner = inner,
            .reader = .{
                .buffer = buffer,
                .seek = 0,
                .end = 0,
                .vtable = &vtable,
            },
        };
    }

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
        .discard = std.Io.Reader.defaultDiscard,
        .readVec = std.Io.Reader.defaultReadVec,
        .rebase = std.Io.Reader.defaultRebase,
    };

    fn stream(ctx: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CancelableReader = @fieldParentPtr("reader", ctx);
        if (cancel.isCancelled()) return error.ReadFailed;
        return self.inner.stream(w, limit);
    }
};

test "CancelableReader passes through when not cancelled and fails when cancelled" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    cancel.reset();
    var fixed = std.Io.Reader.fixed("hello");
    var buffer: [1]u8 = undefined;
    var reader = CancelableReader.init(&fixed, &buffer);
    _ = try reader.reader.streamRemaining(&out.writer);
    try std.testing.expectEqualStrings("hello", out.written());

    cancel.setCancelled();
    defer cancel.reset();
    var fixed2 = std.Io.Reader.fixed("hello");
    var buffer2: [1]u8 = undefined;
    var reader2 = CancelableReader.init(&fixed2, &buffer2);
    try std.testing.expectError(error.ReadFailed, reader2.reader.streamRemaining(&out.writer));
}
