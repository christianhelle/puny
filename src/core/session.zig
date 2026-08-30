const std = @import("std");
const builtin = @import("builtin");
const tool_schema = @import("../tools/schema.zig");
const helpers = @import("../tools/helpers.zig");
const AgentMode = @import("mode.zig").AgentMode;

const Tool = tool_schema.Tool;

var prd_path_global: []const u8 = "";
var html_path_global: []const u8 = "";

var write_blocked_global: bool = false;

pub fn setWriteBlocked(blocked: bool) void {
    write_blocked_global = blocked;
}

pub fn isWriteBlocked() bool {
    return write_blocked_global;
}

pub fn setSessionPaths(prd: []const u8, html: []const u8) void {
    prd_path_global = prd;
    html_path_global = html;
}

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
        pub fn exec(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]const u8 {
            const markdown = args.object.get("markdown") orelse return error.MissingMarkdown;
            const html = args.object.get("html") orelse return error.MissingHtml;
            var md_file = try std.Io.Dir.cwd().createFile(io, prd_path_global, .{});
            defer md_file.close(io);
            try md_file.writeStreamingAll(io, markdown.string);
            var html_file = try std.Io.Dir.cwd().createFile(io, html_path_global, .{});
            defer html_file.close(io);
            try html_file.writeStreamingAll(io, html.string);
            const abs_md = try resolvePath(allocator, io, prd_path_global);
            const abs_html = try resolvePath(allocator, io, html_path_global);
            return std.fmt.allocPrint(
                allocator,
                " - {s}\n - {s}",
                .{ abs_md, abs_html },
            );
        }
    }.exec,
};

pub const SessionMeta = struct {
    mode: AgentMode = .build,
    planning_mode: bool = false,
    first_prompt: ?[]const u8 = null,
};

fn defaultSessionMeta() SessionMeta {
    return .{ .mode = .build, .planning_mode = false, .first_prompt = null };
}

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
        setSessionPaths(prd_path, html_path);
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
        setSessionPaths(owned_prd, owned_html);
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

pub fn configPunyDir(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
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

pub fn readSessionMetaJson(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !SessionMeta {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return defaultSessionMeta(),
        error.StreamTooLong => {
            std.log.warn("session meta at {s} exceeds the read limit", .{path});
            return defaultSessionMeta();
        },
        else => |e| return e,
    };
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        std.log.warn("failed to parse session meta at {s}: {s}", .{ path, @errorName(err) });
        return defaultSessionMeta();
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return defaultSessionMeta(),
    };
    const planning_mode = if (obj.get("planning_mode")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;
    const legacy_mode: AgentMode = if (planning_mode) .planning else .build;
    const mode = if (obj.get("mode")) |v| switch (v) {
        .string => |name| std.meta.stringToEnum(AgentMode, name) orelse legacy_mode,
        else => legacy_mode,
    } else legacy_mode;
    const first_prompt = if (obj.get("first_prompt")) |v| switch (v) {
        .null => null,
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    return .{
        .mode = mode,
        .planning_mode = mode == .planning,
        .first_prompt = first_prompt,
    };
}

pub fn hasFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
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
    const dir = try std.fs.path.join(allocator, &.{ cwd, "zig-out", "test-sessions" });
    // Start from a clean slate: a run that crashed mid-test leaves session
    // directories behind, which would otherwise break tests that assert a
    // directory does not exist on the next run.
    cleanupTestDir(io, dir);
    return dir;
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

test "fromDir sets global session paths and does not create a directory" {
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

    try std.testing.expectEqualStrings(prd_path, prd_path_global);
    try std.testing.expectEqualStrings(html_path, html_path_global);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, dir, .{}));
}

