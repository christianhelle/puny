const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const chat = @import("chat.zig");
const cli = @import("../cli/args.zig");
const commands = @import("../cli/commands.zig");
const core_session = @import("../core/session.zig");
const config = @import("../config/config.zig");
const indicator = @import("../tui/indicator.zig");
const input = @import("../tui/input.zig");
const http_client = @import("../providers/client.zig");
const mock = @import("../providers/mock.zig");
const model_selection = @import("../models/select.zig");
const openai = @import("../providers/openai.zig");
const provider_picker = @import("../tui/provider_picker.zig");
const opencode_zen = @import("../providers/opencode_zen.zig");
const opencode_go = @import("../providers/opencode_go.zig");
const copilot = @import("../providers/copilot.zig");
const prompt_history = @import("../prompts/history.zig");
const prompts = @import("../prompts/prompts.zig");
const provider = @import("../providers/provider.zig");
const instructions = @import("../agents/instructions.zig");
const sigint = @import("../core/sigint.zig");
const skills = @import("../skills/skills.zig");
const tools = @import("../tools/root.zig");
const welcome = @import("../tui/welcome.zig");
const ModelProvider = provider.ModelProvider;

pub const ReconfigurePrompt = struct {
    changed: bool = false,
    cancelled: bool = false,
};

pub const DebugLog = struct {
    file: std.Io.File,
    writer: *std.Io.Writer,

    fn print(self: *DebugLog, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
    }
};

pub const ChatLog = struct {
    file: std.Io.File,
    writer: *std.Io.Writer,

    fn print(self: *ChatLog, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
    }
};

const UserInput = union(enum) {
    message: []const u8,
    continue_loop,
    exit,
};

const TurnResult = enum {
    continue_loop,
    exit,
};

pub const ChatLoopContext = struct {
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
    model_provider: *ModelProvider,
    provider_url: *[]const u8,
    model_key: *[]const u8,
    reasoning_effort: *?openai.ReasoningEffort,
    full_tool_definitions: *std.ArrayList(openai.ToolDefinition),
    planning_tool_definitions: *std.ArrayList(openai.ToolDefinition),
    messages: *std.ArrayList(openai.Message),
    planning_mode: *bool,
    session: *core_session.Session,
    session_stats: *chat.SessionStats,
    debug_log: ?*DebugLog,
    chat_log: ?*ChatLog,
    skill_registry: *skills.Registry,
};

