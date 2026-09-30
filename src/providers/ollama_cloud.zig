const std = @import("std");
const client = @import("client.zig");

pub const default_base_url = "https://ollama.com";

/// Ollama's OpenAI-compatible model list carries no context window, so ask
/// the native `/api/show` endpoint for `model`. Null when it cannot say.
pub fn showContextLength(c: *client.Client, model: []const u8) ?usize {
    const allocator = c.allocator;
    const payload = std.json.Stringify.valueAlloc(allocator, .{ .model = model }, .{}) catch return null;
    defer allocator.free(payload);
    const url = std.fmt.allocPrint(allocator, "{s}/api/show", .{c.base_url}) catch return null;
    defer allocator.free(url);
    var raw = client.requestRaw(c, .POST, url, payload) catch return null;
    defer raw.deinit();
    if (raw.status.class() != .success) return null;
    return parseShowContextLength(allocator, raw.body);
}

/// The context window in an `/api/show` reply. Ollama reports it under the
/// model's architecture, e.g. `model_info["deepseek_v41.context_length"]`.
pub fn parseShowContextLength(allocator: std.mem.Allocator, body: []const u8) ?usize {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const info = parsed.value.object.get("model_info") orelse return null;
    if (info != .object) return null;
    var it = info.object.iterator();
    while (it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.key_ptr.*, ".context_length")) continue;
        if (entry.value_ptr.* != .integer or entry.value_ptr.integer <= 0) continue;
        return std.math.cast(usize, entry.value_ptr.integer);
    }
    return null;
}

test "parseShowContextLength reads the architecture's context window" {
    const body =
        \\{"capabilities":["completion","tools"],"details":{"family":"deepseek_v41"},"model_info":{"deepseek_v41.context_length":1048576,"deepseek_v41.embedding_length":0,"general.architecture":"deepseek_v41"}}
    ;
    try std.testing.expectEqual(@as(?usize, 1048576), parseShowContextLength(std.testing.allocator, body));
}

test "parseShowContextLength returns null when no window is reported" {
    try std.testing.expectEqual(@as(?usize, null), parseShowContextLength(std.testing.allocator, "{\"model_info\":{\"general.architecture\":\"x\"}}"));
    try std.testing.expectEqual(@as(?usize, null), parseShowContextLength(std.testing.allocator, "{\"error\":\"model retired\"}"));
    try std.testing.expectEqual(@as(?usize, null), parseShowContextLength(std.testing.allocator, "not json"));
}
