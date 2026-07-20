const std = @import("std");
const ansi = @import("tui/ansi.zig");
const chat = @import("chat/chat.zig");
const cli = @import("cli/args.zig");
const commands = @import("cli/commands.zig");
const config = @import("config/config.zig");
const indicator = @import("tui/indicator.zig");
const input = @import("tui/input.zig");
const http_client = @import("providers/client.zig");
const mock = @import("providers/mock.zig");
const model_selection = @import("models/select.zig");
const openai = @import("providers/openai.zig");
const provider_picker = @import("tui/provider_picker.zig");
const opencode = @import("providers/opencode.zig");
const copilot = @import("providers/copilot.zig");
const prompt_history = @import("prompts/history.zig");
const prompts = @import("prompts/prompts.zig");
const provider = @import("providers/provider.zig");
const sigint = @import("core/sigint.zig");
const tools = @import("tools");
const welcome = @import("tui/welcome.zig");

const ReconfigurePrompt = struct {
    changed: bool = false,
    cancelled: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    var messages_arena_state = std.heap.ArenaAllocator.init(arena);
    const messages_arena = messages_arena_state.allocator();
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(arena);
    const parsed = cli.parseArgs(io, init.environ_map, args_slice);

    var debug_buffer: [4096]u8 = undefined;
    var debug_file_writer: std.Io.File.Writer = undefined;
    var debug_log: ?DebugLog = if (parsed.debug) blk: {
        const file = try std.Io.Dir.cwd().createFile(io, "puny_debug.log", .{});
        debug_file_writer = .init(file, io, &debug_buffer);
        break :blk DebugLog{
            .file = file,
            .writer = &debug_file_writer.interface,
        };
    } else null;
    defer if (debug_log) |*log| {
        log.writer.flush() catch {};
        log.file.close(io);
    };

    var cfg_result = try config.load(arena, io, init.environ_map);
    defer cfg_result.deinit(arena);
    const cfg = &cfg_result.config;

    var history = try loadHistory(arena, io, init.environ_map);
    defer history.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    if (parsed.reconfigure) {
        try runStartupReconfigure(arena, io, init, cfg, stdout_writer);
    }

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    var prov: provider.Provider = undefined;
    var provider_name: []const u8 = undefined;
    var provider_url: []const u8 = undefined;
    var model_key: []const u8 = undefined;
    try initializeProviderAndModel(
        arena,
        io,
        init,
        parsed,
        cfg,
        stdout_writer,
        random,
        &prov,
        &provider_name,
        &provider_url,
        &model_key,
    );
    if (debug_log) |*log| attachHttpDebugObserver(&prov, log);
    defer prov.deinit();

    var full_tool_definitions = try buildToolDefinitions(arena);
    defer full_tool_definitions.deinit();

    var planning_tool_definitions = try buildPlanningToolDefinitions(arena);
    defer planning_tool_definitions.deinit();

    var stdin_buffer: [4096]u8 = undefined;

    var planning_mode = false;

    var messages = std.array_list.Managed(openai.Message).init(messages_arena);
    defer messages.deinit();
    const system_prompt = try cfg.resolvePrompt(messages_arena, "system", prompts.system);
    try messages.append(.{ .system = system_prompt });

    var pending_prompt: ?[]const u8 = if (parsed.prompt) |p| try arena.dupe(u8, p) else null;
    var session_stats = chat.SessionStats.init(arena, io);
    defer session_stats.deinit();
    sigint.register() catch {};

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();

    var ctx = ChatLoopContext{
        .arena = arena,
        .messages_arena = &messages_arena_state,
        .io = io,
        .init = init,
        .parsed = parsed,
        .cfg = cfg,
        .stdout_writer = stdout_writer,
        .random = random,
        .history = &history,
        .prov = &prov,
        .provider_name = &provider_name,
        .provider_url = &provider_url,
        .model_key = &model_key,
        .full_tool_definitions = &full_tool_definitions,
        .planning_tool_definitions = &planning_tool_definitions,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .pending_prompt = &pending_prompt,
        .session_stats = &session_stats,
        .line_alloc = &line_alloc,
        .stdin_buffer = &stdin_buffer,
        .debug_log = if (debug_log) |*log| log else null,
    };

    try runChatLoop(&ctx);
}

fn isValidProvider(name: []const u8) bool {
    return std.mem.eql(u8, name, "lmstudio") or
        std.mem.eql(u8, name, "opencode") or
        std.mem.eql(u8, name, "copilot") or
        std.mem.eql(u8, name, "mock");
}

