const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const chat = @import("chat.zig");
const cli = @import("../cli/args.zig");
const commands = @import("../cli/commands.zig");
const core_session = @import("../core/session.zig");
const sessions = @import("../sessions/sessions.zig");
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
const prompt_file = @import("../prompts/prompt_file.zig");
const provider = @import("../providers/provider.zig");
const instructions = @import("../agents/instructions.zig");
const sigint = @import("../core/sigint.zig");
const skills = @import("../skills/skills.zig");
const tools = @import("../tools/root.zig");
const welcome = @import("../tui/welcome.zig");
const help = @import("../tui/help.zig");
const ModelProvider = provider.ModelProvider;

pub const ReconfigurePrompt = struct {
    changed: bool = false,
    cancelled: bool = false,
};

pub const DebugLog = struct {
    file: std.Io.File,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,

    fn print(self: *DebugLog, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
    }

    fn printBody(self: *DebugLog, body: []const u8) void {
        const formatted = formatBody(self.allocator, body);
        defer if (formatted.owned) self.allocator.free(formatted.text);
        self.print("{s}\n", .{formatted.text});
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
    restore_incomplete: bool = false,
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
                finalizeSession(ctx);
                return;
            }

            const prompt_file_source: ?[]const u8 = if (ctx.parsed.prompt_file != null and pending_prompt != null) ctx.parsed.prompt_file else null;
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
                try maybeLoadTriggeredSkills(ctx, user_message, &loaded_skills);
            }

            if ((command == .prompt or command == .file or prompt_file_source != null) and !ctx.parsed.oneshot) {
                if (try historyEntryFor(ctx.arena, user_message, command, prompt_file_source)) |entry| {
                    try ctx.history.add(entry);
                    try ctx.history.save(ctx.io);
                }
            }

            switch (action) {
                .exit => {
                    finalizeSession(ctx);
                    return;
                },
                .help => {
                    try help.showHelp(ctx.stdout_writer);
                    continue;
                },
                .continue_ => continue,
                .full_reset => {
                    try saveMessages(ctx);
                    try saveSessionMeta(ctx);
                    upsertCurrentSession(ctx);

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
                    const session_list = try sessions.listSessions(ctx.arena, ctx.io, ctx.session.base);
                    try ctx.stdout_writer.print("\n{s}Saved sessions:{s}\n", .{ ansi.bright, ansi.reset });
                    if (session_list.len == 0) {
                        try ctx.stdout_writer.print("  (none)\n", .{});
                    } else {
                        for (session_list) |s| {
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
                    try sessions.pruneSessions(ctx.arena, ctx.io, ctx.session.base, ctx.session.id);
                    try ctx.stdout_writer.print("\nCleaned up old sessions. Current session preserved.\n", .{});
                    try ctx.stdout_writer.flush();
                    continue;
                },
                .restore_session => |session_id| {
                    const base = ctx.session.base;
                    const found = if (session_id) |sid| try sessions.findSessionByPrefix(ctx.arena, ctx.io, base, sid) else blk: {
                        const session_list = try sessions.listSessions(ctx.arena, ctx.io, base);
                        var conv_count: usize = 0;
                        for (session_list) |s| {
                            if (s.has_conversation) conv_count += 1;
                        }
                        if (conv_count == 0) {
                            try ctx.stdout_writer.print("\nNo saved conversations found.\n", .{});
                            try ctx.stdout_writer.flush();
                        } else if (conv_count == 1) {
                            for (session_list) |s| {
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
                        finalizeSession(ctx);
                        return;
                    }
                    try ctx.stdout_writer.print("\nUse /<skill-name> to load a skill.\n", .{});
                    try ctx.stdout_writer.flush();
                    continue;
                },
                .load_skill => |full_text| {
                    const space = std.mem.indexOfAny(u8, full_text, " \t\r\n");
                    const skill_name = if (space) |s| full_text[0..s] else full_text;
                    const user_text = if (space) |s| std.mem.trimStart(u8, full_text[s..], " \t\r\n") else null;

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

                    // Skill with no content: report and skip, even when trailing
                    // text was supplied (e.g. `/empty-skill hello`), so no empty
                    // system message is appended and no chat turn is run.
                    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
                        try ctx.stdout_writer.print("\n\n{s}Skill '{s}' has no content.{s}\n", .{ ansi.dim, skill_name, ansi.reset });
                        try ctx.stdout_writer.flush();
                        continue;
                    }

                    const has_text = if (user_text) |text| std.mem.trim(u8, text, " \t\r\n").len > 0 else false;
                    if (has_text) {
                        // Skill loaded as system context, trailing text as the user request.
                        try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = content });
                        try ctx.stdout_writer.print("\n\n{s}Skill: {s}{s}\n", .{ ansi.dim, skill_name, ansi.reset });
                        try ctx.stdout_writer.flush();
                        try ctx.messages.append(ctx.messages_arena.allocator(), .{ .user = user_text.? });
                        try ctx.stdout_writer.print(" {s}\n", .{user_text.?});
                        try ctx.stdout_writer.flush();
                        const turn_result = try runChatTurn(ctx);
                        if (turn_result == .exit) return;
                        continue;
                    }

                    // Bare skill command: send the skill content itself as the prompt.
                    try ctx.messages.append(ctx.messages_arena.allocator(), .{ .user = content });
                    try ctx.stdout_writer.print("\n\n{s}Skill: {s}{s}\n", .{ ansi.dim, skill_name, ansi.reset });
                    try ctx.stdout_writer.flush();
                    const turn_result = try runChatTurn(ctx);
                    if (turn_result == .exit) return;
                    continue;
                },
                .load_prompt_file => |source| {
                    const outcome = prompt_file.load(ctx.messages_arena.allocator(), ctx.io, source);
                    switch (outcome) {
                        .ok => |content| {
                            if (content.len == 0) {
                                ctx.messages_arena.allocator().free(content);
                                try ctx.stdout_writer.print("\nPrompt file is empty.\n", .{});
                                try ctx.stdout_writer.flush();
                                continue;
                            }
                            try ctx.stdout_writer.print("\n{s}Loaded prompt from {s} ({d} bytes){s}\n", .{ ansi.dim, source, content.len, ansi.reset });
                            try ctx.stdout_writer.flush();
                            if (ctx.chat_log) |log| {
                                log.print("[USER]\nLoaded from {s}:\n{s}\n\n", .{ source, content });
                            }
                            try maybeLoadTriggeredSkills(ctx, content, &loaded_skills);
                            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .user = content });
                        },
                        .err => |e| {
                            defer if (e.owned) ctx.messages_arena.allocator().free(e.message);
                            try ctx.stdout_writer.print("\nFailed to load prompt from {s}: {s}\n", .{ source, e.message });
                            try ctx.stdout_writer.flush();
                            continue;
                        },
                    }
                },
                .run_chat_turn => {},
            }

            const turn_result = try runChatTurn(ctx);
            if (turn_result == .exit) return;
        }
    }
};

