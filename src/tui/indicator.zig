const std = @import("std");
const ansi = @import("ansi.zig");
const terminal = @import("terminal.zig");
const local_time = @import("../core/local_time.zig");

pub const Status = enum {
    done,
    cancelled,
    interrupted,
    error_,
};

pub const ThinkingIndicator = struct {
    start_time: std.Io.Clock.Timestamp,
    /// Formats the wall-clock time shown after the thought duration. Tests
    /// swap it for a fixed clock.
    local_time: *const fn (std.Io, *local_time.Buffer) []const u8 = local_time.format,

    pub fn init(io: std.Io) @This() {
        return .{
            .start_time = std.Io.Clock.Timestamp.now(io, .awake),
        };
    }

    pub fn show(self: *const @This(), writer: *std.Io.Writer) !void {
        _ = self;
        // Output before the indicator ends its own line, so one newline leaves
        // a single blank line above it.
        try writer.print("\n{s}Thinking...{s}", .{ ansi.dim, ansi.reset });
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

        var time_buf: local_time.Buffer = undefined;
        var buf: [64 + time_buf.len]u8 = undefined;
        const message = switch (status) {
            .done => try formatThought(&buf, elapsed_seconds, self.local_time(io, &time_buf)),
            .cancelled => "Cancelled.",
            .interrupted => "Interrupted.",
            .error_ => "Error.",
        };

        if (status != .done and has_streamed_content) {
            return;
        }

        if (status == .done and has_streamed_content) {
            // Delete the indicator row rather than blanking it, so the output
            // below moves up into its place instead of leaving an empty line.
            // A zero offset has no row to rewind to, and CSI 0 A would move up
            // one row anyway.
            if (cursor_offset > 0) {
                try writer.print(terminal.cursor_up, .{cursor_offset});
                try writer.writeAll(terminal.move_to_line_start);
                try writer.writeAll(terminal.delete_line);
                if (cursor_offset > 1) {
                    try writer.print(terminal.cursor_down, .{cursor_offset - 1});
                }
                try writer.writeAll(terminal.move_to_line_start);
            }
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

fn formatThought(buf: []u8, elapsed_seconds: f64, time_of_day: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    if (elapsed_seconds < 0.01) {
        try writer.writeAll("Thought for <0.01s");
    } else {
        try writer.print("Thought for {d:.2}s", .{elapsed_seconds});
    }
    if (time_of_day.len > 0) try writer.print(" ({s})", .{time_of_day});
    return writer.buffered();
}

fn fixedLocalTime(_: std.Io, _: *local_time.Buffer) []const u8 {
    return "2026-10-23 10:15:00";
}

fn noLocalTime(_: std.Io, _: *local_time.Buffer) []const u8 {
    return "";
}

fn testIndicator() ThinkingIndicator {
    var indicator = ThinkingIndicator.init(std.testing.io);
    indicator.local_time = fixedLocalTime;
    return indicator;
}

test "show writes a thinking hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = testIndicator();
    try indicator.show(&output.writer);
    try std.testing.expectEqualStrings("\n\x1b[2mThinking...\x1b[0m", output.written());
}

test "finish prints done message with provider ttft" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = testIndicator();
    try indicator.finish(std.testing.io, &output.writer, 0, false, false, .done, 1.5);
    try std.testing.expectEqualStrings("\x1b[G\x1b[K\x1b[2mThought for 1.50s (2026-10-23 10:15:00)\x1b[0m\n", output.written());
}

test "finish with streamed content deletes the indicator row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = testIndicator();
    try indicator.finish(std.testing.io, &output.writer, 2, true, true, .done, 0.5);
    try std.testing.expectEqualStrings(
        "\x1b[2A\x1b[G\x1b[M\x1b[1B\x1b[G\n\x1b[2mThought for 0.50s (2026-10-23 10:15:00)\x1b[0m\n",
        output.written(),
    );
}

test "finish deletes the indicator row when output streamed right below it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = testIndicator();
    try indicator.finish(std.testing.io, &output.writer, 1, false, true, .done, 2.0);
    try std.testing.expectEqualStrings(
        "\x1b[1A\x1b[G\x1b[M\x1b[G\n\n\x1b[2mThought for 2.00s (2026-10-23 10:15:00)\x1b[0m\n",
        output.written(),
    );
}

test "finish suppresses the message when cancelled with streamed content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = testIndicator();
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

        var indicator = testIndicator();
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

    var indicator = testIndicator();
    try indicator.finish(std.testing.io, &output.writer, 0, false, false, .done, 0.001);
    try std.testing.expectEqualStrings("\x1b[G\x1b[K\x1b[2mThought for <0.01s (2026-10-23 10:15:00)\x1b[0m\n", output.written());
}

test "finish deletes the indicator row when called out of line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = testIndicator();
    try @call(.never_inline, ThinkingIndicator.finish, .{ &indicator, std.testing.io, &output.writer, 2, true, true, .done, 0.5 });
    try std.testing.expectEqualStrings(
        "\x1b[2A\x1b[G\x1b[M\x1b[1B\x1b[G\n\x1b[2mThought for 0.50s (2026-10-23 10:15:00)\x1b[0m\n",
        output.written(),
    );
}

test "finish with streamed content but no row offset does not rewind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = testIndicator();
    try indicator.finish(std.testing.io, &output.writer, 0, true, true, .done, 0.5);
    try std.testing.expectEqualStrings(
        "\n\x1b[2mThought for 0.50s (2026-10-23 10:15:00)\x1b[0m\n",
        output.written(),
    );
}

test "finished indicator leaves a single blank line above the thought message" {
    const FakeScreen = @import("fake_screen.zig").FakeScreen;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    try output.writer.writeAll("> prompt\r\n\nThinking...\n🔧 one\n🔧 two");
    var indicator = testIndicator();
    try indicator.finish(std.testing.io, &output.writer, 2, false, true, .done, 0.5);

    var screen = FakeScreen{};
    defer screen.deinit(arena);
    try screen.feed(arena, output.written());
    try std.testing.expectEqualStrings(
        "> prompt\n\n🔧 one\n🔧 two\n\nThought for 0.50s (2026-10-23 10:15:00)",
        try screen.toText(arena),
    );
}

test "finish leaves out the brackets when the local time is unavailable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var indicator = ThinkingIndicator.init(std.testing.io);
    indicator.local_time = noLocalTime;
    try indicator.finish(std.testing.io, &output.writer, 0, false, false, .done, 1.5);
    try std.testing.expectEqualStrings("\x1b[G\x1b[K\x1b[2mThought for 1.50s\x1b[0m\n", output.written());
}