pub const ChatSession = struct {
    ctx: ChatLoopContext,

    pub fn init(ctx: ChatLoopContext) ChatSession {
        return .{ .ctx = ctx };
    }

    pub fn run(self: *ChatSession) !void {
        const ctx = &self.ctx;
        var line_alloc = std.Io.Writer.Allocating.init(ctx.arena);
        defer line_alloc.deinit();
        var stdin_buffer: [4096]u8 = undefined;
        var pending_prompt: ?[]const u8 = null;
        if (ctx.parsed.prompt) |p| {
            pending_prompt = try ctx.arena.dupe(u8, p);
        }
        var loaded_skills = std.StringHashMapUnmanaged(void){};
        defer loaded_skills.deinit(ctx.arena);
        while (true) {
            if (sigint.isTriggered()) {
                saveMessages(ctx) catch {};
                saveSessionMeta(ctx) catch {};
                printExit(ctx.session_stats, ctx.io, ctx.stdout_writer) catch {};
                return;
            }

            const user_input = try readUserInput(ctx, &pending_prompt, &line_alloc, &stdin_buffer);
            const user_message = switch (user_input) {
                .message => |text| text,
                .continue_loop => continue,
                .exit => return,
            };
            if (user_message.len == 0) continue;

            if (ctx.chat_log) |log| {
                log.print("[USER]\n{s}\n\n", .{user_message});
            }

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
                .session_prd_path = ctx.session.prd_path,
            });
            core_session.setWriteBlocked(ctx.planning_mode.*);

            if (command == .prompt) {
                for (ctx.skill_registry.records.items) |*r| {
                    if (loaded_skills.contains(r.name)) continue;
                    if (!skills.recordMatchesTrigger(r, user_message)) continue;
                    const content = ctx.skill_registry.loadContent(ctx.io, r.name, ctx.messages_arena.allocator()) catch continue;
                    try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = content });
                    try ctx.stdout_writer.print("\n\n{s}Skill: {s}{s}\n", .{ ansi.dim, r.name, ansi.reset });
                    try ctx.stdout_writer.flush();
                    loaded_skills.put(ctx.arena, r.name, {}) catch {};
                }
            }

            if (command == .prompt and !ctx.parsed.oneshot) {
                try ctx.history.add(user_message);
                try ctx.history.save(ctx.io);
            }

            switch (action) {
                .exit => {
                    saveMessages(ctx) catch {};
                    saveSessionMeta(ctx) catch {};
                    printExit(ctx.session_stats, ctx.io, ctx.stdout_writer) catch {};
                    return;
                },
                .continue_ => continue,
                .full_reset => {
                    try saveMessages(ctx);
                    try saveSessionMeta(ctx);

                    try ctx.stdout_writer.print(" Performing full memory reset...", .{});
                    try ctx.stdout_writer.flush();

                    ctx.prov.deinit();
                    ctx.prov.* = .{ .mock = mock.MockClient.init(ctx.messages_arena.allocator(), ctx.io) };
                    _ = ctx.messages_arena.reset(.free_all);
                    ctx.messages.* = .empty;
                    ctx.planning_mode.* = false;
                    core_session.setWriteBlocked(false);
                    const system_prompt = try ctx.cfg.resolvePrompt(ctx.messages_arena.allocator(), "system", prompts.system);
                    try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = system_prompt });

                    if (try skills.findGitRepoRoot(ctx.arena, ctx.io)) |repo_root| {
                        defer ctx.arena.free(repo_root);
                        if (try instructions.load(ctx.arena, ctx.io, repo_root)) |result| {
                            defer ctx.arena.free(result.filename);
                            defer ctx.arena.free(result.content);
                            const labeled = try std.fmt.allocPrint(ctx.messages_arena.allocator(), "Instructions from {s}:\n{s}", .{ result.filename, result.content });
                            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = labeled });
                        }
                    }

                    ctx.session.* = try core_session.Session.init(ctx.arena, ctx.session.base, ctx.random, ctx.io);

                    ctx.session_stats.deinit();
                    ctx.session_stats.* = chat.SessionStats.init(ctx.arena, ctx.io);
                    ctx.session_stats.session_id = ctx.session.id;

                    const new_api_key = try resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.model_provider.*, ctx.init.environ_map.get("PUNY_API_KEY"));
                    ctx.prov.* = createProvider(ctx.parsed.mock, ctx.model_provider.*, ctx.provider_url.*, new_api_key, ctx.messages_arena.allocator(), ctx.io);
                    if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);

                    ctx.history.clear();
                    loaded_skills.clearRetainingCapacity();

                    try ctx.stdout_writer.print(" OK\n", .{});
                    try ctx.stdout_writer.print("New session: {s}\n", .{ctx.session.id});
                    try ctx.stdout_writer.flush();
                    continue;
                },
                .print_stats => {
                    try ctx.session_stats.print(ctx.io, ctx.stdout_writer);
                    continue;
                },
                .list_sessions => {
                    const sessions = try core_session.listSessions(ctx.arena, ctx.io, ctx.session.base);
                    try ctx.stdout_writer.print("\n{s}Saved sessions:{s}\n", .{ ansi.bright, ansi.reset });
                    if (sessions.len == 0) {
                        try ctx.stdout_writer.print("  (none)\n", .{});
                    } else {
                        for (sessions) |s| {
                            const has_conv = if (s.has_conversation) "  (conversation)" else "";
                            const prd_mark = if (s.has_prd) "  (has plan.md)" else "";
                            const current_mark = if (std.mem.eql(u8, s.id, ctx.session.id)) "  <-- current" else "";
                            const first_prompt_hint = if (s.first_prompt) |p| blk: {
                                if (p.len > 40) {
                                    break :blk std.fmt.allocPrint(ctx.arena, "  \"{s}...\"", .{p[0..40]}) catch "";
                                } else {
                                    break :blk std.fmt.allocPrint(ctx.arena, "  \"{s}\"", .{p}) catch "";
                                }
                            } else "";
                            try ctx.stdout_writer.print("  {s}{s}{s}{s}{s}\n", .{ s.id, has_conv, prd_mark, current_mark, first_prompt_hint });
                            if (s.first_prompt) |p| ctx.arena.free(p);
                        }
                    }
                    try ctx.stdout_writer.flush();
                    continue;
                },
                .prune_sessions => {
                    try core_session.pruneSessions(ctx.arena, ctx.io, ctx.session.base, ctx.session.id);
                    try ctx.stdout_writer.print("\nCleaned up old sessions. Current session preserved.\n", .{});
                    try ctx.stdout_writer.flush();
                    continue;
                },
                .restore_session => |session_id| {
                    const base = ctx.session.base;
                    const found = if (session_id) |sid| try core_session.findSessionByPrefix(ctx.arena, ctx.io, base, sid) else blk: {
                        const sessions = try core_session.listSessions(ctx.arena, ctx.io, base);
                        var conv_count: usize = 0;
                        for (sessions) |s| {
                            if (s.has_conversation) conv_count += 1;
                        }
                        if (conv_count == 0) {
                            try ctx.stdout_writer.print("\nNo saved conversations found.\n", .{});
                            try ctx.stdout_writer.flush();
                        } else if (conv_count == 1) {
                            for (sessions) |s| {
                                if (s.has_conversation) break :blk s;
                            }
                        } else {
                            try ctx.stdout_writer.print("\n{d} sessions have saved conversations. Use /resume <id> to choose one.\n", .{conv_count});
                            try ctx.stdout_writer.flush();
                        }
                        break :blk null;
                    };

                    if (found) |s| {
                        try ctx.stdout_writer.print("\nRestoring session {s}...\n", .{s.id});
                        try ctx.stdout_writer.flush();

                        ctx.prov.deinit();
                        ctx.prov.* = .{ .mock = mock.MockClient.init(ctx.messages_arena.allocator(), ctx.io) };
                        _ = ctx.messages_arena.reset(.free_all);
                        ctx.messages.* = .empty;

                        const dir = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ base, "sessions", s.id });
                        defer ctx.messages_arena.allocator().free(dir);
                        try loadMessagesIntoContext(ctx, dir);

                        ctx.planning_mode.* = s.planning_mode;
                        core_session.setWriteBlocked(ctx.planning_mode.*);

                        ctx.session.* = try core_session.Session.fromDir(
                            ctx.arena,
                            s.id,
                            base,
                            dir,
                            try std.fs.path.join(ctx.arena, &.{ dir, "plan.md" }),
                            try std.fs.path.join(ctx.arena, &.{ dir, "plan.html" }),
                        );
                        core_session.setSessionPaths(ctx.session.prd_path, ctx.session.html_path);

                        ctx.session_stats.deinit();
                        ctx.session_stats.* = chat.SessionStats.init(ctx.arena, ctx.io);
                        ctx.session_stats.session_id = ctx.session.id;

                        const new_api_key = try resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.model_provider.*, ctx.init.environ_map.get("PUNY_API_KEY"));
                        ctx.prov.* = createProvider(ctx.parsed.mock, ctx.model_provider.*, ctx.provider_url.*, new_api_key, ctx.messages_arena.allocator(), ctx.io);
                        if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);

                        ctx.history.clear();
                        try ctx.stdout_writer.print("Session restored — {d} messages:\n", .{ctx.messages.items.len});
                        try printConversation(ctx.stdout_writer, ctx.messages.items);
                        try ctx.stdout_writer.flush();
                    } else {
                        try ctx.stdout_writer.print("\n{s}No matching session found.{s}\n", .{ ansi.dim, ansi.reset });
                        try ctx.stdout_writer.flush();
                    }
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
                .list_skills => {
                    if (!ctx.skill_registry.fully_scanned) {
                        try ctx.skill_registry.fullScan(ctx.io);
                    }
                    try ctx.stdout_writer.print("\n\nAvailable skills:\n\n", .{});
                    if (ctx.skill_registry.count() == 0) {
                        try ctx.stdout_writer.print("  (none found)\n", .{});
                    } else {
                        for (ctx.skill_registry.records.items) |r| {
                            if (r.description) |desc| {
                                try ctx.stdout_writer.print("{s}{s}{s}\n{s}\n\n", .{ ansi.bright, r.name, ansi.reset, desc });
                            } else {
                                try ctx.stdout_writer.print("{s}{s}{s}\n", .{ ansi.bright, r.name, ansi.reset });
                            }
                        }
                    }
                    if (ctx.parsed.oneshot) {
                        try ctx.stdout_writer.print("\n", .{});
                        try ctx.stdout_writer.flush();
                        return;
                    }
                    try ctx.stdout_writer.print("\nUse /<skill-name> to load a skill.\n", .{});
                    try ctx.stdout_writer.flush();
                    continue;
                },
                .load_skill => |full_text| {
                    const space = std.mem.indexOfScalar(u8, full_text, ' ');
                    const skill_name = if (space) |s| full_text[0..s] else full_text;
                    const user_text = if (space) |s| std.mem.trimStart(u8, full_text[s..], " ") else null;

                    const content = ctx.skill_registry.loadContent(ctx.io, skill_name, ctx.messages_arena.allocator()) catch |err| switch (err) {
                        error.SkillNotFound => {
                            const prompt = full_text;
                            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .user = prompt });
                            if (!ctx.parsed.oneshot) {
                                try ctx.history.add(prompt);
                                try ctx.history.save(ctx.io);
                            }
                            const turn_result = try runChatTurn(ctx);
                            if (turn_result == .exit) return;
                            continue;
                        },
                        else => |e| return e,
                    };

                    try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = content });
                    try ctx.stdout_writer.print("\n\n{s}Skill: {s}{s}\n", .{ ansi.dim, skill_name, ansi.reset });
                    try ctx.stdout_writer.flush();

                    const has_text = if (user_text) |text| std.mem.trim(u8, text, " \t\r\n").len > 0 else false;
                    if (has_text) {
                        try ctx.messages.append(ctx.messages_arena.allocator(), .{ .user = user_text.? });
                        try ctx.stdout_writer.print(" {s}\n", .{user_text.?});
                        try ctx.stdout_writer.flush();
                        const turn_result = try runChatTurn(ctx);
                        if (turn_result == .exit) return;
                    }
                    continue;
                },
                .run_chat_turn => {},
            }

            const turn_result = try runChatTurn(ctx);
            if (turn_result == .exit) return;
        }
    }
};

