const std = @import("std");
const chat = @import("chat/chat.zig");
const cli = @import("cli/args.zig");
const config = @import("config/config.zig");
const http_client = @import("providers/client.zig");
const model_selection = @import("models/select.zig");
const openai = @import("providers/openai.zig");
const core_sess = @import("core/session.zig");
const prompt_history = @import("prompts/history.zig");
const prompts = @import("prompts/prompts.zig");
const provider = @import("providers/provider.zig");
const session = @import("chat/session.zig");
const sigint = @import("core/sigint.zig");
const skills = @import("skills/skills.zig");
const tools = @import("tools/root.zig");
const welcome = @import("tui/welcome.zig");
const ModelProvider = provider.ModelProvider;
const DebugLog = session.DebugLog;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    var messages_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const messages_arena = messages_arena_state.allocator();
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(arena);
    const parsed = cli.parseArgs(io, init.environ_map, args_slice);

    if (parsed.upgrade) {
        try runUpgrade(io);
        return;
    }

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
    defer cfg_result.deinit();
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

    const base_dir = try core_sess.sessionBaseDir(arena, init.environ_map);
    var current_session = try core_sess.Session.init(arena, base_dir, random, io);

    var prov: provider.Provider = undefined;
    var selected_provider: ModelProvider = undefined;
    var provider_url: []const u8 = undefined;
    var model_key: []const u8 = undefined;
    try initializeProviderAndModel(
        arena,
        messages_arena,
        io,
        init,
        parsed,
        cfg,
        stdout_writer,
        random,
        &prov,
        &selected_provider,
        &provider_url,
        &model_key,
    );
    try welcome.print(stdout_writer, .{
        .provider_name = if (parsed.mock) "Mock" else provider.getProviderDisplayName(selected_provider),
        .provider_url = provider_url,
        .model_key = model_key,
        .session_id = current_session.id,
        .oneshot = parsed.oneshot,
        .prefilled = parsed.prompt != null,
    });
    if (debug_log) |*log| session.attachHttpDebugObserver(&prov, log);
    defer prov.deinit();

    var full_tool_definitions = try buildToolDefinitions(arena);
    defer full_tool_definitions.deinit(arena);

    var planning_tool_definitions = try buildPlanningToolDefinitions(arena);
    defer planning_tool_definitions.deinit(arena);

    var planning_mode = false;

    var skill_registry = skills.Registry.init(arena);
    defer skill_registry.deinit();
    if (try skills.homeDir(arena, init.environ_map)) |home| {
        const global_path = try std.fs.path.join(arena, &.{ home, ".agents", "skills" });
        try skill_registry.lightScan(io, global_path);
    }
    if (try skills.findGitRepoRoot(arena, io)) |repo_root| {
        const repo_path = try std.fs.path.join(arena, &.{ repo_root, ".agents", "skills" });
        try skill_registry.lightScan(io, repo_path);
    }

    var session_restored = false;

    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(messages_arena);
    if (!session_restored) {
        const system_prompt = try cfg.resolvePrompt(messages_arena, "system", prompts.system);
        try messages.append(messages_arena, .{ .system = system_prompt });
        if (skill_registry.count() > 0) {
            const skills_block = try skill_registry.buildListing(messages_arena);
            try messages.append(messages_arena, .{ .system = skills_block });
        }
    }

    if (!session_restored and (parsed.session != null or parsed.do_resume)) {
        if (parsed.session) |sid| {
            if (try core_sess.findSessionByPrefix(arena, io, base_dir, sid)) |s| {
                const dir = try std.fs.path.join(messages_arena, &.{ base_dir, "sessions", s.id });
                const msg_path = try std.fs.path.join(messages_arena, &.{ dir, "messages.json" });
                const file_open = std.Io.Dir.cwd().openFile(io, msg_path, .{});
                if (file_open) |file| {
                    file.close(io);
                    const data = std.Io.Dir.cwd().readFileAlloc(io, msg_path, messages_arena, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                        try stdout_writer.print("Could not read messages: {s}. Starting fresh.\n", .{@errorName(err)});
                        try stdout_writer.flush();
                        return;
                    };
                    const parsed_val = try std.json.parseFromSlice(std.json.Value, messages_arena, data, .{});
                    for (parsed_val.value.array.items) |item| {
                        const msg = try openai.Message.fromJsonValue(messages_arena, item);
                        try messages.append(messages_arena, msg);
                    }
                    current_session = try core_sess.Session.fromDir(arena, s.id, base_dir, dir,
                        try std.fs.path.join(messages_arena, &.{ dir, "plan.md" }),
                        try std.fs.path.join(messages_arena, &.{ dir, "plan.html" }),
                    );
                    planning_mode = s.planning_mode;
                    session_restored = true;
                    try stdout_writer.print("Restored session {s} — {d} messages:\n", .{ s.id, messages.items.len });
                    try session.printConversation(stdout_writer, messages.items);
                    try stdout_writer.flush();
                } else |_| {
                    try stdout_writer.print("Session '{s}' has no saved conversation. Starting fresh.\n", .{s.id});
                    try stdout_writer.flush();
                }
            } else {
                try stdout_writer.print("Session '{s}' not found. Starting fresh.\n", .{sid});
                try stdout_writer.flush();
            }
        } else if (parsed.do_resume) {
            const sessions = try core_sess.listSessions(arena, io, base_dir);
            var conv_sessions: usize = 0;
            var found_s: ?core_sess.SessionInfo = null;
            for (sessions) |s| {
                if (s.has_conversation) {
                    conv_sessions += 1;
                    found_s = s;
                }
            }
            if (conv_sessions == 1) {
                if (found_s) |s| {
                    const dir = try std.fs.path.join(messages_arena, &.{ base_dir, "sessions", s.id });
                    const msg_path = try std.fs.path.join(messages_arena, &.{ dir, "messages.json" });
                    const file_open = std.Io.Dir.cwd().openFile(io, msg_path, .{});
                    if (file_open) |file| {
                        file.close(io);
                        const data = try std.Io.Dir.cwd().readFileAlloc(io, msg_path, messages_arena, std.Io.Limit.limited(10 * 1024 * 1024));
                        const parsed_val = try std.json.parseFromSlice(std.json.Value, messages_arena, data, .{});
                        for (parsed_val.value.array.items) |item| {
                            const msg = try openai.Message.fromJsonValue(messages_arena, item);
                            try messages.append(messages_arena, msg);
                        }
                        current_session = try core_sess.Session.fromDir(arena, s.id, base_dir, dir,
                            try std.fs.path.join(messages_arena, &.{ dir, "plan.md" }),
                            try std.fs.path.join(messages_arena, &.{ dir, "plan.html" }),
                        );
                        planning_mode = s.planning_mode;
                        session_restored = true;
                        try stdout_writer.print("Restored session {s} — {d} messages:\n", .{ s.id, messages.items.len });
                        try session.printConversation(stdout_writer, messages.items);
                        try stdout_writer.flush();
                    } else |_| {}
                }
            } else if (conv_sessions > 1) {
                try stdout_writer.print("{d} sessions have saved conversations. Use /resume in the chat to pick one.\n", .{conv_sessions});
                try stdout_writer.flush();
            } else {
                try stdout_writer.print("No saved conversations found. Starting fresh.\n", .{});
                try stdout_writer.flush();
            }
        }
    }

    var session_stats = chat.SessionStats.init(arena, io);
    session_stats.session_id = current_session.id;
    defer session_stats.deinit();
    sigint.register() catch {};

    const ctx = session.ChatLoopContext{
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
        .model_provider = &selected_provider,
        .provider_url = &provider_url,
        .model_key = &model_key,
        .full_tool_definitions = &full_tool_definitions,
        .planning_tool_definitions = &planning_tool_definitions,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .session = &current_session,
        .session_stats = &session_stats,
        .debug_log = if (debug_log) |*log| log else null,
        .skill_registry = &skill_registry,
    };

    var chat_session = session.ChatSession.init(ctx);
    try chat_session.run();
}

