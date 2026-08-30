const std = @import("std");
const list_picker = @import("list_picker.zig");
const provider = @import("../providers/provider.zig");
const ModelProvider = provider.ModelProvider;

pub const ProviderOption = struct {
    id: ModelProvider,
    display_name: []const u8,
};

pub fn buildProviderItems(arena: std.mem.Allocator, providers: []const ProviderOption) !std.ArrayList(list_picker.Item) {
    var items: std.ArrayList(list_picker.Item) = .empty;
    errdefer items.deinit(arena);

    for (providers) |p| {
        if (p.id == .mock) continue;
        try items.append(arena, .{
            .value = try arena.dupe(u8, @tagName(p.id)),
            .label = try arena.dupe(u8, p.display_name),
        });
    }

    return items;
}

pub fn selectProviderInteractive(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
) !?ModelProvider {
    _ = init;
    const default_providers = comptime getDefaultProviders();
    var items = try buildProviderItems(arena, &default_providers);
    defer items.deinit(arena);

    const picked = try list_picker.selectFromList(arena, io, "Select a provider (Use arrow keys to navigate, Enter to select, 'q' to quit):", items.items) orelse return null;
    const e = std.meta.stringToEnum(ModelProvider, picked) orelse return null;
    return e;
}

fn getDefaultProviders() [5]ProviderOption {
    return .{
        .{ .id = .lmstudio, .display_name = "LM Studio" },
        .{ .id = .opencode_zen, .display_name = "OpenCode Zen" },
        .{ .id = .opencode_go, .display_name = "OpenCode Go" },
        .{ .id = .copilot, .display_name = "GitHub Copilot" },
        .{ .id = .mock, .display_name = "Mock" },
    };
}

test "getDefaultProviders returns five known providers" {
    const providers = comptime getDefaultProviders();
    try std.testing.expectEqual(@as(usize, 5), providers.len);
    try std.testing.expectEqualStrings("lmstudio", @tagName(providers[0].id));
    try std.testing.expectEqualStrings("opencode_zen", @tagName(providers[1].id));
    try std.testing.expectEqualStrings("opencode_go", @tagName(providers[2].id));
    try std.testing.expectEqualStrings("copilot", @tagName(providers[3].id));
    try std.testing.expectEqualStrings("mock", @tagName(providers[4].id));
    try std.testing.expectEqualStrings("LM Studio", providers[0].display_name);
    try std.testing.expectEqualStrings("Mock", providers[4].display_name);
}

test "buildProviderItems creates list picker items" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const providers = comptime getDefaultProviders();
    var items = try buildProviderItems(arena, &providers);
    defer items.deinit(arena);

    // Mock is deliberately excluded from the interactive provider list: the
    // remaining four providers must appear in order and no item may be "mock".
    try std.testing.expectEqual(@as(usize, 4), items.items.len);
    try std.testing.expectEqualStrings("lmstudio", items.items[0].value);
    try std.testing.expectEqualStrings("opencode_zen", items.items[1].value);
    try std.testing.expectEqualStrings("opencode_go", items.items[2].value);
    try std.testing.expectEqualStrings("copilot", items.items[3].value);
    for (items.items) |item| {
        try std.testing.expect(!std.mem.eql(u8, item.value, "mock"));
    }
}
