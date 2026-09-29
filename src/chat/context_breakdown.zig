const std = @import("std");
const openai = @import("../providers/openai.zig");

/// Approximate tokens each part of the next request takes, at roughly four
/// characters per token.
pub const Breakdown = struct {
    system_prompt: i64 = 0,
    system_tools: i64 = 0,
    skills: i64 = 0,
    messages: i64 = 0,
};

pub fn measure(messages: []const openai.Message, tools: []const openai.ToolDefinition) Breakdown {
    _ = tools;
    var system_chars: usize = 0;
    var message_chars: usize = 0;
    for (messages) |message| {
        switch (message) {
            .system => |text| system_chars += text.len,
            else => message_chars += conversationChars(message),
        }
    }
    return .{
        .system_prompt = tokensFor(system_chars),
        .messages = tokensFor(message_chars),
    };
}

/// Characters of a user, assistant, or tool message, counted the way
/// `usage.estimateUsage` counts them.
fn conversationChars(message: openai.Message) usize {
    return switch (message) {
        .system => 0,
        .user => |text| text.len,
        .assistant => |reply| blk: {
            var chars: usize = if (reply.content) |text| text.len else 0;
            if (reply.tool_calls) |calls| {
                for (calls) |call| chars += call.function.name.len + call.function.arguments.len;
            }
            break :blk chars;
        },
        .tool => |result| result.content.len,
    };
}

fn tokensFor(chars: usize) i64 {
    return @intCast(chars / 4);
}

test "measure counts system messages as the system prompt" {
    const messages = [_]openai.Message{
        .{ .system = "You are puny, a coding agent." },
    };
    const breakdown = measure(&messages, &.{});
    try std.testing.expectEqual(@as(i64, 7), breakdown.system_prompt);
    try std.testing.expectEqual(@as(i64, 0), breakdown.messages);
}

test "measure counts the conversation as messages" {
    const messages = [_]openai.Message{
        .{ .user = "Read build.zig" },
        .{ .assistant = .{
            .content = "Reading it.",
            .tool_calls = &.{.{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\":\"build.zig\"}" } }},
        } },
        .{ .tool = .{ .tool_call_id = "call_1", .content = "const std = @import(\"std\");" } },
    };
    const breakdown = measure(&messages, &.{});
    // 14 + 11 + 9 + 20 + 27 = 81 characters.
    try std.testing.expectEqual(@as(i64, 20), breakdown.messages);
    try std.testing.expectEqual(@as(i64, 0), breakdown.system_prompt);
}