fn runUpgrade(io: std.Io) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    try stderr_writer.print("Upgrading Puny via install script...\n", .{});
    try stderr_writer.flush();

    const argv: []const []const u8 = if (comptime @import("builtin").os.tag == .windows)
        &[_][]const u8{ "powershell", "-Command", "irm https://christianhelle.com/puny/install.ps1 | iex" }
    else
        &[_][]const u8{ "bash", "-c", "curl -fsSL https://christianhelle.com/puny/install | bash" };

    _ = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
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
    const result = try session.promptReconfigure(arena, io, init, stdout_writer, cfg);
    if (result.cancelled) return;
    if (result.changed) {
        try config.save(arena, io, cfg.*, init.environ_map);
        try stdout_writer.print("Configuration saved.\n", .{});
        try stdout_writer.flush();
    }
}

fn initializeProviderAndModel(
    arena: std.mem.Allocator,
    provider_arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    parsed: cli.Options,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
    random: std.Random,
    prov: *provider.Provider,
    selected_provider: *ModelProvider,
    provider_url: *[]const u8,
    model_key: *[]const u8,
) !void {
    selected_provider.* = session.effectiveProvider(parsed, cfg.*);
    provider_url.* = if (parsed.mock) "-" else session.baseUrlFor(selected_provider.*, parsed, cfg.*);
    const api_key = try session.resolveApiKey(arena, io, parsed, cfg.*, selected_provider.*, init.environ_map.get("PUNY_API_KEY"));

    if (!parsed.mock and requiresApiKey(selected_provider.*) and api_key.len == 0) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print(
            "Provider '{s}' requires an API key. Set one with --api-key, PUNY_API_KEY, or --reconfigure.\n",
            .{provider.getProviderDisplayName(selected_provider.*)},
        ) catch {};
        stderr_writer.flush() catch {};
        return error.MissingApiKey;
    }

    const reconfigure_force_picker = parsed.reconfigure and !parsed.model_explicit;
    const configured_model: ?[]const u8 = blk: {
        const raw = if (reconfigure_force_picker) null else parsed.model orelse cfg.providerEntry(selected_provider.*).model;
        if (raw) |id| {
            if (http_client.isValidUtf8(id)) break :blk id;
        }
        break :blk null;
    };

    prov.* = session.createProvider(parsed.mock, selected_provider.*, provider_url.*, api_key, provider_arena, io);
    errdefer prov.deinit();
    if (!parsed.mock) try session.ensureCopilotAuth(arena, io, init, cfg, stdout_writer, prov);

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
        selected_provider.*,
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
            selected_provider.*,
            init.environ_map,
            random,
        )) orelse {
            try stdout_writer.print("No model selected.\n", .{});
            return;
        };
    };
}