/// Loads any skill whose trigger phrase matches `text` into the message list,
/// skipping skills that were already loaded. Shared by the plain prompt path
/// and the prompt-file path.
fn maybeLoadTriggeredSkills(
    ctx: *ChatLoopContext,
    text: []const u8,
    loaded_skills: *std.StringHashMapUnmanaged(void),
) !void {
    for (ctx.skill_registry.records.items) |*r| {
        if (loaded_skills.contains(r.name)) continue;
        if (!skills.recordMatchesTrigger(r, text)) continue;
        const content = ctx.skill_registry.loadContent(ctx.io, r.name, ctx.messages_arena.allocator()) catch continue;
        try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = content });
        try ctx.stdout_writer.print("\n\n{s}Skill: {s}{s}\n", .{ ansi.dim, r.name, ansi.reset });
        try ctx.stdout_writer.flush();
        loaded_skills.put(ctx.arena, r.name, {}) catch {};
    }
}

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

    const first_prompt = firstUserPrompt(ctx.messages.items);

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
            finalizeSession(ctx);
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
            finalizeSession(ctx);
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
            rollBackCancelledTurn(ctx.messages);
            while (skills.takePendingSkill(ctx.messages_arena.allocator())) |_| {}
            ctx.session_stats.finalizeTurn(result.usage, false);
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
    upsertCurrentSession(ctx);

    if (ctx.parsed.oneshot) {
        try ctx.stdout_writer.print("\n", .{});
        finalizeSession(ctx);
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
            .reasoning_effort = ctx.reasoning_effort.*,
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
        ctx.reasoning_effort.*,
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
            .reasoning_effort = ctx.reasoning_effort.*,
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
        entry.stored_blob = null;
        result.changed = true;
    } else if (new_key.len > 0) {
        entry.apiKey = try arena.dupe(u8, new_key);
        entry.stored_blob = null;
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
    cfg.providerEntry(.copilot).stored_blob = null;
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
    logRequestLine(log, method, url);
    log.print("Headers:\n", .{});
    for (headers) |h| {
        log.print("  {s}: {s}\n", .{ h.name, redactHeaderValue(h.name, h.value) });
    }
    if (body) |b| {
        log.print("Body ({d} bytes):\n", .{b.len});
        log.printBody(b);
    }
}

