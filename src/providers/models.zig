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

    const body = try allocator.dupe(u8, raw.body);
    errdefer allocator.free(body);
    const parsed = try std.json.parseFromSlice(ModelsList, allocator, body, .{ .ignore_unknown_fields = true });
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
        const display_name = if (m.display_name.len > 0 and client.isValidUtf8(m.display_name))
            m.display_name
        else
            m.key;
        models[i] = .{
            .id = try arena_alloc.dupe(u8, m.key),
            .display_name = try arena_alloc.dupe(u8, display_name),
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

test "toSharedModels copies LM Studio model fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"Qwen2.5 7B Instruct","size_bytes":123,"max_context_length":32768,"loaded_instances":[]}
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
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"","size_bytes":123,"max_context_length":32768,"loaded_instances":[]}
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
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"Qwen 2.5","size_bytes":123,"max_context_length":32768,"loaded_instances":[]}
        \\]}
    ;

    const owned = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    // Corrupt the display name in place to exercise the UTF-8 fallback.
    const name: []u8 = @constCast(owned.value.models[0].display_name);
    name[0] = 0xff;
    var wrapped = client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqualStrings("qwen2.5-7b", shared.value().models[0].display_name);
}

const ListModelsServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    status: std.http.Status = .ok,
    body: []const u8,
    done: std.atomic.Value(bool) = .init(false),

    fn serve(self: *@This()) void {
        defer self.done.store(true, .release);
        var stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);

        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch return;
        request.respond(self.body, .{ .status = self.status }) catch return;
    }
};

fn startListModelsServer(status: std.http.Status, body: []const u8) !*ListModelsServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(ListModelsServer);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    const thread = try std.Thread.spawn(.{}, ListModelsServer.serve, .{ctx});
    thread.detach();
    return ctx;
}

fn stopListModelsServer(ctx: *ListModelsServer) void {
    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

test "listModels parses a successful model list response" {
    const body =
        \\{"models":[
        \\  {"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"Qwen2.5 7B","max_context_length":32768}
        \\]}
    ;
    const ctx = try startListModelsServer(.ok, body);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var http_client = client.Client.init(std.testing.allocator, std.testing.io, "");
    defer http_client.deinit();
    http_client.withBaseUrl(url);

    var owned = try listModels(&http_client);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 1), owned.value().models.len);
    try std.testing.expectEqualStrings("qwen2.5-7b", owned.value().models[0].key);
    try std.testing.expectEqualStrings("Qwen2.5 7B", owned.value().models[0].display_name);
    try std.testing.expectEqualStrings("lmstudio", owned.value().models[0].publisher);
    try std.testing.expectEqual(@as(i64, 32768), owned.value().models[0].max_context_length);

    stopListModelsServer(ctx);
}