fn providerHasFixedUrl(provider_name: []const u8) bool {
    return std.mem.eql(u8, provider_name, "opencode") or
        std.mem.eql(u8, provider_name, "copilot") or
        std.mem.eql(u8, provider_name, "mock");
}

fn defaultProviderUrl(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "opencode")) return opencode.default_base_url;
    if (std.mem.eql(u8, provider_name, "copilot")) return copilot.default_base_url;
    if (std.mem.eql(u8, provider_name, "mock")) return "-";
    return config.default_lm_studio_url;
}

fn loadHistory(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !prompt_history.History {
    const history_path = try prompt_history.historyPath(arena, environ_map);
    var history = prompt_history.History.init(arena, history_path);
    history.load(io) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    return history;
}

fn runStartupReconfigure(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
) !void {
    try stdout_writer.print("\nReconfiguring Puny.\n", .{});
    const result = try promptReconfigure(arena, io, init, stdout_writer, cfg);
    if (result.cancelled) return;
    if (result.changed) {
        try config.save(arena, io, cfg.*, init.environ_map);
        try stdout_writer.print("Configuration saved.\n", .{});
        try stdout_writer.flush();
    }
}

fn promptReconfigure(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    stdout_writer: *std.Io.Writer,
    cfg: *config.Config,
) !ReconfigurePrompt {
    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();
    var stdin_buffer: [4096]u8 = undefined;

    var result = ReconfigurePrompt{};

    try stdout_writer.print("Current provider: {s}\n", .{cfg.provider});
    try stdout_writer.flush();

    const picked_provider = try provider_picker.selectProviderInteractive(arena, io, init) orelse {
        try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try stdout_writer.flush();
        return .{ .cancelled = true };
    };

    var provider_name: []const u8 = cfg.provider;
    var provider_changed = false;
    if (!std.mem.eql(u8, picked_provider, cfg.provider)) {
        cfg.provider = try arena.dupe(u8, picked_provider);
        provider_name = cfg.provider;
        provider_changed = true;
        result.changed = true;
    }

    const provider_url_is_fixed = providerHasFixedUrl(provider_name);
    if (provider_url_is_fixed) {
        const fixed_url = defaultProviderUrl(provider_name);
        cfg.providerUrl = try arena.dupe(u8, fixed_url);
        result.changed = true;
        try stdout_writer.print("Provider URL is fixed at {s}\n", .{fixed_url});
        try stdout_writer.flush();
    } else {
        line_alloc.clearRetainingCapacity();
        try stdout_writer.print("Current provider URL: {s}\n", .{cfg.providerUrl});
        try stdout_writer.print(
            "Enter new provider URL (default: {s}; press Enter for default): ",
            .{defaultProviderUrl(provider_name)},
        );
        try stdout_writer.flush();

        const new_url = input.readLineSimple(io, &line_alloc, &stdin_buffer) catch |err| {
            if (sigint.isTriggered()) return .{ .cancelled = true };
            return err;
        } orelse {
            try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
            try stdout_writer.flush();
            return .{ .cancelled = true };
        };

        const default_url = defaultProviderUrl(provider_name);
        if (new_url.len > 0) {
            cfg.providerUrl = try arena.dupe(u8, new_url);
            result.changed = true;
        } else if (provider_changed) {
            cfg.providerUrl = try arena.dupe(u8, default_url);
            result.changed = true;
        }
    }

    line_alloc.clearRetainingCapacity();
    const key_status = if (cfg.apiKey.len > 0) "set" else "none";
    try stdout_writer.print("Current API key: ({s})\n", .{key_status});
    try stdout_writer.print("Enter new API key (press Enter to keep, '-' to clear): ", .{});
    try stdout_writer.flush();

    const new_key = input.readLineSimple(io, &line_alloc, &stdin_buffer) catch |err| {
        if (sigint.isTriggered()) return .{ .cancelled = true };
        return err;
    } orelse {
        try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try stdout_writer.flush();
        return .{ .cancelled = true };
    };

    if (std.mem.eql(u8, new_key, "-")) {
        cfg.apiKey = "";
        result.changed = true;
    } else if (new_key.len > 0) {
        cfg.apiKey = try arena.dupe(u8, new_key);
        result.changed = true;
    }

    return result;
}

fn ensureCopilotAuth(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
    prov: *provider.Provider,
) !void {
    const client = prov.asCopilot() orelse return;
    if (client.github_token.len > 0) return;

    if (try copilot.discoverGithubToken(arena, io, init.environ_map)) |token| {
        client.setGithubToken(token);
        return;
    }

    const token = (try copilot.deviceLogin(client, stdout_writer)) orelse return error.MissingApiKey;
    client.setGithubToken(token);

    cfg.apiKey = try arena.dupe(u8, token);
    config.save(arena, io, cfg.*, init.environ_map) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print(
            "Warning: could not persist GitHub Copilot token: {s}\n",
            .{@errorName(err)},
        ) catch {};
        stderr_writer.flush() catch {};
    };
}

