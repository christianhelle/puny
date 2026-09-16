const std = @import("std");
const openai = @import("../providers/openai.zig");
const usage = @import("usage.zig");
const prompts = @import("../prompts/prompts.zig");
const provider = @import("../providers/provider.zig");
const stats = @import("stats.zig");
const accumulator = @import("accumulator.zig");
const chat_retry = @import("retry.zig");

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

/// Longest tool result copied into the summarizer's transcript.
const max_tool_result_chars = 2000;

/// Builds the request that asks the model to summarize `messages`. The
/// transcript travels as plain text so no tool call has to be paired with a
/// result, and the final instruction stands alone as the last user message.
pub fn buildSummaryRequest(allocator: std.mem.Allocator, messages: []const openai.Message) ![]openai.Message {
    var transcript: std.Io.Writer.Allocating = .init(allocator);
    defer transcript.deinit();
    const w = &transcript.writer;
    for (messages) |message| {
        switch (message) {
            .system => {},
            .user => |text| try w.print("User:\n{s}\n\n", .{text}),
            .assistant => |a| {
                if (a.content) |text| try w.print("Assistant:\n{s}\n\n", .{text});
                if (a.tool_calls) |calls| {
                    for (calls) |call| try w.print("Tool call: {s}({s})\n\n", .{ call.function.name, call.function.arguments });
                }
            },
            .tool => |t| {
                if (t.content.len > max_tool_result_chars) {
                    var cut: usize = max_tool_result_chars;
                    while (cut > 0 and t.content[cut] & 0xC0 == 0x80) cut -= 1;
                    try w.print("Tool result:\n{s}\n[truncated]\n\n", .{t.content[0..cut]});
                } else {
                    try w.print("Tool result:\n{s}\n\n", .{t.content});
                }
            },
        }
    }

    const request = try allocator.alloc(openai.Message, 3);
    request[0] = .{ .system = prompts.compact };
    request[1] = .{ .user = try transcript.toOwnedSlice() };
    request[2] = .{ .user = "Write the summary now." };
    return request;
}

/// Replaces `messages[split.start..split.end]` with the system messages from
/// that range, kept so skills and mode prompts stay in force, followed by the
/// summary.
pub fn apply(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(openai.Message),
    split: Split,
    summary: []const u8,
) !void {
    var replacement: std.ArrayList(openai.Message) = .empty;
    defer replacement.deinit(allocator);
    for (messages.items[split.start..split.end]) |message| {
        if (message == .system) try replacement.append(allocator, message);
    }
    const text = try std.fmt.allocPrint(allocator, "Summary of the earlier conversation:\n{s}", .{summary});
    try replacement.append(allocator, .{ .system = text });
    try messages.replaceRange(allocator, split.start, split.end - split.start, replacement.items);
}

pub const SummaryOutcome = union(enum) {
    ok: []const u8,
    cancelled,
    failed,
};

/// Sends a summarization request built by `buildSummaryRequest`, without
/// tools and without streaming the reply to the terminal. The tokens it uses
/// are still counted in the session statistics.
pub fn summarize(
    prov: *provider.Provider,
    allocator: std.mem.Allocator,
    io: std.Io,
    random: std.Random,
    stdout_writer: *std.Io.Writer,
    session_stats: *stats.SessionStats,
    model_key: []const u8,
    request: []const openai.Message,
) !SummaryOutcome {
    session_stats.beginTurn(model_key, usage.estimateUsage(request, 0).input_tokens);
    var acc = accumulator.OpenAiAccumulator.init(allocator, io, null, session_stats);
    defer acc.deinit();

    const outcome = try chat_retry.runChatWithRetry(prov, allocator, .{
        .model = model_key,
        .messages = request,
        .tools = &.{},
        .stream = true,
    }, acc.streamCallback(), io, random, stdout_writer);
    session_stats.finalizeTurn(acc.usage, false);

    return switch (outcome) {
        .cancelled => .cancelled,
        .failed => .failed,
        .success => if (std.mem.trim(u8, acc.content.items, &std.ascii.whitespace).len == 0)
            .failed
        else
            .{ .ok = try allocator.dupe(u8, acc.content.items) },
    };
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

    /// Budget from `--max-context` or, failing that, `max_context_tokens`.
    pub fn init(cli_limit: ?usize, config_limit: ?u64) ContextBudget {
        const configured: ?usize = if (config_limit) |value| std.math.cast(usize, value) else null;
        return .{ .explicit = cli_limit orelse configured };
    }

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

test "buildSummaryRequest renders the transcript for the summarizer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const messages = [_]openai.Message{
        .{ .user = "hello" },
        .{ .assistant = .{ .content = "let me look", .tool_calls = &.{
            .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\":\"a.zig\"}" } },
        } } },
        .{ .tool = .{ .tool_call_id = "call_1", .content = "const a = 1;" } },
        .{ .assistant = .{ .content = "done" } },
    };

    const request = try buildSummaryRequest(arena_state.allocator(), &messages);

    try std.testing.expectEqual(@as(usize, 3), request.len);
    try std.testing.expectEqualStrings(prompts.compact, request[0].system);
    try std.testing.expectEqualStrings(
        "User:\nhello\n\nAssistant:\nlet me look\n\nTool call: read_file({\"path\":\"a.zig\"})\n\nTool result:\nconst a = 1;\n\nAssistant:\ndone\n\n",
        request[1].user,
    );
    try std.testing.expectEqualStrings("Write the summary now.", request[2].user);
}

