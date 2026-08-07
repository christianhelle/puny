const std = @import("std");
const builtin = @import("builtin");
const core_session = @import("../core/session.zig");

pub const SessionInfo = struct {
    id: []const u8,
    has_prd: bool,
    has_conversation: bool,
    planning_mode: bool,
    first_prompt: ?[]const u8,
    last_modified: u64,
};

const first_prompt_limit = 1024;
const index_read_limit = 64 * 1024 * 1024;
const index_filename = "sessions.json";

/// Resolves `<puny_dir>/sessions.json` from the environment, reusing the
/// puny-dir resolution owned by `src/core/session.zig`.
pub fn sessionsPath(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const base = try core_session.configPunyDir(arena, environ_map);
    defer arena.free(base);
    return std.fs.path.join(arena, &.{ base, index_filename });
}

/// Returns the session index (`sessions.json`) contents as `[]SessionInfo`
/// sorted by id. A missing, stale, corrupt, or oversized index is rebuilt from
/// a directory scan (and the index rewritten) before returning.
///
/// Only the returned entries (id and first_prompt slices) are allocated in
/// `arena`; all transient path and parse memory is released before returning.
pub fn listSessions(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8) ![]SessionInfo {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const sessions_dir_path = try std.fs.path.join(scratch, &.{ base_dir, "sessions" });
    const index_path = try std.fs.path.join(scratch, &.{ base_dir, index_filename });

    // A missing sessions dir means there are no sessions; same as today's
    // directory scan, and no index is written.
    const dir_stat = std.Io.Dir.cwd().statFile(io, sessions_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &[_]SessionInfo{},
        else => |e| return e,
    };

    const index_stat = std.Io.Dir.cwd().statFile(io, index_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try rebuildSessionsIndex(arena, io, base_dir),
        else => |e| return e,
    };

    // Cheap O(1) staleness check: a session directory was added or removed
    // outside the upsert path, or a plan file was created mid-session.
    if (dir_stat.mtime.nanoseconds >= index_stat.mtime.nanoseconds) {
        return try rebuildSessionsIndex(arena, io, base_dir);
    }

    const data = std.Io.Dir.cwd().readFileAlloc(io, index_path, scratch, std.Io.Limit.limited(index_read_limit)) catch |err| switch (err) {
        error.StreamTooLong => {
            std.log.warn("sessions index at {s} exceeds the read limit; rebuilding", .{index_path});
            return try rebuildSessionsIndex(arena, io, base_dir);
        },
        else => |e| return e,
    };

    const parsed = std.json.parseFromSlice([]SessionInfo, scratch, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| {
        std.log.warn("failed to parse sessions index at {s}: {s}; rebuilding", .{ index_path, @errorName(err) });
        return try rebuildSessionsIndex(arena, io, base_dir);
    };
    defer parsed.deinit();

    // A corrupted index could carry a session id that escapes the sessions
    // directory (empty, path-like, or "." / ".."); refuse it and rebuild from
    // the directory scan rather than surfacing such entries to callers.
    for (parsed.value) |s| {
        if (!isValidSessionId(s.id)) {
            std.log.warn("sessions index at {s} contains an invalid session id; rebuilding", .{index_path});
            return try rebuildSessionsIndex(arena, io, base_dir);
        }
    }

    // parseFromSlice may have returned string slices pointing into `data` (or
    // other scratch memory), so duplicate id and first_prompt into the
    // caller's arena before the scratch arena is released.
    const entries = try arena.alloc(SessionInfo, parsed.value.len);
    for (parsed.value, 0..) |s, i| {
        entries[i] = try dupeSessionInfo(arena, s);
    }
    return entries;
}

/// Full directory scan: computes every `SessionInfo` field from the session
/// files (last_modified from file mtimes), sorts by id, writes the index, and
/// returns the entries. This is the self-healing path for a missing, stale,
/// corrupt, or oversized index, and the one-time migration for existing
/// installs.
fn rebuildSessionsIndex(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8) ![]SessionInfo {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const sessions_dir_path = try std.fs.path.join(scratch, &.{ base_dir, "sessions" });
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

        // Each entry's metadata is read into a scratch arena released at the
        // end of this iteration, so no per-session file contents accumulate in
        // the caller's arena.
        var entry_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer entry_arena.deinit();
        const entry_tmp = entry_arena.allocator();

        const dir_path = try std.fs.path.join(entry_tmp, &.{ sessions_dir_path, id });
        const has_prd = core_session.sessionHasPlan(io, dir_path);

        const msg_path = try core_session.messagesPath(entry_tmp, sessions_dir_path, id);
        const msg_stat = std.Io.Dir.cwd().statFile(io, msg_path, .{}) catch null;
        const has_conversation = msg_stat != null;

        const meta_path = try core_session.sessionMetaPath(entry_tmp, sessions_dir_path, id);
        const meta = try core_session.readSessionMetaJson(io, entry_tmp, meta_path);

        const first_prompt = if (meta.first_prompt) |p| try truncateFirstPrompt(arena, p) else null;

        // last_modified: messages.json mtime when present, else the plan
        // file mtime when present, else 0.
        var last_modified: u64 = 0;
        if (msg_stat) |st| {
            last_modified = timestampToNs(st.mtime) orelse 0;
        }
        if (last_modified == 0 and has_prd) {
            const md_path = try std.fs.path.join(entry_tmp, &.{ dir_path, "plan.md" });
            if (std.Io.Dir.cwd().statFile(io, md_path, .{})) |st| {
                last_modified = timestampToNs(st.mtime) orelse 0;
            } else |_| {
                const html_path = try std.fs.path.join(entry_tmp, &.{ dir_path, "plan.html" });
                if (std.Io.Dir.cwd().statFile(io, html_path, .{})) |st| {
                    last_modified = timestampToNs(st.mtime) orelse 0;
                } else |_| {}
            }
        }

        try list.append(arena, .{
            .id = id,
            .has_prd = has_prd,
            .has_conversation = has_conversation,
            .planning_mode = meta.planning_mode,
            .first_prompt = first_prompt,
            .last_modified = last_modified,
        });
    }

    std.mem.sort(SessionInfo, list.items, {}, lessThan);
    const entries = try list.toOwnedSlice(arena);
    try writeIndex(io, arena, base_dir, entries);
    return entries;
}