fn initializeProviderAndModel(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    parsed: cli.Options,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
    random: std.Random,
    prov: *provider.Provider,
    provider_name: *[]const u8,
    provider_url: *[]const u8,
    model_key: *[]const u8,
) !void {
    provider_name.* = effectiveProvider(parsed, cfg.*);
    provider_url.* = if (parsed.mock) "-" else baseUrlFor(provider_name.*, parsed, cfg.*);
    const api_key = try resolveApiKey(arena, io, parsed, cfg.*, init.environ_map.get("PUNY_API_KEY"));

    if (!parsed.mock and requiresApiKey(provider_name.*) and api_key.len == 0) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print(
            "Provider '{s}' requires an API key. Set one with --api-key, PUNY_API_KEY, or --reconfigure.\n",
            .{providerDisplayName(provider_name.*)},
        ) catch {};
        stderr_writer.flush() catch {};
        return error.MissingApiKey;
    }

    const reconfigure_force_picker = parsed.reconfigure and !parsed.model_explicit;
    const configured_model: ?[]const u8 = blk: {
        const raw = if (reconfigure_force_picker) null else parsed.model orelse cfg.model;
        if (raw) |id| {
            if (http_client.isValidUtf8(id)) break :blk id;
        }
        break :blk null;
    };

    prov.* = createProvider(parsed.mock, provider_name.*, provider_url.*, api_key, arena, io);
    if (!parsed.mock) try ensureCopilotAuth(arena, io, init, cfg, stdout_writer, prov);

    const skip_validation = parsed.mock or parsed.oneshot or !std.mem.eql(
        u8,
        provider_url.*,
        config.default_lm_studio_url,
    );
    model_key.* = (try model_selection.select(
        prov,
        configured_model,
        arena,
        io,
        init,
        skip_validation,
        cfg,
        init.environ_map,
        random,
    )) orelse blk: {
        if (configured_model) |model_id| {
            try stdout_writer.print(
                "Model '{s}' not found in running models. Showing picker.\n",
                .{model_id},
            );
        }
        break :blk (try model_selection.select(
            prov,
            null,
            arena,
            io,
            init,
            false,
            cfg,
            init.environ_map,
            random,
        )) orelse {
            try stdout_writer.print("No model selected.\n", .{});
            return;
        };
    };

    try welcome.print(stdout_writer, .{
        .provider_name = if (parsed.mock) "Mock" else providerDisplayName(provider_name.*),
        .provider_url = provider_url.*,
        .model_key = model_key.*,
        .oneshot = parsed.oneshot,
        .prefilled = parsed.prompt != null,
    });
}

fn buildToolDefinitions(arena: std.mem.Allocator) !std.array_list.Managed(openai.ToolDefinition) {
    var definitions = std.array_list.Managed(openai.ToolDefinition).init(arena);
    errdefer definitions.deinit();
    for (tools.registry) |tool| {
        const schema = try tool.schema(arena);
        try definitions.append(.{ .function = schema });
    }
    return definitions;
}

fn buildPlanningToolDefinitions(arena: std.mem.Allocator) !std.array_list.Managed(openai.ToolDefinition) {
    var definitions = std.array_list.Managed(openai.ToolDefinition).init(arena);
    errdefer definitions.deinit();
    for (tools.planning_registry) |tool| {
        const schema = try tool.schema(arena);
        try definitions.append(.{ .function = schema });
    }
    return definitions;
}

const UserInput = union(enum) {
    message: []const u8,
    continue_loop,
    exit,
};

const TurnResult = enum {
    continue_loop,
    exit,
};

