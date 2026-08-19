const std = @import("std");
const openai = @import("../providers/openai.zig");
const usage = @import("usage.zig");

/// Conversation messages kept at the tail of the message list when compacting.
pub const default_keep_recent: usize = 20;

test "estimateContextTokens sums the messages in the list" {
    const messages = [_]openai.Message{
        .{ .system = "You are a helpful assistant." },
        .{ .user = "Hello, world!" },
    };
    try std.testing.expectEqual(usage.estimateUsage(&messages, 0).input_tokens, estimateContextTokens(&messages));
}

test "autoCompactLimit is ninety percent of the window" {
    try std.testing.expectEqual(@as(i64, 90000), autoCompactLimit(100000));
}

test "shouldAutoCompact is false below ninety percent" {
    try std.testing.expect(!shouldAutoCompact(899, 1000));
}

test "shouldAutoCompact is true above ninety percent" {
    try std.testing.expect(shouldAutoCompact(901, 1000));
}

test "shouldAutoCompact is false when the context window is unknown" {
    try std.testing.expect(!shouldAutoCompact(100, 0));
}

test "compactMessages keeps leading system messages and the most recent messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .system = "System prompt" });
    try messages.append(allocator, .{ .user = "one" });
    try messages.append(allocator, .{ .assistant = .{ .content = "two" } });
    try messages.append(allocator, .{ .user = "three" });
    try messages.append(allocator, .{ .assistant = .{ .content = "four" } });

    const removed = try compactMessages(allocator, &messages, 1);

    try std.testing.expectEqual(@as(usize, 3), removed);
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .system = "System prompt" }, messages.items[0]);
    try std.testing.expect(messages.items[1] == .system);
    try std.testing.expectEqualDeep(openai.Message{ .assistant = .{ .content = "four" } }, messages.items[2]);
}

test "compactMessages removes nothing when within the keep limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .system = "System prompt" });
    try messages.append(allocator, .{ .user = "hello" });

    const removed = try compactMessages(allocator, &messages, 5);

    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
}

test "compactMessages drops orphaned tool messages at the boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .system = "System prompt" });
    try messages.append(allocator, .{ .user = "one" });
    try messages.append(allocator, .{ .assistant = .{ .content = null, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{}" } },
    } } });
    try messages.append(allocator, .{ .tool = .{ .tool_call_id = "call_1", .content = "data" } });

    const removed = try compactMessages(allocator, &messages, 1);

    try std.testing.expectEqual(@as(usize, 3), removed);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .system = "System prompt" }, messages.items[0]);
    try std.testing.expect(messages.items[1] == .system);
}

test "compactMessages keeps tool messages when their assistant message survives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .system = "System prompt" });
    try messages.append(allocator, .{ .user = "one" });
    try messages.append(allocator, .{ .user = "two" });
    try messages.append(allocator, .{ .assistant = .{ .content = null, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{}" } },
    } } });
    try messages.append(allocator, .{ .tool = .{ .tool_call_id = "call_1", .content = "data" } });

    const removed = try compactMessages(allocator, &messages, 2);

    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .system = "System prompt" }, messages.items[0]);
    try std.testing.expect(messages.items[1] == .system);
    try std.testing.expect(messages.items[2] == .assistant);
    try std.testing.expect(messages.items[3] == .tool);
}

test "compactMessages with only system messages removes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .system = "one" });
    try messages.append(allocator, .{ .system = "two" });

    const removed = try compactMessages(allocator, &messages, 1);

    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
}

pub fn estimateContextTokens(messages: []const openai.Message) i64 {
    return usage.estimateUsage(messages, 0).input_tokens;
}

pub fn autoCompactLimit(context_window_tokens: i64) i64 {
    return @divFloor(context_window_tokens * 90, 100);
}

pub fn shouldAutoCompact(estimated_tokens: i64, context_window_tokens: i64) bool {
    if (context_window_tokens <= 0) return false;
    return estimated_tokens > autoCompactLimit(context_window_tokens);
}

pub fn compactMessages(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(openai.Message),
    keep_recent: usize,
) !usize {
    var conversation_start: usize = 0;
    while (conversation_start < messages.items.len and messages.items[conversation_start] == .system) : (conversation_start += 1) {}

    const conversation_count = messages.items.len - conversation_start;
    if (conversation_count <= keep_recent) return 0;

    var removed: usize = 0;
    var to_remove = conversation_count - keep_recent;
    while (to_remove > 0) : (to_remove -= 1) {
        _ = messages.orderedRemove(conversation_start);
        removed += 1;
    }

    while (messages.items.len > conversation_start and messages.items[conversation_start] == .tool) {
        _ = messages.orderedRemove(conversation_start);
        removed += 1;
    }

    const notice = "Earlier conversation context was compacted to fit the context window. Continue from the most recent context below.";
    try messages.insert(allocator, conversation_start, .{ .system = notice });

    return removed;
}

