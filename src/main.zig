const std = @import("std");
const ansi = @import("tui/ansi.zig");
const chat = @import("chat/chat.zig");
const cli = @import("cli/args.zig");
const commands = @import("cli/commands.zig");
const config = @import("config/config.zig");
const indicator = @import("tui/indicator.zig");
const input = @import("tui/input.zig");
const lmstudio = @import("providers/lmstudio.zig");
const mock = @import("providers/mock.zig");
const model_selection = @import("models/select.zig");
const openai = @import("providers/openai.zig");
const opencode = @import("providers/opencode.zig");
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

fn isValidProvider(name: []const u8) bool {
    return std.mem.eql(u8, name, "lmstudio") or std.mem.eql(u8, name, "opencode");
}

fn defaultProviderUrl(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "opencode")) return opencode.default_base_url;
    return "http://127.0.0.1:1234";
}

fn promptReconfigure(
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    cfg: *config.Config,
) !ReconfigurePrompt {
    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();
    var stdin_buffer: [4096]u8 = undefined;

    var result = ReconfigurePrompt{};

    try stdout_writer.print("Current provider: {s}\n", .{cfg.provider});
    try stdout_writer.print("Enter provider (lmstudio/opencode, or press Enter to keep current): ", .{});
    try stdout_writer.flush();

    const new_provider = input.readLineSimple(io, &line_alloc, &stdin_buffer) catch |err| {
        if (sigint.isTriggered()) return .{ .cancelled = true };
        return err;
    } orelse {
        try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try stdout_writer.flush();
        return .{ .cancelled = true };
    };

    var provider_name: []const u8 = cfg.provider;
    if (new_provider.len > 0) {
        if (!isValidProvider(new_provider)) {
            try stdout_writer.print("Invalid provider '{s}'. Keeping {s}.\n", .{ new_provider, cfg.provider });
            try stdout_writer.flush();
        } else {
            cfg.provider = try arena.dupe(u8, new_provider);
            provider_name = cfg.provider;
            result.changed = true;
        }
    }

    line_alloc.clearRetainingCapacity();
    try stdout_writer.print("Current provider URL: {s}\n", .{cfg.providerUrl});
    try stdout_writer.print("Enter new provider URL (default for {s}: {s}, press Enter to keep current): ", .{ provider_name, defaultProviderUrl(provider_name) });
    try stdout_writer.flush();

    const new_url = input.readLineSimple(io, &line_alloc, &stdin_buffer) catch |err| {
        if (sigint.isTriggered()) return .{ .cancelled = true };
        return err;
    } orelse {
        try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try stdout_writer.flush();
        return .{ .cancelled = true };
    };

    if (new_url.len > 0) {
        cfg.providerUrl = try arena.dupe(u8, new_url);
        result.changed = true;
    } else if (result.changed and cfg.providerUrl.len == 0) {
        cfg.providerUrl = try arena.dupe(u8, defaultProviderUrl(provider_name));
        result.changed = true;
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

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(arena);
    const parsed = cli.parseArgs(io, init.environ_map, args_slice);

    var cfg_result = try config.load(arena, io, init.environ_map);
    const cfg = &cfg_result.config;

    const history_path = try prompt_history.historyPath(arena, init.environ_map);
    var history = prompt_history.History.init(arena, history_path);
    defer history.deinit();
    history.load(io) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    if (parsed.reconfigure) {
        try stdout_writer.print("\nReconfiguring Puny.\n", .{});
        const result = try promptReconfigure(arena, io, stdout_writer, cfg);
        if (result.cancelled) return;
        if (result.changed) {
            try config.save(arena, io, cfg.*, init.environ_map);
            try stdout_writer.print("Configuration saved.\n", .{});
            try stdout_writer.flush();
        }
    }

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    const provider_name = effectiveProvider(parsed, cfg.*);
    const provider_url = if (parsed.mock) "-" else baseUrlFor(provider_name, parsed, cfg.*);
    const api_key = try resolveApiKey(arena, io, parsed, cfg.*, init.environ_map.get("PUNY_API_KEY"));

    if (!parsed.mock and requiresApiKey(provider_name) and api_key.len == 0) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print("Provider '{s}' requires an API key. Set one with --api-key, PUNY_API_KEY, or --reconfigure.\n", .{providerDisplayName(provider_name)}) catch {};
        stderr_writer.flush() catch {};
        return error.MissingApiKey;
    }

    const reconfigure_force_picker = parsed.reconfigure and !parsed.model_explicit;
    const configured_model = if (reconfigure_force_picker) null else parsed.model orelse cfg.model;

    var prov: provider.Provider = if (parsed.mock)
        .{ .mock = mock.MockClient.init(arena, io) }
    else if (std.mem.eql(u8, provider_name, "opencode")) blk: {
        var c = lmstudio.Client.init(arena, io, api_key);
        c.withBaseUrl(provider_url);
        break :blk .{ .opencode = c };
    } else blk: {
        var c = lmstudio.Client.init(arena, io, api_key);
        c.withBaseUrl(provider_url);
        break :blk .{ .lmstudio = c };
    };
    defer prov.deinit();

    const skip_validation = parsed.mock or parsed.oneshot or !std.mem.eql(u8, provider_url, "http://127.0.0.1:1234");
    var model_key = (try model_selection.select(&prov, configured_model, arena, io, init, skip_validation, cfg, init.environ_map, random)) orelse blk: {
        if (configured_model) |model_id| {
            try stdout_writer.print("Model '{s}' not found in running models. Showing picker.\n", .{model_id});
        }
        break :blk (try model_selection.select(&prov, null, arena, io, init, false, cfg, init.environ_map, random)) orelse {
            try stdout_writer.print("No model selected.\n", .{});
            return;
        };
    };

    try welcome.print(stdout_writer, .{
        .provider_name = if (parsed.mock) "Mock" else providerDisplayName(provider_name),
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
            const maybe_input = input.readLine(io, stdout_writer, &line_alloc, &stdin_buffer, &history) catch |err| {
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

        if (command == .prompt) {
            try history.add(user_message);
            try history.save(io);
        }

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
            .reconfigure => {
                if (parsed.oneshot) {
                    try stdout_writer.print("\n/config not available in oneshot mode.\n", .{});
                    try stdout_writer.flush();
                    continue;
                }
                const result = try promptReconfigure(arena, io, stdout_writer, cfg);
                if (result.cancelled) continue;
                if (result.changed) {
                    try config.save(arena, io, cfg.*, init.environ_map);
                    prov.setUrlAndKey(cfg.providerUrl, cfg.apiKey);
                    try stdout_writer.print("Configuration saved and provider updated.\n", .{});
                    try stdout_writer.flush();
                }
                continue;
            },
            .switch_model => |model_id| {
                const model_skip_validation = parsed.mock;
                if (try model_selection.switchModel(&prov, model_id, model_key, arena, io, init, model_skip_validation, stdout_writer, cfg, init.environ_map, random)) |new_key| {
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

fn effectiveProvider(parsed: cli.Options, cfg: config.Config) []const u8 {
    if (parsed.provider) |p| return p;
    if (cfg.provider.len > 0) return cfg.provider;
    return "lmstudio";
}

fn baseUrlFor(provider_name: []const u8, parsed: cli.Options, cfg: config.Config) []const u8 {
    if (parsed.url) |url| return url;
    if (std.mem.eql(u8, cfg.provider, provider_name) and cfg.providerUrl.len > 0) {
        return cfg.providerUrl;
    }
    if (std.mem.eql(u8, provider_name, "opencode")) return opencode.default_base_url;
    return "http://127.0.0.1:1234";
}

fn requiresApiKey(provider_name: []const u8) bool {
    return std.mem.eql(u8, provider_name, "opencode");
}

fn providerDisplayName(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "opencode")) return "OpenCode Zen";
    if (std.mem.eql(u8, provider_name, "lmstudio")) return "LM Studio";
    return provider_name;
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

test "baseUrlFor uses CLI url over defaults" {
    const cfg = config.Config{};
    const parsed = cli.Options{ .url = "http://cli.example" };
    try std.testing.expectEqualStrings("http://cli.example", baseUrlFor("lmstudio", parsed, cfg));
    try std.testing.expectEqualStrings("http://cli.example", baseUrlFor("opencode", parsed, cfg));
}

test "baseUrlFor uses config url only when provider matches config" {
    const cfg_lmstudio = config.Config{ .provider = "lmstudio", .providerUrl = "http://config-lmstudio" };
    try std.testing.expectEqualStrings("http://config-lmstudio", baseUrlFor("lmstudio", .{}, cfg_lmstudio));
    try std.testing.expectEqualStrings(opencode.default_base_url, baseUrlFor("opencode", .{}, cfg_lmstudio));
}

test "baseUrlFor returns provider defaults" {
    const cfg = config.Config{};
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", baseUrlFor("lmstudio", .{}, cfg));
    try std.testing.expectEqualStrings(opencode.default_base_url, baseUrlFor("opencode", .{}, cfg));
}

test "requiresApiKey only for opencode" {
    try std.testing.expect(!requiresApiKey("lmstudio"));
    try std.testing.expect(requiresApiKey("opencode"));
    try std.testing.expect(!requiresApiKey("mock"));
}

test "providerDisplayName maps known providers" {
    try std.testing.expectEqualStrings("LM Studio", providerDisplayName("lmstudio"));
    try std.testing.expectEqualStrings("OpenCode Zen", providerDisplayName("opencode"));
    try std.testing.expectEqualStrings("custom", providerDisplayName("custom"));
}

test "isValidProvider accepts lmstudio and opencode only" {
    try std.testing.expect(isValidProvider("lmstudio"));
    try std.testing.expect(isValidProvider("opencode"));
    try std.testing.expect(!isValidProvider("openai"));
    try std.testing.expect(!isValidProvider(""));
}

test "defaultProviderUrl returns provider-specific defaults" {
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", defaultProviderUrl("lmstudio"));
    try std.testing.expectEqualStrings(opencode.default_base_url, defaultProviderUrl("opencode"));
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", defaultProviderUrl("unknown"));
}
