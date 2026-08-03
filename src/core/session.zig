const std = @import("std");
const builtin = @import("builtin");
const tool_schema = @import("../tools/schema.zig");
const helpers = @import("../tools/helpers.zig");
const context = @import("../tools/context.zig");
const skills = @import("../skills/skills.zig");

const Tool = tool_schema.Tool;

const SavePrdParams = struct {
    markdown: []const u8,
    html: []const u8,
};

fn savePrdSchema(allocator: std.mem.Allocator) !std.json.Value {
    return tool_schema.ToolDefinition("save_prd", "Save the Product Requirements Document. Call this when the user confirms they are ready for the final PRD. Provide the markdown content and HTML content separately.", SavePrdParams).schema(allocator);
}

fn resolvePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, path });
}

pub const save_prd_tool = Tool{
    .name = "save_prd",
    .description = "Save the Product Requirements Document. Call this when the user confirms they are ready for the final PRD. Provide the markdown content and HTML content separately.",
    .schema = savePrdSchema,
    .execute = struct {
        pub fn exec(ctx: *context.ToolContext, args: std.json.Value) ![]const u8 {
            const markdown = args.object.get("markdown") orelse return error.MissingMarkdown;
            const html = args.object.get("html") orelse return error.MissingHtml;
            var md_file = try std.Io.Dir.cwd().createFile(ctx.io, ctx.prd_path, .{});
            defer md_file.close(ctx.io);
            try md_file.writeStreamingAll(ctx.io, markdown.string);
            var html_file = try std.Io.Dir.cwd().createFile(ctx.io, ctx.html_path, .{});
            defer html_file.close(ctx.io);
            try html_file.writeStreamingAll(ctx.io, html.string);
            const abs_md = try resolvePath(ctx.allocator, ctx.io, ctx.prd_path);
            const abs_html = try resolvePath(ctx.allocator, ctx.io, ctx.html_path);
            return std.fmt.allocPrint(
                ctx.allocator,
                " - {s}\n - {s}",
                .{ abs_md, abs_html },
            );
        }
    }.exec,
};

pub const SessionMeta = struct {
    planning_mode: bool,
    first_prompt: ?[]const u8,
};

pub const SessionInfo = struct {
    id: []const u8,
    has_prd: bool,
    has_conversation: bool,
    planning_mode: bool,
    first_prompt: ?[]const u8,
};

pub const Session = struct {
    id: []const u8,
    base: []const u8,
    dir: []const u8,
    prd_path: []const u8,
    html_path: []const u8,

    pub fn init(arena: std.mem.Allocator, base_dir: []const u8, random: std.Random, io: std.Io) !Session {
        const id = try generateUuid(random, arena);
        const dir = try std.fs.path.join(arena, &.{ base_dir, "sessions", id });
        const prd_path = try std.fs.path.join(arena, &.{ dir, "plan.md" });
        const html_path = try std.fs.path.join(arena, &.{ dir, "plan.html" });
        try createSessionDir(io, dir);
        return .{
            .id = id,
            .base = try arena.dupe(u8, base_dir),
            .dir = dir,
            .prd_path = prd_path,
            .html_path = html_path,
        };
    }

    pub fn fromDir(arena: std.mem.Allocator, id: []const u8, base_dir: []const u8, dir: []const u8, prd_path: []const u8, html_path: []const u8) !Session {
        const owned_prd = try arena.dupe(u8, prd_path);
        const owned_html = try arena.dupe(u8, html_path);
        return .{
            .id = try arena.dupe(u8, id),
            .base = try arena.dupe(u8, base_dir),
            .dir = try arena.dupe(u8, dir),
            .prd_path = owned_prd,
            .html_path = owned_html,
        };
    }
};

pub fn sessionBaseDir(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const path = try configPunyDir(arena, environ_map);
    return path;
}

fn configPunyDir(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        const base = environ_map.get("APPDATA") orelse environ_map.get("USERPROFILE") orelse return error.NoConfigDir;
        return std.fs.path.join(arena, &.{ base, "puny" });
    }
    if (environ_map.get("XDG_CONFIG_HOME")) |base| {
        return std.fs.path.join(arena, &.{ base, "puny" });
    }
    const home = environ_map.get("HOME") orelse return error.NoConfigDir;
    return std.fs.path.join(arena, &.{ home, ".config", "puny" });
}