const ChatLoopContext = struct {
    arena: std.mem.Allocator,
    messages_arena: *std.heap.ArenaAllocator,
    io: std.Io,
    init: std.process.Init,
    parsed: cli.Options,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
    random: std.Random,
    history: *prompt_history.History,
    prov: *provider.Provider,
    provider_name: *[]const u8,
    provider_url: *[]const u8,
    model_key: *[]const u8,
    full_tool_definitions: *std.array_list.Managed(openai.ToolDefinition),
    planning_tool_definitions: *std.array_list.Managed(openai.ToolDefinition),
    messages: *std.array_list.Managed(openai.Message),
    planning_mode: *bool,
    pending_prompt: *?[]const u8,
    session_stats: *chat.SessionStats,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: *[4096]u8,
    debug_log: ?*DebugLog,
};

fn readUserInput(ctx: *ChatLoopContext) !UserInput {
    if (ctx.pending_prompt.*) |p| {
        ctx.pending_prompt.* = null;
        return .{ .message = p };
    }

    const maybe_input = input.readLine(ctx.io, ctx.stdout_writer, ctx.line_alloc, ctx.stdin_buffer, ctx.history) catch |err| {
        if (sigint.isTriggered()) {
            printExit(ctx.session_stats, ctx.io, ctx.stdout_writer) catch {};
            return .exit;
        }
        return err;
    };

    return switch (maybe_input) {
        .submitted => |text| .{ .message = text },
        .cancelled => {
            try ctx.stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
            return .continue_loop;
        },
        .interrupted, .eof => {
            if (sigint.isTriggered()) {
                printExit(ctx.session_stats, ctx.io, ctx.stdout_writer) catch {};
            }
            return .exit;
        },
    };
}

fn runChatTurn(ctx: *ChatLoopContext) !TurnResult {
    var turn_complete = false;
    while (!turn_complete) {
        const active_tool_definitions = if (ctx.planning_mode.*) ctx.planning_tool_definitions.items else ctx.full_tool_definitions.items;

        var thinking_indicator = indicator.ThinkingIndicator.init(ctx.io);
        try thinking_indicator.show(ctx.stdout_writer);

        const result = chat.runTurn(
            ctx.prov,
            ctx.messages_arena.allocator(),
            ctx.io,
            ctx.stdout_writer,
            ctx.session_stats,
            ctx.random,
            ctx.model_key.*,
            ctx.messages,
            active_tool_definitions,
            &thinking_indicator,
        ) catch |err| {
            try thinking_indicator.finish(ctx.io, ctx.stdout_writer, 0, false, false, .error_, null);
            return err;
        };

        if (result.was_cancelled) {
            _ = ctx.messages.pop();
            ctx.session_stats.finalizeTurn(null, false);
            break;
        }

        ctx.session_stats.finalizeTurn(result.usage, result.turn_complete);
        turn_complete = result.turn_complete;
    }

    if (ctx.parsed.oneshot) {
        try ctx.stdout_writer.print("\n", .{});
        return .exit;
    }

    return .continue_loop;
}

fn handleReconfigureCommand(ctx: *ChatLoopContext) !void {
    if (ctx.parsed.oneshot) {
        try ctx.stdout_writer.print("\n/config not available in oneshot mode.\n", .{});
        try ctx.stdout_writer.flush();
        return;
    }

    const old_provider_name = effectiveProvider(ctx.parsed, ctx.cfg.*);
    const result = try promptReconfigure(ctx.arena, ctx.io, ctx.init, ctx.stdout_writer, ctx.cfg);
    if (result.cancelled) return;
    if (!result.changed) return;

    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);
    const new_provider_name = effectiveProvider(ctx.parsed, ctx.cfg.*);
    const new_provider_url = if (ctx.parsed.mock) "-" else baseUrlFor(new_provider_name, ctx.parsed, ctx.cfg.*);
    const new_api_key = try resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.init.environ_map.get("PUNY_API_KEY"));

    if (!ctx.parsed.mock and !std.mem.eql(u8, old_provider_name, new_provider_name)) {
        ctx.prov.deinit();
        ctx.prov.* = createProvider(ctx.parsed.mock, new_provider_name, new_provider_url, new_api_key, ctx.arena, ctx.io);
        if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);
        if (!ctx.parsed.mock) try ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
        ctx.provider_name.* = new_provider_name;
        ctx.provider_url.* = new_provider_url;

        const model_skip_validation =
            ctx.parsed.mock or
            ctx.parsed.oneshot or
            !std.mem.eql(u8, new_provider_url, config.default_lm_studio_url);

        const model_selection_result = try model_selection.select(
            ctx.prov,
            null,
            ctx.arena,
            ctx.io,
            ctx.init,
            model_skip_validation,
            ctx.cfg,
            ctx.init.environ_map,
            ctx.random,
        );

        if (model_selection_result) |new_key| {
            ctx.model_key.* = new_key;
        }
    } else {
        ctx.prov.setUrlAndKey(ctx.cfg.providerUrl, ctx.cfg.apiKey);
        ctx.provider_url.* = ctx.cfg.providerUrl;
    }

    try welcome.printSummary(
        ctx.stdout_writer,
        .{
            .provider_name = if (ctx.parsed.mock) "Mock" else providerDisplayName(ctx.provider_name.*),
            .provider_url = ctx.provider_url.*,
            .model_key = ctx.model_key.*,
        },
    );

    try ctx.stdout_writer.print("Configuration saved and provider updated.\n", .{});
    try ctx.stdout_writer.flush();
}

