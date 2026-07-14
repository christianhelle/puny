const std = @import("std");
const openai = @import("../providers/openai.zig");

pub fn estimateUsage(messages: []const openai.Message, output_chars: usize) openai.TurnUsage {
    var input_chars: usize = 0;
    for (messages) |msg| {
        switch (msg) {
            .system => |c| input_chars += c.len,
            .user => |c| input_chars += c.len,
            .assistant => |a| {
                if (a.content) |c| input_chars += c.len;
                if (a.tool_calls) |tcs| {
                    for (tcs) |tc| {
                        input_chars += tc.function.name.len + tc.function.arguments.len;
                    }
                }
            },
            .tool => |t| input_chars += t.content.len,
        }
    }
    return openai.TurnUsage{
        .input_tokens = @intCast(@divFloor(input_chars, 4)),
        .output_tokens = @intCast(@divFloor(output_chars, 4)),
    };
}

test "empty messages returns zero input" {
    const result = estimateUsage(&.{}, 0);
    try std.testing.expectEqual(@as(i64, 0), result.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), result.output_tokens);
}

test "single user message" {
    const msg = openai.Message{ .user = "Hello, world!" };
    const result = estimateUsage(&.{msg}, 0);
    try std.testing.expectEqual(@as(i64, 3), result.input_tokens);
}

test "system and user messages are summed" {
    const msgs = [_]openai.Message{
        .{ .system = "You are a helpful assistant." },
        .{ .user = "What is the weather?" },
    };
    const result = estimateUsage(&msgs, 0);
    const sys_len: usize = "You are a helpful assistant.".len;
    const user_len: usize = "What is the weather?".len;
    const expected: i64 = @intCast(@divFloor(sys_len + user_len, 4));
    try std.testing.expectEqual(expected, result.input_tokens);
}

test "assistant content is counted" {
    const msg = openai.Message{ .assistant = .{ .content = "Sure, let me check." } };
    const result = estimateUsage(&.{msg}, 0);
    const expected: i64 = @intCast(@divFloor("Sure, let me check.".len, 4));
    try std.testing.expectEqual(expected, result.input_tokens);
}

test "assistant tool calls are counted" {
    const msg = openai.Message{
        .assistant = .{
            .tool_calls = &.{
                openai.ToolCall{
                    .id = "call_1",
                    .function = .{ .name = "read_file", .arguments = "{\"path\": \"foo\"}" },
                },
            },
        },
    };
    const result = estimateUsage(&.{msg}, 0);
    const expected: i64 = @intCast(@divFloor("read_file".len + "{\"path\": \"foo\"}".len, 4));
    try std.testing.expectEqual(expected, result.input_tokens);
}

test "assistant content and tool calls both counted" {
    const msg = openai.Message{
        .assistant = .{
            .content = "Let me look that up.",
            .tool_calls = &.{
                openai.ToolCall{
                    .id = "call_1",
                    .function = .{ .name = "search", .arguments = "{\"q\": \"x\"}" },
                },
            },
        },
    };
    const result = estimateUsage(&.{msg}, 0);
    const expected: i64 = @intCast(@divFloor("Let me look that up.".len + "search".len + "{\"q\": \"x\"}".len, 4));
    try std.testing.expectEqual(expected, result.input_tokens);
}

test "tool result content is counted" {
    const msg = openai.Message{ .tool = .{ .tool_call_id = "call_1", .content = "some file contents" } };
    const result = estimateUsage(&.{msg}, 0);
    const expected: i64 = @intCast(@divFloor("some file contents".len, 4));
    try std.testing.expectEqual(expected, result.input_tokens);
}

test "output tokens estimated from char count" {
    const result = estimateUsage(&.{}, 100);
    try std.testing.expectEqual(@as(i64, 25), result.output_tokens);
}

test "mixed message types all counted" {
    const msgs = [_]openai.Message{
        .{ .system = "Be concise." },
        .{ .user = "Hi" },
        .{ .assistant = .{ .content = "Hello!" } },
        .{ .tool = .{ .tool_call_id = "c1", .content = "result data" } },
    };
    const result = estimateUsage(&msgs, 0);
    const total: usize = "Be concise.".len + "Hi".len + "Hello!".len + "result data".len;
    const expected: i64 = @intCast(@divFloor(total, 4));
    try std.testing.expectEqual(expected, result.input_tokens);
}