fn createSessionDir(io: std.Io, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
}

pub fn messagesPath(allocator: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ sessions_dir, id, "messages.json" });
}

pub fn sessionMetaPath(allocator: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ sessions_dir, id, "session.json" });
}

fn readSessionMetaJson(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !SessionMeta {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return SessionMeta{ .planning_mode = false, .first_prompt = null },
        else => |e| return e,
    };
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        std.log.warn("failed to parse session meta at {s}: {s}", .{ path, @errorName(err) });
        return SessionMeta{ .planning_mode = false, .first_prompt = null };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const planning_mode = if (obj.get("planning_mode")) |v| v.bool else false;
    const first_prompt = if (obj.get("first_prompt")) |v| switch (v) {
        .null => null,
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    return SessionMeta{ .planning_mode = planning_mode, .first_prompt = first_prompt };
}

pub fn listSessions(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8) ![]SessionInfo {
    var tmp_arena = std.heap.ArenaAllocator.init(arena);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sessions_dir_path = try std.fs.path.join(tmp, &.{ base_dir, "sessions" });
    var sessions_dir = std.Io.Dir.cwd().openDir(io, sessions_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &[_]SessionInfo{},
        else => |e| return e,
    };
    defer sessions_dir.close(io);

    var list: std.ArrayList(SessionInfo) = .empty;
    errdefer list.deinit(arena);

    var it = sessions_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const id = try arena.dupe(u8, entry.name);

        const prd_path = try std.fs.path.join(tmp, &.{ sessions_dir_path, id, "plan.md" });
        const has_prd = hasFile(io, prd_path);

        const msg_path = try messagesPath(tmp, sessions_dir_path, id);
        const has_conversation = hasFile(io, msg_path);

        const meta_path = try sessionMetaPath(tmp, sessions_dir_path, id);
        const meta = try readSessionMetaJson(io, tmp, meta_path);

        const first_prompt = if (meta.first_prompt) |p| try arena.dupe(u8, p) else null;

        try list.append(arena, .{
            .id = id,
            .has_prd = has_prd,
            .has_conversation = has_conversation,
            .planning_mode = meta.planning_mode,
            .first_prompt = first_prompt,
        });
    }

    std.mem.sort(SessionInfo, list.items, {}, struct {
        fn less(_: void, a: SessionInfo, b: SessionInfo) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    return list.toOwnedSlice(arena);
}

fn hasFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn pruneSessions(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, current_id: []const u8) !void {
    var tmp_arena = std.heap.ArenaAllocator.init(arena);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sessions = try listSessions(tmp, io, base_dir);
    for (sessions) |s| {
        if (std.mem.eql(u8, s.id, current_id)) continue;
        const dir_path = try std.fs.path.join(tmp, &.{ base_dir, "sessions", s.id });
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    }
}

fn dupeSessionInfo(arena: std.mem.Allocator, s: SessionInfo) !SessionInfo {
    const id = try arena.dupe(u8, s.id);
    const first_prompt = if (s.first_prompt) |p| try arena.dupe(u8, p) else null;
    return SessionInfo{
        .id = id,
        .has_prd = s.has_prd,
        .has_conversation = s.has_conversation,
        .planning_mode = s.planning_mode,
        .first_prompt = first_prompt,
    };
}

pub fn findSessionByPrefix(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, prefix: []const u8) !?SessionInfo {
    var tmp_arena = std.heap.ArenaAllocator.init(arena);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sessions = try listSessions(tmp, io, base_dir);
    var matches: usize = 0;
    for (sessions) |s| {
        if (std.mem.startsWith(u8, s.id, prefix)) matches += 1;
    }
    if (matches != 1) return null;

    for (sessions) |s| {
        if (std.mem.startsWith(u8, s.id, prefix)) {
            return try dupeSessionInfo(arena, s);
        }
    }
    return null;
}

pub fn findLatestSession(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8) !?SessionInfo {
    var tmp_arena = std.heap.ArenaAllocator.init(arena);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sessions_dir_path = try std.fs.path.join(tmp, &.{ base_dir, "sessions" });
    const sessions = try listSessions(tmp, io, base_dir);
    var best: ?SessionInfo = null;
    var best_mtime: ?std.Io.Timestamp = null;
    for (sessions) |s| {
        if (!s.has_conversation) continue;
        const msg_path = try messagesPath(tmp, sessions_dir_path, s.id);
        const stat = std.Io.Dir.cwd().statFile(io, msg_path, .{}) catch continue;
        if (best_mtime) |current| {
            if (current.nanoseconds < stat.mtime.nanoseconds) {
                best_mtime = stat.mtime;
                best = s;
            }
        } else {
            best_mtime = stat.mtime;
            best = s;
        }
    }

    if (best) |s| {
        return try dupeSessionInfo(arena, s);
    }
    return null;
}

pub fn generateUuid(random: std.Random, arena: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var buf: [36]u8 = undefined;
    var i: usize = 0;
    var j: usize = 0;
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[j] = '-';
            j += 1;
        }
        buf[j] = hex[bytes[i] >> 4];
        buf[j + 1] = hex[bytes[i] & 0x0f];
        j += 2;
    }
    return try arena.dupe(u8, &buf);
}

