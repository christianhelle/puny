const std = @import("std");
const input_bar = @import("tui/input_bar.zig");

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(message: []const u8, first_trace_address: ?usize) noreturn {
    input_bar.emergencyReset(&input_bar.global, writeStdoutRaw);
    std.debug.defaultPanic(message, first_trace_address);
}

fn writeStdoutRaw(bytes: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
}
const chat = @import("chat/chat.zig");
const stats = @import("chat/stats.zig");
const upgrade = @import("upgrade.zig");
const cli = @import("cli/args.zig");
const config = @import("config/config.zig");
const http_client = @import("providers/client.zig");
const model_selection = @import("models/select.zig");
const openai = @import("providers/openai.zig");
const core_sess = @import("core/session.zig");
const crash = @import("core/crash.zig");
const AgentMode = @import("core/mode.zig").AgentMode;
const git_root = @import("core/git_root.zig");
const log_files = @import("core/log_files.zig");
const sessions = @import("sessions/sessions.zig");
const prompt_history = @import("prompts/history.zig");
const prompt_file = @import("prompts/prompt_file.zig");
const prompts = @import("prompts/prompts.zig");
const provider = @import("providers/provider.zig");
const resolver = @import("providers/resolver.zig");
const session = @import("chat/session.zig");
const compact = @import("chat/compact.zig");
const pricing = @import("chat/pricing.zig");
const display = @import("chat/display.zig");
const diff_view = @import("chat/diff_view.zig");
const sigint = @import("core/sigint.zig");
const instructions = @import("agents/instructions.zig");
const skills = @import("skills/skills.zig");
const tools = @import("tools/root.zig");
const branch_review = @import("review/review.zig");
const welcome = @import("tui/welcome.zig");
const crash_prompt = @import("tui/crash_prompt.zig");
const ansi = @import("tui/ansi.zig");
const vt = @import("tui/vt.zig");
const update_check = @import("upgrade/update_check.zig");

comptime {
    // Keep the module analyzed so its tests run under `zig build test`.
    _ = update_check;
}
const ModelProvider = provider.ModelProvider;
const DebugLog = session.DebugLog;
const ChatLog = session.ChatLog;

pub fn main(init: std.process.Init) !u8 {
    return run(init) catch |err| {
        const arena = init.arena.allocator();
        crash.record(init.io, arena, init.environ_map, @errorName(err));
        if (!branch_review.isActive()) return err;
        const reason = try std.fmt.allocPrint(arena, "Review execution failed: {s}", .{@errorName(err)});
        const saved = branch_review.finish(arena, init.io, reason) catch |write_err| {
            branch_review.reset();
            printStandaloneReviewWriteError(init.io, write_err);
            return 2;
        };
        branch_review.reset();
        printStandaloneReviewResult(init.io, saved);
        return 2;
    };
}

