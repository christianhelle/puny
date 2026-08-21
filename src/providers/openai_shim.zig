const std = @import("std");
const client = @import("client.zig");
const openai_models = @import("openai/models.zig");

pub const Model = openai_models.Model;
pub const ListModelsResponse = openai_models.ListModelsResponse;

pub const Client = client.Client;

// List models via OpenAI-compatible endpoint, lenient parsing for opencode
pub fn listModels(c: *Client) !client.Owned(ListModelsResponse) {
    // Use raw fetch then lenient parse
    const allocator = c.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/v1/models", .{c.base_url});
    var raw = try client.requestRaw(c, std.http.Method.GET, uri_buf.written(), null);
    errdefer raw.deinit();
    if (raw.status.class() != .success) {
        if (client.isAuthFailure(raw.status)) client.printAuthHint(c.io);
        raw.deinit();
        return error.ResponseError;
    }
    // Try generated parsing first
    const body = try allocator.dupe(u8, raw.body);
    errdefer allocator.free(body);
    if (std.json.parseFromSlice(ListModelsResponse, allocator, body, .{ .ignore_unknown_fields = true })) |parsed| {
        raw.deinit();
        return .{ .allocator = allocator, .body = body, .parsed = parsed };
    } else |_| {
        // Fallback to lenient parsing for opencode minimal responses
        allocator.free(body);
        const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, raw.body, .{ .ignore_unknown_fields = true });
        defer parsed_value.deinit();
        const data = parsed_value.value.object.get("data") orelse {
            raw.deinit();
            return error.ResponseParseError;
        };
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);
        var models: std.ArrayList(Model) = .empty;
        for (data.array.items) |item| {
            const id = if (item.object.get("id")) |v| v.string else continue;
            const owned_by = if (item.object.get("owned_by")) |v| v.string else "opencode";
            const object = if (item.object.get("object")) |v| v.string else "model";
            const created = if (item.object.get("created")) |v| v.integer else 0;
            try models.append(arena.allocator(), .{
                .id = try arena.allocator().dupe(u8, id),
                .owned_by = try arena.allocator().dupe(u8, owned_by),
                .object = try arena.allocator().dupe(u8, object),
                .created = created,
            });
        }
        const result = std.json.Parsed(ListModelsResponse){
            .arena = arena,
            .value = .{ .object = "list", .data = try models.toOwnedSlice(arena.allocator()) },
        };
        const owned_body = try allocator.dupe(u8, raw.body);
        raw.deinit();
        return .{ .allocator = allocator, .body = owned_body, .parsed = result };
    }
}

pub fn toSharedModels(owned: *client.Owned(ListModelsResponse)) !client.Owned(client.ModelsList) {
    const allocator = owned.allocator;
    const source = owned.value();
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();
    var models = try arena_alloc.alloc(client.Model, source.data.len);
    for (source.data, 0..) |m, i| {
        models[i] = .{
            .id = try arena_alloc.dupe(u8, m.id),
            .display_name = try arena_alloc.dupe(u8, m.id),
            .provider = try arena_alloc.dupe(u8, m.owned_by),
            .context_length = 0,
        };
    }
    owned.deinit();
    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{ .arena = arena, .value = .{ .models = models } },
    };
}

test "toSharedModels copies openai models" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[{"id":"alpha","object":"model","created":123,"owned_by":"opencode"}]}
    ;
    const parsed = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var owned = client.Owned(ListModelsResponse){ .allocator = allocator, .body = try allocator.dupe(u8, json), .parsed = parsed };
    var shared = try toSharedModels(&owned);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("alpha", shared.value().models[0].id);
    try std.testing.expectEqualStrings("opencode", shared.value().models[0].provider);
}