fn logHttpResponse(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, status: std.http.Status, headers: []const std.http.Header, body: []const u8, duration_ns: u64) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    const ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    log.print("=== RESPONSE ===\n", .{});
    logRequestLine(log, method, url);
    log.print("Status: {d} ({s})\n", .{ @intFromEnum(status), @tagName(status) });
    log.print("Duration: {d:.2}ms\n", .{ms});
    log.print("Headers:\n", .{});
    for (headers) |h| {
        log.print("  {s}: {s}\n", .{ h.name, redactHeaderValue(h.name, h.value) });
    }
    if (body.len > 0) {
        log.print("Body ({d} bytes):\n", .{body.len});
        log.printBody(body);
    }
}

fn logHttpError(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, err_name: []const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== ERROR ===\n", .{});
    logRequestLine(log, method, url);
    log.print("Error: {s}\n", .{err_name});
}

fn logHttpChunk(ctx: ?*anyopaque, data: []const u8) void {
    const log: *DebugLog = @ptrCast(@alignCast(ctx.?));
    log.print("=== CHUNK ===\n", .{});
    log.printBody(data);
}

const FormattedBody = struct {
    text: []const u8,
    owned: bool,
};

/// Pretty-prints `body` when it is valid JSON, otherwise returns it unchanged.
/// `owned` is true only when `text` was allocated and must be freed.
/// Returns `"***"` for credential-bearing header names (case-insensitive)
/// so secrets never reach the debug log; everything else passes through.
fn redactHeaderValue(name: []const u8, value: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "set-cookie") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "x-api-key") or
        std.ascii.eqlIgnoreCase(name, "api-key") or
        std.ascii.eqlIgnoreCase(name, "x-auth-token") or
        std.ascii.eqlIgnoreCase(name, "x-api-token") or
        std.ascii.eqlIgnoreCase(name, "x-access-token") or
        std.ascii.eqlIgnoreCase(name, "x-copilot-auth"))
    {
        return "***";
    }
    return value;
}