fn run(init: std.process.Init) !u8 {
    vt.enableAnsi();
    vt.enableUtf8();
    const arena: std.mem.Allocator = init.arena.allocator();
    var messages_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const messages_arena = messages_arena_state.allocator();
    const startup_time = std.Io.Clock.Timestamp.now(init.io, .awake);

    upgrade.cleanupOldBackup(arena, init.io);

    const args_slice = try init.minimal.args.toSlice(arena);
    var parsed = cli.parseArgs(init.io, init.environ_map, args_slice);
    if (comptime @import("builtin").mode == .debug) {
        parsed.debug = true;
    }
    diff_view.enabled = diff_view.resolveEnabled(parsed.diff, std.Io.File.stdout().isTty(init.io) catch false);

    if (parsed.upgrade) {
        try upgrade.runUpgrade(arena, init.io, init.environ_map, parsed.force_upgrade);
        update_check.clearFlag(init.io, arena, init.environ_map) catch {};
        return 0;
    }

    // Detached child process entry: run the update check and exit quietly.
    // The child is marked with PUNY_UPDATE_CHECK=1 by the parent's spawn, so
    // this branch is only ever taken inside the detached process. The parent
    // surfaces the result via the flag file; the detached spawn discards stderr
    // and ignores the exit code, so failures stay silent here.
    if (std.mem.eql(u8, init.environ_map.get(update_check.check_env_var) orelse "", "1")) {
        _ = update_check.runCheck(init.io, arena, init.environ_map) catch {};
        return 0;
    }

    if (parsed.prune) {
        try runPrune(arena, init.io, init.environ_map, parsed.session orelse "");
        return 0;
    }

    // Load the prompt file up front so a missing file or URL fails fast,
    // before any provider/model initialization work happens. The loaded
    // content becomes the pending prompt, exactly like `--prompt`.
    if (parsed.prompt_file) |source| {
        parsed.prompt = loadPromptFileOrExit(arena, init.io, source);
    }

    var startup_review_scope: ?branch_review.Scope = null;
    if (parsed.review) {
        switch (try prepareStartupReview(arena, init.io)) {
            .exit => |code| return code,
            .ready => |scope| {
                startup_review_scope = scope;
                parsed.prompt = branch_review.request_prompt;
            },
        }
    }

    var debug_buffer: [4096]u8 = undefined;
    var debug_file_writer: std.Io.File.Writer = undefined;
    var debug_log: ?DebugLog = if (parsed.debug) blk: {
        const file = try createLogFile(init.io, log_files.http_log);
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
        const file = try createLogFile(init.io, log_files.chat_log);
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
    input_bar.global.out = &stdout_file_writer.interface;
    var screen_buffer: [1024]u8 = undefined;
    var screen_writer = input_bar.ScreenWriter.init(&stdout_file_writer.interface, &input_bar.global, &input_bar.screen_lock, &screen_buffer);
    const stdout_writer = &screen_writer.interface;

    if (parsed.reconfigure) {
        try runStartupReconfigure(arena, init.io, init, cfg, stdout_writer, !cfg_result.file_existed);
        // Ctrl+C at a setup prompt quits, as it does at the chat prompt.
        if (sigint.isTriggered()) return 0;
    }

    // Applied after reconfiguration, which can persist `cfg` to config.json:
    // a session-only override must never be written to disk.
    applyCliSystemPromptOverride(cfg, parsed.system_prompt);

    var random_source: std.Random.IoSource = .{ .io = init.io };
    const random = random_source.interface();

    const base_dir = try core_sess.sessionBaseDir(arena, init.environ_map);

    const restore_target = try findRestoreTarget(arena, init.io, base_dir, parsed, stdout_writer);

    // The session id is generated before the provider so every request,
    // the model list included, is attributed to this conversation.
    const session_id = if (restore_target) |s| s.id else try core_sess.generateUuid(random, arena);
    crash.setContext(.{ .session_id = session_id });

    var prov: provider.Provider = undefined;
    var selected_provider: ModelProvider = undefined;
    var provider_url: []const u8 = undefined;
    var model_key: []const u8 = undefined;
    var reasoning_effort: ?openai.ReasoningEffort = null;
    var model_context: ?model_selection.ModelContext = null;
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
        &model_context,
        session_id,
    );
    crash.setContext(.{
        .session_id = session_id,
        .provider = if (parsed.mock) "Mock" else provider.getProviderDisplayName(selected_provider),
        .model = model_key,
    });

    var session_restored = false;
    var restore_incomplete = false;
    var agent_mode: AgentMode = if (startup_review_scope != null) .review else .build;
    var review_outcome: ?branch_review.Outcome = null;
    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(messages_arena);

    var current_session = try openCurrentSession(
        arena,
        messages_arena,
        init.io,
        base_dir,
        restore_target,
        session_id,
    );

    var context_budget = compact.ContextBudget.init(parsed.max_context, cfg.max_context_tokens);
    context_budget.setStartupTier(parsed.context_tier orelse cfg.context_tier);
    var context_window: ?usize = null;
    if (model_context) |sizes| {
        context_budget.rememberModel(std.meta.activeTag(prov), model_key, sizes.default, sizes.long_context);
        if (context_budget.explicit == null) context_window = sizes.window(context_budget.tier);
    }

    try welcome.print(stdout_writer, .{
        .provider_name = if (parsed.mock) "Mock" else provider.getProviderDisplayName(selected_provider),
        .provider_url = provider_url,
        .model_key = model_key,
        .reasoning_effort = reasoning_effort,
        .context_window = context_window,
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

    crash_prompt.offer(arena, init.io, init.environ_map, .{
        .oneshot = parsed.oneshot,
        .review = parsed.review,
        .orchestrate = parsed.orchestrate,
        .mock = parsed.mock,
        .prefilled_prompt = parsed.prompt != null,
        .terminal = std.Io.File.stdin().isTty(init.io) catch false,
    }, stdout_writer);

    if (restore_target) |s| {
        const restore_result = try restoreAndShowSession(
            messages_arena,
            init.io,
            base_dir,
            s,
            &agent_mode,
            &messages,
            stdout_writer,
        );
        session_restored = restore_result.restored;
        restore_incomplete = restore_result.incomplete;
    }

    if (debug_log) |*log| session.attachHttpDebugObserver(&prov, log);
    defer prov.deinit();

    var full_tool_definitions = try buildToolDefinitions(arena, parsed.no_skills);
    defer full_tool_definitions.deinit(arena);

    var planning_tool_definitions = try buildPlanningToolDefinitions(arena, parsed.no_skills);
    defer planning_tool_definitions.deinit(arena);

    var review_tool_definitions = try buildReviewToolDefinitions(arena, parsed.no_skills);
    defer review_tool_definitions.deinit(arena);

    var skill_registry = skills.Registry.init(arena);
    defer skill_registry.deinit();
    if (!parsed.no_skills) try scanSkills(arena, init.io, init.environ_map, &skill_registry);
    skills.setGlobalRegistry(&skill_registry);

    if (!session_restored) {
        try session.appendBaseContext(
            messages_arena,
            arena,
            init.io,
            cfg,
            &skill_registry,
            &messages,
        );
        if (startup_review_scope) |scope| {
            core_sess.setWriteBlocked(true);
            const review_prompt = try cfg.resolvePrompt(messages_arena, "review", prompts.review);
            try messages.append(messages_arena, .{ .system = review_prompt });
            const review_context = try branch_review.buildPromptContext(messages_arena, scope);
            try messages.append(messages_arena, .{ .system = review_context });
        }
    } else if (parsed.system_prompt != null) {
        const system_prompt = try cfg.resolvePrompt(messages_arena, "system", prompts.system);
        overrideRestoredSystemPrompt(messages.items, system_prompt);
    }

    var session_stats = stats.SessionStats.init(arena, init.io);
    session_stats.session_id = current_session.id;
    defer session_stats.deinit();
    var pricing_book = pricing.PricingBook.init(arena, &prov);
    defer pricing_book.deinit();
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
        .review_tool_definitions = &review_tool_definitions,
        .messages = &messages,
        .mode = &agent_mode,
        .review_outcome = &review_outcome,
        .restore_incomplete = restore_incomplete,
        .session = &current_session,
        .session_stats = &session_stats,
        .pricing_book = &pricing_book,
        .debug_log = if (debug_log) |*log| log else null,
        .chat_log = if (chat_log) |*log| log else null,
        .skill_registry = &skill_registry,
        .context_budget = &context_budget,
    };

    var chat_session = session.ChatSession.init(ctx);
    crash.setPhase("chat turn");
    try chat_session.run();

    printPendingUpdateNotice(init.io, arena, init.environ_map, stdout_writer);
    return exitCode(parsed, review_outcome);
}

/// Loads skills from the user's and the repository's `.agents/skills`.
/// Skills are optional: a full scan that fails keeps the ones found so far.
fn scanSkills(
    arena: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    registry: *skills.Registry,
) !void {
    if (try skills.homeDir(arena, environ_map)) |home| {
        const global_path = try std.fs.path.join(arena, &.{ home, ".agents", "skills" });
        try registry.lightScan(io, global_path);
    }
    if (try git_root.findGitRepoRoot(arena, io)) |repo_root| {
        const repo_path = try std.fs.path.join(arena, &.{ repo_root, ".agents", "skills" });
        try registry.lightScan(io, repo_path);
    }
    registry.fullScan(io) catch |err| {
        std.log.warn("failed to load skills: {s}", .{@errorName(err)});
    };
}

/// Loads a saved conversation and, when it loads, replays it under a header
/// saying how long that took.
fn restoreAndShowSession(
    messages_arena: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    target: sessions.SessionInfo,
    agent_mode: *AgentMode,
    messages: *std.ArrayList(openai.Message),
    stdout_writer: *std.Io.Writer,
) !RestoreResult {
    const load_start = std.Io.Clock.Timestamp.now(io, .awake);
    const result = try loadRestoredSession(
        messages_arena,
        io,
        base_dir,
        target,
        agent_mode,
        messages,
        stdout_writer,
    );
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed_ns: u64 = @intCast(load_start.raw.durationTo(now.raw).nanoseconds);
    if (result.restored) {
        var header_buf: [256]u8 = undefined;
        try stdout_writer.print(
            "\n{s}\n",
            .{formatRestoreHeader(&header_buf, target.id, messages.items.len, elapsed_ns)},
        );
        try display.printConversation(stdout_writer, messages.items);
        try stdout_writer.flush();
    }
    return result;
}

/// Shows the notice the detached update check left, if it names a newer
/// version; a stale flag is cleared instead. Best-effort: the session is over.
fn printPendingUpdateNotice(
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    stdout_writer: *std.Io.Writer,
) void {
    const maybe_latest = update_check.availableUpdateIfNewer(io, arena, environ_map) catch return;
    const latest = maybe_latest orelse return;
    update_check.printUpdateNotice(stdout_writer, latest) catch {};
    stdout_writer.flush() catch {};
}

/// The process exit code: a review or orchestrate run reports its verdict, an
/// unreached verdict being an operational failure; a one-shot run reports one
/// when it ran a review. Everything else succeeded by getting here.
fn exitCode(parsed: cli.Options, review_outcome: ?branch_review.Outcome) u8 {
    if (parsed.review or parsed.orchestrate) {
        const outcome: branch_review.Outcome = review_outcome orelse .operational_failure;
        return outcome.exitCode();
    }
    if (parsed.oneshot) {
        if (review_outcome) |outcome| return outcome.exitCode();
    }
    return 0;
}

/// `--prune`: deletes every saved session except `keep_id`, when given.
fn runPrune(
    arena: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    keep_id: []const u8,
) !void {
    var buf: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const base_dir = try core_sess.sessionBaseDir(arena, environ_map);
    try sessions.pruneSessions(arena, io, base_dir, keep_id);
    if (keep_id.len > 0) {
        try out.interface.print("Pruned all sessions except '{s}'.\n", .{keep_id});
    } else {
        try out.interface.print("Pruned all sessions.\n", .{});
    }
    try out.interface.flush();
}

/// Returns the prompt `--prompt-file` names, or explains the failure and
/// exits: a run with no prompt to send has nothing to do.
fn loadPromptFileOrExit(arena: std.mem.Allocator, io: std.Io, source: []const u8) []const u8 {
    switch (prompt_file.load(arena, io, source)) {
        .ok => |content| {
            if (content.len == 0) {
                printStartupError(io, source, "prompt file is empty");
                std.process.exit(1);
            }
            return content;
        },
        .err => |e| {
            defer if (e.owned) arena.free(e.message);
            printStartupError(io, source, e.message);
            std.process.exit(1);
        },
    }
}

const StartupReview = union(enum) {
    /// The review was settled without a model: exit with this code.
    exit: u8,
    /// The review has begun and the model runs on this scope.
    ready: branch_review.Scope,
};

/// `--review`: settles a branch that cannot be reviewed or has no changes on
/// the spot, and otherwise begins the review the model will run.
fn prepareStartupReview(arena: std.mem.Allocator, io: std.Io) !StartupReview {
    switch (try branch_review.prepare(arena, io)) {
        .invalid => |failure| {
            printStandaloneReviewError(io, failure.message);
            return .{ .exit = 2 };
        },
        .operational_failure => |failure| {
            const saved = branch_review.writeOperationalFailure(arena, io, failure) catch |err| {
                printStandaloneReviewWriteError(io, err);
                return .{ .exit = 2 };
            };
            printStandaloneReviewResult(io, saved);
            return .{ .exit = saved.outcome.exitCode() };
        },
        .no_changes => |scope| {
            const saved = branch_review.writeNoChanges(arena, io, scope) catch |err| {
                printStandaloneReviewWriteError(io, err);
                return .{ .exit = 2 };
            };
            printStandaloneReviewResult(io, saved);
            return .{ .exit = saved.outcome.exitCode() };
        },
        .ready => |scope| {
            branch_review.begin(scope);
            return .{ .ready = scope };
        },
    }
}

/// Creates (or truncates) a debug log in the working directory, owner-only
/// where the platform allows: it records prompts and provider traffic.
fn createLogFile(io: std.Io, path: []const u8) !std.Io.File {
    const posix = comptime @import("builtin").os.tag != .windows;
    // A new log is owner-only from creation; the chmod below covers one that
    // already existed with a wider mode.
    const options: std.Io.Dir.CreateFileOptions =
        if (posix) .{ .permissions = @fromBackingInt(0o600) } else .{};
    const file = try std.Io.Dir.cwd().createFile(io, path, options);
    if (posix) {
        std.Io.Dir.cwd().setFilePermissions(io, path, @fromBackingInt(0o600), .{}) catch |err| {
            std.log.warn("failed to restrict permissions on {s}: {s}", .{ path, @errorName(err) });
        };
    }
    return file;
}

/// The saved session `--session` or `--resume` asks for, or null for a fresh
/// one. A session that cannot be found or has nothing to restore is
/// explained, and the run starts fresh.
fn findRestoreTarget(
    arena: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    parsed: cli.Options,
    stdout_writer: *std.Io.Writer,
) !?sessions.SessionInfo {
    if (parsed.session) |sid| {
        const maybe_found = sessions.findSessionByPrefix(
            arena,
            io,
            base_dir,
            sid,
        ) catch return null;
        const found = maybe_found orelse {
            try stdout_writer.print("Session '{s}' not found. Starting fresh.\n", .{sid});
            try stdout_writer.flush();
            return null;
        };
        if (found.has_conversation) return found;
        try stdout_writer.print(
            "Session '{s}' has no saved conversation. Starting fresh.\n",
            .{sid},
        );
        try stdout_writer.flush();
        return null;
    }
    if (parsed.do_resume) {
        const latest = sessions.findLatestSession(arena, io, base_dir) catch return null;
        if (latest == null) {
            try stdout_writer.print("No saved conversations found. Starting fresh.\n", .{});
            try stdout_writer.flush();
        }
        return latest;
    }
    return null;
}

/// The session this run writes to: the restored one's directory, or a new
/// one under `session_id`.
fn openCurrentSession(
    arena: std.mem.Allocator,
    messages_arena: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    restore_target: ?sessions.SessionInfo,
    session_id: []const u8,
) !core_sess.Session {
    const restored = restore_target orelse return core_sess.Session.initWithId(
        arena,
        base_dir,
        session_id,
        io,
    );
    std.debug.assert(std.mem.eql(u8, restored.id, session_id));
    const dir = try std.fs.path.join(messages_arena, &.{ base_dir, "sessions", restored.id });
    return core_sess.Session.fromDir(
        arena,
        restored.id,
        base_dir,
        dir,
        try std.fs.path.join(messages_arena, &.{ dir, "plan.md" }),
        try std.fs.path.join(messages_arena, &.{ dir, "plan.html" }),
    );
}

fn printStandaloneReviewError(io: std.Io, message: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
    writer.interface.print("Review could not start: {s}\n", .{message}) catch {};
    writer.interface.flush() catch {};
}

fn printStandaloneReviewResult(io: std.Io, saved: branch_review.SavedReport) void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const verdict = if (saved.outcome == .merge_worthy) "YES" else "NO";
    writer.interface.print("Review report: {s}\nMERGE WORTHY: {s}\n", .{ saved.path, verdict }) catch {};
    writer.interface.flush() catch {};
}