fn saveMessages(ctx: *ChatLoopContext) !void {
    const dir = ctx.session.dir;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(ctx.io, dir) catch {};

    const tmp_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "messages.json.tmp" });
    defer ctx.messages_arena.allocator().free(tmp_path);
    const msg_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "messages.json" });
    defer ctx.messages_arena.allocator().free(msg_path);
    const buffer = try std.json.Stringify.valueAlloc(ctx.messages_arena.allocator(), ctx.messages.items, .{ .whitespace = .indent_2 });
    defer ctx.messages_arena.allocator().free(buffer);

    var file = cwd.createFile(ctx.io, tmp_path, .{}) catch |err| {
        std.log.warn("failed to create temp file: {s}", .{@errorName(err)});
        return;
    };
    errdefer {
        file.close(ctx.io);
        cwd.deleteFile(ctx.io, tmp_path) catch {};
    }

    file.writeStreamingAll(ctx.io, buffer) catch |err| {
        std.log.warn("failed to write messages: {s}", .{@errorName(err)});
        return;
    };
    file.writeStreamingAll(ctx.io, "\n") catch |err| {
        std.log.warn("failed to write newline: {s}", .{@errorName(err)});
        return;
    };
    file.close(ctx.io);

    std.Io.Dir.renameAbsolute(tmp_path, msg_path, ctx.io) catch |err| {
        std.log.warn("failed to rename messages file: {s}", .{@errorName(err)});
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp_path) catch {};
    };
}

