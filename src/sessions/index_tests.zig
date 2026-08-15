//! Tests for the sessions index (`sessions.json`) module. Kept in a separate
//! file so `index.zig` stays focused on the production implementation.
const std = @import("std");
const builtin = @import("builtin");
const core_session = @import("../core/session.zig");
const index = @import("index.zig");

const sessionsPath = index.sessionsPath;
const listSessions = index.listSessions;
const upsertSessionInfo = index.upsertSessionInfo;
const removeSessionFromIndex = index.removeSessionFromIndex;
const pruneSessions = index.pruneSessions;
const index_filename = index.index_filename;
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
    const default_index_read_limit = index.index_read_limit;
    index.index_read_limit = 4 * 1024;
    defer index.index_read_limit = default_index_read_limit;

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
    while (written < index.index_read_limit + 64) : (written += chunk.len) {
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