fn printStandaloneReviewWriteError(io: std.Io, err: anyerror) void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
    writer.interface.print("Review report could not be written: {s}\n", .{@errorName(err)}) catch {};
    writer.interface.flush() catch {};
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
    try stdout_writer.print("{s}Startup time: {s}{s}\n", .{
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
    agent_mode: *AgentMode,
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

    agent_mode.* = s.mode;
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

/// Explains a provider whose server did not answer, so a stopped local server
/// ends startup with a hint instead of a raw socket error.
fn printProviderUnreachable(io: std.Io, selected_provider: ModelProvider, url: []const u8) void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;
    stderr_writer.print(
        "Could not connect to {s} at {s}. Make sure it is running, or pick another provider with --provider or --reconfigure.\n",
        .{ provider.getProviderDisplayName(selected_provider), url },
    ) catch {};
    stderr_writer.flush() catch {};
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
    model_context: *?model_selection.ModelContext,
    session_id: []const u8,
) !void {
    selected_provider.* = try resolver.effectiveProvider(parsed, cfg.*);
    provider_url.* = if (parsed.mock) "-" else resolver.baseUrlFor(selected_provider.*, parsed, cfg.*);
    const api_key = try resolver.resolveApiKey(arena, io, parsed, cfg.*, selected_provider.*, resolver.apiKeyEnv(init.environ_map, selected_provider.*));

    if (resolver.missingRequiredApiKey(parsed.mock, selected_provider.*, api_key)) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print(
            "Provider '{s}' requires an API key. Set one with --api-key, {s}, or --reconfigure.\n",
            .{ provider.getProviderDisplayName(selected_provider.*), resolver.apiKeyEnvNames(selected_provider.*) },
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

    prov.* = resolver.createProvider(parsed.mock, selected_provider.*, provider_url.*, api_key, provider_arena, io, session_id);
    errdefer prov.deinit();
    if (!parsed.mock) try resolver.ensureCopilotAuth(arena, io, init, cfg, stdout_writer, prov);

    // A configured model is trusted at startup rather than checked against
    // the provider's model list: that request would delay the welcome
    // screen. The context window is looked up on the first request instead,
    // and an unknown model surfaces as that request's error.
    const skip_validation = true;
    const init_result = (model_selection.select(
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
    ) catch |err| {
        if (err == error.ProviderUnreachable) printProviderUnreachable(io, selected_provider.*, provider_url.*);
        return err;
    }) orelse blk: {
        if (configured_model) |model_id| {
            try stdout_writer.print(
                "Model '{s}' not found in running models. Showing picker.\n",
                .{model_id},
            );
        }
        break :blk (model_selection.select(
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
        ) catch |err| {
            if (err == error.ProviderUnreachable) printProviderUnreachable(io, selected_provider.*, provider_url.*);
            return err;
        }) orelse {
            try stdout_writer.print("No model selected.\n", .{});
            return;
        };
    };
    model_key.* = init_result.model_key;
    model_context.* = init_result.context;
    reasoning_effort.* = resolveReasoningEffort(
        parsed.effort,
        init_result.reasoning_effort,
        cfg.providerEntry(selected_provider.*).reasoning_effort,
    );
}

/// Settles which reasoning effort a session starts with, following the same
/// command line over environment over config order as every other option.
/// `flag` already carries the environment fallback, `selected` comes from the
/// interactive picker, and `configured` is the level stored for the provider.
fn resolveReasoningEffort(
    flag: ?openai.ReasoningEffort,
    selected: ?openai.ReasoningEffort,
    configured: ?[]const u8,
) ?openai.ReasoningEffort {
    if (flag) |effort| return effort;
    if (selected) |effort| return effort;
    if (configured) |text| return std.meta.stringToEnum(openai.ReasoningEffort, text);
    return null;
}

/// The `--system-prompt` flag takes precedence over any override already
/// loaded from the config file.
fn applyCliSystemPromptOverride(cfg: *config.Config, cli_override: ?[]const u8) void {
    if (cli_override) |value| cfg.prompts.system.override = value;
}

/// Replaces the first system message of a restored session so `--system-prompt`
/// still takes effect when `--resume` or `--session` skips the fresh-session
/// context build. A no-op when the restored conversation has no system message.
fn overrideRestoredSystemPrompt(messages: []openai.Message, new_prompt: []const u8) void {
    for (messages) |*message| {
        if (message.* == .system) {
            message.* = .{ .system = new_prompt };
            return;
        }
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

fn buildReviewToolDefinitions(arena: std.mem.Allocator, no_skills: bool) !std.ArrayList(openai.ToolDefinition) {
    var definitions: std.ArrayList(openai.ToolDefinition) = .empty;
    errdefer definitions.deinit(arena);
    for (tools.review_registry) |tool| {
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

test "exitCode reports a review or orchestrate verdict and treats none as a failure" {
    try std.testing.expectEqual(@as(u8, 0), exitCode(.{ .review = true }, .merge_worthy));
    try std.testing.expectEqual(@as(u8, 1), exitCode(.{ .review = true }, .rejected));
    try std.testing.expectEqual(@as(u8, 2), exitCode(.{ .review = true }, null));
    try std.testing.expectEqual(@as(u8, 2), exitCode(.{ .orchestrate = true }, null));
}

test "exitCode reports a one-shot review verdict and succeeds otherwise" {
    try std.testing.expectEqual(@as(u8, 1), exitCode(.{ .oneshot = true }, .rejected));
    try std.testing.expectEqual(@as(u8, 0), exitCode(.{ .oneshot = true }, null));
    try std.testing.expectEqual(@as(u8, 0), exitCode(.{}, .rejected));
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

fn toolNames(arena: std.mem.Allocator, definitions: []const openai.ToolDefinition) ![][]const u8 {
    const names = try arena.alloc([]const u8, definitions.len);
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
    const names = try toolNames(arena, definitions.items);
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
    const names = try toolNames(arena, definitions.items);
    for (names) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "load_skill"));
    }
    try std.testing.expect(definitions.items.len > 0);
}

test "test runner suppresses warning logs" {
    std.log.warn("expected warning from regression test", .{});
    try std.testing.expectEqual(std.log.Level.err, std.testing.log_level);
}

test "test runner suppresses unexpected error stack traces" {
    try std.testing.expect(!std.options.unexpected_error_tracing);
}

test "include all module tests" {
    if (@import("build_options").slow_tests) {
        _ = @import("testing/slow_tests.zig");
    } else {
        _ = @import("testing/test_runner.zig");
    }
}

test "createLogFile makes an owner-only log on posix" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, log_files.http_log },
    );
    defer std.testing.allocator.free(path);

    const file = try createLogFile(std.testing.io, path);
    file.close(std.testing.io);

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "debug logging is always enabled for debug builds" {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/main.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(data);
    const needle_mode = "comptime @import(\"builtin\").mode" ++ " == .debug";
    const needle_assign = "parsed.debug" ++ " = true";
    try std.testing.expect(std.mem.indexOf(u8, data, needle_mode) != null);
    try std.testing.expect(std.mem.indexOf(u8, data, needle_assign) != null);
    const parse_idx = std.mem.indexOf(u8, data, "parseArgs") orelse 0;
    const mode_idx = std.mem.indexOf(u8, data, needle_mode) orelse 0;
    try std.testing.expect(mode_idx > parse_idx);
}

test "resolveReasoningEffort prefers the command line over everything else" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .low),
        resolveReasoningEffort(.low, .high, "medium"),
    );
}

