const std = @import("std");
const chat = @import("chat/chat.zig");
const stats = @import("chat/stats.zig");
const upgrade = @import("upgrade.zig");
const cli = @import("cli/args.zig");
const config = @import("config/config.zig");
const http_client = @import("providers/client.zig");
const model_selection = @import("models/select.zig");
const openai = @import("providers/openai.zig");
const core_sess = @import("core/session.zig");
const git_root = @import("core/git_root.zig");
const sessions = @import("sessions/sessions.zig");
const prompt_history = @import("prompts/history.zig");
const prompt_file = @import("prompts/prompt_file.zig");
const prompts = @import("prompts/prompts.zig");
const provider = @import("providers/provider.zig");
const resolver = @import("providers/resolver.zig");
const session = @import("chat/session.zig");
const display = @import("chat/display.zig");
const sigint = @import("core/sigint.zig");
const instructions = @import("agents/instructions.zig");
const skills = @import("skills/skills.zig");
const tools = @import("tools/root.zig");
const welcome = @import("tui/welcome.zig");
const ansi = @import("tui/ansi.zig");
const vt = @import("tui/vt.zig");
const update_check = @import("update_check.zig");

comptime {
    // Keep the module analyzed so its tests run under `zig build test`.
    _ = update_check;
}
const ModelProvider = provider.ModelProvider;
const DebugLog = session.DebugLog;
const ChatLog = session.ChatLog;

