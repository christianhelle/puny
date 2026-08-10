const std = @import("std");
const list_picker = @import("list_picker.zig");
const openai = @import("../providers/openai.zig");

pub fn pickEffort(
    arena: std.mem.Allocator,
    io: std.Io,
) !?openai.ReasoningEffort {
    var items: std.ArrayList(list_picker.Item) = .empty;
    defer items.deinit(arena);

    inline for ([_]openai.ReasoningEffort{ .default, .none, .minimal, .low, .medium, .high, .xhigh }) |effort| {
        try items.append(arena, .{
            .value = @tagName(effort),
            .label = switch (effort) {
                .default => "Default (let provider decide)",
                .none => "None",
                .minimal => "Minimal",
                .low => "Low",
                .medium => "Medium",
                .high => "High",
                .xhigh => "Extra High",
            },
        });
    }

    const selected = (try list_picker.selectFromList(arena, io, "Select reasoning effort (Use arrow keys to navigate, Enter to select, 'q' to quit):", items.items)) orelse return null;

    return std.meta.stringToEnum(openai.ReasoningEffort, selected);
}

/// Parses a user-supplied reasoning effort level, trimming surrounding
/// whitespace. Returns null when the text is not a valid level name.
pub fn parseEffort(text: []const u8) ?openai.ReasoningEffort {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    return std.meta.stringToEnum(openai.ReasoningEffort, trimmed);
}

test "pickEffort returns correct enum for each label" {
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .default), std.meta.stringToEnum(openai.ReasoningEffort, "default"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .none), std.meta.stringToEnum(openai.ReasoningEffort, "none"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .minimal), std.meta.stringToEnum(openai.ReasoningEffort, "minimal"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .low), std.meta.stringToEnum(openai.ReasoningEffort, "low"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .medium), std.meta.stringToEnum(openai.ReasoningEffort, "medium"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .high), std.meta.stringToEnum(openai.ReasoningEffort, "high"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .xhigh), std.meta.stringToEnum(openai.ReasoningEffort, "xhigh"));
}

test "parseEffort parses valid level names" {
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .default), parseEffort("default"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .none), parseEffort("none"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .minimal), parseEffort("minimal"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .low), parseEffort("low"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .medium), parseEffort("medium"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .high), parseEffort("high"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .xhigh), parseEffort("xhigh"));
}

test "parseEffort trims whitespace and rejects invalid levels" {
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .high), parseEffort("  high  "));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, .medium), parseEffort("\tmedium"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, null), parseEffort("ultra"));
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, null), parseEffort(""));
}