test "buildSummaryRequest truncates long tool results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const messages = [_]openai.Message{
        .{ .tool = .{ .tool_call_id = "call_1", .content = "y" ** 3000 } },
    };

    const request = try buildSummaryRequest(arena_state.allocator(), &messages);

    const expected = "Tool result:\n" ++ "y" ** 2000 ++ "\n[truncated]\n\n";
    try std.testing.expectEqualStrings(expected, request[1].user);
}

test "buildSummaryRequest truncates tool results on a character boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const messages = [_]openai.Message{
        .{ .tool = .{ .tool_call_id = "call_1", .content = "y" ** 1999 ++ "é" ++ "z" ** 100 } },
    };

    const request = try buildSummaryRequest(arena_state.allocator(), &messages);

    const expected = "Tool result:\n" ++ "y" ** 1999 ++ "\n[truncated]\n\n";
    try std.testing.expectEqualStrings(expected, request[1].user);
}

test "apply replaces the range with its system messages and the summary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(openai.Message) = .empty;
    try messages.appendSlice(arena, &.{
        .{ .system = "base prompt" },
        .{ .user = "first question" },
        .{ .system = "skill content" },
        .{ .assistant = .{ .content = "first answer" } },
        .{ .user = "second question" },
    });

    try apply(arena, &messages, .{ .start = 1, .end = 4 }, "they asked a question");

    const expected = [_]openai.Message{
        .{ .system = "base prompt" },
        .{ .system = "skill content" },
        .{ .system = "Summary of the earlier conversation:\nthey asked a question" },
        .{ .user = "second question" },
    };
    try std.testing.expectEqualDeep(@as([]const openai.Message, &expected), messages.items);
}

fn runSummarizeForTest(arena: std.mem.Allocator, request: []const openai.Message) !SummaryOutcome {
    const mock = @import("../providers/mock.zig");
    var prov = provider.Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();
    var output = std.Io.Writer.Allocating.init(arena);
    var session_stats = stats.SessionStats.init(arena, std.testing.io);
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    return summarize(&prov, arena, std.testing.io, random_source.interface(), &output.writer, &session_stats, "mock-model", request);
}

test "summarize returns the model's reply without streaming it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const request = [_]openai.Message{ .{ .system = prompts.compact }, .{ .user = "Write the summary now, fast." } };

    const outcome = try runSummarizeForTest(arena_state.allocator(), &request);

    try std.testing.expect(std.mem.indexOf(u8, outcome.ok, "You said: Write the summary now, fast.") != null);
}

test "summarize fails on an empty reply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const request = [_]openai.Message{.{ .user = "empty" }};

    const outcome = try runSummarizeForTest(arena_state.allocator(), &request);

    try std.testing.expect(outcome == .failed);
}

test "init prefers the command-line budget over the config file" {
    const budget = ContextBudget.init(16000, 64000);
    try std.testing.expectEqual(@as(?usize, 16000), budget.limit());
}

test "init falls back to the config file budget" {
    const budget = ContextBudget.init(null, 64000);
    try std.testing.expectEqual(@as(?usize, 64000), budget.limit());
}

test "init leaves the budget to the model when neither is set" {
    const budget = ContextBudget.init(null, null);
    try std.testing.expectEqual(@as(?usize, null), budget.limit());
}
