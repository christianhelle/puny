const std = @import("std");

const RunningModel = struct {
    name: []const u8 = "",
    context_length: ?i64 = null,
};

const RunningModels = struct {
    models: []const RunningModel = &.{},
};

/// The context `model` runs with, from an `/api/ps` reply. Only loaded
/// models are listed, and Ollama names untagged models `<name>:latest`.
pub fn parsePsContextLength(allocator: std.mem.Allocator, body: []const u8, model: []const u8) ?usize {
    const parsed = std.json.parseFromSlice(RunningModels, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    for (parsed.value.models) |running| {
        if (!namesModel(running.name, model)) continue;
        const length = running.context_length orelse return null;
        if (length <= 0) return null;
        return std.math.cast(usize, length);
    }
    return null;
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
    try std.testing.expectEqual(@as(?usize, 32768), parsePsContextLength(std.testing.allocator, body, "qwen3:8b"));
}

test "parsePsContextLength matches a model named without its latest tag" {
    const body =
        \\{"models":[{"name":"gemma4:latest","model":"gemma4:latest","context_length":4096}]}
    ;
    try std.testing.expectEqual(@as(?usize, 4096), parsePsContextLength(std.testing.allocator, body, "gemma4"));
}

test "parsePsContextLength returns null when the model is not loaded" {
    const allocator = std.testing.allocator;
    const body =
        \\{"models":[{"name":"gemma4:latest","context_length":4096},{"name":"old:1b"}]}
    ;
    try std.testing.expectEqual(@as(?usize, null), parsePsContextLength(allocator, body, "qwen3:8b"));
    try std.testing.expectEqual(@as(?usize, null), parsePsContextLength(allocator, body, "old:1b"));
    try std.testing.expectEqual(@as(?usize, null), parsePsContextLength(allocator, "{\"models\":[]}", "gemma4"));
    try std.testing.expectEqual(@as(?usize, null), parsePsContextLength(allocator, "not json", "gemma4"));
}
