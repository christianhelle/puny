const std = @import("std");
const list_picker = @import("list_picker.zig");
const openai = @import("../providers/openai.zig");

pub fn pickEffort(
    arena: std.mem.Allocator,
    io: std.Io,
) !?openai.ReasoningEffort {
    var items: std.ArrayList(list_picker.Item) = .empty;
    defer items.deinit(arena);

    inline for ([_]openai.ReasoningEffort{ .default, .high, .max }) |effort| {
        try items.append(arena, .{
            .value = @tagName(effort),
            .label = switch (effort) {
                .default => "Default (let provider decide)",
                .high => "High",
                .max => "Max",
            },
        });
    }

    const selected = (try list_picker.selectFromList(arena, io, "Select reasoning effort (Use arrow keys to navigate, Enter to select, 'q' to quit):", items.items)) orelse return null;

    return std.meta.stringToEnum(openai.ReasoningEffort, selected);
}

test "pickEffort returns correct enum for each label" {
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .default), std.meta.stringToEnum(openai.ReasoningEffort, "default"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .high), std.meta.stringToEnum(openai.ReasoningEffort, "high"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .max), std.meta.stringToEnum(openai.ReasoningEffort, "max"));
}