/// Writes `entries` to `base_dir/sessions.json` as a bare JSON array, using a
/// temp file + atomic rename and owner-only permissions. All transient path
/// and buffer memory lives in a scratch arena released before returning.
fn writeIndex(io: std.Io, allocator: std.mem.Allocator, base_dir: []const u8, entries: []const SessionInfo) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const tmp_path = try std.fs.path.join(scratch, &.{ base_dir, index_filename ++ ".tmp" });
    const final_path = try std.fs.path.join(scratch, &.{ base_dir, index_filename });

    const buffer = try std.json.Stringify.valueAlloc(scratch, entries, .{ .whitespace = .indent_2 });

    var file = cwd.createFile(io, tmp_path, .{}) catch |err| {
        std.log.warn("failed to create sessions index temp file {s}: {s}", .{ tmp_path, @errorName(err) });
        return err;
    };
    errdefer {
        file.close(io);
        cwd.deleteFile(io, tmp_path) catch {};
    }

    file.writeStreamingAll(io, buffer) catch |err| {
        std.log.warn("failed to write sessions index {s}: {s}", .{ tmp_path, @errorName(err) });
        return err;
    };
    file.writeStreamingAll(io, "\n") catch |err| {
        std.log.warn("failed to write sessions index newline {s}: {s}", .{ tmp_path, @errorName(err) });
        return err;
    };
    file.close(io);

    // Force owner-only on the final file (mirrors prompt_history.json's
    // tightening behavior). Setting it before the rename avoids a window where
    // the final path exists with permissive mode.
    if (comptime builtin.os.tag != .windows) {
        cwd.setFilePermissions(io, tmp_path, @enumFromInt(0o600), .{}) catch {};
    }

    std.Io.Dir.renameAbsolute(tmp_path, final_path, io) catch |err| {
        std.log.warn("failed to rename sessions index into place {s}: {s}", .{ final_path, @errorName(err) });
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

/// Adds or updates a single session entry in the index and rewrites it.
/// A missing, stale, corrupt, or oversized index is rebuilt first, so the
/// upsert is applied to the freshest state and self-heals drift.
pub fn upsertSessionInfo(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, info: SessionInfo) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const current = try listSessions(scratch, io, base_dir);

    const id = try scratch.dupe(u8, info.id);
    const first_prompt = if (info.first_prompt) |p| try truncateFirstPrompt(scratch, p) else null;
    const updated = SessionInfo{
        .id = id,
        .has_prd = info.has_prd,
        .has_conversation = info.has_conversation,
        .planning_mode = info.planning_mode,
        .first_prompt = first_prompt,
        .last_modified = info.last_modified,
    };

    var entries: std.ArrayList(SessionInfo) = .empty;
    defer entries.deinit(scratch);
    var found = false;
    for (current) |s| {
        if (std.mem.eql(u8, s.id, id)) {
            try entries.append(scratch, updated);
            found = true;
        } else {
            try entries.append(scratch, s);
        }
    }
    if (!found) try entries.append(scratch, updated);

    std.mem.sort(SessionInfo, entries.items, {}, lessThan);
    try writeIndex(io, scratch, base_dir, entries.items);
}

