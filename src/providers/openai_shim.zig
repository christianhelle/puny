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
    defer raw.deinit();
    if (raw.status.class() != .success) {
        if (client.isAuthFailure(raw.status)) client.printAuthHint(c.io);
        return error.ResponseError;
    }
    // Try generated parsing first, transferring body ownership on success.
    const body = try allocator.dupe(u8, raw.body);
    if (std.json.parseFromSlice(ListModelsResponse, allocator, body, .{ .ignore_unknown_fields = true })) |parsed| {
        return .{ .allocator = allocator, .body = body, .parsed = parsed };
    } else |_| {
        // Fallback to lenient parsing for opencode minimal responses.
        allocator.free(body);
    }

    const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, raw.body, .{ .ignore_unknown_fields = true });
    defer parsed_value.deinit();

    if (parsed_value.value != .object) return error.ResponseParseError;
    const data = parsed_value.value.object.get("data") orelse return error.ResponseParseError;
    if (data != .array) return error.ResponseParseError;

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    var models: std.ArrayList(Model) = .empty;
    for (data.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val != .string) continue;
        const owned_by = if (item.object.get("owned_by")) |v| if (v == .string) v.string else "opencode" else "opencode";
        const object = if (item.object.get("object")) |v| if (v == .string) v.string else "model" else "model";
        const created = if (item.object.get("created")) |v| if (v == .integer) v.integer else 0 else 0;
        try models.append(arena.allocator(), .{
            .id = try arena.allocator().dupe(u8, id_val.string),
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
    return .{ .allocator = allocator, .body = owned_body, .parsed = result };
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
    var models = try arena_alloc.alloc(client.Model, source.data.len);
    for (source.data, 0..) |m, i| {
        models[i] = .{
            .id = try arena_alloc.dupe(u8, m.id),
            .display_name = try arena_alloc.dupe(u8, m.id),
            .provider = try arena_alloc.dupe(u8, m.owned_by),
            .context_length = 0,
        };
    }
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
    ctx.thread = try std.Thread.spawn(.{}, TestServer.serve, .{ctx});
    return ctx;
}

fn stopTestServer(ctx: *TestServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn testServerUrl(ctx: *TestServer) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
}

fn listModelsFrom(body: []const u8) !client.Owned(ListModelsResponse) {
    const ctx = try startTestServer(.ok, body);
    defer stopTestServer(ctx);
    const url = try testServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "");
    defer c.deinit();
    c.withBaseUrl(url);
    return listModels(&c);
}

fn expectListModelsParseError(body: []const u8) !void {
    var owned = listModelsFrom(body) catch |err| {
        try std.testing.expectEqual(error.ResponseParseError, err);
        return;
    };
    owned.deinit();
    return error.ExpectedParseFailure;
}

test "listModels fallback rejects a non-object root" {
    try expectListModelsParseError("42");
}

test "listModels fallback rejects a missing data array" {
    try expectListModelsParseError("{\"object\":\"list\"}");
}

test "listModels fallback rejects object data" {
    try expectListModelsParseError("{\"data\":{}}");
}

test "listModels fallback skips non-object items" {
    var owned = try listModelsFrom("{\"data\":[[1,2]]}");
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), owned.value().data.len);
}

test "listModels fallback skips malformed items and keeps valid ones" {
    var owned = try listModelsFrom("{\"data\":[null,{\"id\":1},{\"id\":\"ok\",\"created\":\"bad\"},{\"id\":\"kept\"}]}");
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 2), owned.value().data.len);
    try std.testing.expectEqualStrings("ok", owned.value().data[0].id);
    try std.testing.expectEqualStrings("kept", owned.value().data[1].id);
}
