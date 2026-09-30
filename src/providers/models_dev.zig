const std = @import("std");

// models.dev is the open catalog OpenCode maintains of every provider's
// models and their limits. OpenCode's own `/v1/models` lists ids only, so
// this is where their context windows come from.

const Limit = struct {
    context: ?i64 = null,
    input: ?i64 = null,
};

const CatalogModel = struct {
    limit: Limit = .{},
};

const CatalogProvider = struct {
    models: std.json.ArrayHashMap(CatalogModel) = .{},
};

const Catalog = std.json.ArrayHashMap(CatalogProvider);

/// The tokens a request to `model` of `provider_id` may carry: the input
/// limit when the catalog lists one, since the window also holds the reply,
/// otherwise the context window. Null when the catalog does not say.
pub fn parseContextLength(allocator: std.mem.Allocator, body: []const u8, provider_id: []const u8, model: []const u8) ?usize {
    const parsed = std.json.parseFromSlice(Catalog, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const entry = parsed.value.map.get(provider_id) orelse return null;
    const found = entry.models.map.get(model) orelse return null;
    return positive(found.limit.input) orelse positive(found.limit.context);
}

fn positive(value: ?i64) ?usize {
    const v = value orelse return null;
    if (v <= 0) return null;
    return std.math.cast(usize, v);
}

test "parseContextLength reads a provider model's context limit" {
    const body =
        \\{"opencode":{"id":"opencode","models":{"deepseek-v4-pro":{"id":"deepseek-v4-pro","limit":{"context":1000000,"output":384000}}}},
        \\ "deepseek":{"id":"deepseek","models":{"deepseek-v4-pro":{"limit":{"context":64000}}}}}
    ;
    try std.testing.expectEqual(@as(?usize, 1000000), parseContextLength(std.testing.allocator, body, "opencode", "deepseek-v4-pro"));
}

test "parseContextLength prefers the input limit, which leaves room for the reply" {
    const body =
        \\{"opencode":{"models":{"gpt-5.5":{"limit":{"context":1050000,"input":922000,"output":128000}}}}}
    ;
    try std.testing.expectEqual(@as(?usize, 922000), parseContextLength(std.testing.allocator, body, "opencode", "gpt-5.5"));
}

test "parseContextLength returns null for unknown providers, models, or bad replies" {
    const body =
        \\{"opencode":{"models":{"unlimited":{"limit":{"context":0}},"nolimit":{"id":"nolimit"}}}}
    ;
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode-go", "unlimited"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode", "missing"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode", "unlimited"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode", "nolimit"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, "not json", "opencode", "x"));
}
