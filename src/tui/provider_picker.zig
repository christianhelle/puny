const std = @import("std");
const list_picker = @import("list_picker.zig");
const input = @import("input.zig");
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

pub fn selectProviderText(
    arena: std.mem.Allocator,
    io: std.Io,
) !?ModelProvider {
    const default_providers = comptime getDefaultProviders();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("\nAvailable providers:\n", .{});
    for (default_providers, 0..) |p, i| {
        try stdout_writer.print("  {d}. {s}\n", .{ i + 1, p.display_name });
    }
    try stdout_writer.print("\nEnter provider number or key: ", .{});
    try stdout_writer.flush();

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();
    var stdin_buffer: [4096]u8 = undefined;
    const line = try input.readLineSimple(io, &line_alloc, &stdin_buffer) orelse return null;
    if (line.len == 0) return null;

    const idx = std.fmt.parseInt(usize, line, 10) catch null;
    if (idx) |i| {
        if (i > 0 and i <= default_providers.len) return default_providers[i - 1].id;
        try stdout_writer.print("Invalid provider number.\n", .{});
        try stdout_writer.flush();
        return null;
    }

    return std.meta.stringToEnum(ModelProvider, line);
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
    const arena = std.testing.allocator;
    const providers = comptime getDefaultProviders();
    var items = try buildProviderItems(arena, &providers);
    defer items.deinit(arena);

    try std.testing.expectEqual(@as(usize, 5), items.items.len);
    try std.testing.expectEqualStrings("lmstudio", items.items[0].value);
    try std.testing.expectEqualStrings("Mock", items.items[4].label);
}
