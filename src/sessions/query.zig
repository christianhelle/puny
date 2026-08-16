const std = @import("std");
const core_session = @import("../core/session.zig");
const types = @import("types.zig");
const index = @import("index.zig");

const SessionInfo = types.SessionInfo;
const dupeSessionInfo = types.dupeSessionInfo;

/// Returns the single session whose id starts with `prefix`, or `null` when
/// there is no match or the prefix is ambiguous. Index-backed; no per-session
/// filesystem access.
pub fn findSessionByPrefix(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, prefix: []const u8) !?SessionInfo {
    var scratch_arena = std.heap.ArenaAllocator.init(arena);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const sessions = try index.listSessions(scratch, io, base_dir);
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

    const sessions = try index.listSessions(scratch, io, base_dir);
    var best: ?SessionInfo = null;
    for (sessions) |s| {
        if (!s.has_conversation) continue;
        if (best == null or s.last_modified > best.?.last_modified) best = s;
    }
    if (best) |s| return try dupeSessionInfo(arena, s);
    return null;
}

test "findSessionByPrefix matches unique prefix" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "abc-111-aaa", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "abc-222-bbb", false);

    const found = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "abc-111");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("abc-111-aaa", found.?.id);
    if (found) |s| {
        std.testing.allocator.free(s.id);
        if (s.first_prompt) |p| std.testing.allocator.free(p);
    }
}

test "findSessionByPrefix returns null on ambiguous or no match" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "abc-111-aaa", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "abc-111-bbb", false);

    const found = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "abc-111");
    try std.testing.expect(found == null);

    const none = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "xyz");
    try std.testing.expect(none == null);
}

test "findSessionByPrefix returns the unique match" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "abc-1", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "abc-2", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "xyz-9", false);

    const unique = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "xyz");
    defer if (unique) |s| {
        if (s.first_prompt) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(s.id);
    };
    try std.testing.expect(unique != null);
    try std.testing.expectEqualStrings("xyz-9", unique.?.id);

    const ambiguous = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "abc");
    try std.testing.expect(ambiguous == null);

    const missing = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "nope");
    try std.testing.expect(missing == null);
}

test "findLatestSession returns most recently modified session with conversation" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDirFull(std.testing.io, test_dir, "a-older", false, true);
    try f.createTestSessionDirFull(std.testing.io, test_dir, "new-session", false, true);
    try f.createTestSessionDir(std.testing.io, test_dir, "no-conversation", false);

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    const old_msg = try core_session.messagesPath(std.testing.allocator, sessions_dir, "a-older");
    defer std.testing.allocator.free(old_msg);
    const new_msg = try core_session.messagesPath(std.testing.allocator, sessions_dir, "new-session");
    defer std.testing.allocator.free(new_msg);
    try f.setFileMtime(std.testing.io, old_msg, std.Io.Timestamp.fromNanoseconds(1_000_000_000_000));
    try f.setFileMtime(std.testing.io, new_msg, std.Io.Timestamp.fromNanoseconds(2_000_000_000_000));

    const latest = try findLatestSession(std.testing.allocator, std.testing.io, test_dir);
    defer if (latest) |s| {
        if (s.first_prompt) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(s.id);
    };
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("new-session", latest.?.id);
}

test "findLatestSession prefers the most recently modified conversation" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDirFull(std.testing.io, test_dir, "a-older", false, true);
    try f.createTestSessionDirFull(std.testing.io, test_dir, "z-newer", false, true);
    try f.createTestSessionDirFull(std.testing.io, test_dir, "no-conv", false, false);

    try index.upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "a-older",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 100,
    });
    try index.upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "z-newer",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 200,
    });
    try index.upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
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
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "plain-1", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "plain-2", true);

    try index.upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
        .id = "plain-1",
        .has_prd = false,
        .has_conversation = false,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 1,
    });
    try index.upsertSessionInfo(std.testing.allocator, std.testing.io, test_dir, .{
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

test "findSessionByPrefix returns null when there are no sessions" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createSessionDir(std.testing.io, test_dir);

    const found = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "abc");
    try std.testing.expect(found == null);
}

test "findSessionByPrefix matches a complete session id" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    try f.createTestSessionDir(std.testing.io, test_dir, "abc-111-aaa", false);
    try f.createTestSessionDir(std.testing.io, test_dir, "abc-222-bbb", false);

    const found = try findSessionByPrefix(std.testing.allocator, std.testing.io, test_dir, "abc-111-aaa");
    defer if (found) |s| {
        if (s.first_prompt) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(s.id);
    };
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("abc-111-aaa", found.?.id);
}

test "findLatestSession returns null when there are no sessions" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }
    try f.createSessionDir(std.testing.io, test_dir);

    const latest = try findLatestSession(std.testing.allocator, std.testing.io, test_dir);
    try std.testing.expect(latest == null);
}

test "findLatestSession returns null for an empty sessions directory" {
    const f = @import("fixtures.zig");
    const test_dir = try f.testBaseDir(std.testing.allocator, std.testing.io, @src().fn_name);
    defer {
        f.cleanupTestDir(std.testing.io, test_dir);
        std.testing.allocator.free(test_dir);
    }

    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "sessions" });
    defer std.testing.allocator.free(sessions_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sessions_dir);

    const latest = try findLatestSession(std.testing.allocator, std.testing.io, test_dir);
    try std.testing.expect(latest == null);
}
