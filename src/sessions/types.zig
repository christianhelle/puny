const std = @import("std");
const AgentMode = @import("../core/mode.zig").AgentMode;

pub const SessionInfo = struct {
    id: []const u8,
    has_prd: bool,
    has_conversation: bool,
    mode: AgentMode = .build,
    planning_mode: bool,
    first_prompt: ?[]const u8,
    last_modified: u64,
};

pub fn dupeSessionInfo(arena: std.mem.Allocator, s: SessionInfo) !SessionInfo {
    const id = try arena.dupe(u8, s.id);
    errdefer arena.free(id);
    const first_prompt = if (s.first_prompt) |p| try arena.dupe(u8, p) else null;
    const mode: AgentMode = if (s.mode == .build and s.planning_mode) .planning else s.mode;
    return .{
        .id = id,
        .has_prd = s.has_prd,
        .has_conversation = s.has_conversation,
        .mode = mode,
        .planning_mode = s.planning_mode,
        .first_prompt = first_prompt,
        .last_modified = s.last_modified,
    };
}

pub fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

test "dupeSessionInfo copies id and first_prompt into the arena" {
    const arena = std.testing.allocator;
    const original = SessionInfo{
        .id = "abc",
        .has_prd = true,
        .has_conversation = false,
        .mode = .review,
        .planning_mode = true,
        .first_prompt = "hello",
        .last_modified = 42,
    };

    const copy = try dupeSessionInfo(arena, original);
    defer {
        arena.free(copy.id);
        if (copy.first_prompt) |p| arena.free(p);
    }

    try std.testing.expectEqualStrings("abc", copy.id);
    try std.testing.expectEqualStrings("hello", copy.first_prompt.?);
    try std.testing.expect(copy.has_prd);
    try std.testing.expect(!copy.has_conversation);
    try std.testing.expectEqual(.review, copy.mode);
    try std.testing.expect(copy.planning_mode);
    try std.testing.expectEqual(@as(u64, 42), copy.last_modified);
}

test "lessThan orders session ids" {
    const a = SessionInfo{ .id = "aaa", .has_prd = false, .has_conversation = false, .planning_mode = false, .first_prompt = null, .last_modified = 0 };
    const b = SessionInfo{ .id = "bbb", .has_prd = false, .has_conversation = false, .planning_mode = false, .first_prompt = null, .last_modified = 0 };
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(!lessThan({}, b, a));
    try std.testing.expect(!lessThan({}, a, a));
}

test "dupeSessionInfo copies fields when first_prompt is null" {
    const arena = std.testing.allocator;
    const original = SessionInfo{
        .id = "s1",
        .has_prd = false,
        .has_conversation = true,
        .planning_mode = false,
        .first_prompt = null,
        .last_modified = 7,
    };

    const copy = try dupeSessionInfo(arena, original);
    defer arena.free(copy.id);

    try std.testing.expectEqualStrings("s1", copy.id);
    try std.testing.expect(copy.first_prompt == null);
    try std.testing.expect(!copy.has_prd);
    try std.testing.expect(copy.has_conversation);
    try std.testing.expect(!copy.planning_mode);
    try std.testing.expectEqual(@as(u64, 7), copy.last_modified);
}

test "dupeSessionInfo maps a legacy planning index entry to planning mode" {
    const original = SessionInfo{
        .id = "legacy-plan",
        .has_prd = true,
        .has_conversation = true,
        .planning_mode = true,
        .first_prompt = null,
        .last_modified = 9,
    };

    const copy = try dupeSessionInfo(std.testing.allocator, original);
    defer std.testing.allocator.free(copy.id);
    try std.testing.expectEqual(.planning, copy.mode);
}

test "lessThan treats an id prefix as smaller" {
    const a = SessionInfo{ .id = "ab", .has_prd = false, .has_conversation = false, .planning_mode = false, .first_prompt = null, .last_modified = 0 };
    const b = SessionInfo{ .id = "abc", .has_prd = false, .has_conversation = false, .planning_mode = false, .first_prompt = null, .last_modified = 0 };
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(!lessThan({}, b, a));
    try std.testing.expect(!lessThan({}, b, b));
}
