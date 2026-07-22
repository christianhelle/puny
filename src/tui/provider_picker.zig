const std = @import("std");
const zz = @import("zigzag");
const input = @import("input.zig");
const provider = @import("../providers/provider.zig");
const ModelProvider = provider.ModelProvider;

pub const ProviderOption = struct {
    id: ModelProvider,
    display_name: []const u8,
};

pub const default_providers = [_]ProviderOption{
    .{ .id = .lmstudio, .display_name = "LM Studio" },
    .{ .id = .opencode_zen, .display_name = "OpenCode Zen" },
    .{ .id = .opencode_go, .display_name = "OpenCode Go" },
    .{ .id = .copilot, .display_name = "GitHub Copilot" },
    .{ .id = .mock, .display_name = "Mock" },
};

var provider_pick_list: []const ProviderOption = &default_providers;

pub fn setProviders(providers: []const ProviderOption) void {
    provider_pick_list = providers;
}

pub const Widget = struct {
    list: zz.List([]const u8),
    selected: ?[]const u8 = null,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *Widget, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .list = zz.List([]const u8).init(ctx.persistent_allocator),
            .selected = null,
        };
        for (provider_pick_list) |p| {
            const id = ctx.persistent_allocator.dupe(u8, @tagName(p.id)) catch continue;
            const display_name = ctx.persistent_allocator.dupe(u8, p.display_name) catch {
                ctx.persistent_allocator.free(id);
                continue;
            };
            self.list.addItem(.init(id, display_name)) catch {
                ctx.persistent_allocator.free(id);
                ctx.persistent_allocator.free(display_name);
            };
        }
        self.list.height = ctx.height -| 2;
        return .none;
    }

    pub fn deinit(self: *Widget) void {
        for (self.list.items.items) |item| {
            self.list.allocator.free(item.value);
            self.list.allocator.free(item.title);
        }
        self.list.deinit();
    }

    pub fn update(self: *Widget, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                if (k.key == .enter) {
                    if (self.list.selectedItem()) |item| {
                        self.selected = item.value;
                        return .quit;
                    }
                } else if (k.key == .char and k.key.char == 'q') {
                    return .quit;
                } else {
                    self.list.handleKey(k);
                }
            },
        }
        return .none;
    }

    pub fn view(self: *const Widget, ctx: *const zz.Context) []const u8 {
        const header = "Select a provider (Use arrow keys to navigate, Enter to select, 'q' to quit):\n";
        const list_view = self.list.view(ctx.allocator) catch "Error rendering";
        return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ header, list_view }) catch "Error";
    }
};

pub fn selectProviderInteractive(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
) !?ModelProvider {
    setProviders(&default_providers);
    var program = zz.Program(Widget).init(init.gpa, io, init.environ_map);
    defer program.deinit();

    program.run() catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print(
            "\nCould not open the interactive provider picker ({s}). Falling back to text selection.\n",
            .{@errorName(err)},
        ) catch {};
        stderr_writer.flush() catch {};

        return try selectProviderText(arena, io);
    };

    const picked = program.model.selected orelse return null;
    const e = std.meta.stringToEnum(ModelProvider, picked) orelse return null;
    return e;
}

pub fn selectProviderText(
    arena: std.mem.Allocator,
    io: std.Io,
) !?ModelProvider {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("\nAvailable providers:\n", .{});
    for (provider_pick_list, 0..) |p, i| {
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
        if (i > 0 and i <= provider_pick_list.len) return provider_pick_list[i - 1].id;
        try stdout_writer.print("Invalid provider number.\n", .{});
        try stdout_writer.flush();
        return null;
    }

    if (findProviderById(line) == null) {
        try stdout_writer.print("Unknown provider '{s}'.\n", .{line});
        try stdout_writer.flush();
        return null;
    }

    if (std.meta.stringToEnum(ModelProvider, line)) |val|
        return val
    else
        return null;
}

fn findProviderById(id: []const u8) ?ProviderOption {
    const parsed = std.meta.stringToEnum(ModelProvider, id);
    if (parsed) |val| {
        for (provider_pick_list) |p| {
            if (p.id == val) return p;
        }
    }
    return null;
}

test "default_providers contains expected providers" {
    try std.testing.expectEqual(@as(usize, 5), default_providers.len);
    try std.testing.expectEqualStrings("lmstudio", default_providers[0].id);
    try std.testing.expectEqualStrings("opencode", default_providers[1].id);
    try std.testing.expectEqualStrings("opencode-go", default_providers[2].id);
    try std.testing.expectEqualStrings("copilot", default_providers[3].id);
    try std.testing.expectEqualStrings("mock", default_providers[4].id);
}

test "findProviderById finds known providers" {
    try std.testing.expectEqualStrings("LM Studio", findProviderById("lmstudio").?.display_name);
    try std.testing.expectEqualStrings("Mock", findProviderById("mock").?.display_name);
    try std.testing.expect(findProviderById("unknown") == null);
}

test "setProviders replaces the picker list" {
    const custom = [_]ProviderOption{
        .{ .id = "custom", .display_name = "Custom Provider" },
    };
    setProviders(&custom);
    defer setProviders(&default_providers);

    try std.testing.expectEqualStrings("Custom Provider", findProviderById("custom").?.display_name);
    try std.testing.expect(findProviderById("lmstudio") == null);
}