fn saveSessionMeta(ctx: *ChatLoopContext) !void {
    const dir = ctx.session.dir;
    const meta_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "session.json" });
    defer ctx.messages_arena.allocator().free(meta_path);

    var first_prompt: ?[]const u8 = null;
    for (ctx.messages.items) |m| {
        if (m == .user) {
            first_prompt = m.user;
            break;
        }
    }

    const MetaStruct = struct {
        planning_mode: bool,
        first_prompt: ?[]const u8,
    };
    const meta = MetaStruct{ .planning_mode = ctx.planning_mode.*, .first_prompt = first_prompt };

    const buffer = try std.json.Stringify.valueAlloc(ctx.messages_arena.allocator(), meta, .{ .whitespace = .indent_2 });
    defer ctx.messages_arena.allocator().free(buffer);
    const cwd = std.Io.Dir.cwd();
    var file = cwd.createFile(ctx.io, meta_path, .{}) catch |err| {
        std.log.warn("failed to save session meta: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, buffer) catch {};
    file.writeStreamingAll(ctx.io, "\n") catch {};
}

fn loadMessagesIntoContext(ctx: *ChatLoopContext, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const msg_path = try std.fs.path.join(ctx.messages_arena.allocator(), &.{ dir, "messages.json" });
    defer ctx.messages_arena.allocator().free(msg_path);

    const data = cwd.readFileAlloc(ctx.io, msg_path, ctx.messages_arena.allocator(), std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.stdout_writer.print("Session has no saved conversation.\n", .{});
            try ctx.stdout_writer.flush();
            return;
        },
        else => |e| return e,
    };
    defer ctx.messages_arena.allocator().free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.messages_arena.allocator(), data, .{});
    defer parsed.deinit();

    for (parsed.value.array.items) |item| {
        const msg = try openai.Message.fromJsonValue(ctx.messages_arena.allocator(), item);
        try ctx.messages.append(ctx.messages_arena.allocator(), msg);
    }
}

