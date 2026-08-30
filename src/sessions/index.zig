const std = @import("std");
const builtin = @import("builtin");
const core_session = @import("../core/session.zig");
const atomic_write = @import("atomic_write.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");

const SessionInfo = types.SessionInfo;
const dupeSessionInfo = types.dupeSessionInfo;
const lessThan = types.lessThan;
const isValidSessionId = validate.isValidSessionId;
const truncateFirstPrompt = validate.truncateFirstPrompt;

/// Read limit for the sessions index file. A `var` so tests can override it
/// and exercise the StreamTooLong path without writing tens of megabytes.
var index_read_limit: usize = 64 * 1024 * 1024;
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
    std.mem.sort(SessionInfo, entries, {}, lessThan);
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
        // the caller's arena. It is backed by the caller's allocator so these
        // transient allocations stay observable and bounded by it.
        var entry_arena = std.heap.ArenaAllocator.init(arena);
        defer entry_arena.deinit();
        const entry_tmp = entry_arena.allocator();

        const dir_path = try std.fs.path.join(entry_tmp, &.{ sessions_dir_path, id });
        const has_prd = core_session.sessionHasPlan(io, dir_path);

        const msg_path = try core_session.messagesPath(entry_tmp, sessions_dir_path, id);
        const msg_stat = std.Io.Dir.cwd().statFile(io, msg_path, .{}) catch null;
        const has_conversation = msg_stat != null;

        const meta_path = try core_session.sessionMetaPath(entry_tmp, sessions_dir_path, id);
        const meta = core_session.readSessionMetaJson(io, entry_tmp, meta_path) catch |err| blk: {
            // One unreadable session.json must not fail the whole listing; fall
            // back to a default entry like the missing/oversized cases do.
            std.log.warn("failed to read session meta at {s}: {s}", .{ meta_path, @errorName(err) });
            break :blk core_session.SessionMeta{ .planning_mode = false, .review_mode = false, .first_prompt = null };
        };

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
            .review_mode = meta.review_mode,
            .first_prompt = first_prompt,
            .last_modified = last_modified,
        });
    }

    std.mem.sort(SessionInfo, list.items, {}, lessThan);
    const entries = try list.toOwnedSlice(arena);
    try writeIndex(io, arena, base_dir, entries);
    return entries;
}

/// Writes `entries` to `base_dir/sessions.json` as a bare JSON array through
/// the shared atomic-write helper, which stages a temp file, applies
/// owner-only permissions, stamps the mtime past the sessions directory, and
/// renames it into place. All transient path and buffer memory lives in a
/// scratch arena released before returning.
fn writeIndex(io: std.Io, allocator: std.mem.Allocator, base_dir: []const u8, entries: []const SessionInfo) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const buffer = try std.json.Stringify.valueAlloc(scratch, entries, .{ .whitespace = .indent_2 });
    const sessions_dir_path = try std.fs.path.join(scratch, &.{ base_dir, "sessions" });

    try atomic_write.writeAtomically(io, scratch, base_dir, index_filename, buffer, .{
        .newer_than = sessions_dir_path,
        .restrict_permissions = true,
    });
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
        .review_mode = info.review_mode,
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

/// Deletes every session directory except `current_id` ("" deletes all, as
/// today), then rebuilds the index from the remaining directories so pruned
/// entries disappear and any other drift heals in one step. The deletion set
/// is derived from the on-disk sessions directory, not the index, so a stale
/// or corrupt index cannot protect or resurrect orphaned directories.
pub fn pruneSessions(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, current_id: []const u8) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const sessions_dir_path = try std.fs.path.join(scratch, &.{ base_dir, "sessions" });
    var sessions_dir = std.Io.Dir.cwd().openDir(io, sessions_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer sessions_dir.close(io);

    // Collect directory names first so deleting entries cannot disturb the
    // live iterator.
    var to_delete: std.ArrayList([]const u8) = .empty;
    defer to_delete.deinit(scratch);
    var it = sessions_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, current_id)) continue;
        try to_delete.append(scratch, try scratch.dupe(u8, entry.name));
    }

    for (to_delete.items) |id| {
        const dir_path = try std.fs.path.join(scratch, &.{ sessions_dir_path, id });
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    }
    _ = try rebuildSessionsIndex(scratch, io, base_dir);
}

fn timestampToNs(ts: std.Io.Timestamp) ?u64 {
    if (ts.nanoseconds < 0) return null;
    return @intCast(ts.nanoseconds);
}

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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createSessionDir(std.testing.io, test_dir);

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer std.testing.allocator.free(sessions);
    try std.testing.expectEqual(@as(usize, 0), sessions.len);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, index_path, .{}));
}

test "testBaseDir wipes leftovers from an interrupted run" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "stale-1", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "stale-2", false);
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "stale-1",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    const reset = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, reset);
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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "abc-111", true);
    try f.createTestSessionDir(std.testing.io, test_dir, "abc-222", false);

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

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, index_path, .{});
    try std.testing.expect(st.size > 0);
}

