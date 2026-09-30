const std = @import("std");
const client = @import("client.zig");

pub const catalog_url = "https://models.dev/api.json";

// models.dev is the open catalog OpenCode maintains of every provider's
// models and their limits. OpenCode's own `/v1/models` lists ids only, so
// this is where their context windows come from.

const Limit = struct {
    context: ?i64 = null,
    input: ?i64 = null,
};

const CatalogModel = struct {
    limit: Limit = .{},
};

const CatalogProvider = struct {
    models: std.json.ArrayHashMap(CatalogModel) = .{},
};

const Catalog = std.json.ArrayHashMap(CatalogProvider);

/// The tokens a request to `model` of `provider_id` may carry: the input
/// limit when the catalog lists one, since the window also holds the reply,
/// otherwise the context window. Null when the catalog does not say.
pub fn parseContextLength(allocator: std.mem.Allocator, body: []const u8, provider_id: []const u8, model: []const u8) ?usize {
    const parsed = std.json.parseFromSlice(Catalog, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const entry = parsed.value.map.get(provider_id) orelse return null;
    const found = entry.models.map.get(model) orelse return null;
    return positive(found.limit.input) orelse positive(found.limit.context);
}

/// Downloads the catalog at `url` and looks up `model` of `provider_id`.
/// A client of its own keeps the provider's API key away from the catalog.
pub fn fetchContextLength(allocator: std.mem.Allocator, io: std.Io, url: []const u8, provider_id: []const u8, model: []const u8) ?usize {
    var c = client.Client.init(allocator, io, "");
    defer c.deinit();
    var raw = client.requestRaw(&c, .GET, url, null) catch return null;
    defer raw.deinit();
    if (raw.status.class() != .success) return null;
    return parseContextLength(allocator, raw.body, provider_id, model);
}

fn positive(value: ?i64) ?usize {
    const v = value orelse return null;
    if (v <= 0) return null;
    return std.math.cast(usize, v);
}

test "parseContextLength reads a provider model's context limit" {
    const body =
        \\{"opencode":{"id":"opencode","models":{"deepseek-v4-pro":{"id":"deepseek-v4-pro","limit":{"context":1000000,"output":384000}}}},
        \\ "deepseek":{"id":"deepseek","models":{"deepseek-v4-pro":{"limit":{"context":64000}}}}}
    ;
    try std.testing.expectEqual(@as(?usize, 1000000), parseContextLength(std.testing.allocator, body, "opencode", "deepseek-v4-pro"));
}

test "parseContextLength prefers the input limit, which leaves room for the reply" {
    const body =
        \\{"opencode":{"models":{"gpt-5.5":{"limit":{"context":1050000,"input":922000,"output":128000}}}}}
    ;
    try std.testing.expectEqual(@as(?usize, 922000), parseContextLength(std.testing.allocator, body, "opencode", "gpt-5.5"));
}

test "parseContextLength returns null for unknown providers, models, or bad replies" {
    const body =
        \\{"opencode":{"models":{"unlimited":{"limit":{"context":0}},"nolimit":{"id":"nolimit"}}}}
    ;
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode-go", "unlimited"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode", "missing"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode", "unlimited"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, body, "opencode", "nolimit"));
    try std.testing.expectEqual(@as(?usize, null), parseContextLength(allocator, "not json", "opencode", "x"));
}

test "fetchContextLength downloads the catalog without credentials" {
    const server = try CatalogServer.start(
        \\{"opencode-go":{"models":{"kimi-k3":{"limit":{"context":1048576}}}}}
    );
    defer server.stop();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/api.json", .{server.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    try std.testing.expectEqual(@as(?usize, 1048576), fetchContextLength(std.testing.allocator, std.testing.io, url, "opencode-go", "kimi-k3"));
    try std.testing.expect(server.saw_request);
    try std.testing.expect(!server.saw_authorization);
}

test "fetchContextLength returns null when the catalog is unreachable" {
    try std.testing.expectEqual(@as(?usize, null), fetchContextLength(std.testing.allocator, std.testing.io, "http://127.0.0.1:1/api.json", "opencode", "x"));
}

const CatalogServer = struct {
    server: std.Io.net.Server,
    body: []const u8,
    thread: std.Thread = undefined,
    saw_request: bool = false,
    saw_authorization: bool = false,

    fn start(body: []const u8) !*CatalogServer {
        const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        const ctx = try std.testing.allocator.create(CatalogServer);
        errdefer std.testing.allocator.destroy(ctx);
        ctx.* = .{ .server = try std.Io.net.IpAddress.listen(&address, std.testing.io, .{}), .body = body };
        errdefer ctx.server.deinit(std.testing.io);
        ctx.thread = try std.Thread.spawn(.{}, serve, .{ctx});
        return ctx;
    }

    fn stop(self: *CatalogServer) void {
        self.server.deinit(std.testing.io);
        self.thread.join();
        std.testing.allocator.destroy(self);
    }

    fn serve(self: *CatalogServer) void {
        var stream = self.server.accept(std.testing.io) catch return;
        defer stream.close(std.testing.io);

        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var reader = stream.reader(std.testing.io, &in_buf);
        var writer = stream.writer(std.testing.io, &out_buf);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch return;
        self.saw_request = true;
        var it = request.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) self.saw_authorization = true;
        }
        request.respond(self.body, .{}) catch return;
    }
};
