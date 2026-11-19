const std = @import("std");
const client = @import("../providers/client.zig");
const pricing = @import("../providers/pricing.zig");
const provider = @import("../providers/provider.zig");

const ProviderKind = std.meta.Tag(provider.Provider);

/// Remembers the current model's USD prices for a session, fetching them at
/// most once per model. Prices are allocated from the allocator given at
/// init, which should be the session's arena.
pub const PricingBook = struct {
    allocator: std.mem.Allocator,
    prov: *provider.Provider,
    /// The provider kind and model the cached prices belong to.
    kind: ?ProviderKind = null,
    model_key: []const u8 = "",
    current: ?pricing.ModelPricing = null,
    /// Models already looked up without prices, so a free model is not
    /// fetched again every turn.
    unpriced: std.ArrayList(Unpriced) = .empty,

    const Unpriced = struct { kind: ProviderKind, model_key: []const u8 };

    pub fn init(allocator: std.mem.Allocator, prov: *provider.Provider) PricingBook {
        return .{ .allocator = allocator, .prov = prov };
    }

    pub fn deinit(self: *PricingBook) void {
        self.unpriced.deinit(self.allocator);
    }

    /// The prices for `model_key`, or null when the provider does not bill in
    /// USD or the model lists none. Fetches only when the model changes.
    pub fn forModel(self: *PricingBook, model_key: []const u8) !?pricing.ModelPricing {
        const kind = std.meta.activeTag(self.prov.*);
        if (self.current) |found| {
            if (self.kind == kind and std.mem.eql(u8, self.model_key, model_key)) return found;
        }
        for (self.unpriced.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.model_key, model_key)) return null;
        }

        const fetched = self.prov.modelPricing(self.allocator, model_key) orelse {
            try self.unpriced.append(self.allocator, .{
                .kind = kind,
                .model_key = try self.allocator.dupe(u8, model_key),
            });
            return null;
        };
        self.current = fetched;
        self.kind = kind;
        self.model_key = try self.allocator.dupe(u8, model_key);
        return fetched;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const TestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    body: []const u8,
    /// Connections still to answer; accept panics once the server closes.
    remaining: usize,
    hits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thread: std.Thread = undefined,

    fn serve(self: *@This()) void {
        while (self.remaining > 0) : (self.remaining -= 1) {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);

            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);

            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch continue;
            _ = self.hits.fetchAdd(1, .monotonic);
            request.respond(self.body, .{ .status = .ok, .keep_alive = false }) catch continue;
        }
    }
};

fn startTestServer(body: []const u8, requests: usize) !*TestServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(TestServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .body = body, .remaining = requests };
    errdefer ctx.server.deinit(std.testing.io);
    ctx.thread = try std.Thread.spawn(.{}, TestServer.serve, .{ctx});
    return ctx;
}

fn stopTestServer(ctx: *TestServer) void {
    ctx.server.deinit(std.testing.io);
    ctx.thread.join();
    std.testing.allocator.destroy(ctx);
}

fn zenProviderFor(ctx: *TestServer, arena: std.mem.Allocator, prov: *provider.Provider) !void {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    prov.* = .{ .opencode = client.Client.init(std.testing.allocator, std.testing.io, "test-key") };
    prov.setConfig(.{ .base_url = url });
}

const zen_models =
    \\{"data":[{"id":"deepseek-v4-pro","cost":{"text":{
    \\  "input":{"price":1.74},"output":{"price":3.48}}}},
    \\ {"id":"free-model","cost":{"text":null}}]}
;

test "PricingBook fetches a model's prices once and reuses them" {
    const ctx = try startTestServer(zen_models, 1);
    defer stopTestServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prov: provider.Provider = undefined;
    try zenProviderFor(ctx, arena, &prov);
    defer prov.deinit();

    var book = PricingBook.init(arena, &prov);
    defer book.deinit();

    const first = (try book.forModel("deepseek-v4-pro")).?;
    const second = (try book.forModel("deepseek-v4-pro")).?;

    try std.testing.expectEqual(@as(i64, 1_740_000_000), first.base.input);
    try std.testing.expectEqual(@as(i64, 1_740_000_000), second.base.input);
    try std.testing.expectEqual(@as(usize, 1), ctx.hits.load(.monotonic));
}

test "PricingBook fetches again when the model changes" {
    const ctx = try startTestServer(zen_models, 2);
    defer stopTestServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prov: provider.Provider = undefined;
    try zenProviderFor(ctx, arena, &prov);
    defer prov.deinit();

    var book = PricingBook.init(arena, &prov);
    defer book.deinit();

    _ = try book.forModel("deepseek-v4-pro");
    _ = try book.forModel("free-model");

    try std.testing.expectEqual(@as(usize, 2), ctx.hits.load(.monotonic));
}

test "PricingBook remembers a model that lists no prices" {
    const ctx = try startTestServer(zen_models, 1);
    defer stopTestServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prov: provider.Provider = undefined;
    try zenProviderFor(ctx, arena, &prov);
    defer prov.deinit();

    var book = PricingBook.init(arena, &prov);
    defer book.deinit();

    try std.testing.expect((try book.forModel("free-model")) == null);
    try std.testing.expect((try book.forModel("free-model")) == null);

    try std.testing.expectEqual(@as(usize, 1), ctx.hits.load(.monotonic));
}

test "PricingBook says nothing for providers that do not bill in USD" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prov = provider.Provider{ .opencode_go = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = "http://127.0.0.1:1" });

    var book = PricingBook.init(arena, &prov);
    defer book.deinit();

    try std.testing.expect((try book.forModel("deepseek-v4-pro")) == null);
}
