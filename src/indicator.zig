const std = @import("std");
const ansi = @import("ansi.zig");
const terminal = @import("terminal.zig");

pub const Status = enum {
    done,
    cancelled,
    interrupted,
    error_,
};

pub const ThinkingIndicator = struct {
    start_time: std.Io.Clock.Timestamp,

    pub fn init(io: std.Io) @This() {
        return .{
            .start_time = std.Io.Clock.Timestamp.now(io, .awake),
        };
    }

    pub fn show(self: *const @This(), writer: *std.Io.Writer) !void {
        _ = self;
        try writer.print("{s}Thinking...{s}", .{ ansi.dim, ansi.reset });
        try writer.flush();
    }

    pub fn finish(
        self: *const @This(),
        io: std.Io,
        writer: *std.Io.Writer,
        lines_printed: usize,
        has_streamed_content: bool,
        status: Status,
        provider_ttft_seconds: ?f64,
    ) !void {
        const elapsed_seconds = if (provider_ttft_seconds) |ttft|
            ttft
        else blk: {
            const now = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed_ns = self.start_time.raw.durationTo(now.raw).nanoseconds;
            break :blk @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
        };

        var buf: [64]u8 = undefined;
        const message = switch (status) {
            .done => try std.fmt.bufPrint(&buf, "Thought for {d:.2}s", .{elapsed_seconds}),
            .cancelled => "Cancelled.",
            .interrupted => "Interrupted.",
            .error_ => "Error.",
        };

        if (has_streamed_content) {
            const offset = lines_printed + 1;
            try writer.print(terminal.cursor_up, .{offset});
            try writer.writeAll(terminal.move_to_line_start);
            try writer.writeAll(terminal.clear_to_end_of_line);
            try writer.print("{s}{s}{s}", .{ ansi.dim, message, ansi.reset });
            try writer.print(terminal.cursor_down, .{offset});
            try writer.writeAll(terminal.move_to_line_start);
        } else {
            try writer.writeAll(terminal.move_to_line_start);
            try writer.writeAll(terminal.clear_to_end_of_line);
            try writer.print("{s}{s}{s}\n", .{ ansi.dim, message, ansi.reset });
        }

        try writer.flush();
    }
};