/// Removes a single session entry from the index and rewrites it. Used by
/// `finalizeSession` when a fully-restored empty session directory is removed,
/// where a targeted update avoids a full scan on every exit.
pub fn removeSessionFromIndex(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, id: []const u8) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const current = try listSessions(scratch, io, base_dir);
    var entries: std.ArrayList(SessionInfo) = .empty;
    defer entries.deinit(scratch);
    for (current) |s| {
        if (std.mem.eql(u8, s.id, id)) continue;
        try entries.append(scratch, s);
    }
    // Nothing was removed (e.g. the id was never indexed); leave the index
    // untouched rather than rewriting it.
    if (entries.items.len == current.len) return;
    try writeIndex(io, scratch, base_dir, entries.items);
}

/// Returns the single session whose id starts with `prefix`, or `null` when
/// there is no match or the prefix is ambiguous. Index-backed; no per-session
/// filesystem access.
pub fn findSessionByPrefix(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, prefix: []const u8) !?SessionInfo {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const sessions = try listSessions(scratch, io, base_dir);
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

/// Returns the session with a conversation and the largest `last_modified`,
/// or `null` when no session has a conversation. Pure in-memory comparison of
/// the index; no per-session `stat` calls.
pub fn findLatestSession(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8) !?SessionInfo {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const sessions = try listSessions(scratch, io, base_dir);
    var best: ?SessionInfo = null;
    for (sessions) |s| {
        if (!s.has_conversation) continue;
        if (best == null or s.last_modified > best.?.last_modified) best = s;
    }
    if (best) |s| return try dupeSessionInfo(arena, s);
    return null;
}

/// Deletes every session directory except `current_id` ("" deletes all, as
/// today), then rebuilds the index from the remaining directories so pruned
/// entries disappear and any other drift heals in one step.
pub fn pruneSessions(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, current_id: []const u8) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const sessions = try listSessions(scratch, io, base_dir);
    for (sessions) |s| {
        if (std.mem.eql(u8, s.id, current_id)) continue;
        const dir_path = try std.fs.path.join(scratch, &.{ base_dir, "sessions", s.id });
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    }
    _ = try rebuildSessionsIndex(scratch, io, base_dir);
}

fn truncateFirstPrompt(arena: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const end = @min(prompt.len, first_prompt_limit);
    return arena.dupe(u8, prompt[0..end]);
}