pub fn main(init: std.process.Init) !void {
    vt.enableAnsi();
    vt.enableUtf8();
    const arena: std.mem.Allocator = init.arena.allocator();
    var messages_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const messages_arena = messages_arena_state.allocator();
    const startup_time = std.Io.Clock.Timestamp.now(init.io, .awake);

    upgrade.cleanupOldBackup(arena, init.io);

    const args_slice = try init.minimal.args.toSlice(arena);
    var parsed = cli.parseArgs(init.io, init.environ_map, args_slice);

    if (parsed.upgrade) {
        try upgrade.runUpgrade(arena, init.io, init.environ_map, parsed.force_upgrade);
        update_check.clearFlag(init.io, arena, init.environ_map) catch {};
        return;
    }

    // Detached child process entry: run the update check and exit quietly.
    // The child is marked with PUNY_UPDATE_CHECK=1 by the parent's spawn, so
    // this branch is only ever taken inside the detached process. The parent
    // surfaces the result via the flag file; the detached spawn discards stderr
    // and ignores the exit code, so failures stay silent here.
    if (std.mem.eql(u8, init.environ_map.get(update_check.check_env_var) orelse "", "1")) {
        _ = update_check.runCheck(init.io, arena, init.environ_map) catch {};
        return;
    }

    if (parsed.prune) {
        var buf: [1024]u8 = undefined;
        var out: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
        const base_dir = try core_sess.sessionBaseDir(arena, init.environ_map);
        const keep_id = parsed.session orelse "";
        try sessions.pruneSessions(arena, init.io, base_dir, keep_id);
        if (keep_id.len > 0) {
            try out.interface.print("Pruned all sessions except '{s}'.\n", .{keep_id});
        } else {
            try out.interface.print("Pruned all sessions.\n", .{});
        }
        try out.interface.flush();
        return;
    }

    // Load the prompt file up front so a missing file or URL fails fast,
    // before any provider/model initialization work happens. The loaded
    // content becomes the pending prompt, exactly like `--prompt`.
    if (parsed.prompt_file) |source| {
        const outcome = prompt_file.load(arena, init.io, source);
        switch (outcome) {
            .ok => |content| {
                if (content.len == 0) {
                    printStartupError(init.io, source, "prompt file is empty");
                    std.process.exit(1);
                }
                parsed.prompt = content;
            },
            .err => |e| {
                defer if (e.owned) arena.free(e.message);
                printStartupError(init.io, source, e.message);
                std.process.exit(1);
            },
        }
    }

    var debug_buffer: [4096]u8 = undefined;
    var debug_file_writer: std.Io.File.Writer = undefined;
    var debug_log: ?DebugLog = if (parsed.debug) blk: {
        const file = try std.Io.Dir.cwd().createFile(init.io, "puny_debug.log", .{});
        debug_file_writer = .init(file, init.io, &debug_buffer);
        break :blk DebugLog{
            .file = file,
            .writer = &debug_file_writer.interface,
            .allocator = std.heap.smp_allocator,
        };
    } else null;
    defer if (debug_log) |*log| {
        log.writer.flush() catch {};
        log.file.close(init.io);
    };

    var chat_buffer: [4096]u8 = undefined;
    var chat_file_writer: std.Io.File.Writer = undefined;
    var chat_log: ?ChatLog = if (parsed.chat_log) blk: {
        const file = try std.Io.Dir.cwd().createFile(init.io, "puny_chat.log", .{});
        if (comptime @import("builtin").os.tag != .windows) {
            std.Io.Dir.cwd().setFilePermissions(init.io, "puny_chat.log", @enumFromInt(0o600), .{}) catch {};
        }
        chat_file_writer = .init(file, init.io, &chat_buffer);
        break :blk ChatLog{
            .file = file,
            .writer = &chat_file_writer.interface,
        };
    } else null;
    defer if (chat_log) |*log| {
        log.writer.flush() catch {};
        log.file.close(init.io);
    };

    var cfg_result = try config.load(arena, init.io, init.environ_map);
    defer cfg_result.deinit();
    const cfg = &cfg_result.config;

    if (!cfg_result.file_existed and !parsed.reconfigure) {
        parsed.reconfigure = true;
    }

    var history = try loadHistory(arena, init.io, init.environ_map);
    defer history.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    if (parsed.reconfigure) {
        try runStartupReconfigure(arena, init.io, init, cfg, stdout_writer, !cfg_result.file_existed);
    }

    var random_source: std.Random.IoSource = .{ .io = init.io };
    const random = random_source.interface();

    const base_dir = try core_sess.sessionBaseDir(arena, init.environ_map);

    var prov: provider.Provider = undefined;
    var selected_provider: ModelProvider = undefined;
    var provider_url: []const u8 = undefined;
    var model_key: []const u8 = undefined;
    var reasoning_effort: ?openai.ReasoningEffort = null;
    try initializeProviderAndModel(
        arena,
        messages_arena,
        init.io,
        init,
        parsed,
        cfg,
        stdout_writer,
        random,
        &prov,
        &selected_provider,
        &provider_url,
        &model_key,
        &reasoning_effort,
    );

    var session_restored = false;
    var restore_incomplete = false;
    var planning_mode = false;
    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(messages_arena);

    var restore_target: ?sessions.SessionInfo = null;
    if (parsed.session) |sid| {
        if (sessions.findSessionByPrefix(arena, init.io, base_dir, sid)) |maybe_s| {
            if (maybe_s) |s| {
                if (s.has_conversation) {
                    restore_target = s;
                } else {
                    try stdout_writer.print("Session '{s}' has no saved conversation. Starting fresh.\n", .{sid});
                    try stdout_writer.flush();
                }
            } else {
                try stdout_writer.print("Session '{s}' not found. Starting fresh.\n", .{sid});
                try stdout_writer.flush();
            }
        } else |_| {}
    } else if (parsed.do_resume) {
        if (sessions.findLatestSession(arena, init.io, base_dir)) |maybe_latest| {
            restore_target = maybe_latest;
            if (maybe_latest == null) {
                try stdout_writer.print("No saved conversations found. Starting fresh.\n", .{});
                try stdout_writer.flush();
            }
        } else |_| {}
    }

    var current_session: core_sess.Session = undefined;
    if (restore_target) |s| {
        const dir = try std.fs.path.join(messages_arena, &.{ base_dir, "sessions", s.id });
        current_session = try core_sess.Session.fromDir(
            arena,
            s.id,
            base_dir,
            dir,
            try std.fs.path.join(messages_arena, &.{ dir, "plan.md" }),
            try std.fs.path.join(messages_arena, &.{ dir, "plan.html" }),
        );
    } else {
        current_session = try core_sess.Session.init(arena, base_dir, random, init.io);
    }

    try welcome.print(stdout_writer, .{
        .provider_name = if (parsed.mock) "Mock" else provider.getProviderDisplayName(selected_provider),
        .provider_url = provider_url,
        .model_key = model_key,
        .reasoning_effort = reasoning_effort,
        .session_id = current_session.id,
        .oneshot = parsed.oneshot,
        .prefilled = parsed.prompt != null,
    });

    try printStartupTime(init.io, stdout_writer, startup_time);

    // Kick off the background update check now that the welcome screen is
    // shown. It is detached and never blocks startup. Skipped for one-shot
    // and mock sessions, which are not interactive.
    if (!parsed.oneshot and !parsed.mock) {
        update_check.spawnBackgroundCheck(init.io, arena, init.environ_map);
    }

    if (restore_target) |s| {
        const load_start = std.Io.Clock.Timestamp.now(init.io, .awake);
        const restore_result = try loadRestoredSession(messages_arena, init.io, base_dir, s, &planning_mode, &messages, stdout_writer);
        const now = std.Io.Clock.Timestamp.now(init.io, .awake);
        const elapsed_ns: u64 = @intCast(load_start.raw.durationTo(now.raw).nanoseconds);
        session_restored = restore_result.restored;
        restore_incomplete = restore_result.incomplete;
        if (restore_result.restored) {
            var header_buf: [256]u8 = undefined;
            try stdout_writer.print("\n\n{s}\n", .{formatRestoreHeader(&header_buf, s.id, messages.items.len, elapsed_ns)});
            try display.printConversation(stdout_writer, messages.items);
            try stdout_writer.flush();
        }
    }

    if (debug_log) |*log| session.attachHttpDebugObserver(&prov, log);
    defer prov.deinit();

    var full_tool_definitions = try buildToolDefinitions(arena, parsed.no_skills);
    defer full_tool_definitions.deinit(arena);

    var planning_tool_definitions = try buildPlanningToolDefinitions(arena, parsed.no_skills);
    defer planning_tool_definitions.deinit(arena);

    var skill_registry = skills.Registry.init(arena);
    defer skill_registry.deinit();
    if (!parsed.no_skills) {
        if (try skills.homeDir(arena, init.environ_map)) |home| {
            const global_path = try std.fs.path.join(arena, &.{ home, ".agents", "skills" });
            try skill_registry.lightScan(init.io, global_path);
        }
        if (try git_root.findGitRepoRoot(arena, init.io)) |repo_root| {
            const repo_path = try std.fs.path.join(arena, &.{ repo_root, ".agents", "skills" });
            try skill_registry.lightScan(init.io, repo_path);
        }
        skill_registry.fullScan(init.io) catch {};
    }
    skills.setGlobalRegistry(&skill_registry);

    if (!session_restored) {
        const system_prompt = try cfg.resolvePrompt(messages_arena, "system", prompts.system);
        try messages.append(messages_arena, .{ .system = system_prompt });
        if (skill_registry.count() > 0) {
            const skills_block = try skill_registry.buildListing(messages_arena);
            try messages.append(messages_arena, .{ .system = skills_block });
        }
        if (try git_root.findGitRepoRoot(arena, init.io)) |repo_root| {
            defer arena.free(repo_root);
            if (try instructions.load(arena, init.io, repo_root)) |result| {
                defer arena.free(result.filename);
                defer arena.free(result.content);
                const labeled = try std.fmt.allocPrint(messages_arena, "Instructions from {s}:\n{s}", .{ result.filename, result.content });
                try messages.append(messages_arena, .{ .system = labeled });
            }
        }
    }

    var session_stats = stats.SessionStats.init(arena, init.io);
    session_stats.session_id = current_session.id;
    defer session_stats.deinit();
    sigint.register() catch {};

    const ctx = session.ChatLoopContext{
        .arena = arena,
        .messages_arena = &messages_arena_state,
        .io = init.io,
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
        .reasoning_effort = &reasoning_effort,
        .full_tool_definitions = &full_tool_definitions,
        .planning_tool_definitions = &planning_tool_definitions,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .restore_incomplete = restore_incomplete,
        .session = &current_session,
        .session_stats = &session_stats,
        .debug_log = if (debug_log) |*log| log else null,
        .chat_log = if (chat_log) |*log| log else null,
        .skill_registry = &skill_registry,
    };

    var chat_session = session.ChatSession.init(ctx);
    try chat_session.run();

    // After the interactive session ends, surface a pending update notice
    // written by the detached update-check child process. Clear stale flags
    // that no longer represent a newer version.
    if (update_check.availableUpdateIfNewer(init.io, arena, init.environ_map)) |maybe_latest| {
        if (maybe_latest) |latest| {
            update_check.printUpdateNotice(stdout_writer, latest) catch {};
            stdout_writer.flush() catch {};
        }
    } else |_| {}
}

