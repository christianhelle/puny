const std = @import("std");
const client = @import("client.zig");

pub const ModelInfo = struct {
    key: []const u8,
    display_name: []const u8,
    publisher: []const u8,
    max_context_length: i64,
};

pub const ModelsList = struct {
    models: []const ModelInfo,
};

pub fn listModels(http_client: *client.Client) !client.Owned(ModelsList) {
    const allocator = http_client.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/api/v1/models", .{http_client.base_url});

    var raw = try client.requestRaw(http_client, std.http.Method.GET, uri_buf.written(), null);
    errdefer raw.deinit();

    if (raw.status.class() != .success) {
        if (client.isAuthFailure(raw.status)) client.printAuthHint(http_client.io);
        raw.deinit();
        return error.ResponseError;
    }

    const parsed = try std.json.parseFromSlice(ModelsList, allocator, raw.body, .{ .ignore_unknown_fields = true });
    const body = try allocator.dupe(u8, raw.body);
    raw.deinit();

    return .{
        .allocator = allocator,
        .body = body,
        .parsed = parsed,
    };
}

/// Convert an LM-Studio-specific model list into the app-wide shared model list.
/// The source `owned` is deinitialized; ownership of the returned value is transferred.
pub fn toSharedModels(owned: *client.Owned(ModelsList)) !client.Owned(client.ModelsList) {
    const allocator = owned.allocator;
    const source = owned.value();

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    var models = try arena_alloc.alloc(client.Model, source.models.len);
    for (source.models, 0..) |m, i| {
        models[i] = .{
            .id = try arena_alloc.dupe(u8, m.key),
            .display_name = try arena_alloc.dupe(u8, m.display_name),
            .provider = try arena_alloc.dupe(u8, m.publisher),
            .context_length = m.max_context_length,
        };
    }

    owned.deinit();

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{
            .arena = arena,
            .value = .{ .models = models },
        },
    };
}