test "listSessions detects conversation" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDirFull(std.testing.io, test_dir, "conv-1", false, true);
    try f.createTestSessionDir(std.testing.io, test_dir, "plain-2", false);

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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "big-meta", false);

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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "huge-meta", false);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    const meta_path = try core_session.sessionMetaPath(std.testing.allocator, sessions_dir, "huge-meta");
    defer std.testing.allocator.free(meta_path);

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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    const prompt_len = 512 * 1024;
    const chunk = [_]u8{'x'} ** (64 * 1024);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const id = try std.fmt.allocPrint(std.testing.allocator, "big-{d}", .{i});
        defer std.testing.allocator.free(id);
        try f.createTestSessionDir(std.testing.io, test_dir, id, false);

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

    var tracking = f.PeakTrackingAllocator{ .backing = std.testing.allocator };
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

    const retained = 4 * (36 + 1024);
    try std.testing.expect(tracking.live <= retained + 16 * 1024);
}

test "listSessions rebuilds from scan on a corrupt index" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDirFull(std.testing.io, test_dir, "corrupt-1", true, true);

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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "valid-1", false);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    var idx = try std.Io.Dir.cwd().createFile(std.testing.io, index_path, .{});
    defer idx.close(std.testing.io);
    try idx.writeStreamingAll(std.testing.io,
        \\[{"id":"../evil","has_prd":false,"has_conversation":false,"planning_mode":false,"first_prompt":null,"last_modified":1}]
    );
    try f.setFileMtime(std.testing.io, index_path, std.Io.Timestamp.fromNanoseconds(2_000_000_000_000_000_000));

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| std.testing.allocator.free(s.id);
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("valid-1", sessions[0].id);
}

test "listSessions tolerates an unreadable session meta file" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "blocked-1", false);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    const meta_path = try core_session.sessionMetaPath(std.testing.allocator, sessions_dir, "blocked-1");
    defer std.testing.allocator.free(meta_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, meta_path);

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| std.testing.allocator.free(s.id);
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("blocked-1", sessions[0].id);
    try std.testing.expect(sessions[0].first_prompt == null);
}

test "listSessions rebuilds from scan on an oversized index" {
    const f = @import("fixtures.zig");
    const default_index_read_limit = index_read_limit;
    index_read_limit = 4 * 1024;
    defer index_read_limit = default_index_read_limit;

    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "over-1", false);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    var big = try std.Io.Dir.cwd().createFile(std.testing.io, index_path, .{});
    defer big.close(std.testing.io);
    const chunk = [_]u8{'x'} ** 1024;
    var written: usize = 0;
    while (written < index_read_limit + 64) : (written += chunk.len) {
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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "a-1", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "b-2", false);

    const first = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (first) |s| std.testing.allocator.free(s.id);
        std.testing.allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 2), first.len);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    try f.setFileMtime(std.testing.io, index_path, std.Io.Timestamp.fromNanoseconds(1_000_000_000_000));
    try f.createTestSessionDir(std.testing.io, test_dir, "c-3", false);

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

test "listSessions sorts entries from an unsorted index by id" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "zzz", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "aaa", false);

    // Write an index with entries in reverse order. Both ids map to real
    // session directories, so the index is parseable and considered valid.
    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = index_path,
        .data =
        \\[{"id":"zzz","has_prd":false,"has_conversation":false,"planning_mode":false,"first_prompt":null,"last_modified":2},{"id":"aaa","has_prd":false,"has_conversation":false,"planning_mode":false,"first_prompt":null,"last_modified":1}]
        ,
    });

    try f.setFileMtime(std.testing.io, index_path, std.Io.Timestamp.fromNanoseconds(std.time.ns_per_hour * 24 * 365 * 100));

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqualStrings("aaa", sessions[0].id);
    try std.testing.expectEqualStrings("zzz", sessions[1].id);
}

test "upsertSessionInfo adds a new entry and reads it back" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "sess-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = true,
        .has_conversation = true,
        .planning_mode = true,
        .review_mode = false,
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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "sess-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = "one",
        .last_modified = 100,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = true,
        .has_conversation = true,
        .planning_mode = true,
        .review_mode = false,
        .first_prompt = "two",
        .last_modified = 200,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "sess-1",
        .has_prd = true,
        .has_conversation = true,
        .planning_mode = true,
        .review_mode = false,
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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "z-9", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "a-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "z-9",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "a-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "long-1", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "null-2", false);

    const long_prompt = [_]u8{'x'} ** 2048;
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "long-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = &long_prompt,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "null-2",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .review_mode = false,
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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "keep-1", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "drop-2", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "keep-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "drop-2",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
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

    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "perm-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "perm-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, index_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0), st.permissions.toMode() & 0o077);
}

test "upsert leaves no temp file behind" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "atomic-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "atomic-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, test_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, index_filename ++ "."));
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}

test "pruneSessions removes all but current and rebuilds the index" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "current-1", true);
    try f.createTestSessionDir(std.testing.io, test_dir, "old-1", true);
    try f.createTestSessionDir(std.testing.io, test_dir, "old-2", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "current-1",
        .has_prd = true,
        .has_conversation = false,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "old-1",
        .has_prd = true,
        .has_conversation = false,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 2,
    });
    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "old-2",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .review_mode = false,
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

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, index_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "old-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "old-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "current-1") != null);
}