pub fn printConversation(writer: *std.Io.Writer, messages: []const openai.Message) !void {
    for (messages) |msg| {
        switch (msg) {
            .user => |content| {
                try writer.print("\n{s}Prompt:{s} ", .{ ansi.bright, ansi.reset });
                try writer.print("{s}\n\n", .{content});
            },
            .assistant => |assistant| {
                if (assistant.content) |content| {
                    try writer.print("{s}\n", .{content});
                }
            },
            else => {},
        }
    }
}

fn readUserInput(
    ctx: *ChatLoopContext,
    pending_prompt: *?[]const u8,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: *[4096]u8,
) !UserInput {
    if (pending_prompt.*) |p| {
        pending_prompt.* = null;
        return .{ .message = p };
    }

    const maybe_input = input.readLine(ctx.io, ctx.stdout_writer, line_alloc, stdin_buffer, ctx.history) catch |err| {
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

        const chat_log_writer = if (ctx.chat_log) |log| log.writer else null;
        const result = chat.runTurn(
            ctx.prov,
            ctx.messages_arena.allocator(),
            ctx.io,
            ctx.stdout_writer,
            ctx.session_stats,
            ctx.parsed.show_thinking,
            ctx.random,
            ctx.model_key.*,
            ctx.reasoning_effort.*,
            ctx.messages,
            active_tool_definitions,
            &thinking_indicator,
            chat_log_writer,
        ) catch |err| {
            try thinking_indicator.finish(ctx.io, ctx.stdout_writer, 0, false, false, .error_, null);
            return err;
        };

        if (result.was_cancelled) {
            _ = ctx.messages.pop();
            while (skills.takePendingSkill(ctx.messages_arena.allocator())) |_| {}
            ctx.session_stats.finalizeTurn(null, false);
            break;
        }

        if (skills.takePendingSkill(ctx.messages_arena.allocator())) |pending| {
            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = pending.content });
            try ctx.stdout_writer.print("\n\n{s}Skill: {s}{s}\n", .{ ansi.dim, pending.name, ansi.reset });
            try ctx.stdout_writer.flush();
        }

        ctx.session_stats.finalizeTurn(result.usage, result.turn_complete);
        turn_complete = result.turn_complete;
    }

    try saveMessages(ctx);
    try saveSessionMeta(ctx);

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

    const old_provider_name = ctx.cfg.provider;
    const result = try promptReconfigure(ctx.arena, ctx.io, ctx.init, ctx.stdout_writer, ctx.cfg);
    if (result.cancelled) return;
    if (!result.changed) return;

    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);
    const new_provider_name = ctx.cfg.provider;
    const new_provider_url = if (ctx.parsed.mock) "-" else baseUrlFor(new_provider_name, ctx.parsed, ctx.cfg.*);
    const new_api_key = try resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, new_provider_name, ctx.init.environ_map.get("PUNY_API_KEY"));

    if (!ctx.parsed.mock and old_provider_name != new_provider_name) {
        ctx.prov.deinit();
        ctx.prov.* = createProvider(ctx.parsed.mock, new_provider_name, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io);
        if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);
        if (!ctx.parsed.mock) try ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
        ctx.model_provider.* = new_provider_name;
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
            new_provider_name,
            ctx.init.environ_map,
            ctx.random,
        );

        if (model_selection_result) |sel| {
            ctx.model_key.* = sel.model_key;
            if (sel.reasoning_effort) |effort| {
                ctx.reasoning_effort.* = effort;
            }
        }
    } else {
        ctx.prov.setConfig(.{ .base_url = new_provider_url, .api_key = new_api_key });
        ctx.provider_url.* = new_provider_url;
        if (!ctx.parsed.mock) try ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
    }

    try welcome.printSummary(
        ctx.stdout_writer,
        .{
            .provider_name = if (ctx.parsed.mock) "Mock" else provider.getProviderDisplayName(ctx.model_provider.*),
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
        ctx.model_provider.*,
        ctx.init.environ_map,
        ctx.random,
    )) |result| {
        ctx.model_key.* = result.model_key;
        if (result.reasoning_effort) |effort| {
            ctx.reasoning_effort.* = effort;
        }
    }
}

