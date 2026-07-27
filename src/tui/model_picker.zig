const std = @import("std");
const list_picker = @import("list_picker.zig");
const client = @import("../providers/client.zig");

var model_pick_list: []const client.Model = &.{};

pub fn setModels(models: []const client.Model) void {
    model_pick_list = models;
}

pub fn pickModel(
    arena: std.mem.Allocator,
    io: std.Io,
) !?[]const u8 {
    var items: std.ArrayList(list_picker.Item) = .empty;
    defer items.deinit(arena);

    for (model_pick_list) |m| {
        try items.append(arena, .{
            .value = try arena.dupe(u8, m.id),
            .label = try std.fmt.allocPrint(arena, "{s}", .{m.display_name}),
        });
    }

    return list_picker.selectFromList(arena, io, "Select a model (Use arrow keys to navigate, Enter to select, 'q' to quit):", items.items);
}

test "setModels stores and retrieves models" {
    const models = [_]client.Model{
        .{ .id = "model-a", .display_name = "Model A", .provider = "test", .context_length = 4096 },
        .{ .id = "model-b", .display_name = "Model B", .provider = "test", .context_length = 8192 },
    };
    setModels(&models);
    try std.testing.expectEqual(@as(usize, 2), model_pick_list.len);
    try std.testing.expectEqualStrings("model-a", model_pick_list[0].id);
    try std.testing.expectEqualStrings("Model B", model_pick_list[1].display_name);
}