fn buildPlanningToolDefinitions(arena: std.mem.Allocator) !std.ArrayList(openai.ToolDefinition) {
    var definitions: std.ArrayList(openai.ToolDefinition) = .empty;
    errdefer definitions.deinit(arena);
    for (tools.planning_registry) |tool| {
        const schema = try tool.schema(arena);
        try definitions.append(arena, .{ .function = schema });
    }
    return definitions;
}

fn buildToolDefinitions(arena: std.mem.Allocator) !std.ArrayList(openai.ToolDefinition) {
    var definitions: std.ArrayList(openai.ToolDefinition) = .empty;
    errdefer definitions.deinit(arena);
    for (tools.registry) |tool| {
        const schema = try tool.schema(arena);
        try definitions.append(arena, .{ .function = schema });
    }
    return definitions;
}

fn requiresApiKey(selected_provider: ModelProvider) bool {
    return selected_provider == .opencode_zen or
        selected_provider == .opencode_go;
}

test "requiresApiKey only for opencode and opencode-go" {
    try std.testing.expect(!requiresApiKey(.lmstudio));
    try std.testing.expect(requiresApiKey(.opencode_zen));
    try std.testing.expect(requiresApiKey(.opencode_go));
    try std.testing.expect(!requiresApiKey(.copilot));
    try std.testing.expect(!requiresApiKey(.mock));
}

test "include core session tests" {
    _ = @import("core/session.zig");
}
