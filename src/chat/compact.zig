const std = @import("std");
const openai = @import("../providers/openai.zig");
const usage = @import("usage.zig");

/// Share of the limit a request may reach before it is compacted.
pub const threshold_percent = 80;

pub fn shouldCompact(tokens: i64, limit: usize) bool {
    if (tokens <= 0) return false;
    return @as(u128, @intCast(tokens)) * 100 >= @as(u128, limit) * threshold_percent;
}

/// The half-open range of messages that a compaction replaces with a summary.
pub const Split = struct {
    start: usize,
    end: usize,
};

pub const SplitMode = union(enum) {
    /// Summarize as much as possible (`/compact`).
    forced,
    /// Keep the most recent exchanges that fit this many tokens.
    auto: usize,
};

/// Chooses which messages to summarize. The range starts after the leading
/// system context and ends where a new exchange begins: at a user message, or
/// at the end of a conversation whose last message is a finished reply. Ending
/// anywhere else could separate an assistant tool call from its results.
pub fn planSplit(messages: []const openai.Message, mode: SplitMode) ?Split {
    var start: usize = 0;
    while (start < messages.len and messages[start] == .system) start += 1;

    var chosen: ?usize = null;
    var end = messages.len;
    while (end > start) : (end -= 1) {
        if (!isExchangeBoundary(messages, end)) continue;
        switch (mode) {
            .forced => return .{ .start = start, .end = end },
            .auto => |keep_budget| {
                const tail = usage.estimateUsage(messages[end..], 0).input_tokens;
                if (chosen == null) chosen = end;
                if (tail <= keep_budget) chosen = end else break;
            },
        }
    }
    const split_end = chosen orelse return null;
    return .{ .start = start, .end = split_end };
}

fn isExchangeBoundary(messages: []const openai.Message, index: usize) bool {
    if (index == messages.len) {
        const last = messages[index - 1];
        return last == .assistant and (last.assistant.tool_calls == null or last.assistant.tool_calls.?.len == 0);
    }
    return messages[index] == .user;
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

const long_text = "x" ** 400; // 100 estimated tokens

test "planSplit forced summarizes every exchange between turns" {
    const messages = [_]openai.Message{
        .{ .system = "system prompt" },
        .{ .user = "hello" },
        .{ .assistant = .{ .content = "hi" } },
    };
    try std.testing.expectEqual(Split{ .start = 1, .end = 3 }, planSplit(&messages, .forced).?);
}

test "planSplit has nothing to summarize without a conversation" {
    const messages = [_]openai.Message{.{ .system = "system prompt" }};
    try std.testing.expectEqual(@as(?Split, null), planSplit(&messages, .forced));
}

test "planSplit auto keeps the recent exchanges that fit the keep budget" {
    const messages = [_]openai.Message{
        .{ .system = "system prompt" },
        .{ .user = long_text },
        .{ .assistant = .{ .content = long_text } },
        .{ .user = "short question" },
        .{ .assistant = .{ .content = "short answer" } },
        .{ .user = "next question" },
    };
    try std.testing.expectEqual(Split{ .start = 1, .end = 3 }, planSplit(&messages, .{ .auto = 50 }).?);
}

test "planSplit auto never separates a tool call from its result" {
    const messages = [_]openai.Message{
        .{ .system = "system prompt" },
        .{ .user = long_text },
        .{ .assistant = .{ .content = long_text } },
        .{ .user = "read it" },
        .{ .assistant = .{ .tool_calls = &.{
            .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{}" } },
        } } },
        .{ .tool = .{ .tool_call_id = "call_1", .content = long_text } },
    };
    try std.testing.expectEqual(Split{ .start = 1, .end = 3 }, planSplit(&messages, .{ .auto = 10 }).?);
}

test "planSplit auto cannot summarize the only pending request" {
    const messages = [_]openai.Message{
        .{ .system = "system prompt" },
        .{ .user = long_text },
    };
    try std.testing.expectEqual(@as(?Split, null), planSplit(&messages, .{ .auto = 10 }));
}
