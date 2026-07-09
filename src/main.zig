const std = @import("std");
const lmstudio = @import("providers/lmstudio.zig");
const openai = @import("providers/openai.zig");
const zz = @import("zigzag");
const ansi = @import("ansi.zig");
const chat = @import("chat.zig");
const model_picker = @import("tui/model_picker.zig");
const retry = @import("retry.zig");
const tools = @import("tools");
const prompts = @import("prompts.zig");
const cli = @import("cli.zig");
const provider = @import("providers/provider.zig");
const mock = @import("providers/mock.zig");

const ModelPicker = model_picker.Widget;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(arena);
    const parsed = cli.parseArgs(io, args_slice);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    var prov: provider.Provider = if (parsed.mock)
        .{ .mock = mock.MockClient.init(arena, io) }
    else blk: {
        var c = lmstudio.Client.init(arena, io, "");
        c.withBaseUrl(parsed.url);
        break :blk .{ .lmstudio = c };
    };
    defer prov.deinit();

    const skip_validation = !std.mem.eql(u8, parsed.url, "http://127.0.0.1:1234") or parsed.oneshot or parsed.mock;
    var model_key = (try selectModel(&prov, parsed.model, arena, io, init, skip_validation)) orelse blk: {
        if (parsed.model) |model_id| {
            try stdout_writer.print("Model '{s}' not found in running models. Showing picker.\n", .{model_id});
        }
        break :blk (try selectModel(&prov, null, arena, io, init, false)) orelse {
            try stdout_writer.print("No model selected.\n", .{});
            return;
        };
    };

    var full_tool_definitions = std.array_list.Managed(openai.ToolDefinition).init(arena);
    defer full_tool_definitions.deinit();
    for (tools.registry) |tool| {
        const schema = try tool.schema(arena);
        try full_tool_definitions.append(.{ .function = schema });
    }

    var planning_tool_definitions = std.array_list.Managed(openai.ToolDefinition).init(arena);
    defer planning_tool_definitions.deinit();
    for (tools.planning_registry) |tool| {
        const schema = try tool.schema(arena);
        try planning_tool_definitions.append(.{ .function = schema });
    }

    var stdin_buffer: [4096]u8 = undefined;

    var planning_mode = false;

    var messages = std.array_list.Managed(openai.Message).init(arena);
    defer messages.deinit();
    try messages.append(.{ .system = prompts.system });

    var pending_prompt = if (parsed.prompt) |p| try arena.dupe(u8, p) else null;
    var session_stats = chat.SessionStats.init(io);

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();

    while (true) {
        const user_message = if (pending_prompt) |p| blk: {
            pending_prompt = null;
            break :blk p;
        } else blk: {
            line_alloc.clearRetainingCapacity();

            var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
            const stdin_reader = &stdin_file_reader.interface;

            try stdout_writer.print("\n\nPrompt: ", .{});
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
            const result: []const u8 = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r') raw_message[0 .. raw_message.len - 1] else raw_message;
            break :blk result;
        };
        if (user_message.len == 0) continue;

        if (std.mem.eql(u8, user_message, "/quit") or std.mem.eql(u8, user_message, "/exit")) {
            try session_stats.print(io, stdout_writer);
            try stdout_writer.print("\nGoodbye.\n", .{});
            try stdout_writer.flush();
            return;
        }

        if (std.mem.eql(u8, user_message, "/reset")) {
            messages.clearRetainingCapacity();
            planning_mode = false;
            try messages.append(.{ .system = prompts.system });
            try stdout_writer.print("\nConversation reset.", .{});
            try stdout_writer.flush();
            continue;
        }

        if (std.mem.eql(u8, user_message, "/stats")) {
            try session_stats.print(io, stdout_writer);
            continue;
        }

        if (std.mem.eql(u8, user_message, "/plan") or std.mem.startsWith(u8, user_message, "/plan ")) {
            planning_mode = true;
            try messages.append(.{ .system = prompts.planning });
            if (user_message.len > 5) {
                const rest = user_message["/plan ".len..];
                try messages.append(.{ .user = try arena.dupe(u8, rest) });
                try stdout_writer.print("\n{s}Entering planning mode: {s}{s}\n", .{ ansi.bright, rest, ansi.reset });
                try stdout_writer.flush();
            } else {
                try stdout_writer.print("\n{s}Entering planning mode.{s}\n", .{ ansi.bright, ansi.reset });
                try stdout_writer.flush();
                continue;
            }
        }

        if (std.mem.eql(u8, user_message, "/build") or std.mem.startsWith(u8, user_message, "/build ")) {
            planning_mode = false;
            try messages.append(.{ .user = "Now implement the plan. Write all necessary code." });
            if (user_message.len > 6) {
                const rest = user_message["/build ".len..];
                try messages.append(.{ .user = try arena.dupe(u8, rest) });
                try stdout_writer.print("\n{s}Switching to build mode: {s}{s}\n", .{ ansi.bright, rest, ansi.reset });
                try stdout_writer.flush();
            } else {
                try stdout_writer.print("\n{s}Switching to build mode.{s}\n", .{ ansi.bright, ansi.reset });
                try stdout_writer.flush();
                continue;
            }
        }

        if (std.mem.eql(u8, user_message, "/model") or std.mem.startsWith(u8, user_message, "/model ")) {
            if (parsed.oneshot) {
                try stdout_writer.print("\n/model not available in oneshot mode.\n", .{});
                try stdout_writer.flush();
                continue;
            }
            const model_id: ?[]const u8 = if (user_message.len > 7) user_message["/model ".len..] else null;
            const model_skip_validation = parsed.mock;
            const new_key = (try selectModel(&prov, model_id, arena, io, init, model_skip_validation)) orelse {
                if (model_id != null) {
                    try stdout_writer.print("\nModel not found.\n", .{});
                    try stdout_writer.flush();
                }
                continue;
            };
            if (std.mem.eql(u8, new_key, model_key)) {
                try stdout_writer.print("\nAlready using model {s}.\n", .{new_key});
                try stdout_writer.flush();
                continue;
            }
            try stdout_writer.print("\nSwitched to model {s}.\n", .{new_key});
            try stdout_writer.flush();
            try stdout_writer.print("Reset conversation? [y/N] ", .{});
            try stdout_writer.flush();
            line_alloc.clearRetainingCapacity();
            var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
            const stdin_reader = &stdin_file_reader.interface;
            _ = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch {};
            const raw = line_alloc.written();
            const answer = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            if (answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y')) {
                messages.clearRetainingCapacity();
                planning_mode = false;
                try messages.append(.{ .system = prompts.system });
                try stdout_writer.print("Conversation reset.\n", .{});
                try stdout_writer.flush();
            }
            model_key = new_key;
            continue;
        }

        try stdout_writer.print("\nChatting with model: {s}", .{model_key});
        try stdout_writer.flush();

        try messages.append(.{ .user = try arena.dupe(u8, user_message) });

        var turn_complete = false;
        while (!turn_complete) {
            const active_tool_definitions = if (planning_mode) planning_tool_definitions.items else full_tool_definitions.items;
            const result = try runChatTurn(&prov, arena, io, stdout_writer, random, model_key, &messages, active_tool_definitions);
            if (result.usage) |usage| session_stats.addTurn(usage);
            turn_complete = result.turn_complete;
        }

        if (parsed.oneshot) {
            try stdout_writer.print("\n", .{});
            return;
        }
    }
}

