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
