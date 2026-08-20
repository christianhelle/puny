const std = @import("std");
const http_client = @import("client.zig");

pub const anthropic = @import("anthropic.zig");
pub const anthropic_version = anthropic.anthropic_version;
pub const default_max_tokens = anthropic.default_max_tokens;

pub const default_base_url = "https://opencode.ai/zen";

pub fn isSupportedModel(model_id: []const u8) bool {
    // Every OpenCode Zen model is reachable through one of the three
    // transports (OpenAI-compatible, Anthropic, or Google). Prefixes listed
    // here are filtered out of the model picker as unreachable.
    const excluded = [_][]const u8{};

    for (excluded) |prefix| {
        if (std.mem.startsWith(u8, model_id, prefix)) return false;
    }
    return true;
}

pub fn isAnthropicModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "claude-");
}

pub const ModelInfo = struct {
    id: []const u8,
    owned_by: []const u8,
};

pub const ModelsList = struct {
    data: []const ModelInfo,
};

pub fn parseModels(allocator: std.mem.Allocator, response_json: []const u8) !http_client.Owned(ModelsList) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    const items = data.array.items;

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);

    var models: std.ArrayList(ModelInfo) = .empty;

    for (items) |item| {
        const id = if (item.object.get("id")) |v| v.string else continue;
        if (!isSupportedModel(id)) continue;

        const owned_by = if (item.object.get("owned_by")) |v| v.string else "opencode";
        const arena_alloc = arena.allocator();

        try models.append(arena_alloc, .{
            .id = try arena_alloc.dupe(u8, id),
            .owned_by = try arena_alloc.dupe(u8, owned_by),
        });
    }

    const result = std.json.Parsed(ModelsList){
        .arena = arena,
        .value = .{ .data = try models.toOwnedSlice(arena.allocator()) },
    };

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, response_json),
        .parsed = result,
    };
}

/// Convert an OpenCode-specific model list into the app-wide shared model list.
/// The source `owned` is deinitialized; ownership of the returned value is transferred.
const default_context_length: i64 = 1_000_000;

