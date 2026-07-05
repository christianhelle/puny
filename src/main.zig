const std = @import("std");
const lmstudio = @import("providers/lmstudio.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var client = lmstudio.Client.init(arena, io, "");
    defer client.deinit();

    // List available models from LM Studio
    var models = try lmstudio.listModels(&client);
    defer models.deinit();

    try stdout_writer.print("Available models:\n", .{});
    for (models.value().models) |model| {
        try stdout_writer.print("  - {s} ({s})\n", .{ model.display_name, model.key });
    }
    try stdout_writer.flush();

    // Chat with the first available model
    if (models.value().models.len > 0) {
        const model_key = models.value().models[0].key;
        try stdout_writer.print("\nChatting with model: {s}\n", .{model_key});

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
    }

    try stdout_writer.flush();
}