fn isSecretMemberName(name: []const u8) bool {
    const secret_names = [_][]const u8{
        "api_key",
        "apiKey",
        "api-key",
        "x-api-key",
        "token",
        "access_token",
        "authorization",
        "proxy-authorization",
        "secret",
        "password",
    };
    for (secret_names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

fn isSecretQueryName(name: []const u8) bool {
    const secret_names = [_][]const u8{
        "api_key",
        "apikey",
        "api-key",
        "x-api-key",
        "key",
        "token",
        "access_token",
        "auth",
        "authorization",
        "signature",
        "secret",
        "password",
    };
    for (secret_names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

/// Returns an allocated copy of `url` with the values of secret query
/// parameters replaced by `"***"`, or `null` when there is nothing to redact.
fn redactUrl(allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    const query = url[query_start + 1 ..];

    var has_secret = false;
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (isSecretQueryName(pair[0..eq])) {
            has_secret = true;
            break;
        }
    }
    if (!has_secret) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, url[0 .. query_start + 1]) catch return null;
    var first = true;
    parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |pair| {
        if (!first) out.append(allocator, '&') catch return null;
        first = false;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            out.appendSlice(allocator, pair) catch return null;
            continue;
        };
        if (isSecretQueryName(pair[0..eq])) {
            out.appendSlice(allocator, pair[0 .. eq + 1]) catch return null;
            out.appendSlice(allocator, "***") catch return null;
        } else {
            out.appendSlice(allocator, pair) catch return null;
        }
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn logRequestLine(log: *DebugLog, method: std.http.Method, url: []const u8) void {
    if (redactUrl(log.allocator, url)) |masked| {
        log.print("{s} {s}\n", .{ @tagName(method), masked });
        log.allocator.free(masked);
    } else {
        log.print("{s} {s}\n", .{ @tagName(method), url });
    }
}

/// Replaces the values of credential-named JSON members with `"***"`,
/// recursively, so request/response bodies cannot leak secrets to the log.
fn redactSecretValues(value: *std.json.Value) void {
    switch (value.*) {
        .object => |obj| {
            const keys = obj.keys();
            const values = obj.values();
            for (keys, values) |key, *val| {
                if (isSecretMemberName(key)) {
                    val.* = .{ .string = "***" };
                } else {
                    redactSecretValues(val);
                }
            }
        },
        .array => |arr| {
            for (arr.items) |*item| redactSecretValues(item);
        },
        else => {},
    }
}

fn isPlainBoundary(c: u8) bool {
    return switch (c) {
        '&', ';', '{', '[', ',', '"', '\'', '(', '=', '\n', '\r', '\t', ' ', '*', ':' => true,
        else => false,
    };
}

fn isPlainValueTerminator(c: u8) bool {
    return switch (c) {
        '&', ';', ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}

/// Masks the values of secret `name=value` and `"name": value` pairs in a body
/// that failed JSON parsing (e.g. form-encoded or truncated JSON), returning an
/// owned copy with the secrets starred out, or `null` when nothing matched.
fn redactPlainBody(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const secret_names = [_][]const u8{
        "api_key",      "apiKey",   "api-key",       "x-api-key",
        "access_token", "token",    "authorization", "proxy-authorization",
        "secret",       "password", "key",           "signature",
        "auth",
    };

    const masked = allocator.dupe(u8, body) catch return null;

    var redacted = false;
    var i: usize = 0;
    while (i < masked.len) {
        // A name must sit at a token boundary so substrings inside words
        // (e.g. "key" in "monkey") never match.
        if (i > 0 and !isPlainBoundary(masked[i - 1])) {
            i += 1;
            continue;
        }

        const name = blk: {
            for (secret_names) |n| {
                if (std.ascii.startsWithIgnoreCase(masked[i..], n)) break :blk n;
            }
            break :blk null;
        } orelse {
            i += 1;
            continue;
        };

        var j = i + name.len;
        while (j < masked.len and (masked[j] == '"' or masked[j] == ' ' or masked[j] == '\t')) j += 1;
        if (j >= masked.len or (masked[j] != '=' and masked[j] != ':')) {
            i += 1;
            continue;
        }
        const delim = masked[j];
        j += 1;
        if (delim == '=') {
            while (j < masked.len and !isPlainValueTerminator(masked[j])) {
                masked[j] = '*';
                j += 1;
            }
        } else {
            while (j < masked.len and masked[j] == ' ') j += 1;
            if (j < masked.len and masked[j] == '"') {
                j += 1;
                while (j < masked.len and masked[j] != '"') {
                    masked[j] = '*';
                    j += 1;
                }
            } else {
                while (j < masked.len and !isPlainValueTerminator(masked[j]) and masked[j] != ',' and masked[j] != '}') {
                    masked[j] = '*';
                    j += 1;
                }
            }
        }
        redacted = true;
        i = j;
    }

    if (!redacted) {
        allocator.free(masked);
        return null;
    }
    return masked;
}

fn formatBody(allocator: std.mem.Allocator, body: []const u8) FormattedBody {
    if (body.len == 0) return .{ .text = body, .owned = false };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        // Not valid JSON (e.g. form-encoded or truncated): best-effort redact
        // secret name=value / "name": value pairs before logging.
        if (redactPlainBody(allocator, body)) |masked| return .{ .text = masked, .owned = true };
        return .{ .text = body, .owned = false };
    };
    defer parsed.deinit();
    redactSecretValues(&parsed.value);
    const formatted = std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 }) catch return .{ .text = body, .owned = false };
    return .{ .text = formatted, .owned = true };
}

test "formatBody pretty-prints valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const formatted = formatBody(allocator, "{\"a\":1,\"b\":[true,null,\"x\"]}");
    defer if (formatted.owned) allocator.free(formatted.text);
    try std.testing.expectEqualStrings(
        \\{
        \\  "a": 1,
        \\  "b": [
        \\    true,
        \\    null,
        \\    "x"
        \\  ]
        \\}
    , formatted.text);
    try std.testing.expect(formatted.owned);
}

