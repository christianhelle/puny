const std = @import("std");
const lmstudio = @import("providers/lmstudio.zig");
const openai = @import("providers/openai.zig");
const zz = @import("zigzag");
const ansi = @import("ansi.zig");
const chat = @import("chat.zig");
const model_picker = @import("tui/model_picker.zig");
const retry = @import("retry.zig");
const tools = @import("tools");

const ModelPicker = model_picker.Widget;

const system_prompt =
    \\You are Puny, a local AI coding assistant powered by LM Studio.
    \\You have access to file-system, shell, search, git, and web tools.
    \\All tools execute automatically without asking the user for confirmation.
    \\Prefer read_file and grep_search before editing files.
    \\When you have enough information, produce a concise final text answer.
;

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

    const selected_model = program.model.selected orelse {
        program.deinit();
        models.deinit();
        try stdout_writer.print("No model selected.\n", .{});
        return;
    };
    const model_key = try arena.dupe(u8, selected_model);
    program.deinit();
    models.deinit();

    var messages = std.array_list.Managed(openai.Message).init(arena);
    defer messages.deinit();
    try messages.append(.{ .system = system_prompt });

    var tool_definitions = std.array_list.Managed(openai.ToolDefinition).init(arena);
    defer tool_definitions.deinit();
    for (tools.registry) |tool| {
        const schema = try tool.schema(arena);
        try tool_definitions.append(.{ .function = schema });
    }

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

        if (std.mem.eql(u8, user_message, "/reset")) {
            messages.clearRetainingCapacity();
            try messages.append(.{ .system = system_prompt });
            try stdout_writer.print("Conversation reset.\n", .{});
            continue;
        }

        try stdout_writer.print("\nChatting with model: {s}\n", .{model_key});
        try stdout_writer.flush();

        try messages.append(.{ .user = try arena.dupe(u8, user_message) });

        var turn_complete = false;
        while (!turn_complete) {
            turn_complete = try runChatTurn(&client, arena, io, stdout_writer, random, model_key, &messages, tool_definitions.items);
        }
    }
}

fn runChatTurn(
    client: *lmstudio.Client,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    random: std.Random,
    model_key: []const u8,
    messages: *std.array_list.Managed(openai.Message),
    tool_definitions: []const openai.ToolDefinition,
) !bool {
    const request = openai.ChatRequest{
        .model = model_key,
        .messages = messages.items,
        .tools = tool_definitions,
        .stream = true,
    };

    var accumulator = chat.OpenAiAccumulator.init(arena, stdout_writer);
    defer accumulator.deinit();
    const callback = accumulator.streamCallback();

    var retry_count: usize = 0;
    const cfg = retry.default_config;

    while (true) {
        if (openai.chatStreaming(client, request, callback)) |_| break else |err| {
            if (!retry.isTransientError(err)) {
                try stdout_writer.print("\nChat failed: {}\n", .{err});
                return true;
            }

            retry_count += 1;
            if (retry_count >= cfg.max_retries) {
                try stdout_writer.print("\nChat failed after {d} retries: {}\n", .{ cfg.max_retries, err });
                return true;
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

    if (accumulator.hasToolCalls()) {
        const assistant_content = try accumulator.cloneAssistantContent(arena) orelse return true;
        try messages.append(.{ .assistant = assistant_content });

        for (assistant_content.tool_calls.?) |tc| {
            try stdout_writer.print("\n{s}🔧 {s}{s}\n", .{ ansi.dim, tc.function.name, ansi.reset });
            try stdout_writer.flush();
            const result = try executeTool(arena, io, tc);
            try messages.append(.{ .tool = .{ .tool_call_id = tc.id, .content = result } });
        }

        return false;
    }

    if (accumulator.content.items.len > 0) {
        const content = try tools.dupeString(arena, accumulator.content.items);
        try messages.append(.{ .assistant = .{ .content = content } });
    }

    try stdout_writer.print("\n", .{});
    try stdout_writer.flush();
    return true;
}

fn executeTool(arena: std.mem.Allocator, io: std.Io, tool_call: openai.ToolCall) ![]const u8 {
    const tool = tools.dispatch(tool_call.function.name) orelse {
        return std.fmt.allocPrint(arena, "Unknown tool: {s}", .{tool_call.function.name});
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, tool_call.function.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return tool.execute(arena, io, parsed.value) catch |err| {
        return std.fmt.allocPrint(arena, "Tool {s} failed: {}", .{ tool_call.function.name, err });
    };
}