fn handleSwitchModelCommand(ctx: *ChatLoopContext, model_id: ?[]const u8) !void {
    const model_skip_validation = ctx.parsed.mock;
    if (try model_selection.switchModel(
        ctx.prov,
        model_id,
        ctx.model_key.*,
        ctx.arena,
        ctx.io,
        ctx.init,
        model_skip_validation,
        ctx.stdout_writer,
        ctx.cfg,
        ctx.init.environ_map,
        ctx.random,
    )) |new_key| {
        ctx.model_key.* = new_key;
    }
}

fn handleSwitchProviderCommand(ctx: *ChatLoopContext, provider_id: ?[]const u8) !void {
    // If a provider ID was given, validate it; otherwise show the picker
    const picked_provider = if (provider_id) |id| blk: {
        if (isValidProvider(id)) {
            break :blk id;
        }
        try ctx.stdout_writer.print("\nUnknown provider '{s}'.\n", .{id});
        try ctx.stdout_writer.flush();
        return;
    } else blk: {
        const picked = try provider_picker.selectProviderInteractive(ctx.arena, ctx.io, ctx.init) orelse {
            try ctx.stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
            try ctx.stdout_writer.flush();
            return;
        };
        break :blk picked;
    };

    // Check if provider actually changed
    const current_provider = effectiveProvider(ctx.parsed, ctx.cfg.*);
    if (std.mem.eql(u8, picked_provider, current_provider)) {
        try ctx.stdout_writer.print("\nAlready using provider {s}.\n", .{providerDisplayName(picked_provider)});
        try ctx.stdout_writer.flush();
        return;
    }

    // Update the config
    ctx.cfg.provider = try ctx.arena.dupe(u8, picked_provider);
    const new_provider_url = defaultProviderUrl(picked_provider);
    if (!providerHasFixedUrl(picked_provider)) {
        ctx.cfg.providerUrl = try ctx.arena.dupe(u8, new_provider_url);
    } else {
        ctx.cfg.providerUrl = try ctx.arena.dupe(u8, new_provider_url);
    }

    // Save the updated config
    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);

    // Re-create the provider
    const new_api_key = try resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.init.environ_map.get("PUNY_API_KEY"));
    ctx.prov.deinit();
    ctx.prov.* = createProvider(ctx.parsed.mock, picked_provider, new_provider_url, new_api_key, ctx.arena, ctx.io);
    if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);
    if (!ctx.parsed.mock) try ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
    ctx.provider_name.* = picked_provider;
    ctx.provider_url.* = new_provider_url;

    // Show model picker for the new provider
    const model_skip_validation = ctx.parsed.mock;
    const model_selection_result = try model_selection.select(
        ctx.prov,
        null,
        ctx.arena,
        ctx.io,
        ctx.init,
        model_skip_validation,
        ctx.cfg,
        ctx.init.environ_map,
        ctx.random,
    );

    if (model_selection_result) |new_key| {
        ctx.model_key.* = new_key;
    }

    // Print welcome summary
    try welcome.printSummary(
        ctx.stdout_writer,
        .{
            .provider_name = if (ctx.parsed.mock) "Mock" else providerDisplayName(ctx.provider_name.*),
            .provider_url = ctx.provider_url.*,
            .model_key = ctx.model_key.*,
        },
    );

    try ctx.stdout_writer.print("Switched to provider {s}.\n", .{providerDisplayName(picked_provider)});
    try ctx.stdout_writer.flush();
}