test "formatBody returns plain text unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "data: {\"hello\":\"world\"}\n\n";
    const formatted = formatBody(allocator, body);
    try std.testing.expectEqualStrings(body, formatted.text);
    try std.testing.expect(!formatted.owned);
}

test "formatBody returns malformed JSON unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"a\":1,}";
    const formatted = formatBody(allocator, body);
    try std.testing.expectEqualStrings(body, formatted.text);
    try std.testing.expect(!formatted.owned);
}

test "formatBody returns empty body unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const formatted = formatBody(allocator, "");
    try std.testing.expectEqualStrings("", formatted.text);
    try std.testing.expect(!formatted.owned);
}

test "DebugLog printBody writes pretty-printed JSON to the log file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = std.testing.allocator,
    };

    log.printBody("{\"a\":1}");

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", std.testing.allocator, std.Io.Limit.limited(64 * 1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("{\n  \"a\": 1\n}\n", content);
}

test "logHttpRequest writes pretty-printed JSON body to the log file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const ctx: ?*anyopaque = @ptrCast(&log);
    logHttpRequest(ctx, .POST, "http://example.com", &.{}, "{\"a\":1}");

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "{\n  \"a\": 1\n}") != null);
}

test "logHttpResponse writes pretty-printed JSON body to the log file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const ctx: ?*anyopaque = @ptrCast(&log);
    logHttpResponse(ctx, .POST, "http://example.com", .ok, &.{}, "{\"a\":1}", 1_000_000);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "{\n  \"a\": 1\n}") != null);
}

test "logHttpChunk writes pretty-printed JSON body to the log file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const ctx: ?*anyopaque = @ptrCast(&log);
    logHttpChunk(ctx, "{\"a\":1}");

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "{\n  \"a\": 1\n}") != null);
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

test "include chat tests" {
    _ = @import("chat.zig");
}

test "include chat usage tests" {
    _ = @import("usage.zig");
}

test "sessionHasContent returns false for empty message list" {
    const messages = [_]openai.Message{};
    try std.testing.expect(!sessionHasContent(&messages));
}

test "sessionHasContent returns false for system-only messages" {
    const messages = [_]openai.Message{
        .{ .system = "You are a helpful assistant." },
        .{ .system = "Skills block" },
    };
    try std.testing.expect(!sessionHasContent(&messages));
}

test "sessionHasContent returns true for a user message" {
    const messages = [_]openai.Message{
        .{ .system = "You are a helpful assistant." },
        .{ .user = "Hello!" },
    };
    try std.testing.expect(sessionHasContent(&messages));
}

test "sessionHasContent returns true for an assistant message" {
    const messages = [_]openai.Message{
        .{ .system = "You are a helpful assistant." },
        .{ .assistant = .{ .content = "Hi there!" } },
    };
    try std.testing.expect(sessionHasContent(&messages));
}

test "sessionHasContent returns true for user and assistant messages" {
    const messages = [_]openai.Message{
        .{ .user = "Hello!" },
        .{ .assistant = .{ .content = "Hi there!" } },
    };
    try std.testing.expect(sessionHasContent(&messages));
}

test "shouldRemoveSessionDir is false when restore was incomplete" {
    const messages = [_]openai.Message{};
    try std.testing.expect(!shouldRemoveSessionDir(true, &messages, std.testing.io, ".zig-cache/tmp"));
}

test "shouldRemoveSessionDir is false when session has content" {
    const messages = [_]openai.Message{
        .{ .user = "Hello!" },
    };
    try std.testing.expect(!shouldRemoveSessionDir(false, &messages, std.testing.io, ".zig-cache/tmp"));
}

test "shouldRemoveSessionDir is true for a fully restored empty session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(dir);
    const messages = [_]openai.Message{};
    try std.testing.expect(shouldRemoveSessionDir(false, &messages, std.testing.io, dir));
}

