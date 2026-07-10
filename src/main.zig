const std = @import("std");
const commands = @import("commands.zig");
const model_selection = @import("model_selection.zig");
const lmstudio = @import("providers/lmstudio.zig");
const openai = @import("providers/openai.zig");
const ansi = @import("ansi.zig");
const chat = @import("chat.zig");
const tools = @import("tools");
const prompts = @import("prompts.zig");
const cli = @import("cli.zig");
const provider = @import("providers/provider.zig");
const mock = @import("providers/mock.zig");
const sigint = @import("sigint.zig");

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
    var model_key = (try model_selection.select(&prov, parsed.model, arena, io, init, skip_validation)) orelse blk: {
        if (parsed.model) |model_id| {
            try stdout_writer.print("Model '{s}' not found in running models. Showing picker.\n", .{model_id});
        }
        break :blk (try model_selection.select(&prov, null, arena, io, init, false)) orelse {
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
    sigint.register() catch {};

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();

    while (true) {
        if (sigint.isTriggered()) {
            printExit(session_stats, io, stdout_writer) catch {};
            return;
        }

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
                else => {
                    if (sigint.isTriggered()) {
                        printExit(session_stats, io, stdout_writer) catch {};
                        return;
                    }
                    return err;
                },
            };
            if (bytes_read == 0) {
                if (sigint.isTriggered()) {
                    printExit(session_stats, io, stdout_writer) catch {};
                }
                return;
            }

            const raw_message = line_alloc.written();
            const result: []const u8 = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r') raw_message[0 .. raw_message.len - 1] else raw_message;
            break :blk result;
        };
        if (user_message.len == 0) continue;

        const command = commands.parse(user_message);
        const action = try commands.dispatch(command, .{
            .arena = arena,
            .stdout_writer = stdout_writer,
            .messages = &messages,
            .planning_mode = &planning_mode,
            .oneshot = parsed.oneshot,
        });

        switch (action) {
            .exit => {
                printExit(session_stats, io, stdout_writer) catch {};
                return;
            },
            .continue_ => continue,
            .print_stats => {
                try session_stats.print(io, stdout_writer);
                continue;
            },
            .switch_model => |model_id| {
                const model_skip_validation = parsed.mock;
                const new_key = (try model_selection.select(&prov, model_id, arena, io, init, model_skip_validation)) orelse {
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
                model_key = new_key;
                continue;
            },
            .run_chat_turn => {},
        }

        var turn_complete = false;
        while (!turn_complete) {
            const active_tool_definitions = if (planning_mode) planning_tool_definitions.items else full_tool_definitions.items;
            const result = chat.runTurn(&prov, arena, io, stdout_writer, random, model_key, &messages, active_tool_definitions) catch |err| switch (err) {
                error.Canceled => {
                    try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
                    _ = messages.pop();
                    break;
                },
                else => return err,
            };
            session_stats.addTurn(result.usage, result.turn_complete);
            turn_complete = result.turn_complete;
        }

        if (parsed.oneshot) {
            try stdout_writer.print("\n", .{});
            return;
        }
    }
}

fn printExit(
    session_stats: chat.SessionStats,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
) !void {
    try session_stats.print(io, stdout_writer);
    try stdout_writer.print("\nGoodbye.\n", .{});
    try stdout_writer.flush();
}

