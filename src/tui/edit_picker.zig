const std = @import("std");
const list_picker = @import("list_picker.zig");
const conversation_edit = @import("../chat/conversation_edit.zig");

pub const Action = conversation_edit.Action;

const message_title = "Select a message to edit (Use arrow keys to navigate, Enter to select, 'q' to quit):";
const older_value = "older";
const newer_value = "newer";

/// Rows assumed for the list when the terminal height is unknown.
const default_rows = 20;

/// Shows `labels` and returns the position of the one picked, or null when
/// dismissed. The picker has no scrolling, so a conversation taller than the
/// screen is shown a page at a time, newest first, with items that move to
/// older and newer pages.
pub fn pickMessage(arena: std.mem.Allocator, io: std.Io, labels: []const []const u8) !?usize {
    const page_size = pageSize(labels.len);
    var end = labels.len;
    var start: list_picker.Start = .new_row;
    // One page per pass: picking a message or backing out returns, and the
    // older and newer items only change the page.
    while (true) {
        const first = end -| page_size;
        var items: std.ArrayList(list_picker.Item) = .empty;
        if (first > 0) try items.append(arena, .{ .value = older_value, .label = "↑ Older messages" });
        for (labels[first..end], first..) |label, i| {
            try items.append(arena, .{ .value = try std.fmt.allocPrint(arena, "{d}", .{i}), .label = label });
        }
        if (end < labels.len) try items.append(arena, .{ .value = newer_value, .label = "↓ Newer messages" });

        const selected = (try list_picker.selectFromListAt(arena, io, start, message_title, items.items)) orelse return null;
        start = .after_picker;
        if (std.mem.eql(u8, selected, older_value)) {
            end = first;
        } else if (std.mem.eql(u8, selected, newer_value)) {
            end = @min(labels.len, end + page_size);
        } else {
            return std.fmt.parseInt(usize, selected, 10) catch null;
        }
    }
}

/// Messages shown per page: all of them when they fit under the title,
/// else as many as fit beside the two page items.
fn pageSize(count: usize) usize {
    const rows = if (list_picker.screenHeight()) |height|
        list_picker.usableRowsUnder(height, list_picker.rowsFor(message_title, list_picker.screenWidth()))
    else
        default_rows;
    if (count <= rows) return @max(count, 1);
    return @max(rows -| 2, 1);
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

const many_labels = [_][]const u8{ "You: 0", "Puny: 1", "You: 2", "Puny: 3", "You: 4" };

/// Screen with 4 rows for the list under the two-row title.
fn shortScreen(keys: []const list_picker.Key, out: *std.Io.Writer) list_picker.Script {
    return .{ .keys = keys, .out = out, .width = 80, .height = 8 };
}

test "pickMessage pages a conversation taller than the screen, newest first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    // Page one: Older, 3, 4. Pick the newest message.
    var script = shortScreen(&.{ .up, .enter }, &out.writer);
    list_picker.script = &script;
    defer list_picker.script = null;

    try std.testing.expectEqual(@as(?usize, 4), try pickMessage(arena_state.allocator(), std.testing.io, &many_labels));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "You: 2") == null);
}

test "pickMessage moves to older and newer pages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    // Older -> page (Older, 1, 2, Newer); Older -> page (0, Newer);
    // Newer -> back to (Older, 1, 2, Newer); pick 1.
    var script = shortScreen(&.{ .enter, .enter, .down, .enter, .down, .enter }, &out.writer);
    list_picker.script = &script;
    defer list_picker.script = null;

    try std.testing.expectEqual(@as(?usize, 1), try pickMessage(arena_state.allocator(), std.testing.io, &many_labels));
}

test "pickMessage shows every message on one page when they fit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    var script = shortScreen(&.{.enter}, &out.writer);
    list_picker.script = &script;
    defer list_picker.script = null;

    try std.testing.expectEqual(@as(?usize, 0), try pickMessage(arena_state.allocator(), std.testing.io, many_labels[0..4]));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Older messages") == null);
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