test "resolveReasoningEffort uses the picked level when no flag is given" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .high),
        resolveReasoningEffort(null, .high, "medium"),
    );
}

test "resolveReasoningEffort falls back to the configured level" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, .medium),
        resolveReasoningEffort(null, null, "medium"),
    );
}

test "resolveReasoningEffort leaves the level unset when nothing is configured" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, null),
        resolveReasoningEffort(null, null, null),
    );
}

test "resolveReasoningEffort ignores an unrecognised configured level" {
    try std.testing.expectEqual(
        @as(?openai.ReasoningEffort, null),
        resolveReasoningEffort(null, null, "enthusiastic"),
    );
}

test "applyCliSystemPromptOverride sets the config override from the flag" {
    var cfg = config.Config{};
    applyCliSystemPromptOverride(&cfg, "You are a pirate.");
    try std.testing.expectEqualStrings("You are a pirate.", cfg.prompts.system.override.?);
}

test "applyCliSystemPromptOverride leaves the config override untouched without a flag" {
    var cfg = config.Config{};
    cfg.prompts.system.override = "from config file";
    applyCliSystemPromptOverride(&cfg, null);
    try std.testing.expectEqualStrings("from config file", cfg.prompts.system.override.?);
}

test "overrideRestoredSystemPrompt replaces the first system message" {
    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.append(std.testing.allocator, .{ .system = "old system prompt" });
    try messages.append(std.testing.allocator, .{ .user = "hi" });

    overrideRestoredSystemPrompt(messages.items, "new system prompt");

    try std.testing.expectEqualStrings("new system prompt", messages.items[0].system);
    try std.testing.expectEqualStrings("hi", messages.items[1].user);
}

test "overrideRestoredSystemPrompt is a no-op without a system message" {
    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.append(std.testing.allocator, .{ .user = "hi" });

    overrideRestoredSystemPrompt(messages.items, "new system prompt");

    try std.testing.expectEqualStrings("hi", messages.items[0].user);
}

test "printStartupTime ends its line" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try printStartupTime(std.testing.io, &out.writer, std.Io.Clock.Timestamp.now(std.testing.io, .awake));

    try std.testing.expect(std.mem.startsWith(u8, out.written(), ansi.dim ++ "Startup time: "));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), ansi.reset ++ "\n"));
}