test "generateUuid produces 36-char string with correct format" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const uuid = try generateUuid(random, std.testing.allocator);
    defer std.testing.allocator.free(uuid);

    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual('-', uuid[8]);
    try std.testing.expectEqual('-', uuid[13]);
    try std.testing.expectEqual('-', uuid[18]);
    try std.testing.expectEqual('-', uuid[23]);
    try std.testing.expectEqual('4', uuid[14]);
}

test "generateUuid produces unique values" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const a = try generateUuid(random, std.testing.allocator);
    defer std.testing.allocator.free(a);

    const b = try generateUuid(random, std.testing.allocator);
    defer std.testing.allocator.free(b);

    try std.testing.expect(!std.mem.eql(u8, a, b));
}

fn testBaseDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, "zig-out", "test-sessions" });
}

fn cleanupTestDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

test "Session.init creates directory with correct paths" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    const session = try Session.init(std.testing.allocator, test_dir, random, std.testing.io);
    defer {
        std.testing.allocator.free(session.id);
        std.testing.allocator.free(session.base);
        std.testing.allocator.free(session.dir);
        std.testing.allocator.free(session.prd_path);
        std.testing.allocator.free(session.html_path);
    }

    try std.testing.expectEqual(@as(usize, 36), session.id.len);
    try std.testing.expect(std.mem.endsWith(u8, session.dir, session.id));
    try std.testing.expect(std.mem.endsWith(u8, session.prd_path, "plan.md"));
    try std.testing.expect(std.mem.endsWith(u8, session.html_path, "plan.html"));

    var session_dir = try std.Io.Dir.cwd().openDir(std.testing.io, session.dir, .{});
    session_dir.close(std.testing.io);
}

test "fromDir sets session paths and does not create a directory" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createSessionDir(std.testing.io, test_dir);

    const id = "restore-1";
    const dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", id });
    defer std.testing.allocator.free(dir);
    const prd_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.md" });
    defer std.testing.allocator.free(prd_path);
    const html_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.html" });
    defer std.testing.allocator.free(html_path);

    const session = try Session.fromDir(std.testing.allocator, id, test_dir, dir, prd_path, html_path);
    defer {
        std.testing.allocator.free(session.id);
        std.testing.allocator.free(session.base);
        std.testing.allocator.free(session.dir);
        std.testing.allocator.free(session.prd_path);
        std.testing.allocator.free(session.html_path);
    }

    try std.testing.expectEqualStrings(prd_path, session.prd_path);
    try std.testing.expectEqualStrings(html_path, session.html_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, dir, .{}));
}

fn createTestSessionDir(io: std.Io, base_dir: []const u8, uuid: []const u8, has_prd: bool) !void {
    return createTestSessionDirFull(io, base_dir, uuid, has_prd, false);
}