/// A session id must be a non-empty path-safe component that is neither "."
/// nor "..", so a corrupted index can never direct file access outside the
/// sessions directory.
fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |c| {
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

fn dupeSessionInfo(arena: std.mem.Allocator, s: SessionInfo) !SessionInfo {
    const id = try arena.dupe(u8, s.id);
    const first_prompt = if (s.first_prompt) |p| try arena.dupe(u8, p) else null;
    return .{
        .id = id,
        .has_prd = s.has_prd,
        .has_conversation = s.has_conversation,
        .planning_mode = s.planning_mode,
        .first_prompt = first_prompt,
        .last_modified = s.last_modified,
    };
}

fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn timestampToNs(ts: std.Io.Timestamp) ?u64 {
    if (ts.nanoseconds < 0) return null;
    return @intCast(ts.nanoseconds);
}

// ---- tests ----

fn testBaseDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const dir = try std.fs.path.join(allocator, &.{ cwd, "zig-out", "test-sessions-index" });
    // Start from a clean slate: a run that crashed mid-test leaves sessions and
    // an index behind, which would otherwise poison assertions that expect an
    // empty directory (e.g. the missing-sessions-dir case) on the next run.
    cleanupTestDir(io, dir);
    return dir;
}

fn cleanupTestDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn createSessionDir(io: std.Io, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
}

fn createTestSessionDir(io: std.Io, base_dir: []const u8, uuid: []const u8, has_prd: bool) !void {
    try createTestSessionDirFull(io, base_dir, uuid, has_prd, false);
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

fn setFileMtime(io: std.Io, path: []const u8, ts: std.Io.Timestamp) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = ts } });
}

/// Test allocator that records the peak number of live bytes it has been asked
/// to hold. Lets a test assert that transient work (like reading each session
/// meta file) is released instead of accumulating in a shared arena.
const PeakTrackingAllocator = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakTrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += len;
        if (self.live > self.peak) self.peak = self.live;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live -= memory.len;
        self.live += new_len;
        if (self.live > self.peak) self.peak = self.live;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live -= memory.len;
        self.live += new_len;
        if (self.live > self.peak) self.peak = self.live;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "sessionsPath resolves under Windows and POSIX env maps" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    if (comptime builtin.os.tag == .windows) {
        try env.put("USERPROFILE", "C:\\Users\\test");
        const path = try sessionsPath(allocator, &env);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("C:\\Users\\test\\puny\\sessions.json", path);
    } else {
        try env.put("XDG_CONFIG_HOME", "/tmp/cfg");
        const xdg = try sessionsPath(allocator, &env);
        defer allocator.free(xdg);
        try std.testing.expectEqualStrings("/tmp/cfg/puny/sessions.json", xdg);

        env.deinit();
        env = std.process.Environ.Map.init(allocator);
        try env.put("HOME", "/tmp/test-home");
        const home = try sessionsPath(allocator, &env);
        defer allocator.free(home);
        try std.testing.expectEqualStrings("/tmp/test-home/.config/puny/sessions.json", home);
    }
}

test "listSessions returns empty when the sessions dir is missing and writes no index" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createSessionDir(std.testing.io, test_dir);

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer std.testing.allocator.free(sessions);
    try std.testing.expectEqual(@as(usize, 0), sessions.len);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, index_path, .{}));
}

test "testBaseDir wipes leftovers from an interrupted run" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    // Simulate the state a crashed run leaves behind in the shared test
    // directory: session directories plus a stale index.
    try createTestSessionDir(std.testing.io, test_dir, "stale-1", false);
    try createTestSessionDir(std.testing.io, test_dir, "stale-2", false);
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "stale-1",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    // Resolving the test base dir again (as the next test does) must start
    // from a clean slate; otherwise stale sessions leak into the listing and
    // poison assertions that expect an empty directory.
    const reset = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, reset);
        std.testing.allocator.free(reset);
    }

    const sessions = try listSessions(std.testing.allocator, std.testing.io, reset);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "listSessions rebuilds and writes the index from discovered sessions" {
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
    try std.testing.expectEqualStrings("abc-111", sessions[0].id);
    try std.testing.expect(sessions[0].has_prd);
    try std.testing.expect(!sessions[0].has_conversation);
    try std.testing.expect(!sessions[1].has_conversation);

    // The rebuild wrote the index beside config.json.
    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, index_path, .{});
    try std.testing.expect(st.size > 0);
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

