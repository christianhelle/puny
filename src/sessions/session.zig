const std = @import("std");

pub const SessionInfo = struct {
    id: []const u8,
    has_prd: bool,
    has_conversation: bool,
    planning_mode: bool,
    first_prompt: ?[]const u8,
    last_modified: u64,
};

const first_prompt_limit = 1024;
pub var index_read_limit: usize = 64 * 1024 * 1024;
pub const index_filename = "sessions.json";

pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |c| {
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

pub fn dupeSessionInfo(arena: std.mem.Allocator, s: SessionInfo) !SessionInfo {
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

pub fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

pub fn truncateFirstPrompt(arena: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    var end = @min(prompt.len, first_prompt_limit);
    while (end < prompt.len and end > 0 and (prompt[end] & 0xC0) == 0x80) {
        end -= 1;
    }
    return arena.dupe(u8, prompt[0..end]);
}

pub fn timestampToNs(ts: std.Io.Timestamp) ?u64 {
    if (ts.nanoseconds < 0) return null;
    return @intCast(ts.nanoseconds);
}