fn runChatLoop(ctx: *ChatLoopContext) !void {
    while (true) {
        if (sigint.isTriggered()) {
            printExit(ctx.session_stats, ctx.io, ctx.stdout_writer) catch {};
            return;
        }

        const user_input = try readUserInput(ctx);
        const user_message = switch (user_input) {
            .message => |text| text,
            .continue_loop => continue,
            .exit => return,
        };
        if (user_message.len == 0) continue;

        const command = commands.parse(user_message);
        const action = try commands.dispatch(command, .{
            .arena = ctx.arena,
            .messages_alloc = ctx.messages_arena.allocator(),
            .messages_arena = ctx.messages_arena,
            .stdout_writer = ctx.stdout_writer,
            .messages = ctx.messages,
            .planning_mode = ctx.planning_mode,
            .oneshot = ctx.parsed.oneshot,
            .cfg = ctx.cfg,
        });

        if (command == .prompt and !ctx.parsed.oneshot) {
            try ctx.history.add(user_message);
            try ctx.history.save(ctx.io);
        }

        switch (action) {
            .exit => {
                printExit(ctx.session_stats, ctx.io, ctx.stdout_writer) catch {};
                return;
            },
            .continue_ => continue,
            .full_reset => {
                try ctx.stdout_writer.print(" Performing full memory reset...", .{});
                try ctx.stdout_writer.flush();

                _ = ctx.messages_arena.reset(.free_all);
                ctx.messages.* = std.array_list.Managed(openai.Message).init(ctx.messages_arena.allocator());
                ctx.planning_mode.* = false;
                const system_prompt = try ctx.cfg.resolvePrompt(ctx.messages_arena.allocator(), "system", prompts.system);
                try ctx.messages.append(.{ .system = system_prompt });

                ctx.session_stats.deinit();
                ctx.session_stats.* = chat.SessionStats.init(ctx.arena, ctx.io);

                const new_api_key = try resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.init.environ_map.get("PUNY_API_KEY"));
                ctx.prov.deinit();
                ctx.prov.* = createProvider(ctx.parsed.mock, ctx.provider_name.*, ctx.provider_url.*, new_api_key, ctx.arena, ctx.io);
                if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);

                ctx.history.clear();

                try ctx.stdout_writer.print(" OK\n", .{});
                try ctx.stdout_writer.flush();
                continue;
            },
            .print_stats => {
                try ctx.session_stats.print(ctx.io, ctx.stdout_writer);
                continue;
            },
            .reconfigure => {
                try handleReconfigureCommand(ctx);
                continue;
            },
            .switch_model => |model_id| {
                try handleSwitchModelCommand(ctx, model_id);
                continue;
            },
            .switch_provider => |provider_id| {
                try handleSwitchProviderCommand(ctx, provider_id);
                continue;
            },
            .run_chat_turn => {},
        }

        const turn_result = try runChatTurn(ctx);
        if (turn_result == .exit) return;
    }
}

fn effectiveProvider(parsed: cli.Options, cfg: config.Config) []const u8 {
    if (parsed.provider) |p| return p;
    if (cfg.provider.len > 0) return cfg.provider;
    return "lmstudio";
}

fn baseUrlFor(provider_name: []const u8, parsed: cli.Options, cfg: config.Config) []const u8 {
    if (providerHasFixedUrl(provider_name)) return defaultProviderUrl(provider_name);
    if (parsed.url) |url| return url;
    if (std.mem.eql(u8, cfg.provider, provider_name) and cfg.providerUrl.len > 0) {
        return cfg.providerUrl;
    }
    return config.default_lm_studio_url;
}

fn requiresApiKey(provider_name: []const u8) bool {
    return std.mem.eql(u8, provider_name, "opencode");
}

fn providerDisplayName(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "opencode")) return "OpenCode Zen";
    if (std.mem.eql(u8, provider_name, "lmstudio")) return "LM Studio";
    if (std.mem.eql(u8, provider_name, "copilot")) return "GitHub Copilot";
    if (std.mem.eql(u8, provider_name, "mock")) return "Mock";
    return provider_name;
}

const DebugLog = struct {
    file: std.Io.File,
    writer: *std.Io.Writer,

    fn print(self: *DebugLog, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
    }
};

fn attachHttpDebugObserver(prov: *provider.Provider, debug_log: *DebugLog) void {
    prov.setHttpObserver(httpDebugObserver(debug_log));
}

