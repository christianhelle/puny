const std = @import("std");
const lmstudio = @import("providers/lmstudio.zig");
const zz = @import("zigzag");

var model_pick_list: []const lmstudio.ModelInfo = &.{};

const PickModel = struct {
    list: zz.List([]const u8),
    selected: ?[]const u8 = null,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *PickModel, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .list = zz.List([]const u8).init(ctx.allocator),
            .selected = null,
        };
        for (model_pick_list) |m| {
            self.list.addItem(.init(m.key, m.display_name)) catch {};
        }
        self.list.height = ctx.height -| 2;
        return .none;
    }

    pub fn update(self: *PickModel, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
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

    pub fn view(self: *const PickModel, ctx: *const zz.Context) []const u8 {
        const header = "Select a model (Use arrow keys to navigate, Enter to select, 'q' to quit):\n";
        const list_view = self.list.view(ctx.allocator) catch "Error rendering";
        return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ header, list_view }) catch "Error";
    }
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var client = lmstudio.Client.init(arena, io, "");
    defer client.deinit();

    var models = try lmstudio.listModels(&client);
    model_pick_list = models.value().models;

    var program = zz.Program(PickModel).init(init.gpa, io, init.environ_map);
    try program.run();

    const model_key = program.model.selected orelse {
        program.deinit();
        try stdout_writer.print("No model selected.\n", .{});
        return;
    };
    program.deinit();

    try stdout_writer.print("\nChatting with model: {s}\n", .{model_key});
    try stdout_writer.flush();

    var msg = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try msg.put(arena, "type", .{ .string = "text" });
    try msg.put(arena, "content", .{ .string = "Say 'Hello from Puny!' and nothing else." });

    var messages = try std.json.Array.initCapacity(arena, 1);
    try messages.append(.{ .object = msg });

    const chat_request = lmstudio.ChatRequest{
        .model = model_key,
        .input = .{ .array = messages },
    };

    var response = try lmstudio.chat(&client, chat_request);
    defer response.deinit();

    if (response.value().output.len > 0) {
        const output = response.value().output[0];
        if (output == .object) {
            if (output.object.get("content")) |content| {
                try stdout_writer.print("Response: {s}\n", .{content.string});
            }
        }
    }

    try stdout_writer.flush();
}