/// Prints `Failed to load prompt from <source>: <reason>` to stderr and flushes.
fn printStartupError(io: std.Io, source: []const u8, reason: []const u8) void {
    var err_buf: [512]u8 = undefined;
    var err_writer: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr_writer = &err_writer.interface;
    stderr_writer.print("Failed to load prompt from {s}: {s}\n", .{ source, reason }) catch {};
    stderr_writer.flush() catch {};
}

fn printStartupTime(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    startup_time: std.Io.Clock.Timestamp,
) !void {
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed_ns: u64 = @intCast(startup_time.raw.durationTo(now.raw).nanoseconds);
    var startup_buf: [64]u8 = undefined;
    try stdout_writer.print("{s}Startup time: {s}{s}", .{
        ansi.dim, formatDuration(&startup_buf, elapsed_ns), ansi.reset,
    });
    try stdout_writer.flush();
}

fn loadHistory(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !prompt_history.History {
    const history_path = try prompt_history.historyPath(arena, environ_map);
    var history = prompt_history.History.init(arena, history_path);
    history.load(io) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    return history;
}

const RestoreResult = struct {
    restored: bool,
    incomplete: bool,
};

fn loadRestoredSession(
    msg_alloc: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    s: sessions.SessionInfo,
    planning_mode: *bool,
    messages: *std.ArrayList(openai.Message),
    stdout_writer: *std.Io.Writer,
) !RestoreResult {
    const dir = try std.fs.path.join(msg_alloc, &.{ base_dir, "sessions", s.id });
    defer msg_alloc.free(dir);

    const msg_path = try std.fs.path.join(msg_alloc, &.{ dir, "messages.json" });
    defer msg_alloc.free(msg_path);

    var file = std.Io.Dir.cwd().openFile(io, msg_path, .{}) catch {
        try stdout_writer.print("Session '{s}' has no saved conversation. Starting fresh.\n", .{s.id});
        try stdout_writer.flush();
        return .{ .restored = false, .incomplete = false };
    };
    defer file.close(io);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, msg_path, msg_alloc, std.Io.Limit.limited(10 * 1024 * 1024));
    defer msg_alloc.free(data);

    const parsed_val = try std.json.parseFromSlice(std.json.Value, msg_alloc, data, .{});
    defer parsed_val.deinit();

    var restore_incomplete = false;
    for (parsed_val.value.array.items) |item| {
        if (openai.Message.fromJsonValue(msg_alloc, item)) |msg| {
            try messages.append(msg_alloc, msg);
        } else |_| {
            restore_incomplete = true;
        }
    }

    if (restore_incomplete) {
        try stdout_writer.print("Warning: session '{s}' has messages that could not be restored.\n", .{s.id});
        try stdout_writer.flush();
    }

    planning_mode.* = s.planning_mode;
    return .{ .restored = true, .incomplete = restore_incomplete };
}

