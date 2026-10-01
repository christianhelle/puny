const std = @import("std");
const client = @import("../providers/client.zig");
const list_picker = @import("list_picker.zig");
const token_stats = @import("token_stats.zig");

/// Asks which context window to use for `model`, as the GitHub Copilot app
/// does. Returns null without asking when the model has only one window, or
/// when the picker is cancelled.
pub fn pickTier(arena: std.mem.Allocator, io: std.Io, model: client.Model) !?client.ContextTier {
    const items = try tierItems(arena, model);
    if (items.len == 0) return null;
    const selected = (try list_picker.selectFromList(arena, io, "Select context size (Use arrow keys to navigate, Enter to select, 'q' to quit):", items)) orelse return null;
    return std.meta.stringToEnum(client.ContextTier, selected);
}

/// The context sizes `model` can be used with, labelled by their whole
/// window. Empty when the model has no long-context tier to choose.
pub fn tierItems(arena: std.mem.Allocator, model: client.Model) ![]const list_picker.Item {
    if (model.long_context_length <= 0) return &.{};
    const default_window = if (model.context_window > 0) model.context_window else model.context_length;
    const long_window = if (model.long_context_window > 0) model.long_context_window else model.long_context_length;

    var buf: [16]u8 = undefined;
    const default_label = try arena.dupe(u8, token_stats.formatContextSize(&buf, @intCast(default_window)));
    const long_label = try std.fmt.allocPrint(arena, "{s} (long context, higher token price)", .{token_stats.formatContextSize(&buf, @intCast(long_window))});

    const items = try arena.alloc(list_picker.Item, 2);
    items[0] = .{ .value = @tagName(client.ContextTier.default), .label = default_label };
    items[1] = .{ .value = @tagName(client.ContextTier.long_context), .label = long_label };
    return items;
}

test "tierItems offers both windows of a model priced in context tiers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const model = client.Model{
        .id = "gpt-6-luna",
        .display_name = "GPT-6 Luna",
        .provider = "OpenAI",
        .context_length = 272000,
        .long_context_length = 872000,
        .context_window = 400000,
        .long_context_window = 1000000,
    };

    const items = try tierItems(arena_state.allocator(), model);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("default", items[0].value);
    try std.testing.expectEqualStrings("400K", items[0].label);
    try std.testing.expectEqualStrings("long_context", items[1].value);
    try std.testing.expectEqualStrings("1M (long context, higher token price)", items[1].label);
}

test "tierItems offers nothing for a model with one window" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const model = client.Model{ .id = "kimi-k3", .display_name = "", .provider = "", .context_length = 917504, .context_window = 1048576 };

    try std.testing.expectEqual(@as(usize, 0), (try tierItems(arena_state.allocator(), model)).len);
}