test "shouldRemoveSessionDir is false when a plan exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(dir);
    const plan_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.md" });
    defer std.testing.allocator.free(plan_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, plan_path, .{});
    file.close(std.testing.io);
    const messages = [_]openai.Message{};
    try std.testing.expect(!shouldRemoveSessionDir(false, &messages, std.testing.io, dir));
}

test "rollBackCancelledTurn keeps the user message on a cancelled turn" {
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(std.testing.allocator);
    try messages.append(std.testing.allocator, .{ .system = "You are a helpful assistant." });
    try messages.append(std.testing.allocator, .{ .user = "Hello!" });

    rollBackCancelledTurn(&messages);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .user = "Hello!" }, messages.items[1]);
}

test "rollBackCancelledTurn rolls back partial tool messages but keeps the user message" {
    var messages = std.ArrayList(openai.Message).empty;
    defer messages.deinit(std.testing.allocator);
    try messages.append(std.testing.allocator, .{ .system = "You are a helpful assistant." });
    try messages.append(std.testing.allocator, .{ .user = "Read the file" });
    try messages.append(std.testing.allocator, .{ .assistant = .{ .content = null, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{}" } },
    } } });
    try messages.append(std.testing.allocator, .{ .tool = .{ .tool_call_id = "call_1", .content = "file contents" } });

    rollBackCancelledTurn(&messages);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualDeep(openai.Message{ .user = "Read the file" }, messages.items[1]);
}

fn sessionHasContent(messages: []const openai.Message) bool {
    for (messages) |msg| {
        switch (msg) {
            .user, .assistant => return true,
            else => {},
        }
    }
    return false;
}

fn shouldRemoveSessionDir(restore_incomplete: bool, messages: []const openai.Message, io: std.Io, dir: []const u8) bool {
    return !restore_incomplete and !sessionHasContent(messages) and !core_session.sessionHasPlan(io, dir);
}

fn rollBackCancelledTurn(messages: *std.ArrayList(openai.Message)) void {
    while (messages.items.len > 0) {
        switch (messages.items[messages.items.len - 1]) {
            .assistant, .tool => _ = messages.pop(),
            else => break,
        }
    }
}

/// Returns the entry to record in prompt history for `command`, or `null` when
/// nothing should be recorded. Prompt-file prompts are recorded as their
/// `/file <source>` command so the user can re-run the prompt after editing the
/// file. A pending `prompt_file_source` takes precedence over the parsed
/// command: the `/file <source>` command is recorded even when the file content
/// itself parses as a command (e.g. it begins with `/quit` or `/file`).
fn historyEntryFor(
    allocator: std.mem.Allocator,
    user_message: []const u8,
    command: commands.Command,
    prompt_file_source: ?[]const u8,
) !?[]const u8 {
    if (prompt_file_source) |source| {
        return try std.fmt.allocPrint(allocator, "/file {s}", .{source});
    }
    switch (command) {
        .file => |source| {
            const path = if (source) |s| std.mem.trim(u8, s, &std.ascii.whitespace) else "";
            if (path.len == 0) return null;
            return try std.fmt.allocPrint(allocator, "/file {s}", .{path});
        },
        .prompt => return user_message,
        else => return null,
    }
}

test "historyEntryFor records a typed /file input as its command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const entry = (try historyEntryFor(allocator, "/file spec.md", commands.parse("/file spec.md"), null)).?;
    try std.testing.expectEqualStrings("/file spec.md", entry);
}

test "historyEntryFor trims surrounding whitespace from the /file argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const entry = (try historyEntryFor(allocator, "/file   spec.md  ", commands.parse("/file   spec.md  "), null)).?;
    try std.testing.expectEqualStrings("/file spec.md", entry);
}

test "historyEntryFor records the /file command for a prompt loaded from --prompt-file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const content = "do the thing";
    const entry = (try historyEntryFor(allocator, content, commands.parse(content), "spec.md")).?;
    try std.testing.expectEqualStrings("/file spec.md", entry);
}

test "historyEntryFor prioritizes the pending --prompt-file source over a /file command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const content = "/file notes.txt";
    const entry = (try historyEntryFor(allocator, content, commands.parse(content), "spec.md")).?;
    try std.testing.expectEqualStrings("/file spec.md", entry);
}