fn runStartupReconfigure(
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    cfg: *config.Config,
    stdout_writer: *std.Io.Writer,
    first_launch: bool,
) !void {
    if (first_launch) {
        try stdout_writer.print("\nWelcome to Puny! Let's get you set up.\n", .{});
    } else {
        try stdout_writer.print("\nReconfiguring Puny.\n", .{});
    }
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
    reasoning_effort: *?openai.ReasoningEffort,
) !void {
    selected_provider.* = resolver.effectiveProvider(parsed, cfg.*);
    provider_url.* = if (parsed.mock) "-" else resolver.baseUrlFor(selected_provider.*, parsed, cfg.*);
    const api_key = try resolver.resolveApiKey(arena, io, parsed, cfg.*, selected_provider.*, init.environ_map.get("PUNY_API_KEY"));

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
        const raw = if (reconfigure_force_picker) null else parsed.model orelse if (selected_provider.* == .mock) null else cfg.providerEntry(selected_provider.*).model;
        if (raw) |id| {
            if (http_client.isValidUtf8(id)) break :blk id;
        }
        break :blk null;
    };

    prov.* = resolver.createProvider(parsed.mock, selected_provider.*, provider_url.*, api_key, provider_arena, io);
    errdefer prov.deinit();
    if (!parsed.mock) try resolver.ensureCopilotAuth(arena, io, init, cfg, stdout_writer, prov);

    const skip_validation = parsed.mock or parsed.oneshot or !std.mem.eql(
        u8,
        provider_url.*,
        config.default_lm_studio_url,
    );
    const init_result = (try model_selection.select(
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
    model_key.* = init_result.model_key;
    if (init_result.reasoning_effort) |effort| {
        reasoning_effort.* = effort;
    } else if (cfg.providerEntry(selected_provider.*).reasoning_effort) |effort_str| {
        reasoning_effort.* = std.meta.stringToEnum(openai.ReasoningEffort, effort_str);
    }
}

fn buildPlanningToolDefinitions(arena: std.mem.Allocator, no_skills: bool) !std.ArrayList(openai.ToolDefinition) {
    var definitions: std.ArrayList(openai.ToolDefinition) = .empty;
    errdefer definitions.deinit(arena);
    for (tools.planning_registry) |tool| {
        if (no_skills and std.mem.eql(u8, tool.name, "load_skill")) continue;
        const schema = try tool.schema(arena);
        try definitions.append(arena, .{ .function = schema });
    }
    return definitions;
}

fn buildToolDefinitions(arena: std.mem.Allocator, no_skills: bool) !std.ArrayList(openai.ToolDefinition) {
    var definitions: std.ArrayList(openai.ToolDefinition) = .empty;
    errdefer definitions.deinit(arena);
    for (tools.registry) |tool| {
        if (no_skills and std.mem.eql(u8, tool.name, "load_skill")) continue;
        const schema = try tool.schema(arena);
        try definitions.append(arena, .{ .function = schema });
    }
    return definitions;
}

fn formatDuration(buf: []u8, elapsed_ns: u64) []const u8 {
    if (elapsed_ns < 1000)
        return std.fmt.bufPrint(buf, "{d} ns", .{elapsed_ns}) catch "0 ns";
    const us = elapsed_ns / 1000;
    if (us < 1000)
        return std.fmt.bufPrint(buf, "{d} µs", .{us}) catch "0 µs";
    const ms = us / 1000;
    if (ms < 1000)
        return std.fmt.bufPrint(buf, "{d} ms", .{ms}) catch "0 ms";
    const s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    return std.fmt.bufPrint(buf, "{d:.1} s", .{s}) catch "0 s";
}

fn requiresApiKey(selected_provider: ModelProvider) bool {
    return selected_provider == .opencode_zen or
        selected_provider == .opencode_go;
}

fn formatRestoreHeader(buf: []u8, id: []const u8, count: usize, elapsed_ns: u64) []const u8 {
    var time_buf: [64]u8 = undefined;
    const time_str = formatDuration(&time_buf, elapsed_ns);
    return std.fmt.bufPrint(buf, "Restored session {s} — {d} messages ({s})", .{
        id, count, time_str,
    }) catch "Restored session";
}

test "formatDuration formats sub-millisecond as µs" {
    var buf: [64]u8 = undefined;
    const result = formatDuration(&buf, 5000);
    try std.testing.expectEqualStrings("5 µs", result);
}

test "formatDuration formats milliseconds" {
    var buf: [64]u8 = undefined;
    const result = formatDuration(&buf, 42_000_000);
    try std.testing.expectEqualStrings("42 ms", result);
}

test "formatDuration formats seconds" {
    var buf: [64]u8 = undefined;
    const result = formatDuration(&buf, 2_500_000_000);
    try std.testing.expectEqualStrings("2.5 s", result);
}

test "formatDuration handles zero" {
    var buf: [64]u8 = undefined;
    const result = formatDuration(&buf, 0);
    try std.testing.expectEqualStrings("0 ns", result);
}

test "formatDuration boundary between ns and µs" {
    var buf: [64]u8 = undefined;
    const result = formatDuration(&buf, 999);
    try std.testing.expectEqualStrings("999 ns", result);
}

test "formatDuration boundary between µs and ms" {
    var buf: [64]u8 = undefined;
    const result = formatDuration(&buf, 999_999);
    try std.testing.expectEqualStrings("999 µs", result);
}

test "formatDuration boundary between ms and s" {
    var buf: [64]u8 = undefined;
    const result = formatDuration(&buf, 999_000_000);
    try std.testing.expectEqualStrings("999 ms", result);
}

test "formatRestoreHeader includes load time" {
    var buf: [256]u8 = undefined;
    const result = formatRestoreHeader(&buf, "abc123", 5, 42_000_000);
    try std.testing.expectEqualStrings("Restored session abc123 — 5 messages (42 ms)", result);
}

test "formatRestoreHeader falls back when the buffer is too small" {
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("Restored session", formatRestoreHeader(&small, "abc123", 5, 42_000_000));
}

fn toolNames(definitions: []const openai.ToolDefinition) [][]const u8 {
    const names = std.heap.page_allocator.alloc([]const u8, definitions.len) catch unreachable;
    for (definitions, 0..) |definition, i| {
        names[i] = definition.function.object.get("name").?.string;
    }
    return names;
}

test "buildToolDefinitions excludes load_skill when skills are disabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var definitions = try buildToolDefinitions(arena, true);
    defer definitions.deinit(arena);
    const names = toolNames(definitions.items);
    for (names) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "load_skill"));
    }
    try std.testing.expect(definitions.items.len > 0);
}

