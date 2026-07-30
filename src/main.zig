const std = @import("std");
const chat = @import("chat/chat.zig");
const cli = @import("cli/args.zig");
const config = @import("config/config.zig");
const helpers = @import("tools/helpers.zig");
const http_client = @import("providers/client.zig");
const model_selection = @import("models/select.zig");
const openai = @import("providers/openai.zig");
const core_sess = @import("core/session.zig");
const prompt_history = @import("prompts/history.zig");
const prompts = @import("prompts/prompts.zig");
const provider = @import("providers/provider.zig");
const session = @import("chat/session.zig");
const sigint = @import("core/sigint.zig");
const instructions = @import("agents/instructions.zig");
const skills = @import("skills/skills.zig");
const tools = @import("tools/root.zig");
const version = @import("version.zig");
const welcome = @import("tui/welcome.zig");
const ansi = @import("tui/ansi.zig");
const ModelProvider = provider.ModelProvider;
const DebugLog = session.DebugLog;
const ChatLog = session.ChatLog;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    var messages_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const messages_arena = messages_arena_state.allocator();
    const io = init.io;

    cleanupOldBackup(arena, io);

    const args_slice = try init.minimal.args.toSlice(arena);
    var parsed = cli.parseArgs(io, init.environ_map, args_slice);

    if (parsed.upgrade) {
        try runUpgrade(arena, io, init.environ_map, parsed.force_upgrade);
        return;
    }

    if (parsed.prune) {
        var buf: [1024]u8 = undefined;
        var out: std.Io.File.Writer = .init(.stdout(), io, &buf);
        const base_dir = try core_sess.sessionBaseDir(arena, init.environ_map);
        const keep_id = parsed.session orelse "";
        try core_sess.pruneSessions(arena, io, base_dir, keep_id);
        if (keep_id.len > 0) {
            try out.interface.print("Pruned all sessions except '{s}'.\n", .{keep_id});
        } else {
            try out.interface.print("Pruned all sessions.\n", .{});
        }
        try out.interface.flush();
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

    var chat_buffer: [4096]u8 = undefined;
    var chat_file_writer: std.Io.File.Writer = undefined;
    var chat_log: ?ChatLog = if (parsed.chat_log) blk: {
        const file = try std.Io.Dir.cwd().createFile(io, "puny_chat.log", .{});
        if (comptime @import("builtin").os.tag != .windows) {
            std.Io.Dir.cwd().setFilePermissions(io, "puny_chat.log", @enumFromInt(0o600), .{}) catch {};
        }
        chat_file_writer = .init(file, io, &chat_buffer);
        break :blk ChatLog{
            .file = file,
            .writer = &chat_file_writer.interface,
        };
    } else null;
    defer if (chat_log) |*log| {
        log.writer.flush() catch {};
        log.file.close(io);
    };

    var cfg_result = try config.load(arena, io, init.environ_map);
    defer cfg_result.deinit();
    const cfg = &cfg_result.config;

    if (!cfg_result.file_existed and !parsed.reconfigure) {
        parsed.reconfigure = true;
    }

    var history = try loadHistory(arena, io, init.environ_map);
    defer history.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    if (parsed.reconfigure) {
        try runStartupReconfigure(arena, io, init, cfg, stdout_writer, !cfg_result.file_existed);
    }

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    const base_dir = try core_sess.sessionBaseDir(arena, init.environ_map);
    var current_session = try core_sess.Session.init(arena, base_dir, random, io);

    var prov: provider.Provider = undefined;
    var selected_provider: ModelProvider = undefined;
    var provider_url: []const u8 = undefined;
    var model_key: []const u8 = undefined;
    var reasoning_effort: ?openai.ReasoningEffort = null;
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
        &reasoning_effort,
    );
    var startup_time = std.Io.Clock.Timestamp.now(io, .awake);
    try welcome.print(stdout_writer, .{
        .provider_name = if (parsed.mock) "Mock" else provider.getProviderDisplayName(selected_provider),
        .provider_url = provider_url,
        .model_key = model_key,
        .reasoning_effort = reasoning_effort,
        .session_id = current_session.id,
        .oneshot = parsed.oneshot,
        .prefilled = parsed.prompt != null,
    });

    const now = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed_ns: u64 = @intCast(startup_time.raw.durationTo(now.raw).nanoseconds);
    var startup_buf: [64]u8 = undefined;
    try stdout_writer.print("{s}Startup time: {s}{s}", .{
        ansi.dim, formatStartupTime(&startup_buf, elapsed_ns), ansi.reset,
    });
    try stdout_writer.flush();

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
    skill_registry.fullScan(io) catch {};
    skills.setGlobalRegistry(&skill_registry);

    var session_restored = false;
    var messages: std.ArrayList(openai.Message) = .empty;
    defer messages.deinit(messages_arena);

    if (parsed.session) |sid| {
        if (core_sess.findSessionByPrefix(arena, io, base_dir, sid)) |maybe_s| {
            if (maybe_s) |s| {
                session_restored = try restoreSessionAtStartup(
                    arena,
                    messages_arena,
                    io,
                    base_dir,
                    s,
                    &current_session,
                    &planning_mode,
                    &messages,
                    stdout_writer,
                );
            } else {
                try stdout_writer.print("Session '{s}' not found. Starting fresh.\n", .{sid});
                try stdout_writer.flush();
            }
        } else |_| {}
    } else if (parsed.do_resume) {
        if (core_sess.listSessions(arena, io, base_dir)) |sessions| {
            var conv_count: usize = 0;
            var found: ?core_sess.SessionInfo = null;
            for (sessions) |s| {
                if (s.has_conversation) {
                    conv_count += 1;
                    found = s;
                }
            }
            if (conv_count == 1) {
                if (found) |s| {
                    session_restored = try restoreSessionAtStartup(
                        arena,
                        messages_arena,
                        io,
                        base_dir,
                        s,
                        &current_session,
                        &planning_mode,
                        &messages,
                        stdout_writer,
                    );
                }
            } else if (conv_count > 1) {
                try stdout_writer.print("{d} sessions have saved conversations. Use /resume in the chat to pick one.\n", .{conv_count});
                try stdout_writer.flush();
            } else {
                try stdout_writer.print("No saved conversations found. Starting fresh.\n", .{});
                try stdout_writer.flush();
            }
        } else |_| {}
    }

    if (!session_restored) {
        const system_prompt = try cfg.resolvePrompt(messages_arena, "system", prompts.system);
        try messages.append(messages_arena, .{ .system = system_prompt });
        if (skill_registry.count() > 0) {
            const skills_block = try skill_registry.buildListing(messages_arena);
            try messages.append(messages_arena, .{ .system = skills_block });
        }
        if (try skills.findGitRepoRoot(arena, io)) |repo_root| {
            defer arena.free(repo_root);
            if (try instructions.load(arena, io, repo_root)) |result| {
                defer arena.free(result.filename);
                defer arena.free(result.content);
                const labeled = try std.fmt.allocPrint(messages_arena, "Instructions from {s}:\n{s}", .{ result.filename, result.content });
                try messages.append(messages_arena, .{ .system = labeled });
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
        .reasoning_effort = &reasoning_effort,
        .full_tool_definitions = &full_tool_definitions,
        .planning_tool_definitions = &planning_tool_definitions,
        .messages = &messages,
        .planning_mode = &planning_mode,
        .session = &current_session,
        .session_stats = &session_stats,
        .debug_log = if (debug_log) |*log| log else null,
        .chat_log = if (chat_log) |*log| log else null,
        .skill_registry = &skill_registry,
    };

    var chat_session = session.ChatSession.init(ctx);
    try chat_session.run();
}

fn cleanupOldBackup(allocator: std.mem.Allocator, io: std.Io) void {
    const exe_path = std.process.executablePathAlloc(io, allocator) catch return;
    defer allocator.free(exe_path);
    const old_path = std.fmt.allocPrint(allocator, "{s}.old", .{exe_path}) catch return;
    defer allocator.free(old_path);
    std.Io.Dir.deleteFileAbsolute(io, old_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            var buf: [512]u8 = undefined;
            var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
            w.interface.print("warning: failed to remove old backup: {s}\n", .{@errorName(err)}) catch {};
            w.interface.flush() catch {};
        },
    };
}

