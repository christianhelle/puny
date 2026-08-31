const std = @import("std");
const http_client = @import("client.zig");
const openai = @import("openai.zig");
const opencode = @import("opencode_zen.zig");

pub const default_base_url = "https://opencode.ai/zen/go";

pub fn isSupportedModel(_: []const u8) bool {
    return true;
}

pub fn isAnthropicModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "minimax-") or
        std.mem.startsWith(u8, model_id, "qwen");
}

pub fn isResponsesModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "muse-spark-");
}

pub const ModelInfo = opencode.ModelInfo;
pub const ModelsList = opencode.ModelsList;
pub const parseModels = opencode.parseModels;
pub const toSharedModels = opencode.toSharedModels;
pub const listModelsRaw = opencode.listModelsRaw;

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

test "isAnthropicModel detects minimax and qwen families" {
    try std.testing.expect(isAnthropicModel("minimax-m3"));
    try std.testing.expect(isAnthropicModel("minimax-m2.7"));
    try std.testing.expect(isAnthropicModel("minimax-m2.5"));
    try std.testing.expect(isAnthropicModel("qwen3.7-max"));
    try std.testing.expect(isAnthropicModel("qwen3.7-plus"));
    try std.testing.expect(isAnthropicModel("qwen3.6-plus"));
    try std.testing.expect(!isAnthropicModel("deepseek-v4-flash"));
    try std.testing.expect(!isAnthropicModel("grok-4.5"));
    try std.testing.expect(!isAnthropicModel("kimi-k2.7-code"));
}

test "isAnthropicModel requires the family prefix" {
    try std.testing.expect(!isAnthropicModel("minimax"));
    try std.testing.expect(!isAnthropicModel(""));
    try std.testing.expect(!isAnthropicModel("xqwen3.7-max"));
}

test "isSupportedModel accepts any model id" {
    try std.testing.expect(isSupportedModel("deepseek-v4-pro"));
    try std.testing.expect(isSupportedModel(""));
}

test "isResponsesModel detects muse-spark family" {
    try std.testing.expect(isResponsesModel("muse-spark-1.2-contributor"));
    try std.testing.expect(isResponsesModel("muse-spark-1.2"));
    try std.testing.expect(isResponsesModel("muse-spark-"));
    try std.testing.expect(!isResponsesModel("deepseek-v4-flash"));
    try std.testing.expect(!isResponsesModel("muse-spark"));
    try std.testing.expect(!isResponsesModel(""));
    try std.testing.expect(!isResponsesModel("xmuse-spark-1.2"));
}

const TestModelsServer = struct {
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

fn startTestModelsServer(status: std.http.Status, body: []const u8) !*TestModelsServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(TestModelsServer);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    const thread = try std.Thread.spawn(.{}, TestModelsServer.serve, .{ctx});
    thread.detach();
    return ctx;
}

fn stopTestModelsServer(ctx: *TestModelsServer) void {
    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn testClientFor(base_url: []const u8) http_client.Client {
    var client = http_client.Client.init(std.testing.allocator, std.testing.io, "");
    client.withBaseUrl(base_url);
    return client;
}

test "listModels parses a successful model list response" {
    const body =
        \\{"data":[
        \\  {"id":"minimax-m3","owned_by":"opencode"},
        \\  {"id":"qwen3.7-max"}
        \\]}
    ;
    const ctx = try startTestModelsServer(.ok, body);
    defer stopTestModelsServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var client = testClientFor(url);
    defer client.deinit();

    var owned = try listModels(&client);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.value().data.len);
    try std.testing.expectEqualStrings("minimax-m3", owned.value().data[0].id);
    try std.testing.expectEqualStrings("opencode", owned.value().data[0].owned_by);
    try std.testing.expectEqualStrings("qwen3.7-max", owned.value().data[1].id);
    try std.testing.expectEqualStrings("opencode", owned.value().data[1].owned_by);
}

test "listModels returns ResponseError for a non-success status" {
    const ctx = try startTestModelsServer(.not_found, "");
    defer stopTestModelsServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var client = testClientFor(url);
    defer client.deinit();

    try std.testing.expectError(error.ResponseError, listModels(&client));
}

test "listModels returns ResponseParseError for an invalid body" {
    const ctx = try startTestModelsServer(.ok, "not json");
    defer stopTestModelsServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var client = testClientFor(url);
    defer client.deinit();

    try std.testing.expectError(error.ResponseParseError, listModels(&client));
}

test "listModels returns ResponseParseError when data is missing" {
    const ctx = try startTestModelsServer(.ok, "{\"other\":[]}");
    defer stopTestModelsServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var client = testClientFor(url);
    defer client.deinit();

    try std.testing.expectError(error.ResponseParseError, listModels(&client));
}
