const std = @import("std");
const openai = @import("../providers/openai.zig");
const skills = @import("../skills/skills.zig");
const usage = @import("usage.zig");

/// Approximate tokens each part of the next request takes, at roughly four
/// characters per token.
pub const Breakdown = struct {
    system_prompt: i64 = 0,
    system_tools: i64 = 0,
    skills: i64 = 0,
    messages: i64 = 0,

    pub fn total(self: Breakdown) i64 {
        return self.system_prompt + self.system_tools + self.skills + self.messages;
    }
};

pub fn measure(messages: []const openai.Message, tools: []const openai.ToolDefinition) Breakdown {
    var system_chars: usize = 0;
    var skill_chars: usize = 0;
    var message_chars: usize = 0;
    for (messages) |message| {
        switch (message) {
            .system => |text| {
                if (skills.isSkillContext(text)) skill_chars += text.len else system_chars += text.len;
            },
            else => message_chars += conversationChars(message),
        }
    }
    return .{
        .system_prompt = tokensFor(system_chars),
        .system_tools = usage.estimateToolTokens(tools),
        .skills = tokensFor(skill_chars),
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

/// Writes one line per part of the context, with its share of `limit` when
/// a limit is known.
pub fn write(writer: *std.Io.Writer, breakdown: Breakdown, limit: ?usize) !void {
    try writeRow(writer, "System prompt", breakdown.system_prompt, limit);
    try writeRow(writer, "System tools", breakdown.system_tools, limit);
    try writeRow(writer, "Skills", breakdown.skills, limit);
    try writeRow(writer, "Messages", breakdown.messages, limit);
}

fn writeRow(writer: *std.Io.Writer, label: []const u8, tokens: i64, limit: ?usize) !void {
    const count: u64 = @intCast(@max(tokens, 0));
    try writer.print("  {s:<14}{d:>9} tokens", .{ label, count });
    if (limit) |total| {
        const permille = @as(u128, count) * 1000 / total;
        try writer.print(" ({d}.{d}%)", .{ permille / 10, permille % 10 });
    }
    try writer.writeByte('\n');
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

test "measure counts the available skills listing as skills" {
    const messages = [_]openai.Message{
        .{ .system = "You are puny." },
        .{ .system = "<available_skills>\n  <skill>\n    <name>tdd</name>\n  </skill>\n</available_skills>" },
    };
    const breakdown = measure(&messages, &.{});
    try std.testing.expectEqual(@as(i64, 3), breakdown.system_prompt);
    try std.testing.expectEqual(@as(i64, 20), breakdown.skills);
}

test "measure counts loaded skills as skills" {
    const loaded = try skills.formatLoaded(std.testing.allocator, "tdd", "Red, then green.");
    defer std.testing.allocator.free(loaded);
    const messages = [_]openai.Message{
        .{ .system = "You are puny." },
        .{ .system = loaded },
    };
    const breakdown = measure(&messages, &.{});
    try std.testing.expectEqual(@as(i64, 3), breakdown.system_prompt);
    // <skill name="tdd">\nRed, then green.\n</skill> is 44 characters.
    try std.testing.expectEqual(@as(i64, 11), breakdown.skills);
}

test "write lists each part with its share of the limit" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, .{ .system_prompt = 1200, .system_tools = 3450, .skills = 80, .messages = 64000 }, 128000);
    try std.testing.expectEqualStrings(
        \\  System prompt      1200 tokens (0.9%)
        \\  System tools       3450 tokens (2.6%)
        \\  Skills               80 tokens (0.0%)
        \\  Messages          64000 tokens (50.0%)
        \\
    , writer.buffered());
}

test "write leaves out shares when no limit is set" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, .{ .system_prompt = 1200, .system_tools = 3450, .skills = 80, .messages = 64000 }, null);
    try std.testing.expectEqualStrings(
        \\  System prompt      1200 tokens
        \\  System tools       3450 tokens
        \\  Skills               80 tokens
        \\  Messages          64000 tokens
        \\
    , writer.buffered());
}