fn handleSwitchProviderCommand(ctx: *ChatLoopContext, provider_id: ?[]const u8) !void {
    const picked_provider = if (provider_id) |id| {
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

    const current_provider = ctx.model_provider.*;
    if (picked_provider == current_provider) {
        try ctx.stdout_writer.print("\nAlready using provider {s}.\n", .{provider.getProviderDisplayName(picked_provider)});
        try ctx.stdout_writer.flush();
        return;
    }

    ctx.cfg.provider = picked_provider;
    const new_provider_url = defaultProviderUrl(picked_provider);
    ctx.cfg.providerEntry(picked_provider).url = try ctx.arena.dupe(u8, new_provider_url);

    try config.save(ctx.arena, ctx.io, ctx.cfg.*, ctx.init.environ_map);

    const new_api_key = try resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, picked_provider, ctx.init.environ_map.get("PUNY_API_KEY"));
    ctx.prov.deinit();
    ctx.prov.* = createProvider(ctx.parsed.mock, picked_provider, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io);
    if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);
    if (!ctx.parsed.mock) try ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
    ctx.model_provider.* = picked_provider;
    ctx.provider_url.* = new_provider_url;

    const model_skip_validation = ctx.parsed.mock;
    const model_selection_result = try model_selection.select(
        ctx.prov,
        null,
        ctx.arena,
        ctx.io,
        ctx.init,
        model_skip_validation,
        ctx.cfg,
        picked_provider,
        ctx.init.environ_map,
        ctx.random,
    );

    if (model_selection_result) |sel| {
        ctx.model_key.* = sel.model_key;
        if (sel.reasoning_effort) |effort| {
            ctx.reasoning_effort.* = effort;
        }
    }

    try welcome.printSummary(
        ctx.stdout_writer,
        .{
            .provider_name = if (ctx.parsed.mock) "Mock" else provider.getProviderDisplayName(ctx.model_provider.*),
            .provider_url = ctx.provider_url.*,
            .model_key = ctx.model_key.*,
        },
    );

    try ctx.stdout_writer.print("Switched to provider {s}.\n", .{provider.getProviderDisplayName(picked_provider)});
    try ctx.stdout_writer.flush();
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

pub fn promptReconfigure(
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

    try stdout_writer.print("Current provider: {s}\n", .{@tagName(cfg.provider)});
    try stdout_writer.flush();

    const picked_provider = try provider_picker.selectProviderInteractive(arena, io, init) orelse {
        try stdout_writer.print("\n{s}Cancelled.{s}\n", .{ ansi.dim, ansi.reset });
        try stdout_writer.flush();
        return .{ .cancelled = true };
    };

    var provider_name = cfg.provider;
    var provider_changed = false;
    if (picked_provider != cfg.provider) {
        cfg.provider = picked_provider;
        provider_name = cfg.provider;
        provider_changed = true;
        result.changed = true;
    }

    const entry = cfg.providerEntry(provider_name);
    const provider_url_is_fixed = providerHasFixedUrl(provider_name);
    if (provider_url_is_fixed) {
        const fixed_url = defaultProviderUrl(provider_name);
        entry.url = try arena.dupe(u8, fixed_url);
        result.changed = true;
        try stdout_writer.print("Provider URL is fixed at {s}\n", .{fixed_url});
        try stdout_writer.flush();
    } else {
        line_alloc.clearRetainingCapacity();
        try stdout_writer.print("Current provider URL: {s}\n", .{entry.url});
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
            entry.url = try arena.dupe(u8, new_url);
            result.changed = true;
        } else if (provider_changed) {
            entry.url = try arena.dupe(u8, default_url);
            result.changed = true;
        }
    }

    line_alloc.clearRetainingCapacity();
    const key_status = if (entry.apiKey) |_| "set" else "none";
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
        entry.apiKey = null;
        result.changed = true;
    } else if (new_key.len > 0) {
        entry.apiKey = try arena.dupe(u8, new_key);
        result.changed = true;
    }

    return result;
}