fn createTestSessionDirFull(io: std.Io, base_dir: []const u8, uuid: []const u8, has_prd: bool, has_conversation: bool) !void {
    const dir = try std.fs.path.join(std.testing.allocator, &.{ base_dir, "sessions", uuid });
    defer std.testing.allocator.free(dir);
    try createSessionDir(io, dir);
    if (has_prd) {
        const prd_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.md" });
        defer std.testing.allocator.free(prd_path);
        var file = try std.Io.Dir.cwd().createFile(io, prd_path, .{});
        file.close(io);
    }
    if (has_conversation) {
        const msg_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "messages.json" });
        defer std.testing.allocator.free(msg_path);
        var file = try std.Io.Dir.cwd().createFile(io, msg_path, .{});
        file.close(io);
        const meta_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "session.json" });
        defer std.testing.allocator.free(meta_path);
        var meta_file = try std.Io.Dir.cwd().createFile(io, meta_path, .{});
        defer meta_file.close(io);
        try meta_file.writeStreamingAll(io, "{\"planning_mode\":false,\"first_prompt\":\"hello\"}");
    }
}

test "listSessions returns discovered sessions" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "abc-111", true);
    try createTestSessionDir(std.testing.io, test_dir, "abc-222", false);

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expect(!sessions[0].has_conversation);
    try std.testing.expect(!sessions[1].has_conversation);
}

test "listSessions detects conversation" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDirFull(std.testing.io, test_dir, "conv-1", false, true);
    try createTestSessionDir(std.testing.io, test_dir, "plain-2", false);

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    const conv = for (sessions) |s| {
        if (std.mem.eql(u8, s.id, "conv-1")) break s;
    } else unreachable;
    const plain = for (sessions) |s| {
        if (std.mem.eql(u8, s.id, "plain-2")) break s;
    } else unreachable;
    try std.testing.expect(conv.has_conversation);
    try std.testing.expect(!plain.has_conversation);
    try std.testing.expectEqualStrings("hello", conv.first_prompt.?);
}

test "pruneSessions removes all but current" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "current-1", true);
    try createTestSessionDir(std.testing.io, test_dir, "old-1", true);
    try createTestSessionDir(std.testing.io, test_dir, "old-2", false);

    try pruneSessions(std.testing.allocator, std.testing.io, test_dir, "current-1");

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("current-1", sessions[0].id);
}

test "findSessionByPrefix matches unique prefix" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "abc-111-aaa", false);
    try createTestSessionDir(std.testing.io, test_dir, "abc-222-bbb", false);

    const found = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "abc-111");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("abc-111-aaa", found.?.id);
    if (found) |s| {
        std.testing.allocator.free(s.id);
        if (s.first_prompt) |p| std.testing.allocator.free(p);
    }
}

test "findSessionByPrefix returns null on ambiguous or no match" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "abc-111-aaa", false);
    try createTestSessionDir(std.testing.io, test_dir, "abc-111-bbb", false);

    const found = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "abc-111");
    try std.testing.expect(found == null);

    const none = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "xyz");
    try std.testing.expect(none == null);
}

fn setFileMtime(io: std.Io, path: []const u8, ts: std.Io.Timestamp) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = ts } });
}

test "findLatestSession returns most recently modified session with conversation" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDirFull(std.testing.io, test_dir, "a-older", false, true);
    try createTestSessionDirFull(std.testing.io, test_dir, "z-newer", false, true);
    try createTestSessionDirFull(std.testing.io, test_dir, "no-conv", false, false);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);

    const older_msg = try messagesPath(std.testing.allocator, sessions_dir, "a-older");
    defer std.testing.allocator.free(older_msg);
    try setFileMtime(std.testing.io, older_msg, std.Io.Timestamp.fromNanoseconds(1_000_000_000_000));

    const newer_msg = try messagesPath(std.testing.allocator, sessions_dir, "z-newer");
    defer std.testing.allocator.free(newer_msg);
    try setFileMtime(std.testing.io, newer_msg, std.Io.Timestamp.fromNanoseconds(1_001_000_000_000));

    const found = try findLatestSession(std.testing.allocator, std.testing.io, test_dir);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("z-newer", found.?.id);
    if (found) |s| {
        std.testing.allocator.free(s.id);
        if (s.first_prompt) |p| std.testing.allocator.free(p);
    }
}

