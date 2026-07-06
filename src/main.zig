const std = @import("std");
const lmstudio = @import("providers/lmstudio.zig");
const zz = @import("zigzag");
const ansi = @import("ansi.zig");
const chat = @import("chat.zig");
const model_picker = @import("tui/model_picker.zig");
const retry = @import("retry.zig");

const ModelPicker = model_picker.Widget;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    var client = lmstudio.Client.init(arena, io, "");
    client.withBaseUrl("http://127.0.0.1:1234");
    defer client.deinit();

    var models = try lmstudio.listModels(&client);
    model_picker.setModels(models.value().models);

    var program = zz.Program(ModelPicker).init(init.gpa, io, init.environ_map);
    try program.run();

    const model_key = program.model.selected orelse {
        program.deinit();
        try stdout_writer.print("No model selected.\n", .{});
        return;
    };
    program.deinit();

    var stdin_buffer: [4096]u8 = undefined;

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();

    while (true) {
        line_alloc.clearRetainingCapacity();

        var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
        const stdin_reader = &stdin_file_reader.interface;

        try stdout_writer.print("\nEnter your message: ", .{});
        try stdout_writer.flush();

        const bytes_read = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout_writer.print("\nInput too long (max {d} bytes).\n", .{stdin_buffer.len});
                continue;
            },
            else => return err,
        };
        if (bytes_read == 0) return;

        const raw_message = line_alloc.written();
        const user_message = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r') raw_message[0 .. raw_message.len - 1] else raw_message;
        if (user_message.len == 0) continue;

        if (std.mem.eql(u8, user_message, "/quit") or std.mem.eql(u8, user_message, "/exit")) {
            try stdout_writer.print("Goodbye.\n", .{});
            return;
        }

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

        var callback = chat.StreamCallback{
            .stdout = stdout_writer,
            .arena = arena,
            .has_header = false,
            .stats = null,
        };

        var retry_count: usize = 0;
        const cfg = retry.default_config;

        while (true) {
            if (lmstudio.chatStreaming(&client, chat_request, &callback)) |_| break else |err| {
                if (!retry.isTransientError(err)) {
                    try stdout_writer.print("\nChat failed: {}\n", .{err});
                    break;
                }

                retry_count += 1;
                if (retry_count >= cfg.max_retries) {
                    try stdout_writer.print("\nChat failed after {d} retries: {}\n", .{ cfg.max_retries, err });
                    break;
                }

                var delay_ms: u64 = cfg.base_delay_ms;
                var i: usize = 1;
                while (i < retry_count) : (i += 1) delay_ms *= 2;
                delay_ms += random.intRangeAtMost(u64, 0, cfg.jitter_max_ms);

                try stdout_writer.print("\n{s}Connection error ({}), retrying in {}ms ({d}/{d})...{s}\n", .{ ansi.dim, err, delay_ms, retry_count, cfg.max_retries, ansi.reset });
                try stdout_writer.flush();
                io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
            }
        }

        if (callback.stats) |stats| {
            try chat.printStats(stdout_writer, stats);
        }
    }
}
