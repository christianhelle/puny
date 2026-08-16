const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const WebFetchParams = struct {
    url: []const u8,
    timeout_seconds: ?i64 = null,
};

fn webFetch(allocator: std.mem.Allocator, io: std.Io, params: WebFetchParams) ![]const u8 {
    const timeout_ns = helpers.resolveTimeoutSeconds(params.timeout_seconds, helpers.web_fetch_timeout_ns);
    return helpers.httpGetTimed(allocator, io, params.url, timeout_ns) catch |err| switch (err) {
        error.TimedOut => std.fmt.allocPrint(
            allocator,
            "Tool web_fetch timed out after {d} seconds. If the page legitimately takes longer, retry with a larger timeout_seconds (max 300).",
            .{@divTrunc(timeout_ns, std.time.ns_per_s)},
        ),
        else => return err,
    };
}

pub const web_fetch = tools.defineTool(
    "web_fetch",
    "Fetch the contents of a URL using HTTP GET.",
    WebFetchParams,
    webFetch,
);

test "web_fetch retrieves a body from a local server" {
    const Ctx = struct {
        io: std.Io,
        server: std.Io.net.Server,
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
            request.respond("hello from test server", .{}) catch return;
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch |err| {
        std.debug.print("listen failed: {s}\n", .{@errorName(err)});
        return error.ListenFailed;
    };
    const port = server.socket.address.getPort();

    var ctx = Ctx{ .io = std.testing.io, .server = server };
    const thread = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
    errdefer {
        // Unblock accept() on failure so join cannot hang the test runner.
        ctx.server.deinit(std.testing.io);
        thread.join();
    }

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/test", .{port});
    defer std.testing.allocator.free(url);

    const body = try webFetch(std.testing.allocator, std.testing.io, .{ .url = url });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello from test server", body);

    thread.join();
    ctx.server.deinit(std.testing.io);
}

test "web_fetch reports a timeout message when the server never responds" {
    const Ctx = struct {
        io: std.Io,
        server: std.Io.net.Server,
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
            _ = http_server.receiveHead() catch return;
            // Hold the connection open well past the client timeout so the
            // client gives up before the server closes the socket.
            self.io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_s }, .awake) catch {};
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch |err| {
        std.debug.print("listen failed: {s}\n", .{@errorName(err)});
        return error.ListenFailed;
    };
    const port = server.socket.address.getPort();

    var ctx = Ctx{ .io = std.testing.io, .server = server };
    const thread = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/slow", .{port});
    defer std.testing.allocator.free(url);

    const body = try webFetch(std.testing.allocator, std.testing.io, .{ .url = url, .timeout_seconds = 1 });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "timed out after 1 seconds"));

    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    thread.join();
    ctx.server.deinit(std.testing.io);
}