fn archiveNameForTarget() []const u8 {
    const target = @import("builtin").target;
    const aarch = target.cpu.arch;
    const os = target.os.tag;
    if (aarch == .aarch64) {
        return switch (os) {
            .windows => "puny-windows-aarch64.zip",
            .linux => "puny-linux-aarch64.tar.gz",
            .macos => "puny-macos-aarch64.tar.gz",
            else => @compileError("unsupported OS for upgrade"),
        };
    } else if (aarch == .x86_64) {
        return switch (os) {
            .windows => "puny-windows-x86_64.zip",
            .linux => "puny-linux-x86_64.tar.gz",
            .macos => "puny-macos-x86_64.tar.gz",
            else => @compileError("unsupported OS for upgrade"),
        };
    }
    @compileError("unsupported CPU architecture for upgrade");
}

fn upgradeTempParent(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("TMPDIR")) |t| return try arena.dupe(u8, t);
    if (environ_map.get("TEMP")) |t| return try arena.dupe(u8, t);
    if (environ_map.get("TMP")) |t| return try arena.dupe(u8, t);
    if (comptime @import("builtin").os.tag == .windows) return try arena.dupe(u8, "C:\\Windows\\Temp");
    return try arena.dupe(u8, "/tmp");
}

fn runUpgrade(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, force: bool) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    try stderr_writer.print("\nChecking for updates...\n", .{});
    try stderr_writer.flush();

    const release_url = "https://api.github.com/repos/christianhelle/puny/releases/latest";
    const json_bytes = try helpers.httpGet(arena, io, release_url);
    defer arena.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{});
    defer parsed.deinit();

    const tag_name = parsed.value.object.get("tag_name") orelse return error.MissingReleaseTag;
    const latest_tag = tag_name.string;
    const latest_ver_str = if (std.mem.startsWith(u8, latest_tag, "v")) latest_tag[1..] else latest_tag;

    const current_ver = try std.SemanticVersion.parse(version.version);
    const latest_ver = try std.SemanticVersion.parse(latest_ver_str);

    if (!force and current_ver.order(latest_ver) != .lt) {
        try stderr_writer.print("Already up to date (v{s}). Use --force to upgrade anyway.\n", .{version.version});
        try stderr_writer.flush();
        return;
    }

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();
    const unique = random.int(u64);
    var unique_buf: [32]u8 = undefined;
    const unique_str = try std.fmt.bufPrint(&unique_buf, "{x}", .{unique});
    const tmp_parent = try upgradeTempParent(arena, environ_map);
    defer arena.free(tmp_parent);
    const tmp_rel_name = try std.fmt.allocPrint(arena, "puny-upgrade-{s}", .{unique_str});
    defer arena.free(tmp_rel_name);
    const tmp_dir_path = try std.fs.path.join(arena, &.{ tmp_parent, tmp_rel_name });
    defer arena.free(tmp_dir_path);

    try std.Io.Dir.createDirAbsolute(io, tmp_dir_path, @enumFromInt(0o755));
    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp_dir_path, .{ .iterate = true });
    errdefer {
        tmp_dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, tmp_dir_path) catch {};
    }

    const archive_name = archiveNameForTarget();
    const download_url = try std.fmt.allocPrint(arena, "https://github.com/christianhelle/puny/releases/download/{s}/{s}", .{ latest_tag, archive_name });
    defer arena.free(download_url);

    try stderr_writer.print("Downloading {s}...\n", .{archive_name});
    try stderr_writer.flush();
    try helpers.httpDownloadFile(arena, io, download_url, tmp_dir, archive_name);

    try stderr_writer.print("Extracting...\n", .{});
    try stderr_writer.flush();

    const binary_name = if (@import("builtin").os.tag == .windows) "puny.exe" else "puny";

    if (@import("builtin").os.tag == .windows) {
        var archive_buf: [4096]u8 = undefined;
        var archive_file = try tmp_dir.openFile(io, archive_name, .{});
        defer archive_file.close(io);
        var archive_reader = archive_file.reader(io, &archive_buf);
        try std.zip.extract(tmp_dir, &archive_reader, .{});
    } else {
        var archive_buf: [4096]u8 = undefined;
        var tar_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var archive_file = try tmp_dir.openFile(io, archive_name, .{});
        defer archive_file.close(io);
        var archive_reader = archive_file.reader(io, &archive_buf);
        var decompress = std.compress.flate.Decompress.init(&archive_reader.interface, .gzip, &tar_buf);
        try std.tar.extract(io, tmp_dir, &decompress.reader, .{});
    }

    const extracted_path = (try findInDir(arena, io, tmp_dir, binary_name)) orelse return error.BinaryNotFoundInArchive;
    defer arena.free(extracted_path);

    try stderr_writer.print("Installing...\n", .{});
    try stderr_writer.flush();

    const exe_path = try std.process.executablePathAlloc(io, arena);
    defer arena.free(exe_path);
    const exe_dir_path = std.fs.path.dirname(exe_path) orelse ".";
    const exe_name = std.fs.path.basename(exe_path);

    var exe_dir = try std.Io.Dir.cwd().openDir(io, exe_dir_path, .{});
    defer exe_dir.close(io);

    if (@import("builtin").os.tag == .windows) {
        const update_name = try std.fmt.allocPrint(arena, "{s}.update", .{exe_name});
        defer arena.free(update_name);
        try std.Io.Dir.copyFile(tmp_dir, extracted_path, exe_dir, update_name, io, .{});

        const full_update_path = try std.fs.path.join(arena, &.{ exe_dir_path, update_name });
        defer arena.free(full_update_path);

        const batch_name = try std.fmt.allocPrint(arena, "puny-upgrade-{s}.bat", .{unique_str});
        defer arena.free(batch_name);
        const batch_path = try std.fs.path.join(arena, &.{ exe_dir_path, batch_name });
        defer arena.free(batch_path);

        const batch_body = try std.fmt.allocPrint(arena, "@echo off\r\n" ++
            ":retry\r\n" ++
            "del \"{s}\" > nul 2>&1\r\n" ++
            "if exist \"{s}\" (\r\n" ++
            "  ping 127.0.0.1 -n 3 > nul\r\n" ++
            "  goto retry\r\n" ++
            ")\r\n" ++
            "copy /Y \"{s}\" \"{s}\" > nul\r\n" ++
            "del \"{s}\" > nul\r\n" ++
            "rmdir /S /Q \"{s}\" > nul 2>&1\r\n" ++
            "del /Q \"{s}\" > nul 2>&1\r\n", .{ exe_path, exe_path, full_update_path, exe_path, full_update_path, tmp_dir_path, batch_path });
        defer arena.free(batch_body);

        var batch_file = try exe_dir.createFile(io, batch_name, .{});
        defer batch_file.close(io);
        try batch_file.writeStreamingAll(io, batch_body);

        _ = try std.process.spawn(io, .{
            .argv = &[_][]const u8{ "cmd", "/c", batch_path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
    } else {
        const new_name = try std.fmt.allocPrint(arena, "{s}.new", .{exe_name});
        defer arena.free(new_name);
        const old_name = try std.fmt.allocPrint(arena, "{s}.old", .{exe_name});
        defer arena.free(old_name);

        try std.Io.Dir.copyFile(tmp_dir, extracted_path, exe_dir, new_name, io, .{});
        std.Io.Dir.setFilePermissions(exe_dir, io, new_name, @enumFromInt(0o755), .{}) catch {};

        try std.Io.Dir.rename(exe_dir, exe_name, exe_dir, old_name, io);
        errdefer std.Io.Dir.rename(exe_dir, old_name, exe_dir, exe_name, io) catch {};

        std.Io.Dir.rename(exe_dir, new_name, exe_dir, exe_name, io) catch |err| {
            std.Io.Dir.rename(exe_dir, old_name, exe_dir, exe_name, io) catch {};
            std.Io.Dir.deleteFile(exe_dir, io, new_name) catch {};
            return err;
        };

        std.Io.Dir.deleteFile(exe_dir, io, old_name) catch {};
    }

    tmp_dir.close(io);
    if (@import("builtin").os.tag != .windows) {
        std.Io.Dir.cwd().deleteTree(io, tmp_dir_path) catch {};
    }

    try stderr_writer.print("Upgraded to v{s}. Restart to use the new version.\n", .{latest_ver_str});
    try stderr_writer.flush();
}

fn findInDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !?[]const u8 {
    var walk = try dir.walk(allocator);
    defer walk.deinit();
    while (try walk.next(io)) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.basename, name)) {
            return try allocator.dupe(u8, entry.path);
        }
    }
    return null;
}

