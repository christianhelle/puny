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

const ansi_reset = "\x1b[0m";
const ansi_dim = "\x1b[2m";
const ansi_bright = "\x1b[1;37m";
const ansi_gray = "\x1b[90m";

const ChatStreamCallback = struct {
    stdout: *std.Io.Writer,
    arena: std.mem.Allocator,
    has_header: bool,
    stats: ?lmstudio.ChatStats,

    pub fn event(self: *@This(), event_name: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, event_name, "reasoning.delta")) {
            if (!self.has_header) {
                try self.stdout.print("\n\n{s}─── Response ───{s}\n", .{ ansi_dim, ansi_reset });
                self.has_header = true;
            }
            const parsed = try std.json.parseFromSlice(std.json.Value, self.arena, data, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const content = parsed.value.object.get("content") orelse return;
            if (content != .string) return;
            try self.stdout.print("{s}{s}{s}", .{ ansi_gray, content.string, ansi_reset });
            try self.stdout.flush();
        } else if (std.mem.eql(u8, event_name, "reasoning.end")) {
            try self.stdout.print("\n", .{});
        } else if (std.mem.eql(u8, event_name, "message.delta")) {
            if (!self.has_header) {
                try self.stdout.print("\n\n{s}─── Response ───{s}\n", .{ ansi_dim, ansi_reset });
                self.has_header = true;
            }
            const parsed = try std.json.parseFromSlice(std.json.Value, self.arena, data, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const content = parsed.value.object.get("content") orelse return;
            if (content != .string) return;
            try self.stdout.print("{s}{s}{s}", .{ ansi_bright, content.string, ansi_reset });
            try self.stdout.flush();
        } else if (std.mem.eql(u8, event_name, "chat.end")) {
            const parsed = try std.json.parseFromSlice(std.json.Value, self.arena, data, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const result = parsed.value.object.get("result") orelse return;
            const stats_val = result.object.get("stats") orelse return;
            var s: lmstudio.ChatStats = undefined;
            s.input_tokens = stats_val.object.get("input_tokens").?.integer;
            s.total_output_tokens = stats_val.object.get("total_output_tokens").?.integer;
            s.reasoning_output_tokens = stats_val.object.get("reasoning_output_tokens").?.integer;
            s.tokens_per_second = @floatCast(stats_val.object.get("tokens_per_second").?.float);
            s.time_to_first_token_seconds = @floatCast(stats_val.object.get("time_to_first_token_seconds").?.float);
            s.model_load_time_seconds = if (stats_val.object.get("model_load_time_seconds")) |v| @floatCast(v.float) else null;
            self.stats = s;
        }
    }
};

fn isTransientError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.ReadTimedOut,
        error.ReadFailed,
        error.WriteFailed,
        error.DnsFailed,
        error.NameResolveFailed,
        error.TlsFailure,
        error.SslUpgradeFailed,
        error.EndOfStream,
        => true,
        else => false,
    };
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

    var callback = ChatStreamCallback{
        .stdout = stdout_writer,
        .arena = arena,
        .has_header = false,
        .stats = null,
    };

    try lmstudio.chatStreaming(&client, chat_request, &callback);

    if (callback.stats) |stats| {
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
}
