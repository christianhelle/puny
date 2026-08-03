const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const cancel = @import("../core/cancel.zig");
const openai = @import("../providers/openai.zig");
const retry = @import("../core/retry.zig");

pub const ChatRetryOutcome = union(enum) {
    success,
    cancelled,
    failed: anyerror,
};

pub fn runChatWithRetry(
    prov: anytype,
    request: openai.ChatRequest,
    callback: openai.StreamCallback,
    io: std.Io,
    random: std.Random,
    stdout_writer: *std.Io.Writer,
) !ChatRetryOutcome {
    var retry_count: usize = 0;
    const cfg = retry.default_config;

    var cancel_stderr_buf: [128]u8 = undefined;
    var cancel_stderr_fw: std.Io.File.Writer = .init(.stderr(), io, &cancel_stderr_buf);
    const cancel_stderr = &cancel_stderr_fw.interface;

    while (true) {
        cancel.reset();
        cancel.start(io, cancel_stderr) catch {};

        // Drop partial state from the failed attempt so a retry does not
        // duplicate streamed content or usage in the accumulator.
        if (retry_count > 0) callback.reset();

        if (prov.chatStreaming(request, callback)) |_| {
            cancel.stop();
            return .success;
        } else |err| {
            cancel.stop();

            if (err == error.Canceled) return .cancelled;

            if (!retry.isTransientError(err)) {
                try stdout_writer.print("\nChat failed: {}\n", .{err});
                try stdout_writer.flush();
                return .{ .failed = err };
            }

            retry_count += 1;
            if (retry_count >= cfg.max_retries) {
                try stdout_writer.print("\nChat failed after {d} retries: {}\n", .{ cfg.max_retries, err });
                try stdout_writer.flush();
                return .{ .failed = err };
            }

            var delay_ms: u64 = cfg.base_delay_ms;
            var i: usize = 1;
            while (i < retry_count) : (i += 1) delay_ms *= 2;
            delay_ms += random.intRangeAtMost(u64, 0, cfg.jitter_max_ms);

            io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
        }
    }
}

const TestChatProvider = struct {
    calls: usize = 0,
    fail_count: usize = 0,
    err: anyerror = error.ConnectionRefused,

    pub fn chatStreaming(self: *@This(), _: openai.ChatRequest, _: openai.StreamCallback) !void {
        self.calls += 1;
        if (self.calls <= self.fail_count) return self.err;
    }
};

const TestRetryState = struct {
    events: usize = 0,
    resets: usize = 0,

    fn callback(self: *@This()) openai.StreamCallback {
        return .{
            .context = self,
            .vtable = &.{
                .event = struct {
                    pub fn event(ctx: *anyopaque, _: openai.StreamEvent) !void {
                        const state: *TestRetryState = @ptrCast(@alignCast(ctx));
                        state.events += 1;
                    }
                }.event,
                .reset = struct {
                    pub fn reset(ctx: *anyopaque) void {
                        const state: *TestRetryState = @ptrCast(@alignCast(ctx));
                        state.resets += 1;
                        state.events = 0;
                    }
                }.reset,
            },
        };
    }
};

test "runChatWithRetry resets callback state between attempts" {
    var state = TestRetryState{};
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const FlakyProvider = struct {
        attempts: usize = 0,

        pub fn chatStreaming(self: *@This(), _: openai.ChatRequest, callback: openai.StreamCallback) !void {
            self.attempts += 1;
            if (self.attempts == 1) {
                try callback.emit(.{ .content = "partial" });
                return error.ConnectionRefused;
            }
            try callback.emit(.{ .content = "ok" });
        }
    };
    var provider = FlakyProvider{};

    const request = openai.ChatRequest{
        .model = "test",
        .messages = &.{},
        .tools = &.{},
    };

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const outcome = try runChatWithRetry(&provider, request, state.callback(), std.testing.io, random, &output.writer);
    try std.testing.expectEqual(ChatRetryOutcome.success, outcome);
    try std.testing.expectEqual(@as(usize, 2), provider.attempts);
    try std.testing.expectEqual(@as(usize, 1), state.resets);
    try std.testing.expectEqual(@as(usize, 1), state.events);
}

test "runChatWithRetry silently retries transient failures" {
    var prov = TestChatProvider{ .fail_count = 2 };
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var callback_context: u8 = 0;
    const callback = openai.StreamCallback{
        .context = &callback_context,
        .vtable = &.{
            .event = struct {
                pub fn event(_: *anyopaque, _: openai.StreamEvent) anyerror!void {}
            }.event,
        },
    };

    const request = openai.ChatRequest{
        .model = "test",
        .messages = &.{},
        .tools = &.{},
    };

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const outcome = try runChatWithRetry(&prov, request, callback, std.testing.io, random, &output.writer);
    try std.testing.expectEqual(@as(usize, 3), prov.calls);
    try std.testing.expectEqual(ChatRetryOutcome.success, outcome);
    try std.testing.expectEqualStrings("", output.written());
}
