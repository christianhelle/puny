const std = @import("std");
const ansi = @import("ansi.zig");
const chat = @import("chat.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const indicator = @import("indicator.zig");
const input = @import("input.zig");
const lmstudio = @import("providers/lmstudio.zig");
const mock = @import("providers/mock.zig");
const model_selection = @import("model_selection.zig");
const openai = @import("providers/openai.zig");
const prompts = @import("prompts.zig");
const provider = @import("providers/provider.zig");
const sigint = @import("sigint.zig");
const tools = @import("tools");
const welcome = @import("welcome.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(arena);
    const parsed = cli.parseArgs(io, init.environ_map, args_slice);

    var cfg_result = try config.load(arena, io, init.environ_map);
    const cfg = &cfg_result.config;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    if (parsed.reconfigure) {
        var reconfigure_line_alloc: std.Io.Writer.Allocating = .init(arena);
        defer reconfigure_line_alloc.deinit();
        var reconfigure_stdin_buffer: [4096]u8 = undefined;

        try stdout_writer.print("\nReconfiguring Puny.\n", .{});
        try stdout_writer.print("Current provider URL: {s}\n", .{cfg.providerUrl});
        try stdout_writer.print("Enter new provider URL (or press Enter to keep current): ", .{});
        try stdout_writer.flush();

        const new_url = input.readLineSimple(io, &reconfigure_line_alloc, &reconfigure_stdin_buffer) catch |err| {
            if (sigint.isTriggered()) return;
            return err;
        } orelse {
            try stdout_writer.print("\n{s}Reconfigure cancelled.{s}\n", .{ ansi.dim, ansi.reset });
            try stdout_writer.flush();
            return;
        };
        if (new_url.len > 0) {
            cfg.providerUrl = try arena.dupe(u8, new_url);
            try config.save(arena, io, cfg.*, init.environ_map);
            try stdout_writer.print("Updated provider URL to {s}.\n", .{cfg.providerUrl});
            try stdout_writer.flush();
        }
    }

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    const provider_url = parsed.url orelse cfg.providerUrl;
    const reconfigure_force_picker = parsed.reconfigure and !parsed.model_explicit;
    const configured_model = if (reconfigure_force_picker) null else parsed.model orelse cfg.model;

    var prov: provider.Provider = if (parsed.mock)
        .{ .mock = mock.MockClient.init(arena, io) }
    else blk: {
        var c = lmstudio.Client.init(arena, io, "");
        c.withBaseUrl(provider_url);
        break :blk .{ .lmstudio = c };
    };
    defer prov.deinit();

    const skip_validation = !std.mem.eql(u8, provider_url, "http://127.0.0.1:1234") or parsed.oneshot or parsed.mock;
    var model_key = (try model_selection.select(&prov, configured_model, arena, io, init, skip_validation, cfg, init.environ_map)) orelse blk: {
        if (configured_model) |model_id| {
            try stdout_writer.print("Model '{s}' not found in running models. Showing picker.\n", .{model_id});
        }
        break :blk (try model_selection.select(&prov, null, arena, io, init, false, cfg, init.environ_map)) orelse {
            try stdout_writer.print("No model selected.\n", .{});
            return;
        };
    };

    try welcome.print(stdout_writer, .{
        .provider_name = if (parsed.mock) "Mock" else "LM Studio",
        .provider_url = provider_url,
        .model_key = model_key,
        .oneshot = parsed.oneshot,
    });

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
    const system_prompt = try cfg.resolvePrompt(arena, "system", prompts.system);
    try messages.append(.{ .system = system_prompt });

    var pending_prompt = if (parsed.prompt) |p| try arena.dupe(u8, p) else null;
    var session_stats = chat.SessionStats.init(arena, io);
    defer session_stats.deinit();
    sigint.register() catch {};

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();

    while (true) {
        if (sigint.isTriggered()) {
            printExit(&session_stats, io, stdout_writer) catch {};
            return;
        }

        const user_message = if (pending_prompt) |p| blk: {
            pending_prompt = null;
            break :blk p;
        } else blk: {
            const maybe_input = input.readLine(io, stdout_writer, &line_alloc, &stdin_buffer) catch |err| {
                if (sigint.isTriggered()) {
                    printExit(&session_stats, io, stdout_writer) catch {};
                    return;
                }
                return err;
            };
            break :blk switch (maybe_input) {
                .submitted => |text| text,
                .cancelled => {
                    try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
                    continue;
                },
                .interrupted, .eof => {
                    if (sigint.isTriggered()) {
                        printExit(&session_stats, io, stdout_writer) catch {};
                    }
                    return;
                },
            };
        };
        if (user_message.len == 0) continue;

        const command = commands.parse(user_message);
        const action = try commands.dispatch(command, .{
            .arena = arena,
            .stdout_writer = stdout_writer,
            .messages = &messages,
            .planning_mode = &planning_mode,
            .oneshot = parsed.oneshot,
            .cfg = cfg,
        });

        switch (action) {
            .exit => {
                printExit(&session_stats, io, stdout_writer) catch {};
                return;
            },
            .continue_ => continue,
            .print_stats => {
                try session_stats.print(io, stdout_writer);
                continue;
            },
            .switch_model => |model_id| {
                const model_skip_validation = parsed.mock;
                if (try model_selection.switchModel(&prov, model_id, model_key, arena, io, init, model_skip_validation, stdout_writer, cfg, init.environ_map)) |new_key| {
                    model_key = new_key;
                }
                continue;
            },
            .run_chat_turn => {},
        }

        var turn_complete = false;
        while (!turn_complete) {
            const active_tool_definitions = if (planning_mode) planning_tool_definitions.items else full_tool_definitions.items;

            var thinking_indicator = indicator.ThinkingIndicator.init(io);
            try thinking_indicator.show(stdout_writer);

            const result = chat.runTurn(&prov, arena, io, stdout_writer, &session_stats, random, model_key, &messages, active_tool_definitions, &thinking_indicator) catch |err| {
                try thinking_indicator.finish(io, stdout_writer, 0, false, false, .error_, null);
                return err;
            };

            if (result.was_cancelled) {
                // Cancelled turn: runTurn already finalized the indicator and usage.
                _ = messages.pop();
                session_stats.finalizeTurn(null, false);
                break;
            }

            session_stats.finalizeTurn(result.usage, result.turn_complete);
            turn_complete = result.turn_complete;
        }

        if (parsed.oneshot) {
            try stdout_writer.print("\n", .{});
            return;
        }
    }
}

fn printExit(
    session_stats: *const chat.SessionStats,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
) !void {
    try session_stats.print(io, stdout_writer);
    try stdout_writer.print("\nGoodbye.\n", .{});
    try stdout_writer.flush();
}

