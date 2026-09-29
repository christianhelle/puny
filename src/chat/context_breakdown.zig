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
    for (messages) |message| {
        switch (message) {
            .system => |text| system_chars += text.len,
            else => {},
        }
    }
    return .{ .system_prompt = tokensFor(system_chars) };
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
