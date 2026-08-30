const std = @import("std");

pub const SessionInfo = struct {
    id: []const u8,
    has_prd: bool,
    has_conversation: bool,
    planning_mode: bool,
    review_mode: bool,
    first_prompt: ?[]const u8,
    last_modified: u64,
};

pub fn dupeSessionInfo(arena: std.mem.Allocator, s: SessionInfo) !SessionInfo {
    const id = try arena.dupe(u8, s.id);
    errdefer arena.free(id);
    const first_prompt = if (s.first_prompt) |p| try arena.dupe(u8, p) else null;
    return .{
        .id = id,
        .has_prd = s.has_prd,
        .has_conversation = s.has_conversation,
        .planning_mode = s.planning_mode,
        .review_mode = s.review_mode,
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
        .planning_mode = true,
        .review_mode = false,
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
    try std.testing.expect(copy.planning_mode);
    try std.testing.expect(!copy.review_mode);
    try std.testing.expectEqual(@as(u64, 42), copy.last_modified);
}

test "lessThan orders session ids" {
    const a = SessionInfo{ .id = "aaa", .has_prd = false, .has_conversation = false, .planning_mode = false, .review_mode = false, .first_prompt = null, .last_modified = 0 };
    const b = SessionInfo{ .id = "bbb", .has_prd = false, .has_conversation = false, .planning_mode = false, .review_mode = false, .first_prompt = null, .last_modified = 0 };
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
        .review_mode = true,
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
    try std.testing.expect(copy.review_mode);
    try std.testing.expectEqual(@as(u64, 7), copy.last_modified);
}

test "lessThan treats an id prefix as smaller" {
    const a = SessionInfo{ .id = "ab", .has_prd = false, .has_conversation = false, .planning_mode = false, .review_mode = false, .first_prompt = null, .last_modified = 0 };
    const b = SessionInfo{ .id = "abc", .has_prd = false, .has_conversation = false, .planning_mode = false, .review_mode = false, .first_prompt = null, .last_modified = 0 };
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(!lessThan({}, b, a));
    try std.testing.expect(!lessThan({}, b, b));
}