fn httpDebugObserver(debug_log: *DebugLog) http_client.HttpObserver {
    return .{
        .ctx = debug_log,
        .onRequest = &logHttpRequest,
        .onResponse = &logHttpResponse,
        .onError = &logHttpError,
        .on_chunk = &logHttpChunk,
    };
}

fn logHttpRequest(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== REQUEST ===\n", .{});
    log.print("{s} {s}\n", .{ @tagName(method), url });
    log.print("Headers:\n", .{});
    for (headers) |h| {
        log.print("  {s}: {s}\n", .{ h.name, h.value });
    }
    if (body) |b| {
        log.print("Body ({d} bytes):\n{s}\n", .{ b.len, b });
    }
}

fn logHttpResponse(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, status: std.http.Status, headers: []const std.http.Header, body: []const u8, duration_ns: u64) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    const ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    log.print("=== RESPONSE ===\n", .{});
    log.print("{s} {s}\n", .{ @tagName(method), url });
    log.print("Status: {d} ({s})\n", .{ @intFromEnum(status), @tagName(status) });
    log.print("Duration: {d:.2}ms\n", .{ms});
    log.print("Headers:\n", .{});
    for (headers) |h| {
        log.print("  {s}: {s}\n", .{ h.name, h.value });
    }
    if (body.len > 0) {
        log.print("Body ({d} bytes):\n{s}\n", .{ body.len, body });
    }
}

fn logHttpError(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, err_name: []const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== ERROR ===\n", .{});
    log.print("{s} {s}\n", .{ @tagName(method), url });
    log.print("Error: {s}\n", .{err_name});
}

fn logHttpChunk(ctx: ?*anyopaque, data: []const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== CHUNK ===\n", .{});
    log.print("{s}\n", .{data});
}

fn createProvider(is_mock: bool, provider_name: []const u8, url: []const u8, api_key: []const u8, arena: std.mem.Allocator, io: std.Io) provider.Provider {
    if (is_mock or std.mem.eql(u8, provider_name, "mock")) return .{ .mock = mock.MockClient.init(arena, io) };
    if (std.mem.eql(u8, provider_name, "opencode")) {
        var c = http_client.Client.init(arena, io, api_key);
        c.withBaseUrl(url);
        return .{ .opencode = c };
    }
    if (std.mem.eql(u8, provider_name, "copilot")) {
        var c = copilot.Client.init(arena, io, api_key);
        c.withBaseUrl(url);
        return .{ .copilot = c };
    }
    var c = http_client.Client.init(arena, io, api_key);
    c.withBaseUrl(url);
    return .{ .lmstudio = c };
}

test "createProvider returns mock for mock flag or provider name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var by_flag = createProvider(true, "lmstudio", "http://example", "", allocator, std.testing.io);
    defer by_flag.deinit();
    try std.testing.expectEqual(std.meta.activeTag(by_flag), std.meta.Tag(provider.Provider).mock);

    var by_name = createProvider(false, "mock", "-", "", allocator, std.testing.io);
    defer by_name.deinit();
    try std.testing.expectEqual(std.meta.activeTag(by_name), std.meta.Tag(provider.Provider).mock);
}

fn resolveApiKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: cli.Options,
    cfg: config.Config,
    api_key_env: ?[]const u8,
) ![]const u8 {
    if (parsed.api_key) |key| return key;

    if (parsed.api_key_file) |path| {
        const cwd = std.Io.Dir.cwd();
        const data = try cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024));
        return std.mem.trim(u8, data, &std.ascii.whitespace);
    }

    if (api_key_env) |key| return key;

    return cfg.apiKey;
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

test "include chat retry tests" {
    _ = @import("chat/retry.zig");
}

test "resolveApiKey uses CLI key over env and config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const cfg = config.Config{ .apiKey = "config-key" };
    const parsed = cli.Options{ .api_key = "cli-key" };
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, "env-key");
    try std.testing.expectEqualStrings("cli-key", key);
}

test "resolveApiKey uses env key over config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const cfg = config.Config{ .apiKey = "config-key" };
    const parsed = cli.Options{};
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, "env-key");
    try std.testing.expectEqualStrings("env-key", key);
}

test "resolveApiKey falls back to config key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const cfg = config.Config{ .apiKey = "config-key" };
    const parsed = cli.Options{};
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, null);
    try std.testing.expectEqualStrings("config-key", key);
}

test "resolveApiKey reads and trims api key file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "key.txt", .data = "file-key\n" });

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "key.txt" });

    const cfg = config.Config{};
    const parsed = cli.Options{ .api_key_file = path };
    const key = try resolveApiKey(allocator, std.testing.io, parsed, cfg, "env-key");
    try std.testing.expectEqualStrings("file-key", key);
}

