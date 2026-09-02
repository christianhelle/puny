const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const chat = @import("chat.zig");
const stats = @import("stats.zig");
const debug_log = @import("debug_log.zig");
const display = @import("display.zig");
const persistence = @import("persistence.zig");
const session_commands = @import("session_commands.zig");
const context = @import("context.zig");
const token_stats = @import("../tui/token_stats.zig");
const commands = @import("../cli/commands.zig");
const core_session = @import("../core/session.zig");
const git_root = @import("../core/git_root.zig");
const sessions = @import("../sessions/sessions.zig");
const indicator = @import("../tui/indicator.zig");
const input = @import("../tui/input.zig");
const mock = @import("../providers/mock.zig");
const openai = @import("../providers/openai.zig");
const prompt_history = @import("../prompts/history.zig");
const prompts = @import("../prompts/prompts.zig");
const prompt_file = @import("../prompts/prompt_file.zig");
const resolver = @import("../providers/resolver.zig");
const instructions = @import("../agents/instructions.zig");
const sigint = @import("../core/sigint.zig");
const skills = @import("../skills/skills.zig");
const tools = @import("../tools/root.zig");
const branch_review = @import("../review/review.zig");
const orchestrate = @import("orchestrate.zig");
const help = @import("../tui/help.zig");

pub const ReconfigurePrompt = session_commands.ReconfigurePrompt;
pub const promptReconfigure = session_commands.promptReconfigure;
pub const DebugLog = debug_log.DebugLog;
pub const attachHttpDebugObserver = debug_log.attachHttpDebugObserver;
pub const ChatLog = context.ChatLog;
pub const ChatLoopContext = context.ChatLoopContext;

const UserInput = union(enum) {
    message: []const u8,
    continue_loop,
    exit,
};

