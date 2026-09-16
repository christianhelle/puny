const std = @import("std");
const openai = @import("../providers/openai.zig");
const usage = @import("usage.zig");

/// Share of the limit a request may reach before it is compacted.
pub const threshold_percent = 80;

pub fn shouldCompact(tokens: i64, limit: usize) bool {
    if (tokens <= 0) return false;
    return @as(u128, @intCast(tokens)) * 100 >= @as(u128, limit) * threshold_percent;
}

/// Tracks how large the conversation may grow before it is compacted.
pub const ContextBudget = struct {
    /// Budget set by `/context`, `--max-context`, or `max_context_tokens`.
    explicit: ?usize = null,
    /// Context window the provider reports for the active model, if any.
    model_reported: ?usize = null,
    /// Input tokens the provider reported for the most recent request, and
    /// how many messages that request carried.
    last_prompt_tokens: ?i64 = null,
    last_prompt_message_count: usize = 0,

    /// The effective token limit, or null when auto compaction is off.
    pub fn limit(self: *const ContextBudget) ?usize {
        return self.explicit orelse self.model_reported;
    }

    /// Records the provider-reported size of a request of `message_count` messages.
    pub fn recordPrompt(self: *ContextBudget, input_tokens: i64, message_count: usize) void {
        self.last_prompt_tokens = input_tokens;
        self.last_prompt_message_count = message_count;
    }

    pub fn resetUsage(self: *ContextBudget) void {
        self.last_prompt_tokens = null;
        self.last_prompt_message_count = 0;
    }

    /// Approximate tokens the next request will carry. Starts from the last
    /// provider-reported prompt size when it still describes a prefix of the
    /// conversation, and estimates only the messages added since.
    pub fn estimate(self: *const ContextBudget, messages: []const openai.Message) i64 {
        if (self.last_prompt_tokens) |reported| {
            if (self.last_prompt_message_count <= messages.len) {
                return reported + usage.estimateUsage(messages[self.last_prompt_message_count..], 0).input_tokens;
            }
        }
        return usage.estimateUsage(messages, 0).input_tokens;
    }
};

test "limit prefers the explicit budget over the model's reported window" {
    const budget = ContextBudget{ .explicit = 32000, .model_reported = 128000 };
    try std.testing.expectEqual(@as(?usize, 32000), budget.limit());
}

test "limit falls back to the model's reported window" {
    const budget = ContextBudget{ .model_reported = 128000 };
    try std.testing.expectEqual(@as(?usize, 128000), budget.limit());
}

test "limit is null when nothing is known" {
    const budget = ContextBudget{};
    try std.testing.expectEqual(@as(?usize, null), budget.limit());
}

test "estimate uses the character estimate before any provider usage is known" {
    const budget = ContextBudget{};
    const messages = [_]openai.Message{
        .{ .system = "12345678" },
        .{ .user = "abcdefgh" },
    };
    try std.testing.expectEqual(@as(i64, 4), budget.estimate(&messages));
}

test "estimate adds newer messages to the last reported prompt size" {
    var budget = ContextBudget{};
    const messages = [_]openai.Message{
        .{ .system = "12345678" },
        .{ .user = "abcdefgh" },
        .{ .assistant = .{ .content = "0123456789abcdef" } },
    };
    budget.recordPrompt(1000, 2);
    try std.testing.expectEqual(@as(i64, 1004), budget.estimate(&messages));
}

test "estimate ignores reported usage once the conversation shrank" {
    var budget = ContextBudget{};
    budget.recordPrompt(1000, 5);
    const messages = [_]openai.Message{.{ .user = "abcdefgh" }};
    try std.testing.expectEqual(@as(i64, 2), budget.estimate(&messages));
}

test "resetUsage forgets the reported prompt size" {
    var budget = ContextBudget{};
    budget.recordPrompt(1000, 1);
    budget.resetUsage();
    const messages = [_]openai.Message{.{ .user = "abcdefgh" }};
    try std.testing.expectEqual(@as(i64, 2), budget.estimate(&messages));
}

test "shouldCompact triggers at 80 percent of the limit" {
    try std.testing.expect(!shouldCompact(799, 1000));
    try std.testing.expect(shouldCompact(800, 1000));
    try std.testing.expect(shouldCompact(1500, 1000));
}
