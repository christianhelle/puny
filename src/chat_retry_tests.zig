//! Slow runChatWithRetry tests, run only as part of the regression suite
//! (`zig build test-regression`) so that `zig build test` stays fast.
const std = @import("std");
const chat_retry = @import("chat/retry.zig");
const http_client = @import("providers/client.zig");
const openai = @import("providers/openai.zig");

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

    const outcome = try chat_retry.runChatWithRetry(&provider, std.testing.allocator, request, state.callback(), std.testing.io, random, &output.writer);
    try std.testing.expectEqual(chat_retry.ChatRetryOutcome.success, outcome);
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

    const outcome = try chat_retry.runChatWithRetry(&prov, std.testing.allocator, request, callback, std.testing.io, random, &output.writer);
    try std.testing.expectEqual(@as(usize, 3), prov.calls);
    try std.testing.expectEqual(chat_retry.ChatRetryOutcome.success, outcome);
    try std.testing.expectEqualStrings("", output.written());
}

test "runChatWithRetry returns cancelled without retrying" {
    const CancellingProvider = struct {
        calls: usize = 0,

        pub fn chatStreaming(self: *@This(), _: openai.ChatRequest, _: openai.StreamCallback) !void {
            self.calls += 1;
            return error.Canceled;
        }
    };
    var prov = CancellingProvider{};
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

    const outcome = try chat_retry.runChatWithRetry(&prov, std.testing.allocator, request, callback, std.testing.io, random, &output.writer);
    try std.testing.expectEqual(chat_retry.ChatRetryOutcome.cancelled, outcome);
    try std.testing.expectEqual(@as(usize, 1), prov.calls);
}

test "runChatWithRetry reports non-transient failures immediately" {
    var prov = TestChatProvider{ .fail_count = 1, .err = error.OutOfMemory };
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

    const outcome = try chat_retry.runChatWithRetry(&prov, std.testing.allocator, request, callback, std.testing.io, random, &output.writer);
    try std.testing.expectEqual(chat_retry.ChatRetryOutcome{ .failed = error.OutOfMemory }, outcome);
    try std.testing.expectEqual(@as(usize, 1), prov.calls);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Chat failed") != null);
}

test "runChatWithRetry reports HTTP status and API message" {
    const FailingProvider = struct {
        failure: http_client.HttpFailure = .{
            .status = .internal_server_error,
            .body = @constCast("{\"error\":{\"message\":\"model is temporarily unavailable\"}}"),
        },

        pub fn chatStreaming(_: *@This(), _: openai.ChatRequest, _: openai.StreamCallback) !void {
            return error.ResponseError;
        }

        pub fn lastHttpFailure(self: *const @This()) ?*const http_client.HttpFailure {
            return &self.failure;
        }
    };
    var prov = FailingProvider{};
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

    const outcome = try chat_retry.runChatWithRetry(
        &prov,
        std.testing.allocator,
        request,
        callback,
        std.testing.io,
        random_source.interface(),
        &output.writer,
    );

    try std.testing.expectEqual(chat_retry.ChatRetryOutcome{ .failed = error.ResponseError }, outcome);
    try std.testing.expectEqualStrings(
        "\nChat failed: HTTP 500 Internal Server Error: model is temporarily unavailable\n",
        output.written(),
    );
}

test "runChatWithRetry gives up after max retries" {
    var prov = TestChatProvider{ .fail_count = 10 };
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

    const outcome = try chat_retry.runChatWithRetry(&prov, std.testing.allocator, request, callback, std.testing.io, random, &output.writer);
    try std.testing.expectEqual(chat_retry.ChatRetryOutcome{ .failed = error.ConnectionRefused }, outcome);
    try std.testing.expectEqual(@as(usize, 5), prov.calls);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Chat failed after 5 retries") != null);
}