const TurnResult = enum {
    continue_loop,
    exit,
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
        var pending_orchestrate: ?orchestrate.Spec = null;

        if (ctx.parsed.orchestrate) {
            pending_prompt = null;
            _ = try runOrchestrate(ctx, .{
                .task = ctx.parsed.prompt orelse "",
                .max_iterations = ctx.parsed.max_iterations,
            });
            finalizeSession(ctx);
            return;
        }

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
                .mode = ctx.mode,
                .oneshot = ctx.parsed.oneshot,
                .cfg = ctx.cfg,
                .session_prd_path = ctx.session.prd_path,
            });
            core_session.setWriteBlocked(ctx.mode.blocksSourceWrites());

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
                    try persistence.saveMessages(ctx);
                    try persistence.saveSessionMeta(ctx);
                    upsertCurrentSession(ctx);

                    try ctx.stdout_writer.print(" Performing full memory reset...", .{});
                    try ctx.stdout_writer.flush();

                    try recycleMessagesArena(ctx);
                    ctx.mode.* = .build;
                    core_session.setWriteBlocked(false);
                    try installBaseContext(ctx);

                    ctx.session.* = try core_session.Session.init(ctx.arena, ctx.session.base, ctx.random, ctx.io);

                    ctx.session_stats.deinit();
                    ctx.session_stats.* = stats.SessionStats.init(ctx.arena, ctx.io);
                    ctx.session_stats.session_id = ctx.session.id;

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
                        try persistence.loadMessagesIntoContext(ctx, dir);

                        ctx.mode.* = s.mode;
                        core_session.setWriteBlocked(ctx.mode.blocksSourceWrites());

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
                        try display.printConversation(ctx.stdout_writer, ctx.messages.items);
                        try ctx.stdout_writer.flush();
                    } else {
                        try ctx.stdout_writer.print("\n{s}No matching session found.{s}\n", .{ ansi.dim, ansi.reset });
                        try ctx.stdout_writer.flush();
                    }
                    continue;
                },
                .reconfigure => {
                    try session_commands.handleReconfigureCommand(ctx);
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
                .begin_review => {
                    const prepared = try branch_review.prepare(ctx.messages_arena.allocator(), ctx.io);
                    switch (prepared) {
                        .invalid => |failure| {
                            try ctx.stdout_writer.print("\nReview could not start: {s}\n", .{failure.message});
                            try ctx.stdout_writer.flush();
                            ctx.review_outcome.* = .operational_failure;
                            if (ctx.parsed.oneshot) {
                                finalizeSession(ctx);
                                return;
                            }
                            continue;
                        },
                        .operational_failure => |failure| {
                            const failure_context = try std.fmt.allocPrint(
                                ctx.messages_arena.allocator(),
                                "Review preflight failed before an immutable scope could be established: {s}",
                                .{failure.message},
                            );
                            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = failure_context });
                            const saved = branch_review.writeOperationalFailure(ctx.messages_arena.allocator(), ctx.io, failure) catch |err| {
                                ctx.review_outcome.* = .operational_failure;
                                printReviewWriteError(ctx.io, err);
                                if (ctx.parsed.oneshot) {
                                    finalizeSession(ctx);
                                    return;
                                }
                                continue;
                            };
                            ctx.review_outcome.* = saved.outcome;
                            try printReviewResult(ctx.stdout_writer, saved);
                            try persistence.saveSessionMeta(ctx);
                            upsertCurrentSession(ctx);
                            if (ctx.parsed.oneshot) {
                                finalizeSession(ctx);
                                return;
                            }
                            continue;
                        },
                        .no_changes => |scope| {
                            const review_context = try branch_review.buildPromptContext(ctx.messages_arena.allocator(), scope);
                            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = review_context });
                            const saved = branch_review.writeNoChanges(ctx.messages_arena.allocator(), ctx.io, scope) catch |err| {
                                ctx.review_outcome.* = .operational_failure;
                                printReviewWriteError(ctx.io, err);
                                if (ctx.parsed.oneshot) {
                                    finalizeSession(ctx);
                                    return;
                                }
                                continue;
                            };
                            ctx.review_outcome.* = saved.outcome;
                            try printReviewResult(ctx.stdout_writer, saved);
                            try persistence.saveSessionMeta(ctx);
                            upsertCurrentSession(ctx);
                            if (ctx.parsed.oneshot) {
                                finalizeSession(ctx);
                                return;
                            }
                            continue;
                        },
                        .ready => |scope| {
                            try enterReviewMode(ctx);
                            branch_review.begin(scope);
                            const review_context = try branch_review.buildPromptContext(ctx.messages_arena.allocator(), scope);
                            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = review_context });
                            try ctx.messages.append(ctx.messages_arena.allocator(), .{ .user = branch_review.request_prompt });
                            try ctx.stdout_writer.print("\n{s}Reviewing {s} against {s}.{s}\n", .{ ansi.bright, scope.branch, scope.base_ref, ansi.reset });
                            try ctx.stdout_writer.flush();
                        },
                    }
                },
                .begin_orchestrate => |text| {
                    const spec = orchestrate.parseCommand(text) catch |err| {
                        try ctx.stdout_writer.print("\n{s}\n{s}", .{ orchestrate.parseError(err), orchestrate.usage });
                        try ctx.stdout_writer.flush();
                        if (ctx.parsed.oneshot) {
                            ctx.review_outcome.* = .operational_failure;
                            finalizeSession(ctx);
                            return;
                        }
                        continue;
                    };

                    if (spec.plan) {
                        // Planning is an interview the REPL has to drive, so the
                        // run starts once the model saves the PRD. Handing off
                        // through plan.md keeps the same artifact contract the
                        // phases use. Reuses the /plan dispatch so the planning
                        // setup lives in exactly one place.
                        pending_orchestrate = spec;
                        core_session.setWriteBlocked(true);
                        _ = try commands.dispatch(.{ .plan = spec.task }, .{
                            .arena = ctx.arena,
                            .messages_alloc = ctx.messages_arena.allocator(),
                            .messages_arena = ctx.messages_arena,
                            .io = ctx.io,
                            .stdout_writer = ctx.stdout_writer,
                            .messages = ctx.messages,
                            .mode = ctx.mode,
                            .oneshot = ctx.parsed.oneshot,
                            .cfg = ctx.cfg,
                            .session_prd_path = ctx.session.prd_path,
                        });
                        try ctx.stdout_writer.print("Orchestrate starts once the PRD is saved.\n", .{});
                        try ctx.stdout_writer.flush();
                    } else {
                        _ = try runOrchestrate(ctx, spec);
                        if (ctx.parsed.oneshot) {
                            finalizeSession(ctx);
                            return;
                        }
                        if (sigint.isTriggered()) sigint.clear();
                        continue;
                    }
                },
                .run_chat_turn => {},
            }

            const turn_result = runChatTurn(ctx) catch |err| {
                if (!branch_review.isActive()) return err;
                const reason = try std.fmt.allocPrint(
                    ctx.messages_arena.allocator(),
                    "Review execution failed: {s}",
                    .{@errorName(err)},
                );
                const saved = branch_review.failActive(ctx.messages_arena.allocator(), ctx.io, reason) catch |write_err| {
                    branch_review.reset();
                    ctx.review_outcome.* = .operational_failure;
                    printReviewWriteError(ctx.io, write_err);
                    try persistence.saveMessages(ctx);
                    try persistence.saveSessionMeta(ctx);
                    upsertCurrentSession(ctx);
                    if (ctx.parsed.oneshot) {
                        finalizeSession(ctx);
                        return;
                    }
                    continue;
                };
                branch_review.reset();
                ctx.review_outcome.* = saved.outcome;
                try printReviewResult(ctx.stdout_writer, saved);
                try persistence.saveMessages(ctx);
                try persistence.saveSessionMeta(ctx);
                upsertCurrentSession(ctx);
                if (ctx.parsed.oneshot) {
                    finalizeSession(ctx);
                    return;
                }
                continue;
            };
            if (turn_result == .exit) return;

            // `/orchestrate --plan` waits here: the planning interview runs as
            // ordinary turns, and the run begins the moment save_prd lands a
            // plan in the session directory. Leaving planning mode any other
            // way cancels it.
            if (pending_orchestrate) |pending| {
                if (ctx.mode.* != .planning) {
                    pending_orchestrate = null;
                } else if (core_session.sessionHasPlan(ctx.io, ctx.session.dir)) {
                    pending_orchestrate = null;
                    try ctx.stdout_writer.print("\nPRD saved. Starting orchestrate.\n", .{});
                    try ctx.stdout_writer.flush();
                    _ = try runOrchestrate(ctx, .{ .max_iterations = pending.max_iterations });
                    if (ctx.parsed.oneshot) {
                        finalizeSession(ctx);
                        return;
                    }
                    if (sigint.isTriggered()) sigint.clear();
                }
            }
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

