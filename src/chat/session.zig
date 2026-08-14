const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const chat = @import("chat.zig");
const stats = @import("stats.zig");
const debug_log = @import("debug_log.zig");
const session_commands = @import("session_commands.zig");
const token_stats = @import("../tui/token_stats.zig");
const cli = @import("../cli/args.zig");
const commands = @import("../cli/commands.zig");
const core_session = @import("../core/session.zig");
const git_root = @import("../core/git_root.zig");
const sessions = @import("../sessions/sessions.zig");
const config = @import("../config/config.zig");
const indicator = @import("../tui/indicator.zig");
const input = @import("../tui/input.zig");
const mock = @import("../providers/mock.zig");
const model_selection = @import("../models/select.zig");
const openai = @import("../providers/openai.zig");
const provider_picker = @import("../tui/provider_picker.zig");
const effort_picker = @import("../tui/effort_picker.zig");
const prompt_history = @import("../prompts/history.zig");
const prompts = @import("../prompts/prompts.zig");
const prompt_file = @import("../prompts/prompt_file.zig");
const provider = @import("../providers/provider.zig");
const resolver = @import("../providers/resolver.zig");
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

pub const DebugLog = debug_log.DebugLog;
pub const attachHttpDebugObserver = debug_log.attachHttpDebugObserver;
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
    session_stats: *stats.SessionStats,
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
                .io = ctx.io,
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

                    if (try git_root.findGitRepoRoot(ctx.arena, ctx.io)) |repo_root| {
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
                    ctx.session_stats.* = stats.SessionStats.init(ctx.arena, ctx.io);
                    ctx.session_stats.session_id = ctx.session.id;

                    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.model_provider.*, ctx.init.environ_map.get("PUNY_API_KEY"));
                    ctx.prov.* = resolver.createProvider(ctx.parsed.mock, ctx.model_provider.*, ctx.provider_url.*, new_api_key, ctx.messages_arena.allocator(), ctx.io);
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
                        ctx.session_stats.* = stats.SessionStats.init(ctx.arena, ctx.io);
                        ctx.session_stats.session_id = ctx.session.id;

                        const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.model_provider.*, ctx.init.environ_map.get("PUNY_API_KEY"));
                        ctx.prov.* = resolver.createProvider(ctx.parsed.mock, ctx.model_provider.*, ctx.provider_url.*, new_api_key, ctx.messages_arena.allocator(), ctx.io);
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
                    try session_commands.handleSwitchModelCommand(ctx, model_id);
                    continue;
                },
                .switch_provider => |provider_id| {
                    try session_commands.handleSwitchProviderCommand(ctx, provider_id);
                    continue;
                },
                .switch_effort => |effort| {
                    try session_commands.handleSwitchEffortCommand(ctx, effort);
                    continue;
                },
                .list_skills => {
                    if (ctx.parsed.no_skills) {
                        try ctx.stdout_writer.print("\n\nSkills are disabled.\n", .{});
                        try ctx.stdout_writer.flush();
                        if (ctx.parsed.oneshot) {
                            try ctx.stdout_writer.print("\n", .{});
                            try ctx.stdout_writer.flush();
                            finalizeSession(ctx);
                            return;
                        }
                        continue;
                    }
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
    if (ctx.parsed.no_skills) return;
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
                try writer.print("\n{s}{s}{s} ", .{ ansi.bright, prompts.prompt_text, ansi.reset });
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

    const maybe_input = input.readLine(ctx.arena, ctx.io, ctx.stdout_writer, line_alloc, stdin_buffer, ctx.history) catch |err| {
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
    var turn_cancelled = false;
    var turn_had_error = false;
    var turn_estimated = false;
    var turn_in: i64 = 0;
    var turn_out: i64 = 0;
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
            turn_cancelled = true;
            rollBackCancelledTurn(ctx.messages);
            while (skills.takePendingSkill(ctx.messages_arena.allocator())) |_| {}
            ctx.session_stats.finalizeTurn(result.usage, false);
            break;
        }

        turn_had_error = turn_had_error or result.had_error;
        if (result.usage) |u| {
            turn_in += u.input_tokens;
            turn_out += u.output_tokens;
        }
        turn_estimated = turn_estimated or result.usage_estimated;

        if (skills.takePendingSkill(ctx.messages_arena.allocator())) |pending| {
            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = pending.content });
            try ctx.stdout_writer.print("\n\n{s}Skill: {s}{s}\n", .{ ansi.dim, pending.name, ansi.reset });
            try ctx.stdout_writer.flush();
        }

        ctx.session_stats.finalizeTurn(result.usage, result.turn_complete);
        turn_complete = result.turn_complete;
    }

    if (turn_complete and !turn_cancelled and !turn_had_error) {
        try token_stats.printTokenFooter(ctx.stdout_writer, turn_in, turn_out, turn_estimated, ctx.session_stats.totalTokens());
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
    const new_provider_url = if (ctx.parsed.mock) "-" else resolver.baseUrlFor(new_provider_name, ctx.parsed, ctx.cfg.*);
    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, new_provider_name, ctx.init.environ_map.get("PUNY_API_KEY"));

    if (!ctx.parsed.mock and old_provider_name != new_provider_name) {
        ctx.prov.deinit();
        ctx.prov.* = resolver.createProvider(ctx.parsed.mock, new_provider_name, new_provider_url, new_api_key, ctx.messages_arena.allocator(), ctx.io);
        if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);
        if (!ctx.parsed.mock) try resolver.ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
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
        if (!ctx.parsed.mock) try resolver.ensureCopilotAuth(ctx.arena, ctx.io, ctx.init, ctx.cfg, ctx.stdout_writer, ctx.prov);
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

fn printExit(
    session_stats: *const stats.SessionStats,
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
    const provider_url_is_fixed = resolver.providerHasFixedUrl(provider_name);
    if (provider_url_is_fixed) {
        const fixed_url = resolver.defaultProviderUrl(provider_name);
        entry.url = try arena.dupe(u8, fixed_url);
        result.changed = true;
        try stdout_writer.print("Provider URL is fixed at {s}\n", .{fixed_url});
        try stdout_writer.flush();
    } else {
        line_alloc.clearRetainingCapacity();
        try stdout_writer.print("Current provider URL: {s}\n", .{entry.url});
        try stdout_writer.print(
            "Enter new provider URL (default: {s}; press Enter for default): ",
            .{resolver.defaultProviderUrl(provider_name)},
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

        const default_url = resolver.defaultProviderUrl(provider_name);
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
