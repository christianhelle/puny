const std = @import("std");
const openai = @import("../providers/openai.zig");
const text_width = @import("../tui/markdown/width.zig");
const ansi = @import("../tui/ansi.zig");

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

/// One-line picker label: who wrote the message and its text, with control
/// characters scrubbed and whitespace collapsed, cut so the whole picker row
/// fits a `width` column terminal. The picker can't redraw a row that wraps,
/// and model-written escapes must not reach the terminal.
pub fn itemLabel(allocator: std.mem.Allocator, msg: openai.Message, width: usize) ![]const u8 {
    const who, const content = switch (msg) {
        .user => |content| .{ "You: ", content },
        .assistant => |assistant| .{ "Puny: ", assistant.content orelse "" },
        .system => |content| .{ "System: ", content },
        .tool => |tool| .{ "Tool: ", tool.content },
    };

    const scrubbed = try allocator.dupe(u8, content);
    defer allocator.free(scrubbed);
    ansi.scrubControls(scrubbed);

    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(allocator);
    var words = std.mem.tokenizeAny(u8, scrubbed, &std.ascii.whitespace);
    while (words.next()) |word| {
        if (flat.items.len > 0) try flat.append(allocator, ' ');
        try flat.appendSlice(allocator, word);
    }

    // The picker puts "> " before the selected label, and one spare cell
    // keeps a full row from wrapping.
    const text_cells = (width -| picker_row_cells) -| who.len;
    if (text_width.displayWidth(flat.items) <= text_cells) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ who, flat.items });
    }
    const shown = text_width.prefixFitting(flat.items, text_cells -| 1);
    return std.fmt.allocPrint(allocator, "{s}{s}…", .{ who, shown });
}

/// Cells of a picker row that aren't the label: the "> " selection marker
/// and one spare cell.
const picker_row_cells = 3;

/// Removes the message at `index`. An assistant reply takes its tool results
/// with it, since providers reject results whose call is missing. Only the
/// results right after the reply are its own: some providers reuse call ids
/// such as `call_0` in every response.
///
/// Removing the first user prompt also removes the replies to it, up to the
/// next prompt: Anthropic and Gemini reject a conversation whose first turn
/// is the model's. System messages stay. Returns how many messages went.
pub fn remove(messages: *std.ArrayList(openai.Message), index: usize) usize {
    const before = messages.items.len;
    switch (messages.orderedRemove(index)) {
        .assistant => |assistant| if (assistant.tool_calls) |calls| {
            while (index < messages.items.len) {
                const msg = messages.items[index];
                if (msg != .tool or !callsInclude(calls, msg.tool.tool_call_id)) break;
                _ = messages.orderedRemove(index);
            }
        },
        .user => if (!hasUserBefore(messages.items, index)) {
            var i = index;
            while (i < messages.items.len and messages.items[i] != .user) {
                if (messages.items[i] == .system) {
                    i += 1;
                } else {
                    _ = messages.orderedRemove(i);
                }
            }
        },
        else => {},
    }
    return before - messages.items.len;
}

fn hasUserBefore(messages: []const openai.Message, index: usize) bool {
    for (messages[0..index]) |msg| {
        if (msg == .user) return true;
    }
    return false;
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
    const user = try itemLabel(allocator, .{ .user = "fix\n\n  the   bug" }, 80);
    defer allocator.free(user);
    try std.testing.expectEqualStrings("You: fix the bug", user);

    const reply = try itemLabel(allocator, .{ .assistant = .{ .content = "Done." } }, 80);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("Puny: Done.", reply);
}

test "itemLabel scrubs terminal control sequences" {
    const allocator = std.testing.allocator;
    const label = try itemLabel(allocator, .{ .assistant = .{ .content = "a\x1b[2Jb\x1b[Hc" } }, 80);
    defer allocator.free(label);
    try std.testing.expect(std.mem.indexOfScalar(u8, label, 0x1b) == null);
    try std.testing.expectEqualStrings("Puny: a [2Jb [Hc", label);
}

test "itemLabel fits the whole picker row in the terminal width" {
    const allocator = std.testing.allocator;
    const long: [200]u8 = @splat('x');
    for ([_]usize{ 40, 80, 120 }) |width| {
        const label = try itemLabel(allocator, .{ .assistant = .{ .content = &long } }, width);
        defer allocator.free(label);
        // "> " marker plus label must leave a spare cell.
        try std.testing.expectEqual(width - 1, 2 + text_width.displayWidth(label));
        try std.testing.expect(std.mem.endsWith(u8, label, "x…"));
    }
}

test "itemLabel keeps text that just fits uncut" {
    const allocator = std.testing.allocator;
    const fits: [80 - 3 - "You: ".len]u8 = @splat('x');
    const label = try itemLabel(allocator, .{ .user = &fits }, 80);
    defer allocator.free(label);
    try std.testing.expect(!std.mem.endsWith(u8, label, "…"));
}

test "remove drops a user prompt alone" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), remove(&messages, 6));
    try std.testing.expectEqual(@as(usize, 9), messages.items.len);
    try std.testing.expect(messages.items[6] == .assistant);
}

test "remove drops an assistant reply with its tool results" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), remove(&messages, 2));
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

test "remove leaves later results that reuse the reply's call ids" {
    const allocator = std.testing.allocator;
    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(allocator);
    const reused = [_]openai.ToolCall{testCall("call_0")};
    try messages.appendSlice(allocator, &.{
        .{ .user = "first" },
        .{ .assistant = .{ .content = "looking", .tool_calls = &reused } },
        .{ .tool = .{ .tool_call_id = "call_0", .content = "early" } },
        .{ .user = "second" },
        .{ .assistant = .{ .tool_calls = &reused } },
        .{ .tool = .{ .tool_call_id = "call_0", .content = "late" } },
    });

    try std.testing.expectEqual(@as(usize, 2), remove(&messages, 1));
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqualStrings("late", messages.items[3].tool.content);
}

test "remove of the first prompt takes its replies so a prompt still leads" {
    const allocator = std.testing.allocator;
    var messages = try sampleConversation(allocator);
    defer messages.deinit(allocator);
    try messages.insert(allocator, 3, .{ .system = "skill" });

    try std.testing.expectEqual(@as(usize, 5), remove(&messages, 1));
    try std.testing.expectEqual(@as(usize, 6), messages.items.len);
    try std.testing.expectEqualStrings("base", messages.items[0].system);
    try std.testing.expectEqualStrings("skill", messages.items[1].system);
    try std.testing.expectEqualStrings("second", messages.items[2].user);
}

test "remove of the only prompt takes every reply" {
    const allocator = std.testing.allocator;
    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(allocator);
    try messages.appendSlice(allocator, &.{ .{ .system = "base" }, .{ .user = "hi" }, .{ .assistant = .{ .content = "hello" } } });

    try std.testing.expectEqual(@as(usize, 2), remove(&messages, 1));
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
}
