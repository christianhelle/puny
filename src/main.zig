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

fn spinnerAnimation(io: std.Io, stop: *volatile bool) void {
    const frames = "|/-\\";
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &stderr_writer.interface;
    while (!stop.*) {
        const c = frames[i % frames.len];
        w.print("\rThinking... {c}", .{c}) catch break;
        w.flush() catch break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        i += 1;
    }
    w.print("\r                \r", .{}) catch {};
}

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

    try stdout_writer.print("\nEnter your message: ", .{});
    try stdout_writer.flush();

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();
    _ = try stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len));
    const user_message = line_alloc.written();

    try stdout_writer.print("\nChatting with model: {s}\n", .{model_key});
    try stdout_writer.flush();

    var msg = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try msg.put(arena, "type", .{ .string = "text" });
    try msg.put(arena, "content", .{ .string = user_message });

    var messages = try std.json.Array.initCapacity(arena, 1);
    try messages.append(.{ .object = msg });

    const chat_request = lmstudio.ChatRequest{
        .model = model_key,
        .input = .{ .array = messages },
    };

    var stop_spinner: bool = false;
    const spinner = try std.Thread.spawn(.{}, spinnerAnimation, .{ io, &stop_spinner });

    var response = try lmstudio.chat(&client, chat_request);
    defer response.deinit();

    stop_spinner = true;
    spinner.join();

    const ansi_reset = "\x1b[0m";
    const ansi_dim = "\x1b[2m";
    const ansi_bright = "\x1b[1;37m";
    const ansi_gray = "\x1b[90m";

    try stdout_writer.print("\n\n{s}─── Response ───{s}\n", .{ ansi_dim, ansi_reset });

    for (response.value().output) |item| {
        if (item == .object) {
            const output_type = item.object.get("type") orelse continue;
            const content = item.object.get("content") orelse continue;
            if (content != .string) continue;
            if (output_type != .string) continue;

            if (std.mem.eql(u8, output_type.string, "reasoning")) {
                try stdout_writer.print("{s}{s}{s}\n", .{ ansi_gray, content.string, ansi_reset });
            } else if (std.mem.eql(u8, output_type.string, "message")) {
                try stdout_writer.print("{s}{s}{s}\n", .{ ansi_bright, content.string, ansi_reset });
            } else {
                try stdout_writer.print("{s}\n", .{content.string});
            }
        }
    }

    const stats = response.value().stats;
    try stdout_writer.print("\n{s}─── Stats ───{s}\n", .{ ansi_dim, ansi_reset });
    try stdout_writer.print("  Input tokens:        {d}\n", .{stats.input_tokens});
    try stdout_writer.print("  Output tokens:       {d} (reasoning: {d})\n", .{ stats.total_output_tokens, stats.reasoning_output_tokens });
    try stdout_writer.print("  Tokens per second:   {d:.1}\n", .{stats.tokens_per_second});
    try stdout_writer.print("  Time to first token: {d:.2}s\n", .{stats.time_to_first_token_seconds});
    if (stats.model_load_time_seconds) |load_time| {
        try stdout_writer.print("  Model load time:     {d:.2}s\n", .{load_time});
    }

    try stdout_writer.flush();
}
