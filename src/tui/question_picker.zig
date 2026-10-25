const std = @import("std");
const list_picker = @import("list_picker.zig");

/// Value of the trailing item that lets the user type an answer the
/// options don't cover.
pub const other_value = "\x00other";

/// Picker items for a multiple choice question: each option in the order
/// given, the one matching `recommended` labelled as such, then "Other".
pub fn answerItems(arena: std.mem.Allocator, options: []const []const u8, recommended: ?[]const u8) ![]const list_picker.Item {
    const items = try arena.alloc(list_picker.Item, options.len + 1);
    for (options, 0..) |option, i| {
        const is_recommended = if (recommended) |r| std.mem.eql(u8, r, option) else false;
        items[i] = .{
            .value = option,
            .label = if (is_recommended) try std.fmt.allocPrint(arena, "{s} (recommended)", .{option}) else option,
        };
    }
    items[options.len] = .{ .value = other_value, .label = "Other (type your own answer)" };
    return items;
}

/// How the user responded to a multiple choice question.
pub const Answer = union(enum) {
    picked: []const u8,
    typed: []const u8,
    cancelled,
};

/// The ask_user tool result that reports `answer` back to the model.
pub fn toolResult(arena: std.mem.Allocator, answer: Answer) ![]const u8 {
    return switch (answer) {
        .picked => |text| std.fmt.allocPrint(arena, "The user chose: {s}", .{text}),
        .typed => |text| std.fmt.allocPrint(arena, "The user answered: {s}", .{text}),
        .cancelled => "The user dismissed the choices and will answer in their next message. End your turn now.",
    };
}

test "answerItems lists the options, marks the recommended one and offers Other last" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const items = try answerItems(arena_state.allocator(), &.{ "SQLite", "Postgres" }, "Postgres");
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("SQLite", items[0].value);
    try std.testing.expectEqualStrings("SQLite", items[0].label);
    try std.testing.expectEqualStrings("Postgres", items[1].value);
    try std.testing.expectEqualStrings("Postgres (recommended)", items[1].label);
    try std.testing.expectEqualStrings(other_value, items[2].value);
    try std.testing.expectEqualStrings("Other (type your own answer)", items[2].label);
}

test "toolResult tells the model which answer the user gave" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("The user chose: Postgres", try toolResult(arena, .{ .picked = "Postgres" }));
    try std.testing.expectEqualStrings("The user answered: use DuckDB", try toolResult(arena, .{ .typed = "use DuckDB" }));
    try std.testing.expectEqualStrings(
        "The user dismissed the choices and will answer in their next message. End your turn now.",
        try toolResult(arena, .cancelled),
    );
}
