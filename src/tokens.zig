const std = @import("std");
const openai = @import("providers/openai.zig");

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
