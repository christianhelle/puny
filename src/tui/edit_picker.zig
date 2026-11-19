const std = @import("std");
const list_picker = @import("list_picker.zig");
const conversation_edit = @import("../chat/conversation_edit.zig");

pub const Action = conversation_edit.Action;

/// Shows `labels` and returns the position of the one picked, or null when
/// dismissed.
pub fn pickMessage(arena: std.mem.Allocator, io: std.Io, labels: []const []const u8) !?usize {
    var items: std.ArrayList(list_picker.Item) = .empty;
    defer items.deinit(arena);
    for (labels, 0..) |label, i| {
        try items.append(arena, .{ .value = try std.fmt.allocPrint(arena, "{d}", .{i}), .label = label });
    }

    const selected = (try list_picker.selectFromList(arena, io, "Select a message to edit (Use arrow keys to navigate, Enter to select, 'q' to quit):", items.items)) orelse return null;
    return std.fmt.parseInt(usize, selected, 10) catch null;
}

/// Asks what to do with the picked message, opening right below the message
/// picker.
pub fn pickAction(arena: std.mem.Allocator, io: std.Io) !?Action {
    const items = [_]list_picker.Item{
        .{ .value = @tagName(Action.remove), .label = "Remove this message" },
        .{ .value = @tagName(Action.rewind), .label = "Rewind to this message (remove everything after it)" },
    };
    const selected = (try list_picker.selectFromListAt(arena, io, .after_picker, "Select an action (Use arrow keys to navigate, Enter to select, 'q' to quit):", &items)) orelse return null;
    return std.meta.stringToEnum(Action, selected);
}

fn withKeys(keys: []const list_picker.Key, out: *std.Io.Writer) list_picker.Script {
    return .{ .keys = keys, .out = out };
}

test "pickMessage returns the position of the picked label" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    var script = withKeys(&.{ .down, .down, .enter }, &out.writer);
    list_picker.script = &script;
    defer list_picker.script = null;

    try std.testing.expectEqual(@as(?usize, 2), try pickMessage(arena_state.allocator(), std.testing.io, &.{ "You: a", "Puny: b", "You: c" }));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Select a message to edit") != null);
}

test "pickMessage returns null when dismissed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    var script = withKeys(&.{.quit}, &out.writer);
    list_picker.script = &script;
    defer list_picker.script = null;

    try std.testing.expectEqual(@as(?usize, null), try pickMessage(arena_state.allocator(), std.testing.io, &.{"You: a"}));
}

test "pickAction returns the picked action" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    var script = withKeys(&.{.enter}, &out.writer);
    list_picker.script = &script;
    defer list_picker.script = null;

    try std.testing.expectEqual(@as(?Action, .remove), try pickAction(arena_state.allocator(), std.testing.io));
    script = withKeys(&.{ .down, .enter }, &out.writer);
    try std.testing.expectEqual(@as(?Action, .rewind), try pickAction(arena_state.allocator(), std.testing.io));
}

test "pickAction returns null when dismissed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    var script = withKeys(&.{.escape}, &out.writer);
    list_picker.script = &script;
    defer list_picker.script = null;

    try std.testing.expectEqual(@as(?Action, null), try pickAction(arena_state.allocator(), std.testing.io));
}