fn selectModel(
    prov: *provider.Provider,
    model_id: ?[]const u8,
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    skip_validation: bool,
) !?[]const u8 {
    if (model_id) |id| {
        if (skip_validation) {
            return try arena.dupe(u8, id);
        }
        var models = try prov.listModels();
        defer models.deinit();
        const found = for (models.value().models) |m| {
            if (std.mem.eql(u8, m.key, id)) break true;
        } else false;
        if (found) {
            return try arena.dupe(u8, id);
        }
        return null;
    }
    var models = try prov.listModels();
    defer models.deinit();
    model_picker.setModels(models.value().models);
    var program = zz.Program(ModelPicker).init(init.gpa, io, init.environ_map);
    try program.run();
    const picked = program.model.selected orelse {
        program.deinit();
        return null;
    };
    const key = try arena.dupe(u8, picked);
    program.deinit();
    return key;
}

fn runChatTurn(
    prov: *provider.Provider,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    random: std.Random,
    model_key: []const u8,
    messages: *std.array_list.Managed(openai.Message),
    tool_definitions: []const openai.ToolDefinition,
) !struct { turn_complete: bool, usage: ?openai.TurnUsage } {
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
        if (prov.chatStreaming(request, callback)) |_| break else |err| {
            if (!retry.isTransientError(err)) {
                try stdout_writer.print("\nChat failed: {}\n", .{err});
                return .{ .turn_complete = true, .usage = accumulator.usage };
            }

            retry_count += 1;
            if (retry_count >= cfg.max_retries) {
                try stdout_writer.print("\nChat failed after {d} retries: {}\n", .{ cfg.max_retries, err });
                return .{ .turn_complete = true, .usage = accumulator.usage };
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

    if (accumulator.content.items.len > 0) {
        try accumulator.replaceWithRendered(stdout_writer);
    }

    if (accumulator.hasToolCalls()) {
        const assistant_content = try accumulator.cloneAssistantContent(arena) orelse return .{ .turn_complete = true, .usage = accumulator.usage };
        try messages.append(.{ .assistant = assistant_content });

        for (assistant_content.tool_calls.?) |tc| {
            try stdout_writer.print("\n{s}🔧 {s} {s}{s}", .{ ansi.dim, tc.function.name, tc.function.arguments, ansi.reset });
            try stdout_writer.flush();
            const result = try executeTool(arena, io, tc);
            try messages.append(.{ .tool = .{ .tool_call_id = tc.id, .content = result } });
        }

        return .{ .turn_complete = false, .usage = accumulator.usage };
    }

    if (accumulator.content.items.len > 0) {
        const content = try tools.dupeString(arena, accumulator.content.items);
        try messages.append(.{ .assistant = .{ .content = content } });
    }

    return .{ .turn_complete = true, .usage = accumulator.usage };
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