/// Drives one agentic turn. `honor_oneshot` is false for orchestrate phases,
/// which run several turns inside a single `--oneshot` invocation.
fn runTurn(ctx: *ChatLoopContext, honor_oneshot: bool) !orchestrate.TurnReport {
    var turn_complete = false;
    var turn_cancelled = false;
    var turn_had_error = false;
    var turn_estimated = false;
    var turn_in: i64 = 0;
    var turn_out: i64 = 0;
    while (!turn_complete) {
        const active_tool_definitions = switch (ctx.mode.*) {
            .build => ctx.full_tool_definitions.items,
            .planning => ctx.planning_tool_definitions.items,
            .review => ctx.review_tool_definitions.items,
        };

        var thinking_indicator = indicator.ThinkingIndicator.init(ctx.io);
        try thinking_indicator.show(ctx.stdout_writer);

        const chat_log_writer = if (ctx.chat_log) |log| log.writer else null;
        const result = chat.runTurnWithMode(
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
            ctx.mode.*,
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

    if (branch_review.isActive()) {
        const saved = if (turn_cancelled or turn_had_error)
            try branch_review.failActive(
                ctx.messages_arena.allocator(),
                ctx.io,
                if (turn_cancelled) "Review execution was cancelled." else "The provider failed before the review completed.",
            )
        else
            try branch_review.finish(
                ctx.messages_arena.allocator(),
                ctx.io,
                "The model returned without saving valid review results.",
            );
        branch_review.reset();
        ctx.review_outcome.* = saved.outcome;
        try printReviewResult(ctx.stdout_writer, saved);
    }

    try persistence.saveMessages(ctx);
    try persistence.saveSessionMeta(ctx);
    upsertCurrentSession(ctx);

    if (honor_oneshot and ctx.parsed.oneshot) {
        try ctx.stdout_writer.print("\n", .{});
        finalizeSession(ctx);
        return .{ .cancelled = turn_cancelled, .had_error = turn_had_error, .exited = true };
    }

    return .{ .cancelled = turn_cancelled, .had_error = turn_had_error };
}

fn runChatTurn(ctx: *ChatLoopContext) !TurnResult {
    const report = try runTurn(ctx, true);
    return if (report.exited) .exit else .continue_loop;
}

fn printReviewResult(stdout_writer: *std.Io.Writer, saved: branch_review.SavedReport) !void {
    const verdict = if (saved.outcome == .merge_worthy) "YES" else "NO";
    try stdout_writer.print(
        "\nReview report: {s}\nMERGE WORTHY: {s}\n",
        .{ saved.path, verdict },
    );
    try stdout_writer.flush();
}

fn printReviewWriteError(io: std.Io, err: anyerror) void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
    writer.interface.print("Review report could not be written: {s}\n", .{@errorName(err)}) catch {};
    writer.interface.flush() catch {};
}

/// Tears down and rebuilds the provider around a `messages_arena` reset.
///
/// The provider is allocated from `messages_arena`, so resetting the arena
/// without this dance leaves a dangling client. Shared by `/reset` and by the
/// orchestrate loop, which starts every phase from a clean conversation.
fn recycleMessagesArena(ctx: *ChatLoopContext) !void {
    ctx.prov.deinit();
    ctx.prov.* = .{ .mock = mock.MockClient.init(ctx.messages_arena.allocator(), ctx.io) };
    _ = ctx.messages_arena.reset(.free_all);
    ctx.messages.* = .empty;

    const new_api_key = try resolver.resolveApiKey(ctx.arena, ctx.io, ctx.parsed, ctx.cfg.*, ctx.model_provider.*, ctx.init.environ_map.get("PUNY_API_KEY"));
    ctx.prov.* = resolver.createProvider(ctx.parsed.mock, ctx.model_provider.*, ctx.provider_url.*, new_api_key, ctx.messages_arena.allocator(), ctx.io);
    if (ctx.debug_log) |log| attachHttpDebugObserver(ctx.prov, log);
}

/// Re-installs the standing system context after an arena reset: the system
/// prompt, the skills listing, and the repository instructions file.
fn installBaseContext(ctx: *ChatLoopContext) !void {
    const alloc = ctx.messages_arena.allocator();
    const system_prompt = try ctx.cfg.resolvePrompt(alloc, "system", prompts.system);
    try ctx.messages.append(alloc, .{ .system = system_prompt });

    if (!ctx.parsed.no_skills and ctx.skill_registry.count() > 0) {
        const skills_block = try ctx.skill_registry.buildListing(alloc);
        try ctx.messages.append(alloc, .{ .system = skills_block });
    }

    if (try git_root.findGitRepoRoot(ctx.arena, ctx.io)) |repo_root| {
        defer ctx.arena.free(repo_root);
        if (try instructions.load(ctx.arena, ctx.io, repo_root)) |result| {
            defer ctx.arena.free(result.filename);
            defer ctx.arena.free(result.content);
            const labeled = try std.fmt.allocPrint(alloc, "Instructions from {s}:\n{s}", .{ result.filename, result.content });
            try ctx.messages.append(alloc, .{ .system = labeled });
        }
    }
}

/// Gives the next orchestrate phase a clean conversation while keeping the
/// session itself: same directory, same `plan.md`, same accumulated token
/// stats, same prompt history. That is what separates a phase boundary from
/// `/reset`, which mints a whole new session.
fn resetContextForPhase(ctx: *ChatLoopContext) anyerror!void {
    persistence.saveMessages(ctx) catch {};
    try recycleMessagesArena(ctx);
    try installBaseContext(ctx);
}

/// One agentic turn that ignores `--oneshot`. The orchestrate loop drives
/// several turns inside a single invocation, so it cannot use `runChatTurn`,
/// which finalizes and exits the session as soon as a one-shot turn completes.
fn runManagedTurn(ctx: *ChatLoopContext) anyerror!orchestrate.TurnReport {
    return runTurn(ctx, false);
}

/// Starts an orchestrate run and records its verdict for the process exit code.
fn runOrchestrate(ctx: *ChatLoopContext, spec: orchestrate.Spec) !orchestrate.Status {
    const status = try orchestrate.run(ctx, spec, .{
        .run_turn = runManagedTurn,
        .reset_context = resetContextForPhase,
    });
    ctx.review_outcome.* = status.toOutcome();
    persistence.saveMessages(ctx) catch {};
    persistence.saveSessionMeta(ctx) catch {};
    upsertCurrentSession(ctx);
    return status;
}

fn enterReviewMode(ctx: *ChatLoopContext) !void {
    ctx.mode.* = .review;
    core_session.setWriteBlocked(true);
    const review_prompt = try ctx.cfg.resolvePrompt(ctx.messages_arena.allocator(), "review", prompts.review);
    try ctx.messages.append(ctx.messages_arena.allocator(), .{ .system = review_prompt });
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
    persistence.saveMessages(ctx) catch {};
    persistence.saveSessionMeta(ctx) catch {};
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
        .mode = ctx.mode.*,
        .planning_mode = ctx.mode.* == .planning,
        .first_prompt = persistence.firstUserPrompt(ctx.messages.items),
        .last_modified = now_ns,
    }) catch |err| {
        std.log.warn("failed to update sessions index: {s}", .{@errorName(err)});
    };
}