test "listSessions stores a 1024-char preview for first prompts longer than 1024 bytes" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "big-meta", false);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    const meta_path = try core_session.sessionMetaPath(std.testing.allocator, sessions_dir, "big-meta");
    defer std.testing.allocator.free(meta_path);

    const long_prompt = [_]u8{'x'} ** 2048;
    var meta_file = try std.Io.Dir.cwd().createFile(std.testing.io, meta_path, .{});
    defer meta_file.close(std.testing.io);
    try meta_file.writeStreamingAll(std.testing.io, "{\"planning_mode\":false,\"first_prompt\":\"");
    try meta_file.writeStreamingAll(std.testing.io, &long_prompt);
    try meta_file.writeStreamingAll(std.testing.io, "\"}");

    // First listing rebuilds from scan; the index stores the truncated preview.
    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("big-meta", sessions[0].id);
    try std.testing.expectEqual(@as(usize, 1024), sessions[0].first_prompt.?.len);

    // Second listing reads the index and still returns the truncated preview.
    const again = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (again) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(again);
    }
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expectEqual(@as(usize, 1024), again[0].first_prompt.?.len);
}

test "listSessions survives a session meta larger than the read limit" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "huge-meta", false);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    const meta_path = try core_session.sessionMetaPath(std.testing.allocator, sessions_dir, "huge-meta");
    defer std.testing.allocator.free(meta_path);

    // A meta file that exceeds the read limit must not crash the listing; the
    // session is listed without a preview.
    var meta_file = try std.Io.Dir.cwd().createFile(std.testing.io, meta_path, .{});
    defer meta_file.close(std.testing.io);
    try meta_file.writeStreamingAll(std.testing.io, "{\"planning_mode\":false,\"first_prompt\":\"");
    const chunk = [_]u8{'x'} ** 4096;
    var written: usize = 0;
    while (written < 10 * 1024 * 1024) : (written += chunk.len) {
        try meta_file.writeStreamingAll(std.testing.io, &chunk);
    }
    try meta_file.writeStreamingAll(std.testing.io, "\"}");

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("huge-meta", sessions[0].id);
    try std.testing.expect(sessions[0].first_prompt == null);
}

test "listSessions does not retain every session's metadata in the shared arena" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    // Four sessions, each with a ~512KB first prompt. The rebuild must keep
    // only the retained results (id plus one truncated 1024-char preview per
    // session) in the caller's arena; the file contents and parsed metadata of
    // every entry must be released before the next entry is processed.
    const prompt_len = 512 * 1024;
    const chunk = [_]u8{'x'} ** (64 * 1024);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const id = try std.fmt.allocPrint(std.testing.allocator, "big-{d}", .{i});
        defer std.testing.allocator.free(id);
        try createTestSessionDir(std.testing.io, test_dir, id, false);

        const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
        defer std.testing.allocator.free(sessions_dir);
        const meta_path = try core_session.sessionMetaPath(std.testing.allocator, sessions_dir, id);
        defer std.testing.allocator.free(meta_path);

        var meta_file = try std.Io.Dir.cwd().createFile(std.testing.io, meta_path, .{});
        defer meta_file.close(std.testing.io);
        try meta_file.writeStreamingAll(std.testing.io, "{\"planning_mode\":false,\"first_prompt\":\"");
        var written: usize = 0;
        while (written < prompt_len) : (written += chunk.len) {
            try meta_file.writeStreamingAll(std.testing.io, &chunk);
        }
        try meta_file.writeStreamingAll(std.testing.io, "\"}");
    }

    var tracking = PeakTrackingAllocator{ .backing = std.testing.allocator };
    const sessions = try listSessions(tracking.allocator(), std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 4), sessions.len);
    for (sessions) |s| {
        try std.testing.expectEqual(@as(usize, 1024), s.first_prompt.?.len);
    }

    // The retained results are ~4.3KB (one id plus one 1024-char preview per
    // session). The 512KB file contents used to accumulate in the shared arena
    // until the listing finished; bound the peak to the retained results plus
    // a small constant.
    const retained = 4 * (36 + 1024);
    try std.testing.expect(tracking.peak < retained + 2 * 1024 * 1024);
}