pub fn effectiveProvider(parsed: cli.Options, cfg: config.Config) ModelProvider {
    if (parsed.provider) |p| {
        const parsed_enum = std.meta.stringToEnum(provider.ModelProvider, p);
        if (parsed_enum) |val| return val;
    }
    return cfg.provider;
}

pub fn baseUrlFor(model_provider: ModelProvider, parsed: cli.Options, cfg: config.Config) []const u8 {
    if (providerHasFixedUrl(model_provider)) return defaultProviderUrl(model_provider);
    if (parsed.url) |url| return url;
    const entry = cfg.providerEntryConst(model_provider);
    if (entry.url.len > 0) return entry.url;
    return config.default_lm_studio_url;
}

pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: cli.Options,
    cfg: config.Config,
    effective_provider: provider.ModelProvider,
    api_key_env: ?[]const u8,
) ![]const u8 {
    if (parsed.api_key) |key| return key;

    if (parsed.api_key_file) |path| {
        const cwd = std.Io.Dir.cwd();
        const data = try cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024));
        return std.mem.trim(u8, data, &std.ascii.whitespace);
    }

    if (api_key_env) |key| return key;

    if (effective_provider == .mock) return "";
    return cfg.providerEntryConst(effective_provider).apiKey orelse "";
}

fn providerHasFixedUrl(selectedProvider: provider.ModelProvider) bool {
    return selectedProvider == .opencode_zen or
        selectedProvider == .opencode_go or
        selectedProvider == .copilot or
        selectedProvider == .mock;
}

fn defaultProviderUrl(selectedProvider: provider.ModelProvider) []const u8 {
    if (selectedProvider == .opencode_zen) return opencode_zen.default_base_url;
    if (selectedProvider == .opencode_go) return opencode_go.default_base_url;
    if (selectedProvider == .copilot) return copilot.default_base_url;
    if (selectedProvider == .mock) return "-";
    return config.default_lm_studio_url;
}

pub fn createProvider(
    is_mock: bool,
    prov: ModelProvider,
    url: []const u8,
    api_key: []const u8,
    arena: std.mem.Allocator,
    io: std.Io,
) provider.Provider {
    if (is_mock) return .{ .mock = mock.MockClient.init(arena, io) };
    switch (prov) {
        .lmstudio => {
            var c = http_client.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .lmstudio = c };
        },
        .opencode_zen => {
            var c = http_client.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .opencode = c };
        },
        .opencode_go => {
            var c = http_client.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .opencode_go = c };
        },
        .copilot => {
            var c = copilot.Client.init(arena, io, api_key);
            c.withBaseUrl(url);
            return .{ .copilot = c };
        },
        .mock => {
            return .{ .mock = mock.MockClient.init(arena, io) };
        },
    }
}

pub fn ensureCopilotAuth(
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

    cfg.providerEntry(.copilot).apiKey = try arena.dupe(u8, token);
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

pub fn attachHttpDebugObserver(prov: *provider.Provider, debug_log: *DebugLog) void {
    prov.setConfig(.{ .http_observer = httpDebugObserver(debug_log) });
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

test "createProvider returns mock for mock flag or provider name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var by_flag = createProvider(true, .lmstudio, "http://example", "", allocator, std.testing.io);
    defer by_flag.deinit();
    try std.testing.expectEqual(std.meta.activeTag(by_flag), std.meta.Tag(provider.Provider).mock);

    var by_name = createProvider(false, .mock, "-", "", allocator, std.testing.io);
    defer by_name.deinit();
    try std.testing.expectEqual(std.meta.activeTag(by_name), std.meta.Tag(provider.Provider).mock);
}

test "resolveApiKey uses CLI key over env and config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).apiKey = "config-key";
    const parsed = cli.Options{ .api_key = "cli-key" };
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, .lmstudio, "env-key");
    try std.testing.expectEqualStrings("cli-key", key);
}