test "testBaseDir wipes leftovers from an interrupted run" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    // Simulate the state a crashed run leaves behind: a session directory
    // (with a plan file) in the shared test directory.
    try createTestSessionDir(std.testing.io, test_dir, "stale-1", true);

    const stale_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "stale-1" });
    defer std.testing.allocator.free(stale_dir);

    // Resolving the test base dir again (as the next test does) must start
    // from a clean slate; otherwise the stale session directory survives and
    // breaks tests that assert a directory does not exist.
    const reset = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, reset);
        std.testing.allocator.free(reset);
    }

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, stale_dir, .{}));
}

fn createTestSessionDir(io: std.Io, base_dir: []const u8, uuid: []const u8, has_prd: bool) !void {
    const dir = try std.fs.path.join(std.testing.allocator, &.{ base_dir, "sessions", uuid });
    defer std.testing.allocator.free(dir);
    try createSessionDir(io, dir);
    if (has_prd) {
        const prd_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.md" });
        defer std.testing.allocator.free(prd_path);
        var file = try std.Io.Dir.cwd().createFile(io, prd_path, .{});
        file.close(io);
    }
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

test "messagesPath and sessionMetaPath join session directories" {
    const sep = std.fs.path.sep;

    const expected_msg = try std.fmt.allocPrint(std.testing.allocator, "/sessions{c}abc-1{c}messages.json", .{ sep, sep });
    defer std.testing.allocator.free(expected_msg);
    const msg = try messagesPath(std.testing.allocator, "/sessions", "abc-1");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(expected_msg, msg);

    const expected_meta = try std.fmt.allocPrint(std.testing.allocator, "/sessions{c}abc-1{c}session.json", .{ sep, sep });
    defer std.testing.allocator.free(expected_meta);
    const meta = try sessionMetaPath(std.testing.allocator, "/sessions", "abc-1");
    defer std.testing.allocator.free(meta);
    try std.testing.expectEqualStrings(expected_meta, meta);
}

test "save_prd_tool writes the plan files and reports their paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base);
    const prd = try std.fs.path.join(std.testing.allocator, &.{ base, "plan.md" });
    defer std.testing.allocator.free(prd);
    const html = try std.fs.path.join(std.testing.allocator, &.{ base, "plan.html" });
    defer std.testing.allocator.free(html);
    setSessionPaths(prd, html);
    defer setSessionPaths("", "");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"markdown\":\"# Plan\\n\",\"html\":\"<h1>Plan</h1>\"}", .{});

    const result = try save_prd_tool.execute(arena_state.allocator(), std.testing.io, args);
    try std.testing.expect(std.mem.indexOf(u8, result, prd) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, html) != null);

    const md_content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, prd, std.testing.allocator, std.Io.Limit.limited(1 << 20));
    defer std.testing.allocator.free(md_content);
    try std.testing.expectEqualStrings("# Plan\n", md_content);

    const html_content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, html, std.testing.allocator, std.Io.Limit.limited(1 << 20));
    defer std.testing.allocator.free(html_content);
    try std.testing.expectEqualStrings("<h1>Plan</h1>", html_content);
}

test "save_prd_tool resolves relative plan paths against the working directory" {
    const prd = "puny-test-relative-plan.md";
    const html = "puny-test-relative-plan.html";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prd) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, html) catch {};
    setSessionPaths(prd, html);
    defer setSessionPaths("", "");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"markdown\":\"md\",\"html\":\"html\"}", .{});

    const result = try save_prd_tool.execute(arena_state.allocator(), std.testing.io, args);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const abs_prd = try std.fs.path.join(std.testing.allocator, &.{ cwd, prd });
    defer std.testing.allocator.free(abs_prd);
    const abs_html = try std.fs.path.join(std.testing.allocator, &.{ cwd, html });
    defer std.testing.allocator.free(abs_html);
    try std.testing.expect(std.mem.indexOf(u8, result, abs_prd) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, abs_html) != null);
}

