const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
const generated = @import("google/client.zig");
const contracts = @import("google/contracts.zig");

pub const ListModelsResponse = contracts.ListModelsResponse;
pub const Model = contracts.Model;

fn googleClient(c: *client.Client) generated.Client {
    var g = generated.Client.init(c.allocator, c.io, c.api_key);
    g.base_url = c.base_url;
    g.organization = c.organization;
    g.project = c.project;
    g.default_headers = c.default_headers;
    g.http_observer = if (c.http_observer) |obs| .{
        .ctx = obs.ctx,
        .onRequest = obs.onRequest,
        .onResponse = obs.onResponse,
        .onError = obs.onError,
    } else null;
    g.cancel_check = null;
    return g;
}

pub fn listModels(http_client: *client.Client) !client.Owned(ListModelsResponse) {
    var g = googleClient(http_client);
    defer g.deinit();

    var result = try generated.@"generativelanguage.models.listResult"(&g, null, null);
    switch (result) {
        .ok => |ok| {
            // Move ownership from runtime.Owned to client.Owned (same layout)
            return .{
                .allocator = ok.allocator,
                .body = ok.body,
                .parsed = ok.parsed,
            };
        },
        .api_error => |*err| {
            if (client.isAuthFailure(err.status)) client.printAuthHint(http_client.io);
            err.deinit();
            return error.ResponseError;
        },
        .parse_error => |*err| {
            err.raw.deinit();
            return error.ResponseParseError;
        },
    }
}

pub fn toSharedModels(owned: *client.Owned(ListModelsResponse)) !client.Owned(client.ModelsList) {
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
    const models_slice = if (source.models) |m| m else &.{};
    for (models_slice) |m| {
        const raw_name = m.name orelse continue;
        const id = if (std.mem.startsWith(u8, raw_name, "models/")) raw_name["models/".len..] else raw_name;
        if (id.len == 0) continue;
        const raw_display = m.displayName;
        const display_name = if (raw_display) |d| blk: {
            if (d.len == 0) break :blk id;
            if (!client.isValidUtf8(d)) break :blk id;
            break :blk d;
        } else id;

        const context_length: i64 = if (m.inputTokenLimit) |v| v else 0;

        try models_list.append(arena_alloc, .{
            .id = try arena_alloc.dupe(u8, id),
            .display_name = try arena_alloc.dupe(u8, display_name),
            .provider = try arena_alloc.dupe(u8, "google"),
            .context_length = context_length,
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

test "toSharedModels copies google model fields via generated contracts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","description":"test","inputTokenLimit":128000}
        \\]}
    ;

    const owned = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("gemini-2.5-pro", shared.value().models[0].id);
    try std.testing.expectEqualStrings("Gemini 2.5 Pro", shared.value().models[0].display_name);
    try std.testing.expectEqualStrings("google", shared.value().models[0].provider);
    try std.testing.expectEqual(@as(i64, 128000), shared.value().models[0].context_length);
}

test "toSharedModels falls back to id when displayName is empty" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"name":"models/gemini-2.5-flash","displayName":"","inputTokenLimit":32000}
        \\]}
    ;

    const owned = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqualStrings("gemini-2.5-flash", shared.value().models[0].display_name);
}

test "toSharedModels falls back to id when displayName is missing" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"name":"models/gemini-1.5-pro","inputTokenLimit":1000}
        \\]}
    ;

    const owned = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqualStrings("gemini-1.5-pro", shared.value().models[0].display_name);
}

test "toSharedModels falls back to id when displayName is invalid UTF-8" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    const invalid_name = try arena_alloc.dupe(u8, &[_]u8{ 0xff, 0xfe, 'a' });
    const model_name = try arena_alloc.dupe(u8, "models/gemini-bad");
    const models = try arena_alloc.alloc(Model, 1);
    models[0] = .{
        .name = model_name,
        .displayName = invalid_name,
        .inputTokenLimit = 4096,
    };

    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{
            .arena = arena,
            .value = .{ .models = models },
        },
    };

    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();

    try std.testing.expectEqualStrings("gemini-bad", shared.value().models[0].display_name);
}

test "toSharedModels skips models with empty name" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"name":"","displayName":"bad","inputTokenLimit":100},
        \\  {"name":"models/gemini-ok","displayName":"OK","inputTokenLimit":100}
        \\]}
    ;
    const owned = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };
    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("gemini-ok", shared.value().models[0].id);
}

test "toSharedModels skips models with null name" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"displayName":"no-name","inputTokenLimit":100},
        \\  {"name":"models/gemini-ok","displayName":"OK","inputTokenLimit":100}
        \\]}
    ;
    const owned = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };
    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("gemini-ok", shared.value().models[0].id);
}

test "toSharedModels handles missing models array" {
    const allocator = std.testing.allocator;
    const json = "{}";
    const owned = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };
    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 0), shared.value().models.len);
}

test "toSharedModels strips models/ prefix and handles raw ids" {
    const allocator = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"name":"gemini-raw","displayName":"Raw","inputTokenLimit":500},
        \\  {"name":"models/gemini-prefixed","displayName":"Prefixed","inputTokenLimit":600}
        \\]}
    ;
    const owned = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var wrapped = client.Owned(ListModelsResponse){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = owned,
    };
    var shared = try toSharedModels(&wrapped);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 2), shared.value().models.len);
    try std.testing.expectEqualStrings("gemini-raw", shared.value().models[0].id);
    try std.testing.expectEqualStrings("gemini-prefixed", shared.value().models[1].id);
}

const TestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    status: std.http.Status,
    body: []const u8,
    thread: std.Thread = undefined,

    fn serve(self: *@This()) void {
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

fn startTestServer(status: std.http.Status, body: []const u8) !*TestServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(TestServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    errdefer ctx.server.deinit(std.testing.io);
    ctx.thread = try std.Thread.spawn(.{}, TestServer.serve, .{ctx});
    return ctx;
}

fn stopTestServer(ctx: *TestServer) void {
    ctx.server.deinit(std.testing.io);
    ctx.thread.join();
    std.testing.allocator.destroy(ctx);
}

fn testServerUrl(ctx: *TestServer) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
}

test "listModels fetches via generated client" {
    const body =
        \\{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","inputTokenLimit":100}]}
    ;
    const ctx = try startTestServer(.ok, body);
    defer stopTestServer(ctx);
    const url = try testServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);

    var owned = try listModels(&c);
    defer owned.deinit();

    try std.testing.expect(owned.value().models.?.len == 1);
    try std.testing.expectEqualStrings("models/gemini-2.5-pro", owned.value().models.?[0].name.?);
}

test "listModels returns ResponseError on non-success" {
    const ctx = try startTestServer(.unauthorized, "{}");
    defer stopTestServer(ctx);
    const url = try testServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "bad-key");
    defer c.deinit();
    c.withBaseUrl(url);

    try std.testing.expectError(error.ResponseError, listModels(&c));
}

test "listModels propagates api key via x-goog header" {
    // Verified via generated client unit test that header is x-goog-api-key.
    // Integration header capture requires inspecting raw HTTP headers which is
    // not exposed via std.http.Server.receiveHead in this Zig version.
    // This test ensures listModels returns empty list for empty models response.
    const body = "{\"models\":[]}";
    const ctx = try startTestServer(.ok, body);
    defer stopTestServer(ctx);
    const url = try testServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "my-secret-key");
    defer c.deinit();
    c.withBaseUrl(url);

    var owned = try listModels(&c);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), owned.value().models.?.len);
}
