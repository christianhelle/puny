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
    var system_chars: usize = 0;
    var message_chars: usize = 0;
    for (messages) |message| {
        switch (message) {
            .system => |text| system_chars += text.len,
            else => message_chars += conversationChars(message),
        }
    }
    var tool_chars: usize = 0;
    for (tools) |tool| tool_chars += toolChars(tool);
    return .{
        .system_prompt = tokensFor(system_chars),
        .system_tools = tokensFor(tool_chars),
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

/// Characters of a tool definition serialized as JSON, the way it is sent.
fn toolChars(tool: openai.ToolDefinition) usize {
    var buffer: [256]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&buffer);
    std.json.Stringify.value(tool, .{}, &counter.writer) catch return 0;
    return @intCast(counter.fullCount());
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

test "measure counts tool definitions as they are sent" {
    var function: std.json.ObjectMap = .empty;
    defer function.deinit(std.testing.allocator);
    try function.put(std.testing.allocator, "name", .{ .string = "read_file" });
    const tools = [_]openai.ToolDefinition{.{ .function = .{ .object = function } }};
    const breakdown = measure(&.{}, &tools);
    // {"type":"function","function":{"name":"read_file"}} is 51 characters.
    try std.testing.expectEqual(@as(i64, 12), breakdown.system_tools);
}