test "historyEntryFor records the pending --prompt-file source for /quit content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const content = "/quit";
    const entry = (try historyEntryFor(allocator, content, commands.parse(content), "spec.md")).?;
    try std.testing.expectEqualStrings("/file spec.md", entry);
}

test "historyEntryFor keeps plain prompts as the message itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const entry = (try historyEntryFor(allocator, "hello", commands.parse("hello"), null)).?;
    try std.testing.expectEqualStrings("hello", entry);
}

test "historyEntryFor returns null for bare /file and other commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    try std.testing.expectEqual(@as(?[]const u8, null), try historyEntryFor(allocator, "/file", commands.parse("/file"), null));
    try std.testing.expectEqual(@as(?[]const u8, null), try historyEntryFor(allocator, "/quit", commands.parse("/quit"), null));
}

test "prompt-file prompts persist in history as /file commands end to end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const history_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "prompt_history.json" });
    defer allocator.free(history_path);

    var history = prompt_history.History.init(allocator, history_path);
    defer history.deinit();

    const content = "do the thing";

    // Typing `/file spec.md` records the command, not the file content.
    const typed = "/file spec.md";
    try history.add((try historyEntryFor(allocator, typed, commands.parse(typed), null)).?);

    // A prompt loaded via the --prompt-file CLI arg records the same command,
    // even when its content parses as a slash command like /quit.
    try history.add((try historyEntryFor(allocator, content, commands.parse(content), "spec.md")).?);
    const quit_content = "/quit";
    try history.add((try historyEntryFor(allocator, quit_content, commands.parse(quit_content), "spec.md")).?);

    try history.save(std.testing.io);

    // A fresh session reloads history and up-arrow restores the command so the
    // edited file can be re-run.
    var reloaded = prompt_history.History.init(allocator, history_path);
    defer reloaded.deinit();
    try reloaded.load(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.items.len);
    try std.testing.expectEqualStrings("/file spec.md", reloaded.entries.items[0]);
    try std.testing.expectEqualStrings("/file spec.md", reloaded.previous("").?);
}

fn finalizeSession(ctx: *ChatLoopContext) void {
    saveMessages(ctx) catch {};
    saveSessionMeta(ctx) catch {};
    if (shouldRemoveSessionDir(ctx.restore_incomplete, ctx.messages.items, ctx.io, ctx.session.dir)) {
        core_session.removeSessionDir(ctx.io, ctx.session.dir);
        sessions.removeSessionFromIndex(ctx.arena, ctx.io, ctx.session.base, ctx.session.id) catch {};
    } else {
        upsertCurrentSession(ctx);
    }
    printExit(ctx.session_stats, ctx.io, ctx.stdout_writer) catch {};
}

/// Refreshes the current session's entry in the sessions index after a content
/// mutation. Best-effort like saveMessages/saveSessionMeta: a failed index
/// write must not interrupt the chat loop.
fn upsertCurrentSession(ctx: *ChatLoopContext) void {
    const now_ns: u64 = @intCast(std.Io.Timestamp.now(ctx.io, .awake).nanoseconds);
    sessions.upsertSessionInfo(ctx.arena, ctx.io, ctx.session.base, .{
        .id = ctx.session.id,
        .has_prd = core_session.sessionHasPlan(ctx.io, ctx.session.dir),
        .has_conversation = sessionHasContent(ctx.messages.items),
        .planning_mode = ctx.planning_mode.*,
        .first_prompt = firstUserPrompt(ctx.messages.items),
        .last_modified = now_ns,
    }) catch |err| {
        std.log.warn("failed to update sessions index: {s}", .{@errorName(err)});
    };
}

/// The first user message in the conversation, or null when there is none.
fn firstUserPrompt(messages: []const openai.Message) ?[]const u8 {
    for (messages) |m| {
        if (m == .user) return m.user;
    }
    return null;
}

test "logHttpRequest redacts the authorization header value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = "Bearer sk-super-secret-123" },
        .{ .name = "content-type", .value = "application/json" },
    };
    logHttpRequest(@ptrCast(&log), .POST, "http://example.com", &headers, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sk-super-secret-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "authorization: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "content-type: application/json") != null);
}

