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
        try writer.print("\n\n{s}Thinking...{s}", .{ ansi.dim, ansi.reset });
        try writer.flush();
    }

    pub fn finish(
        self: *const @This(),
        io: std.Io,
        writer: *std.Io.Writer,
        cursor_offset: usize,
        output_ends_with_newline: bool,
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
            .done => if (elapsed_seconds < 0.01)
                "Thought for <0.01s"
            else
                try std.fmt.bufPrint(&buf, "Thought for {d:.2}s", .{elapsed_seconds}),
            .cancelled => "Cancelled.",
            .interrupted => "Interrupted.",
            .error_ => "Error.",
        };

        if (status != .done and has_streamed_content) {
            return;
        }

        if (status == .done and has_streamed_content) {
            try writer.print(terminal.cursor_up, .{cursor_offset});
            try writer.writeAll(terminal.move_to_line_start);
            try writer.writeAll(terminal.clear_to_end_of_line);
            try writer.print(terminal.cursor_down, .{cursor_offset});
            try writer.writeAll(terminal.move_to_line_start);
            if (output_ends_with_newline) {
                try writer.print("\n{s}{s}{s}\n", .{ ansi.dim, message, ansi.reset });
            } else {
                try writer.print("\n\n{s}{s}{s}\n", .{ ansi.dim, message, ansi.reset });
            }
        } else {
            try writer.writeAll(terminal.move_to_line_start);
            try writer.writeAll(terminal.clear_to_end_of_line);
            try writer.print("{s}{s}{s}\n", .{ ansi.dim, message, ansi.reset });
        }

        try writer.flush();
    }
};

test "show writes a thinking hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = ThinkingIndicator.init(std.testing.io);
    try indicator.show(&output.writer);
    try std.testing.expectEqualStrings("\n\n\x1b[2mThinking...\x1b[0m", output.written());
}

test "finish prints done message with provider ttft" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = ThinkingIndicator.init(std.testing.io);
    try indicator.finish(std.testing.io, &output.writer, 0, false, false, .done, 1.5);
    try std.testing.expectEqualStrings("\x1b[G\x1b[K\x1b[2mThought for 1.50s\x1b[0m\n", output.written());
}

test "finish with streamed content rewrites the indicator line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = ThinkingIndicator.init(std.testing.io);
    try indicator.finish(std.testing.io, &output.writer, 2, true, true, .done, 0.5);
    try std.testing.expectEqualStrings(
        "\x1b[2A\x1b[G\x1b[K\x1b[2B\x1b[G\n\x1b[2mThought for 0.50s\x1b[0m\n",
        output.written(),
    );
}

test "finish with streamed content and no trailing newline adds a blank line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = ThinkingIndicator.init(std.testing.io);
    try indicator.finish(std.testing.io, &output.writer, 1, false, true, .done, 2.0);
    try std.testing.expectEqualStrings(
        "\x1b[1A\x1b[G\x1b[K\x1b[1B\x1b[G\n\n\x1b[2mThought for 2.00s\x1b[0m\n",
        output.written(),
    );
}

test "finish suppresses the message when cancelled with streamed content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = ThinkingIndicator.init(std.testing.io);
    try indicator.finish(std.testing.io, &output.writer, 0, false, true, .cancelled, null);
    try std.testing.expectEqualStrings("", output.written());
}

test "finish reports cancelled, interrupted, and error statuses" {
    const statuses = [_]Status{ .cancelled, .interrupted, .error_ };
    const expected = [_][]const u8{ "Cancelled.", "Interrupted.", "Error." };
    for (statuses, expected) |status, msg| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var output = std.Io.Writer.Allocating.init(arena);
        defer output.deinit();

        var indicator = ThinkingIndicator.init(std.testing.io);
        try indicator.finish(std.testing.io, &output.writer, 0, false, false, status, null);
        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena, "\x1b[G\x1b[K\x1b[2m{s}\x1b[0m\n", .{msg}),
            output.written(),
        );
    }
}

test "finish reports sub-10ms thinking as a rounded message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = ThinkingIndicator.init(std.testing.io);
    try indicator.finish(std.testing.io, &output.writer, 0, false, false, .done, 0.001);
    try std.testing.expectEqualStrings("\x1b[G\x1b[K\x1b[2mThought for <0.01s\x1b[0m\n", output.written());
}