test "effectiveProvider precedence" {
    const cfg_default = config.Config{};
    try std.testing.expectEqualStrings("lmstudio", effectiveProvider(.{}, cfg_default));

    const cfg_opencode = config.Config{ .provider = "opencode" };
    try std.testing.expectEqualStrings("opencode", effectiveProvider(.{}, cfg_opencode));

    const parsed_flag = cli.Options{ .provider = "opencode" };
    try std.testing.expectEqualStrings("opencode", effectiveProvider(parsed_flag, config.Config{ .provider = "lmstudio" }));
}

test "baseUrlFor uses CLI url for lmstudio only" {
    const cfg = config.Config{};
    const parsed = cli.Options{ .url = "http://cli.example" };
    try std.testing.expectEqualStrings("http://cli.example", baseUrlFor("lmstudio", parsed, cfg));
    try std.testing.expectEqualStrings(opencode.default_base_url, baseUrlFor("opencode", parsed, cfg));
    try std.testing.expectEqualStrings(copilot.default_base_url, baseUrlFor("copilot", parsed, cfg));
    try std.testing.expectEqualStrings("-", baseUrlFor("mock", parsed, cfg));
}

test "baseUrlFor uses config url only when provider matches config" {
    const cfg_lmstudio = config.Config{ .provider = "lmstudio", .providerUrl = "http://config-lmstudio" };
    try std.testing.expectEqualStrings("http://config-lmstudio", baseUrlFor("lmstudio", .{}, cfg_lmstudio));
    try std.testing.expectEqualStrings(opencode.default_base_url, baseUrlFor("opencode", .{}, cfg_lmstudio));

    const cfg_opencode = config.Config{ .provider = "opencode", .providerUrl = "http://config-opencode" };
    try std.testing.expectEqualStrings(opencode.default_base_url, baseUrlFor("opencode", .{}, cfg_opencode));
}

test "baseUrlFor returns provider defaults" {
    const cfg = config.Config{};
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", baseUrlFor("lmstudio", .{}, cfg));
    try std.testing.expectEqualStrings(opencode.default_base_url, baseUrlFor("opencode", .{}, cfg));
    try std.testing.expectEqualStrings("-", baseUrlFor("mock", .{}, cfg));
}

test "requiresApiKey only for opencode" {
    try std.testing.expect(!requiresApiKey("lmstudio"));
    try std.testing.expect(requiresApiKey("opencode"));
    try std.testing.expect(!requiresApiKey("copilot"));
    try std.testing.expect(!requiresApiKey("mock"));
}

test "providerDisplayName maps known providers" {
    try std.testing.expectEqualStrings("LM Studio", providerDisplayName("lmstudio"));
    try std.testing.expectEqualStrings("OpenCode Zen", providerDisplayName("opencode"));
    try std.testing.expectEqualStrings("GitHub Copilot", providerDisplayName("copilot"));
    try std.testing.expectEqualStrings("Mock", providerDisplayName("mock"));
    try std.testing.expectEqualStrings("custom", providerDisplayName("custom"));
}

test "isValidProvider accepts lmstudio, opencode, copilot and mock" {
    try std.testing.expect(isValidProvider("lmstudio"));
    try std.testing.expect(isValidProvider("opencode"));
    try std.testing.expect(isValidProvider("copilot"));
    try std.testing.expect(isValidProvider("mock"));
    try std.testing.expect(!isValidProvider("openai"));
    try std.testing.expect(!isValidProvider(""));
}

test "defaultProviderUrl returns provider-specific defaults" {
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", defaultProviderUrl("lmstudio"));
    try std.testing.expectEqualStrings(opencode.default_base_url, defaultProviderUrl("opencode"));
    try std.testing.expectEqualStrings(copilot.default_base_url, defaultProviderUrl("copilot"));
    try std.testing.expectEqualStrings("-", defaultProviderUrl("mock"));
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", defaultProviderUrl("unknown"));
}

test "providerHasFixedUrl for opencode, copilot and mock" {
    try std.testing.expect(providerHasFixedUrl("opencode"));
    try std.testing.expect(providerHasFixedUrl("copilot"));
    try std.testing.expect(providerHasFixedUrl("mock"));
    try std.testing.expect(!providerHasFixedUrl("lmstudio"));
}
