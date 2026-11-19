const std = @import("std");
const client = @import("../providers/client.zig");
const pricing = @import("../providers/pricing.zig");
const provider = @import("../providers/provider.zig");

const ProviderKind = std.meta.Tag(provider.Provider);

/// Remembers the USD prices of the models a session calls, fetching each model
/// at most once. Prices are allocated from the allocator given at init, which
/// should be the session's arena.
pub const PricingBook = struct {
    allocator: std.mem.Allocator,
    prov: *provider.Provider,
    /// Models whose prices were read.
    priced: std.ArrayList(Priced) = .empty,
    /// Models already looked up without prices, so a free model is not
    /// fetched again every turn.
    unpriced: std.ArrayList(Unpriced) = .empty,

    const Priced = struct { kind: ProviderKind, model_key: []const u8, prices: pricing.ModelPricing };
    const Unpriced = struct { kind: ProviderKind, model_key: []const u8 };

    pub fn init(allocator: std.mem.Allocator, prov: *provider.Provider) PricingBook {
        return .{ .allocator = allocator, .prov = prov };
    }

    pub fn deinit(self: *PricingBook) void {
        self.priced.deinit(self.allocator);
        self.unpriced.deinit(self.allocator);
    }

    /// The prices for `model_key`, or null when the provider does not bill in
    /// USD or the model lists none. Fetches only the first time a model is
    /// seen, so switching back to an earlier model reuses its prices. A model
    /// is only remembered after the fetch answers.
    pub fn forModel(self: *PricingBook, model_key: []const u8) !?pricing.ModelPricing {
        const kind = std.meta.activeTag(self.prov.*);
        for (self.priced.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.model_key, model_key)) return entry.prices;
        }
        for (self.unpriced.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.model_key, model_key)) return null;
        }

        // A failed fetch says nothing about the model, so it is not cached and
        // a later turn can try again.
        const fetched = try self.prov.modelPricing(self.allocator, model_key);
        if (fetched) |prices| {
            try self.priced.append(self.allocator, .{
                .kind = kind,
                .model_key = try self.allocator.dupe(u8, model_key),
                .prices = prices,
            });
            return prices;
        }
        try self.unpriced.append(self.allocator, .{
            .kind = kind,
            .model_key = try self.allocator.dupe(u8, model_key),
        });
        return null;
    }

    /// The prices to charge `model_key`, or null when they are unknown or the
    /// provider does not bill in USD. Best effort: a failed lookup leaves the
    /// cost out rather than interrupting a turn.
    pub fn pricesFor(self: *PricingBook, model_key: []const u8) ?pricing.ModelPricing {
        return self.forModel(model_key) catch null;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const TestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    body: []const u8,
    /// Connections still to answer; accept panics once the server closes.
    remaining: usize,
    /// Statuses to answer with in order; the last one repeats.
    statuses: []const std.http.Status = &.{.ok},
    served: usize = 0,
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
            const status = self.statuses[@min(self.served, self.statuses.len - 1)];
            self.served += 1;
            request.respond(self.body, .{ .status = status, .keep_alive = false }) catch continue;
        }
    }
};

fn startTestServer(body: []const u8, requests: usize) !*TestServer {
    return startTestServerStatuses(body, &.{.ok}, requests);
}

fn startTestServerStatuses(body: []const u8, statuses: []const std.http.Status, requests: usize) !*TestServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(TestServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .body = body, .remaining = requests, .statuses = statuses };
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

test "PricingBook reuses the prices when a model is revisited" {
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

    // A → B → A fetches each model once, not the last one twice.
    const first = (try book.forModel("deepseek-v4-pro")).?;
    try std.testing.expect((try book.forModel("free-model")) == null);
    const again = (try book.forModel("deepseek-v4-pro")).?;

    try std.testing.expectEqual(first.base.input, again.base.input);
    try std.testing.expectEqual(@as(usize, 2), ctx.hits.load(.monotonic));
}

test "PricingBook retries a model after a failed price fetch" {
    const statuses = [_]std.http.Status{ .internal_server_error, .ok };
    const ctx = try startTestServerStatuses(zen_models, &statuses, 2);
    defer stopTestServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prov: provider.Provider = undefined;
    try zenProviderFor(ctx, arena, &prov);
    defer prov.deinit();

    var book = PricingBook.init(arena, &prov);
    defer book.deinit();

    // The failed fetch is not remembered as "this model has no prices".
    try std.testing.expectError(error.ResponseError, book.forModel("deepseek-v4-pro"));
    try std.testing.expectEqual(@as(usize, 0), book.unpriced.items.len);

    // A later lookup retries and succeeds, then sticks.
    const found = book.pricesFor("deepseek-v4-pro").?;
    try std.testing.expectEqual(@as(i64, 1_740_000_000), found.base.input);
    const reused = (try book.forModel("deepseek-v4-pro")).?;
    try std.testing.expectEqual(found.base.input, reused.base.input);
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
    try std.testing.expect(book.pricesFor("deepseek-v4-pro") == null);
}