test "findLatestSession returns null when no session has a conversation" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "plain-1", false);
    try createTestSessionDir(std.testing.io, test_dir, "plain-2", true);

    const found = try findLatestSession(std.testing.allocator, std.testing.io, test_dir);
    try std.testing.expect(found == null);
}

test "sessionBaseDir extracts from environ map" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    if (comptime builtin.os.tag == .windows) {
        try env.put("USERPROFILE", "C:\\Users\\test");
        const dir = try sessionBaseDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("C:\\Users\\test\\puny", dir);
    } else {
        try env.put("HOME", "/tmp/test-home");
        const dir = try sessionBaseDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("/tmp/test-home/.config/puny", dir);
    }
}

test "sessionHasPlan returns false when no plan files exist" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "no-plan-1", false);

    const dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "no-plan-1" });
    defer std.testing.allocator.free(dir);

    try std.testing.expect(!sessionHasPlan(std.testing.io, dir));
}

test "sessionHasPlan returns true when plan.md exists" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "md-plan-1", true);

    const dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "md-plan-1" });
    defer std.testing.allocator.free(dir);

    try std.testing.expect(sessionHasPlan(std.testing.io, dir));
}

test "sessionHasPlan returns true when plan.html exists" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "html-plan-1", false);

    const dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "html-plan-1" });
    defer std.testing.allocator.free(dir);
    const html_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.html" });
    defer std.testing.allocator.free(html_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, html_path, .{});
    file.close(std.testing.io);

    try std.testing.expect(sessionHasPlan(std.testing.io, dir));
}

test "sessionHasPlan returns true when both plan files exist" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "both-plan-1", true);

    const dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "both-plan-1" });
    defer std.testing.allocator.free(dir);
    const html_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.html" });
    defer std.testing.allocator.free(html_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, html_path, .{});
    file.close(std.testing.io);

    try std.testing.expect(sessionHasPlan(std.testing.io, dir));
}

pub fn sessionHasPlan(io: std.Io, dir: []const u8) bool {
    var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const md_path = std.fs.path.join(tmp, &.{ dir, "plan.md" }) catch return false;
    if (hasFile(io, md_path)) return true;

    const html_path = std.fs.path.join(tmp, &.{ dir, "plan.html" }) catch return false;
    return hasFile(io, html_path);
}

test "removeSessionDir deletes an existing session directory" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "rm-1", false);

    const dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "rm-1" });
    defer std.testing.allocator.free(dir);

    removeSessionDir(std.testing.io, dir);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, dir, .{}));
}

test "removeSessionDir is a no-op for a missing directory" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createSessionDir(std.testing.io, test_dir);

    const dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "missing-1" });
    defer std.testing.allocator.free(dir);

    removeSessionDir(std.testing.io, dir);
}

pub fn removeSessionDir(io: std.Io, dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "save_prd writes markdown and html to context session paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var skill_registry = skills.Registry.init(arena);
    defer skill_registry.deinit();

    const session_dir = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sessions", "abc-123" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, session_dir);
    const prd_path = try std.fs.path.join(arena, &.{ session_dir, "plan.md" });
    const html_path = try std.fs.path.join(arena, &.{ session_dir, "plan.html" });

    var ctx = context.ToolContext.init(arena, std.testing.io, &skill_registry);
    defer ctx.deinit();
    ctx.setSession(.{ .prd_path = prd_path, .html_path = html_path });

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"markdown\":\"# PRD\\n\",\"html\":\"<h1>PRD</h1>\\n\"}", .{});

    const result = try save_prd_tool.execute(&ctx, args);
    try std.testing.expect(std.mem.indexOf(u8, result, prd_path) != null);

    const md = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, prd_path, arena, std.Io.Limit.limited(1024));
    try std.testing.expectEqualStrings("# PRD\n", md);
    const html = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, html_path, arena, std.Io.Limit.limited(1024));
    try std.testing.expectEqualStrings("<h1>PRD</h1>\n", html);
}
