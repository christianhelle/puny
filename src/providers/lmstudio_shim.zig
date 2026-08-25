const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
const lmstudio = @import("lmstudio/contracts.zig");

pub const ModelInfo = lmstudio.ModelInfo;
pub const ModelsList = lmstudio.ListModelsResponse;

pub fn listModels(http_client: *client.Client) !client.Owned(ModelsList) {
    const allocator = http_client.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/api/v1/models", .{http_client.base_url});

    var raw = try client.requestRaw(http_client, std.http.Method.GET, uri_buf.written(), null);
    defer raw.deinit();

    if (raw.status.class() != .success) {
        if (client.isAuthFailure(raw.status)) client.printAuthHint(http_client.io);
        return error.ResponseError;
    }

    const body = try allocator.dupe(u8, raw.body);
    errdefer allocator.free(body);
    const parsed = try std.json.parseFromSlice(ModelsList, allocator, body, .{ .ignore_unknown_fields = true });

    return .{
        .allocator = allocator,
        .body = body,
        .parsed = parsed,
    };
}

/// Convert a LM-Studio-specific model list into the app-wide shared model list.
pub fn toSharedModels(owned: *client.Owned(ModelsList)) !client.Owned(client.ModelsList) {
    const allocator = owned.allocator;
    const source = owned.value();
    defer owned.deinit();

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    var models_list: std.ArrayList(client.Model) = .empty;
    for (source.models) |m| {
        if (m.key.len == 0) continue;
        const display_name = if (m.display_name.len > 0 and client.isValidUtf8(m.display_name))
            m.display_name
        else
            m.key;
        try models_list.append(arena_alloc, .{
            .id = try arena_alloc.dupe(u8, m.key),
            .display_name = try arena_alloc.dupe(u8, display_name),
            .provider = try arena_alloc.dupe(u8, m.publisher),
            .context_length = m.max_context_length,
        });
    }
    const models = try models_list.toOwnedSlice(arena_alloc);

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{
            .arena = arena,
            .value = .{ .models = models },
        },
    };
}

test "toSharedModels copies LM Studio model fields via generated contracts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"Qwen2.5 7B Instruct","format":"gguf","size_bytes":123,"max_context_length":32768,"loaded_instances":[]}
        \\]}
    ;

    const owned = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("qwen2.5-7b", shared.value().models[0].id);
    try std.testing.expectEqualStrings("Qwen2.5 7B Instruct", shared.value().models[0].display_name);
    try std.testing.expectEqualStrings("lmstudio", shared.value().models[0].provider);
    try std.testing.expectEqual(@as(i64, 32768), shared.value().models[0].context_length);
}

test "toSharedModels falls back to key when display_name is empty" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"","format":"gguf","size_bytes":123,"max_context_length":32768,"loaded_instances":[]}
        \\]}
    ;

    const owned = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqualStrings("qwen2.5-7b", shared.value().models[0].display_name);
}

test "toSharedModels falls back to key when display_name is invalid UTF-8" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    const invalid_name = try arena_alloc.dupe(u8, &[_]u8{ 0xff, 0xfe, 'a' });
    const models = try arena_alloc.alloc(ModelInfo, 1);
    models[0] = .{
        .key = "qwen2.5-7b",
        .display_name = invalid_name,
        .publisher = "lmstudio",
        .max_context_length = 32768,
        .type = "llm",
        .format = "gguf",
        .size_bytes = 123,
        .loaded_instances = &.{},
    };

    var wrapped = client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{
            .arena = arena,
            .value = .{ .models = models },
        },
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqualStrings("qwen2.5-7b", shared.value().models[0].display_name);
}

test "toSharedModels skips LM Studio models with empty key" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"type":"llm","publisher":"lmstudio","key":"","display_name":"","format":"gguf","size_bytes":123,"max_context_length":32768,"loaded_instances":[]},
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"Qwen2.5 7B","format":"gguf","size_bytes":123,"max_context_length":32768,"loaded_instances":[]}
        \\]}
    ;
    const owned = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };
    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("qwen2.5-7b", shared.value().models[0].id);
}

test "toSharedModels handles null format" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"Qwen","format":null,"size_bytes":123,"max_context_length":32768,"loaded_instances":[]}
        \\]}
    ;
    const owned = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };
    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
}