test "pruneSessions removes orphaned directories absent from the index" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "keep-1", true);
    try f.createTestSessionDir(std.testing.io, test_dir, "orphan-1", true);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "keep-1",
        .has_prd = true,
        .has_conversation = false,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    try pruneSessions(std.testing.allocator, std.testing.io, test_dir, "keep-1");

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

    const orphan_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "orphan-1" });
    defer std.testing.allocator.free(orphan_dir);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, orphan_dir, .{}));
}

test "sessionsPath errors without a config dir" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.NoConfigDir, sessionsPath(std.testing.allocator, &env));
}

test "timestampToNs returns null for negative timestamps" {
    try std.testing.expectEqual(@as(?u64, null), timestampToNs(std.Io.Timestamp.fromNanoseconds(-1)));
    try std.testing.expectEqual(@as(?u64, 1_000_000), timestampToNs(std.Io.Timestamp.fromNanoseconds(1_000_000)));
}

test "listSessions uses the plan.md mtime when there is no conversation" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "plan-only-1", true);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    const plan_path = try std.fs.path.join(std.testing.allocator, &.{ sessions_dir, "plan-only-1", "plan.md" });
    defer std.testing.allocator.free(plan_path);
    try f.setFileMtime(std.testing.io, plan_path, std.Io.Timestamp.fromNanoseconds(1_500_000_000_000));

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| std.testing.allocator.free(s.id);
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expect(sessions[0].has_prd);
    try std.testing.expect(!sessions[0].has_conversation);
    try std.testing.expectEqual(@as(u64, 1_500_000_000_000), sessions[0].last_modified);
}

test "listSessions falls back to plan.html when plan.md is missing" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "html-only-1", false);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    const html_path = try std.fs.path.join(std.testing.allocator, &.{ sessions_dir, "html-only-1", "plan.html" });
    defer std.testing.allocator.free(html_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = html_path, .data = "<html/>" });
    try f.setFileMtime(std.testing.io, html_path, std.Io.Timestamp.fromNanoseconds(1_600_000_000_000));

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| std.testing.allocator.free(s.id);
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expect(sessions[0].has_prd);
    try std.testing.expectEqual(@as(u64, 1_600_000_000_000), sessions[0].last_modified);
}

test "upsertSessionInfo writes the index even when the sessions directory is missing" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createSessionDir(std.testing.io, test_dir);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "no-dir-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions.json" });
    defer std.testing.allocator.free(index_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, index_path, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "no-dir-1") != null);
}

test "removeSessionFromIndex leaves the index untouched for an unknown id" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createTestSessionDir(std.testing.io, test_dir, "keep-1", false);

    try upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "keep-1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .review_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });

    try removeSessionFromIndex(std.testing.allocator, std.testing.io, test_dir, "unknown-id");

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

test "pruneSessions with an empty current id removes every session" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "drop-a", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "drop-b", true);

    try pruneSessions(std.testing.allocator, std.testing.io, test_dir, "");

    const sessions = try listSessions(std.testing.allocator, std.testing.io, test_dir);
    defer {
        for (sessions) |s| {
            std.testing.allocator.free(s.id);
            if (s.first_prompt) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 0), sessions.len);

    const drop_a = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions", "drop-a" });
    defer std.testing.allocator.free(drop_a);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, drop_a, .{}));
}

test "pruneSessions is a no-op when the sessions directory is missing" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createSessionDir(std.testing.io, test_dir);

    try pruneSessions(std.testing.allocator, std.testing.io, test_dir, "whatever");
}

test "pruneSessions leaves non-directory entries in the sessions directory" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sessions_dir);
    const scratch = try std.fs.path.join(std.testing.allocator, &.{ sessions_dir, "scratch.txt" });
    defer std.testing.allocator.free(scratch);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = scratch, .data = "keep me" });
    try f.createTestSessionDir(std.testing.io, test_dir, "drop-1", false);

    try pruneSessions(std.testing.allocator, std.testing.io, test_dir, "");

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, scratch, std.testing.allocator, std.Io.Limit.limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("keep me", data);
}

test "listSessions propagates a stat failure for an overlong base dir" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const long = [_]u8{'a'} ** 5000;
    try std.testing.expectError(error.NameTooLong, listSessions(std.testing.allocator, std.testing.io, long[0..]));
}

test "listSessions propagates when the sessions path is a file" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createSessionDir(std.testing.io, test_dir);

    // Replace the sessions directory with a regular file: the initial stat
    // succeeds, the missing index triggers a rebuild, and openDir must fail
    // with NotDir rather than scanning the file.
    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    try std.Io.Dir.cwd().deleteTree(std.testing.io, sessions_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sessions_dir, .data = "not a dir" });

    try std.testing.expectError(error.NotDir, listSessions(std.testing.allocator, std.testing.io, test_dir));
}