test "listSessions rebuilds from scan on a corrupt index" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDirFull(std.testing.io, test_dir, "corrupt-1", true, true);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    var bad = try std.Io.Dir.cwd().createFile(std.testing.io, index_path, .{});
    defer bad.close(std.testing.io);
    try bad.writeStreamingAll(std.testing.io, "this is not json {{{");

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("corrupt-1", sessions[0].id);
    try std.testing.expect(sessions[0].has_prd);
    try std.testing.expect(sessions[0].has_conversation);
    try std.testing.expectEqualStrings("hello", sessions[0].first_prompt.?);
}

test "listSessions rebuilds when the index contains an invalid session id" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "valid-1", false);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    var idx = try std.Io.Dir.cwd().createFile(std.testing.io, index_path, .{});
    defer idx.close(std.testing.io);
    try idx.writeStreamingAll(std.testing.io,
        \\[{"id":"../evil","has_prd":false,"has_conversation":false,"planning_mode":false,"first_prompt":null,"last_modified":1}]
    );
    // Make the index strictly newer than the sessions dir so the staleness
    // check cannot mask the invalid-id path.
    try setFileMtime(std.testing.io, index_path, std.Io.Timestamp.fromNanoseconds(2_000_000_000_000_000_000));

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| std.testing.allocator.free(s.id);
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("valid-1", sessions[0].id);
}

test "listSessions rebuilds from scan on an oversized index" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "over-1", false);

    // An index larger than the 64 MB read limit must trigger a rebuild rather
    // than a crash or a truncated listing.
    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    var big = try std.Io.Dir.cwd().createFile(std.testing.io, index_path, .{});
    defer big.close(std.testing.io);
    const chunk = [_]u8{'x'} ** (1024 * 1024);
    var written: usize = 0;
    while (written < 64 * 1024 * 1024 + 1024) : (written += chunk.len) {
        try big.writeStreamingAll(std.testing.io, &chunk);
    }

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("over-1", sessions[0].id);
}

test "listSessions rebuilds when the sessions dir is newer than the index" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "a-1", false);
    try createTestSessionDir(std.testing.io, test_dir, "b-2", false);

    // First listing writes the index; the sessions dir is then older than it.
    const first = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (first) |s| std.testing.allocator.free(s.id);
        std.testing.allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 2), first.len);

    // Age the index and add a session directory so the sessions dir mtime is
    // newer than the index mtime; the next listing must rebuild.
    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    try setFileMtime(std.testing.io, index_path, std.Io.Timestamp.fromNanoseconds(1_000_000_000_000));
    try createTestSessionDir(std.testing.io, test_dir, "c-3", false);

    const second = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (second) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(second);
    }
    try std.testing.expectEqual(@as(usize, 3), second.len);
    const has_c = for (second) |s| {
        if (std.mem.eql(u8, s.id, "c-3")) break true;
    } else false;
    try std.testing.expect(has_c);
}

test "upsertSessionInfo adds a new entry and reads it back" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "sess-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = true,
        .has_conversation = true,
        .planning_mode = true,
        .first_prompt = "hello",
        .last_modified = 100,
    });

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("sess-1", sessions[0].id);
    try std.testing.expect(sessions[0].has_prd);
    try std.testing.expect(sessions[0].has_conversation);
    try std.testing.expect(sessions[0].planning_mode);
    try std.testing.expectEqualStrings("hello", sessions[0].first_prompt.?);
    try std.testing.expectEqual(@as(u64, 100), sessions[0].last_modified);
}