test "logHttpRequest redacts api-key style header values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = "sk-xyz-987" },
        .{ .name = "proxy-authorization", .value = "Basic c2VjcmV0" },
        .{ .name = "content-type", .value = "application/json" },
    };
    logHttpRequest(@ptrCast(&log), .POST, "http://example.com", &headers, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sk-xyz-987") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Basic c2VjcmV0") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "x-api-key: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "proxy-authorization: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "content-type: application/json") != null);
}

test "logHttpRequest redacts secret query parameters in the URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    logHttpRequest(@ptrCast(&log), .GET, "https://example.com/models?api_key=sk-query-1&token=tok-2&model=gpt-4o", &.{}, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sk-query-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "tok-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "model=gpt-4o") != null);
}

test "logHttpRequest redacts the cookie header value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "Cookie", .value = "session=sekrit-session-1; Path=/" },
        .{ .name = "content-type", .value = "application/json" },
    };
    logHttpRequest(@ptrCast(&log), .POST, "http://example.com", &headers, null);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sekrit-session-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Cookie: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "content-type: application/json") != null);
}

test "logHttpResponse redacts authorization and set-cookie header values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var file = try tmp.dir.createFile(std.testing.io, "debug.log", .{});
    defer file.close(std.testing.io);
    var file_writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
    var log = DebugLog{
        .file = file,
        .writer = &file_writer.interface,
        .allocator = allocator,
    };

    const headers = [_]std.http.Header{
        .{ .name = "Set-Cookie", .value = "session=abc123; HttpOnly" },
        .{ .name = "Authorization", .value = "Bearer sekrit" },
        .{ .name = "date", .value = "Mon, 01 Jan 2024" },
    };
    logHttpResponse(@ptrCast(&log), .POST, "http://example.com", .ok, &headers, "{}", 1_000_000);

    try file_writer.interface.flush();
    const content = try tmp.dir.readFileAlloc(std.testing.io, "debug.log", allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sekrit") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Set-Cookie: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Authorization: ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "date: Mon, 01 Jan 2024") != null);
}

test "formatBody redacts key-named JSON members" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"model\":\"gpt-4o\",\"api_key\":\"sk-leak\",\"nested\":{\"token\":\"t-1\",\"access_token\":\"at-2\",\"ok\":1},\"list\":[{\"apiKey\":\"k-3\"}],\"authorization\":\"Bearer hdr\"}";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-leak") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "t-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "at-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "k-3") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "hdr") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "\"model\": \"gpt-4o\"") != null);
    try std.testing.expect(std.mem.count(u8, formatted.text, "\"***\"") >= 5);
}

test "formatBody redacts secret member names case-insensitively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"API_KEY\":\"sk-upper\",\"Access_Token\":\"tok-x\",\"Nested\":{\"Authorization\":\"Bearer hdr2\"},\"ok\":1}";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-upper") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "tok-x") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "hdr2") == null);
    try std.testing.expect(std.mem.count(u8, formatted.text, "\"***\"") >= 3);
}

test "formatBody redacts x-api-key and credential members" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const body = "{\"x-api-key\":\"sk-hdr\",\"api-key\":\"k-dash\",\"password\":\"p-1\",\"secret\":\"s-2\",\"ok\":1}";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-hdr") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "k-dash") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "p-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "s-2") == null);
    try std.testing.expect(std.mem.count(u8, formatted.text, "\"***\"") >= 4);
}

test "formatBody redacts secret pairs in a non-JSON body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Not valid JSON, so it falls through to plain-text redaction.
    const body = "api_key=sk-form-1&token=tok-9&model=gpt-4o";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-form-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "tok-9") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "model=gpt-4o") != null);
}

test "formatBody redacts secret pairs case-insensitively in a non-JSON body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Not valid JSON, so it falls through to plain-text redaction. Secret
    // names must match regardless of case, like the JSON and query paths.
    const body = "API_KEY=sk-form-upper&Token=tok-upper&model=gpt-4o";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-form-upper") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "tok-upper") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "model=gpt-4o") != null);
}

test "formatBody redacts secret pairs in a truncated JSON body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Truncated JSON: parse fails, but the credential must still be masked.
    const body = "{\"api_key\":\"sk-truncated\",\"model\":\"gpt-4o\"";
    const formatted = formatBody(allocator, body);
    defer if (formatted.owned) allocator.free(formatted.text);

    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "sk-truncated") == null);
}
