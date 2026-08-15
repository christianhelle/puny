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

/// Read limit for the sessions index file. `pub` and `var` so tests can
/// override it and exercise the StreamTooLong path without writing tens of
/// megabytes.
pub var index_read_limit: usize = 64 * 1024 * 1024;
pub const index_filename = "sessions.json";

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
            break :blk core_session.SessionMeta{ .planning_mode = false, .first_prompt = null };
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