test "save_prd_tool reports missing markdown and html arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const no_md = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"html\":\"<h1>Plan</h1>\"}", .{});
    try std.testing.expectError(error.MissingMarkdown, save_prd_tool.execute(arena_state.allocator(), std.testing.io, no_md));

    // The markdown file is written before the html argument is validated, so
    // point the global paths at disposable files.
    const prd = "puny-test-missing-html.md";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prd) catch {};
    setSessionPaths(prd, "puny-test-missing-html.html");
    defer setSessionPaths("", "");

    const no_html = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"markdown\":\"md\"}", .{});
    try std.testing.expectError(error.MissingHtml, save_prd_tool.execute(arena_state.allocator(), std.testing.io, no_html));
}

test "readSessionMetaJson returns defaults for a missing file" {
    const path = "puny-test-meta-missing.json";
    const cwd = std.Io.Dir.cwd();
    // A stale file left by an interrupted prior run would otherwise turn
    // this into a read of leftover content; start from a clean slate.
    cwd.deleteFile(std.testing.io, path) catch {};

    const meta = try readSessionMetaJson(std.testing.io, std.testing.allocator, path);
    try std.testing.expect(!meta.planning_mode);
    try std.testing.expect(meta.first_prompt == null);
}

test "readSessionMetaJson parses a valid meta file" {
    const path = "puny-test-meta-valid.json";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};
    {
        var f = try cwd.createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"planning_mode\":true,\"first_prompt\":\"hello\"}");
    }

    const meta = try readSessionMetaJson(std.testing.io, std.testing.allocator, path);
    defer if (meta.first_prompt) |p| std.testing.allocator.free(p);
    try std.testing.expect(meta.planning_mode);
    try std.testing.expectEqualStrings("hello", meta.first_prompt.?);
}

test "readSessionMetaJson restores an explicit review mode" {
    const path = "puny-test-meta-review.json";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};
    {
        var f = try cwd.createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"mode\":\"review\",\"first_prompt\":\"check it\"}");
    }

    const meta = try readSessionMetaJson(std.testing.io, std.testing.allocator, path);
    defer if (meta.first_prompt) |p| std.testing.allocator.free(p);
    try std.testing.expectEqual(.review, meta.mode);
    try std.testing.expectEqualStrings("check it", meta.first_prompt.?);
}

test "readSessionMetaJson maps legacy planning mode to agent mode" {
    const path = "puny-test-meta-legacy-plan.json";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};
    {
        var f = try cwd.createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"planning_mode\":true,\"first_prompt\":null}");
    }

    const meta = try readSessionMetaJson(std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqual(.planning, meta.mode);
}

test "readSessionMetaJson tolerates invalid JSON" {
    const path = "puny-test-meta-invalid.json";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};
    {
        var f = try cwd.createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "not json");
    }

    const meta = try readSessionMetaJson(std.testing.io, std.testing.allocator, path);
    try std.testing.expect(!meta.planning_mode);
    try std.testing.expect(meta.first_prompt == null);
}

test "readSessionMetaJson tolerates a non-object root" {
    const path = "puny-test-meta-nonobject.json";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};
    {
        var f = try cwd.createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "[]");
    }

    const meta = try readSessionMetaJson(std.testing.io, std.testing.allocator, path);
    try std.testing.expect(!meta.planning_mode);
    try std.testing.expect(meta.first_prompt == null);
}

test "readSessionMetaJson tolerates a non-boolean planning_mode" {
    const path = "puny-test-meta-nonbool.json";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};
    {
        var f = try cwd.createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"planning_mode\":\"true\"}");
    }

    const meta = try readSessionMetaJson(std.testing.io, std.testing.allocator, path);
    try std.testing.expect(!meta.planning_mode);
    try std.testing.expect(meta.first_prompt == null);
}

test "hasFile detects file existence" {
    const path = "puny-test-hasfile.txt";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(std.testing.io, path) catch {};
    try std.testing.expect(!hasFile(std.testing.io, path));
    {
        var f = try cwd.createFile(std.testing.io, path, .{});
        f.close(std.testing.io);
    }
    try std.testing.expect(hasFile(std.testing.io, path));
}