test "buildToolDefinitions includes load_skill when skills are enabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var definitions = try buildToolDefinitions(arena, false);
    defer definitions.deinit(arena);
    var found = false;
    for (definitions.items) |definition| {
        const name = definition.function.object.get("name").?.string;
        if (std.mem.eql(u8, name, "load_skill")) found = true;
    }
    try std.testing.expect(found);
}

test "buildPlanningToolDefinitions excludes load_skill when skills are disabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var definitions = try buildPlanningToolDefinitions(arena, true);
    defer definitions.deinit(arena);
    const names = toolNames(definitions.items);
    for (names) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "load_skill"));
    }
    try std.testing.expect(definitions.items.len > 0);
}

test "requiresApiKey only for opencode and opencode-go" {
    try std.testing.expect(!requiresApiKey(.lmstudio));
    try std.testing.expect(requiresApiKey(.opencode_zen));
    try std.testing.expect(requiresApiKey(.opencode_go));
    try std.testing.expect(!requiresApiKey(.copilot));
    try std.testing.expect(!requiresApiKey(.mock));
}

test "test runner suppresses warning logs" {
    std.log.warn("expected warning from regression test", .{});
    try std.testing.expectEqual(std.log.Level.err, std.testing.log_level);
}

test "test runner suppresses unexpected error stack traces" {
    try std.testing.expect(!std.options.unexpected_error_tracing);
}

test "include all module tests" {
    _ = @import("test_runner.zig");
}