test "resolveApiKey uses env key over config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).apiKey = "config-key";
    const parsed = cli.Options{};
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, .lmstudio, "env-key");
    try std.testing.expectEqualStrings("env-key", key);
}

test "resolveApiKey falls back to config key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).apiKey = "config-key";
    const parsed = cli.Options{};
    const key = try resolveApiKey(allocator, undefined, parsed, cfg, .lmstudio, null);
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
    const key = try resolveApiKey(allocator, std.testing.io, parsed, cfg, .lmstudio, "env-key");
    try std.testing.expectEqualStrings("file-key", key);
}

test "effectiveProvider precedence" {
    const cfg_default = config.Config{};
    try std.testing.expectEqual(.lmstudio, effectiveProvider(.{}, cfg_default));

    const cfg_opencode = config.Config{ .provider = .opencode_zen };
    try std.testing.expectEqual(.opencode_zen, effectiveProvider(.{}, cfg_opencode));

    const parsed_flag = cli.Options{ .provider = "opencode_zen" };
    try std.testing.expectEqual(.opencode_zen, effectiveProvider(parsed_flag, config.Config{ .provider = .lmstudio }));
}

test "baseUrlFor uses CLI url for lmstudio only" {
    const cfg = config.Config{};
    const parsed = cli.Options{ .url = "http://cli.example" };
    try std.testing.expectEqualStrings("http://cli.example", baseUrlFor(.lmstudio, parsed, cfg));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, baseUrlFor(.opencode_zen, parsed, cfg));
    try std.testing.expectEqualStrings(opencode_go.default_base_url, baseUrlFor(.opencode_go, parsed, cfg));
    try std.testing.expectEqualStrings(copilot.default_base_url, baseUrlFor(.copilot, parsed, cfg));
    try std.testing.expectEqualStrings("-", baseUrlFor(.mock, parsed, cfg));
}

test "baseUrlFor uses per-provider url" {
    var cfg = config.Config{};
    cfg.providerEntry(.lmstudio).url = "http://config-lmstudio";
    try std.testing.expectEqualStrings("http://config-lmstudio", baseUrlFor(.lmstudio, .{}, cfg));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, baseUrlFor(.opencode_zen, .{}, cfg));
}

test "baseUrlFor returns provider defaults" {
    const cfg = config.Config{};
    try std.testing.expectEqualStrings("http://127.0.0.1:1234", baseUrlFor(.lmstudio, .{}, cfg));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, baseUrlFor(.opencode_zen, .{}, cfg));
    try std.testing.expectEqualStrings(opencode_go.default_base_url, baseUrlFor(.opencode_go, .{}, cfg));
    try std.testing.expectEqualStrings("-", baseUrlFor(.mock, .{}, cfg));
}

test "defaultProviderUrl returns provider-specific defaults" {
    try std.testing.expectEqualStrings(config.default_lm_studio_url, defaultProviderUrl(.lmstudio));
    try std.testing.expectEqualStrings(opencode_zen.default_base_url, defaultProviderUrl(.opencode_zen));
    try std.testing.expectEqualStrings(opencode_go.default_base_url, defaultProviderUrl(.opencode_go));
    try std.testing.expectEqualStrings(copilot.default_base_url, defaultProviderUrl(.copilot));
    try std.testing.expectEqualStrings("-", defaultProviderUrl(.mock));
}

test "providerHasFixedUrl for opencode, opencode-go, copilot and mock" {
    try std.testing.expect(providerHasFixedUrl(.opencode_zen));
    try std.testing.expect(providerHasFixedUrl(.opencode_go));
    try std.testing.expect(providerHasFixedUrl(.copilot));
    try std.testing.expect(providerHasFixedUrl(.mock));
    try std.testing.expect(!providerHasFixedUrl(.lmstudio));
}

test "include chat retry tests" {
    _ = @import("retry.zig");
}
