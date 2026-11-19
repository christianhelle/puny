const std = @import("std");
const openai = @import("../providers/openai.zig");
const text_width = @import("../tui/markdown/width.zig");

/// Display cells of message text shown in a picker label.
pub const label_cells = 70;

/// What `/edit` does to the picked message.
pub const Action = enum { remove, rewind };

/// Indices of the messages `/edit` offers: user prompts and assistant replies
/// that carry text. System prompts, tool results, and tool-call-only replies
/// are hidden; they follow the message they belong to.
pub fn editableIndices(allocator: std.mem.Allocator, messages: []const openai.Message) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    errdefer indices.deinit(allocator);
    for (messages, 0..) |msg, i| {
        if (isEditable(msg)) try indices.append(allocator, i);
    }
    return indices.toOwnedSlice(allocator);
}

fn isEditable(msg: openai.Message) bool {
    return switch (msg) {
        .user => |content| std.mem.trim(u8, content, &std.ascii.whitespace).len > 0,
        .assistant => |assistant| if (assistant.content) |content| std.mem.trim(u8, content, &std.ascii.whitespace).len > 0 else false,
        else => false,
    };
}

/// One-line picker label: who wrote the message and its text, whitespace
/// collapsed and cut to `label_cells` cells.
pub fn itemLabel(allocator: std.mem.Allocator, msg: openai.Message) ![]const u8 {
    const who, const content = switch (msg) {
        .user => |content| .{ "You", content },
        .assistant => |assistant| .{ "Puny", assistant.content orelse "" },
        .system => |content| .{ "System", content },
        .tool => |tool| .{ "Tool", tool.content },
    };

    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(allocator);
    var words = std.mem.tokenizeAny(u8, content, &std.ascii.whitespace);
    while (words.next()) |word| {
        if (flat.items.len > 0) try flat.append(allocator, ' ');
        try flat.appendSlice(allocator, word);
    }

    const shown = text_width.prefixFitting(flat.items, label_cells);
    const ellipsis = if (shown.len < flat.items.len) "..." else "";
    return std.fmt.allocPrint(allocator, "{s}: {s}{s}", .{ who, shown, ellipsis });
}

/// Removes the message at `index`. An assistant reply takes its tool results
/// with it, since providers reject results whose call is missing.
pub fn remove(messages: *std.ArrayList(openai.Message), index: usize) void {
    const removed = messages.orderedRemove(index);
    const calls = switch (removed) {
        .assistant => |assistant| assistant.tool_calls orelse return,
        else => return,
    };
    var i = index;
    while (i < messages.items.len) {
        const msg = messages.items[i];
        if (msg == .tool and callsInclude(calls, msg.tool.tool_call_id)) {
            _ = messages.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn callsInclude(calls: []const openai.ToolCall, id: []const u8) bool {
    for (calls) |call| {
        if (std.mem.eql(u8, call.id, id)) return true;
    }
    return false;
}

/// Keeps the conversation up to and including `index`, dropping everything
/// after it. Returns how many messages were dropped. A kept assistant reply
/// loses its tool calls, since their results were dropped.
pub fn rewind(messages: *std.ArrayList(openai.Message), index: usize) usize {
    const dropped = messages.items.len - (index + 1);
    messages.shrinkRetainingCapacity(index + 1);
    switch (messages.items[index]) {
        .assistant => |*assistant| assistant.tool_calls = null,
        else => {},
    }
    return dropped;
}

fn testCall(id: []const u8) openai.ToolCall {
    return .{ .id = id, .function = .{ .name = "read_file", .arguments = "{}" } };
}

const sample_calls = [_]openai.ToolCall{ testCall("a"), testCall("b") };

fn sampleConversation(allocator: std.mem.Allocator) !std.ArrayList(openai.Message) {
    var messages: std.ArrayList(openai.Message) = .empty;
    try messages.appendSlice(allocator, &.{
        .{ .system = "base" }, // 0
        .{ .user = "first" }, // 1
        .{ .assistant = .{ .content = "looking", .tool_calls = &sample_calls } }, // 2
        .{ .tool = .{ .tool_call_id = "a", .content = "A" } }, // 3
        .{ .tool = .{ .tool_call_id = "b", .content = "B" } }, // 4
        .{ .assistant = .{ .content = "done" } }, // 5
        .{ .user = "second" }, // 6
        .{ .assistant = .{ .tool_calls = &.{testCall("c")} } }, // 7
        .{ .tool = .{ .tool_call_id = "c", .content = "C" } }, // 8
        .{ .assistant = .{ .content = "  " } }, // 9
    });
    return messages;
}

test "editableIndices lists user prompts and assistant replies with text" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    const indices = try editableIndices(allocator, messages.items);
    defer allocator.free(indices);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 5, 6 }, indices);
}

test "itemLabel names the author and flattens whitespace" {
    const allocator = std.testing.allocator;
    const user = try itemLabel(allocator, .{ .user = "fix\n\n  the   bug" });
    defer allocator.free(user);
    try std.testing.expectEqualStrings("You: fix the bug", user);

    const reply = try itemLabel(allocator, .{ .assistant = .{ .content = "Done." } });
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("Puny: Done.", reply);
}

test "itemLabel cuts long text with an ellipsis" {
    const allocator = std.testing.allocator;
    const long: [label_cells + 10]u8 = @splat('x');
    const label = try itemLabel(allocator, .{ .user = &long });
    defer allocator.free(label);
    try std.testing.expectEqual(@as(usize, "You: ".len + label_cells + "...".len), label.len);
    try std.testing.expect(std.mem.endsWith(u8, label, "x..."));
}

test "remove drops a user prompt alone" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    remove(&messages, 6);
    try std.testing.expectEqual(@as(usize, 9), messages.items.len);
    try std.testing.expect(messages.items[6] == .assistant);
}

test "remove drops an assistant reply with its tool results" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    remove(&messages, 2);
    try std.testing.expectEqual(@as(usize, 7), messages.items.len);
    try std.testing.expectEqualStrings("done", messages.items[2].assistant.content.?);
    for (messages.items) |msg| {
        if (msg == .tool) try std.testing.expectEqualStrings("c", msg.tool.tool_call_id);
    }
}

test "rewind keeps the picked message and drops the rest" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), rewind(&messages, 5));
    try std.testing.expectEqual(@as(usize, 6), messages.items.len);
    try std.testing.expectEqualStrings("done", messages.items[5].assistant.content.?);
}

test "rewind to a user prompt keeps the prompt" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 8), rewind(&messages, 1));
    try std.testing.expectEqualStrings("first", messages.items[1].user);
}

test "rewind to an assistant reply drops its tool calls" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), rewind(&messages, 2));
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqualStrings("looking", messages.items[2].assistant.content.?);
    try std.testing.expect(messages.items[2].assistant.tool_calls == null);
}