pub fn toSharedModels(owned: *http_client.Owned(ModelsList)) !http_client.Owned(http_client.ModelsList) {
    const allocator = owned.allocator;
    const source = owned.value();

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    var models = try arena_alloc.alloc(http_client.Model, source.data.len);
    for (source.data, 0..) |m, i| {
        models[i] = .{
            .id = try arena_alloc.dupe(u8, m.id),
            .display_name = try arena_alloc.dupe(u8, m.id),
            .provider = try arena_alloc.dupe(u8, m.owned_by),
            .context_length = default_context_length,
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

pub fn listModelsRaw(client: *http_client.Client) !http_client.RawResponse {
    const allocator = client.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/v1/models", .{client.base_url});
    return http_client.requestRaw(client, std.http.Method.GET, uri_buf.written(), null);
}

fn listModelsResult(client: *http_client.Client) !http_client.ApiResult(ModelsList) {
    var raw = try listModelsRaw(client);
    if (raw.status.class() != .success) return .{ .api_error = raw };
    const result = parseModels(client.allocator, raw.body) catch |err| {
        return .{ .parse_error = .{ .raw = raw, .error_name = @errorName(err) } };
    };
    raw.deinit();
    return .{ .ok = result };
}

pub fn listModels(client: *http_client.Client) !http_client.Owned(ModelsList) {
    var result = try listModelsResult(client);
    switch (result) {
        .ok => |ok| return ok,
        .api_error => |*err| {
            if (http_client.isAuthFailure(err.status)) http_client.printAuthHint(client.io);
            err.deinit();
            return error.ResponseError;
        },
        .parse_error => |*err| {
            err.raw.deinit();
            return error.ResponseParseError;
        },
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "isSupportedModel accepts supported model families" {
    try std.testing.expect(isSupportedModel("deepseek-v4-pro"));
    try std.testing.expect(isSupportedModel("deepseek-v4-flash-free"));
    try std.testing.expect(isSupportedModel("kimi-k2.7-code"));
    try std.testing.expect(isSupportedModel("kimi-k2.5"));
    try std.testing.expect(isSupportedModel("glm-5.2"));
    try std.testing.expect(isSupportedModel("minimax-m3"));
    try std.testing.expect(isSupportedModel("grok-4.5"));
    try std.testing.expect(isSupportedModel("grok-build-0.1"));
    try std.testing.expect(isSupportedModel("big-pickle"));
    try std.testing.expect(isSupportedModel("mimo-v2.5-free"));
    try std.testing.expect(isSupportedModel("north-mini-code-free"));
    try std.testing.expect(isSupportedModel("nemotron-3-ultra-free"));
    try std.testing.expect(isSupportedModel("claude-opus-4-8"));
    try std.testing.expect(isSupportedModel("claude-sonnet-4.6"));
    try std.testing.expect(isSupportedModel("claude-haiku-4.5"));
    try std.testing.expect(isSupportedModel("gpt-5.5"));
    try std.testing.expect(isSupportedModel("gpt-5.3-codex"));
    try std.testing.expect(isSupportedModel("gemini-3.5-flash"));
    try std.testing.expect(isSupportedModel("gemini-3.1-pro"));
}

test "isAnthropicModel detects claude families" {
    try std.testing.expect(isAnthropicModel("claude-opus-4-8"));
    try std.testing.expect(isAnthropicModel("claude-sonnet-4.6"));
    try std.testing.expect(isAnthropicModel("claude-haiku-4.5"));
    try std.testing.expect(!isAnthropicModel("deepseek-v4-pro"));
    try std.testing.expect(!isAnthropicModel("kimi-k2.7-code"));
}

test "parseModels maps OpenAI model list" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"deepseek-v4-pro","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"gemini-3.5-flash","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"kimi-k2.7-code","object":"model","created":1784147408,"owned_by":"opencode"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.value().data.len);
    try std.testing.expectEqualStrings("deepseek-v4-pro", result.value().data[0].id);
    try std.testing.expectEqualStrings("opencode", result.value().data[0].owned_by);
    try std.testing.expectEqualStrings("gemini-3.5-flash", result.value().data[1].id);
    try std.testing.expectEqualStrings("kimi-k2.7-code", result.value().data[2].id);
}

test "parseModels ignores unknown fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","extra":true,"data":[
        \\  {"id":"big-pickle","object":"model","created":1784147408,"owned_by":"opencode","unknown_field":123}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.value().data.len);
    try std.testing.expectEqualStrings("big-pickle", result.value().data[0].id);
}

test "parseModels errors when the data field is missing" {
    try std.testing.expectError(error.MissingData, parseModels(std.testing.allocator, "{\"object\":\"list\"}"));
}

test "parseModels skips entries without id and defaults owned_by" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data":[
        \\  {"object":"model","owned_by":"vendor-a"},
        \\  {"id":"alpha","object":"model"},
        \\  {"id":"beta","object":"model","owned_by":"vendor-b"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.value().data.len);
    try std.testing.expectEqualStrings("alpha", result.value().data[0].id);
    try std.testing.expectEqualStrings("opencode", result.value().data[0].owned_by);
    try std.testing.expectEqualStrings("beta", result.value().data[1].id);
    try std.testing.expectEqualStrings("vendor-b", result.value().data[1].owned_by);
}

test "toSharedModels copies zen models into the shared model list" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data":[
        \\  {"id":"alpha","owned_by":"opencode"},
        \\  {"id":"beta","owned_by":"acme"}
        \\]}
    ;

    const parsed = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    var owned = http_client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = parsed,
    };

    var shared = try toSharedModels(&owned);
    defer shared.deinit();

    try std.testing.expectEqual(@as(usize, 2), shared.value().models.len);
    try std.testing.expectEqualStrings("alpha", shared.value().models[0].id);
    try std.testing.expectEqualStrings("alpha", shared.value().models[0].display_name);
    try std.testing.expectEqualStrings("opencode", shared.value().models[0].provider);
    try std.testing.expectEqual(@as(i64, 1_000_000), shared.value().models[0].context_length);
    try std.testing.expectEqualStrings("beta", shared.value().models[1].id);
    try std.testing.expectEqualStrings("acme", shared.value().models[1].provider);
}

// ── listModels server tests ──────────────────────────────────────────

const ModelsServer = struct {
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

fn startModelsServer(status: std.http.Status, body: []const u8) !*ModelsServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(ModelsServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    ctx.thread = try std.Thread.spawn(.{}, ModelsServer.serve, .{ctx});
    return ctx;
}

fn stopModelsServer(ctx: *ModelsServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn clientForServer(ctx: *ModelsServer, arena: std.mem.Allocator) !http_client.Client {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    var c = http_client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    c.withBaseUrl(url);
    return c;
}

test "listModels fetches and parses the model list" {
    const body =
        \\{"data":[{"id":"big-pickle","object":"model","owned_by":"opencode"}]}
    ;
    const ctx = try startModelsServer(.ok, body);
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    var owned = try listModels(&c);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 1), owned.value().data.len);
    try std.testing.expectEqualStrings("big-pickle", owned.value().data[0].id);
}

test "listModels returns ResponseError on API failure" {
    const ctx = try startModelsServer(.internal_server_error, "nope");
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    try std.testing.expectError(error.ResponseError, listModels(&c));
}

test "listModels returns ResponseParseError on invalid body" {
    const ctx = try startModelsServer(.ok, "not json at all");
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    try std.testing.expectError(error.ResponseParseError, listModels(&c));
}

test "listModels returns ResponseError on unauthorized" {
    const ctx = try startModelsServer(.unauthorized, "{}");
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    try std.testing.expectError(error.ResponseError, listModels(&c));
}