fn loadHistory(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !prompt_history.History {
    const history_path = try prompt_history.historyPath(arena, environ_map);
    var history = prompt_history.History.init(arena, history_path);
    history.load(io) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    return history;
}

fn restoreSessionAtStartup(
    arena: std.mem.Allocator,
    msg_alloc: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    s: core_sess.SessionInfo,
    current_session: *core_sess.Session,
    planning_mode: *bool,
    messages: *std.ArrayList(openai.Message),
    stdout_writer: *std.Io.Writer,
) !bool {
    const dir = try std.fs.path.join(msg_alloc, &.{ base_dir, "sessions", s.id });
    defer msg_alloc.free(dir);

    const msg_path = try std.fs.path.join(msg_alloc, &.{ dir, "messages.json" });
    defer msg_alloc.free(msg_path);

    var file = std.Io.Dir.cwd().openFile(io, msg_path, .{}) catch {
        try stdout_writer.print("Session '{s}' has no saved conversation. Starting fresh.\n", .{s.id});
        try stdout_writer.flush();
        return false;
    };
    defer file.close(io);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, msg_path, msg_alloc, std.Io.Limit.limited(10 * 1024 * 1024));
    defer msg_alloc.free(data);

    const parsed_val = try std.json.parseFromSlice(std.json.Value, msg_alloc, data, .{});
    defer parsed_val.deinit();

    for (parsed_val.value.array.items) |item| {
        if (openai.Message.fromJsonValue(msg_alloc, item)) |msg| {
            try messages.append(msg_alloc, msg);
        } else |_| {}
    }

    current_session.* = try core_sess.Session.fromDir(
        arena,
        s.id,
        base_dir,
        dir,
        try std.fs.path.join(msg_alloc, &.{ dir, "plan.md" }),
        try std.fs.path.join(msg_alloc, &.{ dir, "plan.html" }),
    );
    planning_mode.* = s.planning_mode;
    try stdout_writer.print("Restored session {s} — {d} messages:\n", .{ s.id, messages.items.len });
    try session.printConversation(stdout_writer, messages.items);
    try stdout_writer.flush();
    return true;
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
        const raw = if (reconfigure_force_picker) null else parsed.model orelse if (selected_provider.* == .mock) null else cfg.providerEntry(selected_provider.*).model;
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

fn formatStartupTime(buf: []u8, elapsed_ns: u64) []const u8 {
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

test "formatStartupTime formats sub-millisecond as µs" {
    var buf: [64]u8 = undefined;
    const result = formatStartupTime(&buf, 5000);
    try std.testing.expectEqualStrings("5 µs", result);
}

test "formatStartupTime formats milliseconds" {
    var buf: [64]u8 = undefined;
    const result = formatStartupTime(&buf, 42_000_000);
    try std.testing.expectEqualStrings("42 ms", result);
}

test "formatStartupTime formats seconds" {
    var buf: [64]u8 = undefined;
    const result = formatStartupTime(&buf, 2_500_000_000);
    try std.testing.expectEqualStrings("2.5 s", result);
}

test "formatStartupTime handles zero" {
    var buf: [64]u8 = undefined;
    const result = formatStartupTime(&buf, 0);
    try std.testing.expectEqualStrings("0 ns", result);
}

test "formatStartupTime boundary between ns and µs" {
    var buf: [64]u8 = undefined;
    const result = formatStartupTime(&buf, 999);
    try std.testing.expectEqualStrings("999 ns", result);
}

test "formatStartupTime boundary between µs and ms" {
    var buf: [64]u8 = undefined;
    const result = formatStartupTime(&buf, 999_999);
    try std.testing.expectEqualStrings("999 µs", result);
}

test "formatStartupTime boundary between ms and s" {
    var buf: [64]u8 = undefined;
    const result = formatStartupTime(&buf, 999_000_000);
    try std.testing.expectEqualStrings("999 ms", result);
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