test "upsertSessionInfo updates an existing entry and refreshes last_modified" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "sess-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = "one",
        .last_modified = 100,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = true,
        .has_conversation = true,
        .planning_mode = true,
        .first_prompt = "two",
        .last_modified = 200,
    });
    // Re-upserting the same id must not create a duplicate entry.
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = true,
        .has_conversation = true,
        .planning_mode = true,
        .first_prompt = "two",
        .last_modified = 300,
    });

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expect(sessions[0].has_prd);
    try std.testing.expect(sessions[0].planning_mode);
    try std.testing.expectEqualStrings("two", sessions[0].first_prompt.?);
    try std.testing.expectEqual(@as(u64, 300), sessions[0].last_modified);
}

test "upsertSessionInfo keeps the index sorted by id" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "z-9", false);
    try createTestSessionDir(std.testing.io, test_dir, "a-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "z-9",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "a-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 2,
    });

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqualStrings("a-1", sessions[0].id);
    try std.testing.expectEqualStrings("z-9", sessions[1].id);
}

test "upsertSessionInfo truncates first_prompt beyond 1024 chars and preserves null" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "long-1", false);
    try createTestSessionDir(std.testing.io, test_dir, "null-2", false);

    const long_prompt = [_]u8{'x'} ** 2048;
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "long-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = &long_prompt,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "null-2",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 2,
    });

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    const long = for (sessions) |s| {
        if (std.mem.eql(u8, s.id, "long-1")) break s;
    } else unreachable;
    const null_ = for (sessions) |s| {
        if (std.mem.eql(u8, s.id, "null-2")) break s;
    } else unreachable;
    try std.testing.expectEqual(@as(usize, 1024), long.first_prompt.?.len);
    try std.testing.expect(null_.first_prompt == null);
}

test "removeSessionFromIndex removes a single entry" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "keep-1", false);
    try createTestSessionDir(std.testing.io, test_dir, "drop-2", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "keep-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "drop-2",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 2,
    });

    try removeSessionFromIndex(std.testing.allocator, std.testing.io, test_dir, "drop-2");

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("keep-1", sessions[0].id);
}

test "upsert writes the index with owner-only permissions" {
    if (comptime builtin.os.tag == .windows) return;

    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "perm-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "perm-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, index_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0), st.permissions.toMode() & 0o077);
}

test "upsert leaves no temp file behind" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try createTestSessionDir(std.testing.io, test_dir, "atomic-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "atomic-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    const tmp_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json.tmp" });
    defer std.testing.allocator.free(tmp_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, tmp_path, .{}));
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

test "findLatestSession returns most recently modified session with conversation" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    // Sessions exist on disk; the last_modified values come from upserts,
    // which is what --resume now reads instead of messages.json mtimes.
    try createTestSessionDirFull(std.testing.io, test_dir, "a-older", false, true);
    try createTestSessionDirFull(std.testing.io, test_dir, "z-newer", false, true);
    try createTestSessionDirFull(std.testing.io, test_dir, "no-conv", false, false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "a-older",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 100,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "z-newer",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 200,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "no-conv",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 300,
    });

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

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "plain-1",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "plain-2",
        .has_prd = true,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 2,
    });

    const found = try findLatestSession(std.testing.allocator, std.testing.io, test_dir);
    try std.testing.expect(found == null);
}

test "pruneSessions removes all but current and rebuilds the index" {
    const test_dir = try testBaseDir(std.testing.allocator, std.testing.io);
    defer {
        cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try createTestSessionDir(std.testing.io, test_dir, "current-1", true);
    try createTestSessionDir(std.testing.io, test_dir, "old-1", true);
    try createTestSessionDir(std.testing.io, test_dir, "old-2", false);

    // Seed the index so prune has entries to remove from it.
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "current-1",
        .has_prd = true,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "old-1",
        .has_prd = true,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 2,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "old-2",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 3,
    });

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

    // The rebuilt index no longer contains the pruned ids.
    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, index_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "old-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "old-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "current-1") != null);
}
