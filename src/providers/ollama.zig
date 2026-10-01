const std = @import("std");
const client = @import("client.zig");

const ContextLookup = client.ContextLookup;

const RunningModel = struct {
    name: []const u8 = "",
    context_length: ?i64 = null,
};

const RunningModels = struct {
    models: []const RunningModel = &.{},
};

/// Asks Ollama's `/api/ps` for the context `model` runs with. Its
/// OpenAI-compatible model list carries no window, and `/api/show` gives the
/// model's trained maximum rather than the context the server loaded it with.
pub fn psContextLength(c: *client.Client, model: []const u8) ContextLookup {
    const allocator = c.allocator;
    const url = std.fmt.allocPrint(allocator, "{s}/api/ps", .{c.base_url}) catch return .unreported;
    defer allocator.free(url);
    var raw = client.requestRaw(c, .GET, url, null) catch return .unreported;
    defer raw.deinit();
    if (raw.status.class() != .success) return .unreported;
    return parsePsContextLength(allocator, raw.body, model);
}

/// The context `model` runs with, from an `/api/ps` reply. Only loaded
/// models are listed, and Ollama names untagged models `<name>:latest`.
/// Ollama versions before `context_length` was added count as unreported.
pub fn parsePsContextLength(allocator: std.mem.Allocator, body: []const u8, model: []const u8) ContextLookup {
    const parsed = std.json.parseFromSlice(RunningModels, allocator, body, .{ .ignore_unknown_fields = true }) catch return .unreported;
    defer parsed.deinit();
    for (parsed.value.models) |running| {
        if (!namesModel(running.name, model)) continue;
        const length = running.context_length orelse return .unreported;
        if (length <= 0) return .unreported;
        return .from(std.math.cast(usize, length));
    }
    return .not_loaded;
}

fn namesModel(name: []const u8, model: []const u8) bool {
    if (std.mem.eql(u8, name, model)) return true;
    const tag = ":latest";
    return name.len == model.len + tag.len and
        std.mem.startsWith(u8, name, model) and
        std.mem.endsWith(u8, name, tag);
}

test "parsePsContextLength reads the context a loaded model runs with" {
    const body =
        \\{"models":[
        \\{"name":"qwen3:8b","model":"qwen3:8b","size":6591830464,"size_vram":5333539264,"context_length":32768},
        \\{"name":"gemma4:latest","model":"gemma4:latest","context_length":4096}
        \\]}
    ;
    try std.testing.expectEqual(ContextLookup{ .size = .{ .prompt = 32768 } }, parsePsContextLength(std.testing.allocator, body, "qwen3:8b"));
}

test "parsePsContextLength matches a model named without its latest tag" {
    const body =
        \\{"models":[{"name":"gemma4:latest","model":"gemma4:latest","context_length":4096}]}
    ;
    try std.testing.expectEqual(ContextLookup{ .size = .{ .prompt = 4096 } }, parsePsContextLength(std.testing.allocator, body, "gemma4"));
}

test "parsePsContextLength says a model missing from the list is not loaded yet" {
    const allocator = std.testing.allocator;
    const body =
        \\{"models":[{"name":"gemma4:latest","context_length":4096}]}
    ;
    try std.testing.expectEqual(ContextLookup.not_loaded, parsePsContextLength(allocator, body, "qwen3:8b"));
    try std.testing.expectEqual(ContextLookup.not_loaded, parsePsContextLength(allocator, "{\"models\":[]}", "gemma4"));
}

test "parsePsContextLength treats older Ollama versions and bad replies as unreported" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(ContextLookup.unreported, parsePsContextLength(allocator, "{\"models\":[{\"name\":\"old:1b\"}]}", "old:1b"));
    try std.testing.expectEqual(ContextLookup.unreported, parsePsContextLength(allocator, "not json", "gemma4"));
}
