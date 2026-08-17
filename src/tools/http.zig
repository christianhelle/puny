const std = @import("std");

/// Default timeout applied to web_fetch when the model does not provide one.
pub const web_fetch_timeout_ns: i96 = 15 * std.time.ns_per_s;

/// Floor applied to a model-supplied `timeout_seconds` value, in seconds.
const min_timeout_s = 1;

/// Ceiling applied to a model-supplied `timeout_seconds` value, in seconds.
/// Keeps the guard in force even when the model asks for a huge deadline.
const max_timeout_s = 300;

/// Resolves the effective timeout for a tool call. When the model supplies a
/// `timeout_seconds` value it is clamped to [min_timeout_s, max_timeout_s] and
/// converted to nanoseconds; otherwise `default_ns` (a trusted compile-time
/// constant) is returned unchanged.
pub fn resolveTimeoutSeconds(model_value: ?i64, default_ns: i96) i96 {
    const value = model_value orelse return default_ns;
    const seconds: i96 = @intCast(value);
    const clamped: i96 = std.math.clamp(seconds, min_timeout_s, max_timeout_s);
    return clamped * std.time.ns_per_s;
}

pub fn httpDownloadFile(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_dir: std.Io.Dir, dest_name: []const u8) !void {
    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var file = try dest_dir.createFile(io, dest_name, .{});
    errdefer {
        file.close(io);
        dest_dir.deleteFile(io, dest_name) catch {};
    }

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(io, &buf);

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &file_writer.interface,
    }) catch |err| return err;

    try file_writer.interface.flush();

    if (result.status != .ok) {
        return error.HttpNotOk;
    }

    const stat = try dest_dir.statFile(io, dest_name, .{});
    if (stat.size == 0) return error.TruncatedDownload;

    file.close(io);
}

pub fn httpGet(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    _ = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &response_body.writer,
    });
    if (response_body.written().len == 0) return "";
    return response_body.toOwnedSlice();
}

const HttpGetShared = struct {
    io: std.Io,
    /// Worker-owned copy of the URL: it, the events, and the result all live
    /// in `arena`, which the worker releases when it finishes, so a timed-out
    /// call never reads or writes caller-owned memory after returning.
    url: []const u8,
    done: *std.Io.Event,
    ack: *std.Io.Event,
    result: anyerror![]const u8,
    arena: std.heap.ArenaAllocator,
};

fn httpGetThread(shared: *HttpGetShared) void {
    shared.result = httpGet(shared.arena.allocator(), shared.io, shared.url);
    shared.done.set(shared.io);
    shared.ack.waitUncancelable(shared.io);
    shared.arena.deinit();
}

/// Fetches `url` in a worker thread and waits up to `timeout_ns` for the
/// request to finish. If the deadline passes, `error.TimedOut` is returned and
/// the in-flight request is abandoned: it cannot be aborted mid-flight, so the
/// worker thread keeps running until the socket settles, then releases
/// everything it owns. The returned body is caller-owned.
pub fn httpGetTimed(allocator: std.mem.Allocator, io: std.Io, url: []const u8, timeout_ns: i96) ![]const u8 {
    const spawn_ctx = blk: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // Only active during setup below: once the worker thread starts it owns
        // the arena and frees it when it finishes, so the caller must never
        // deinit it again on the timeout path.
        errdefer arena.deinit();

        const shared = arena.allocator().create(HttpGetShared) catch return error.OutOfMemory;
        shared.* = .{
            .io = io,
            .url = &.{},
            .done = undefined,
            .ack = undefined,
            .result = undefined,
            .arena = arena,
        };
        shared.url = arena.allocator().dupe(u8, url) catch return error.OutOfMemory;

        shared.done = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.ack = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.done.* = .unset;
        shared.ack.* = .unset;

        const thread = std.Thread.spawn(.{}, httpGetThread, .{shared}) catch |err| return err;
        break :blk .{ .thread = thread, .shared = shared };
    };
    const thread = spawn_ctx.thread;
    const shared = spawn_ctx.shared;

    const timeout = std.Io.Timeout{ .duration = .{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake,
    } };
    shared.done.waitTimeout(io, timeout) catch |wait_err| switch (wait_err) {
        error.Timeout => {
            // The request cannot be aborted mid-flight. The worker owns
            // everything it touches and tears it down when the fetch settles,
            // so abandoning the wait never reads or writes caller-owned memory.
            shared.ack.set(io);
            thread.detach();
            return error.TimedOut;
        },
        else => {
            shared.ack.set(io);
            thread.detach();
            return error.TimedOut;
        },
    };

    const transferred = if (shared.result) |bytes|
        allocator.dupe(u8, bytes) catch return error.OutOfMemory
    else |err|
        err;
    shared.ack.set(io);
    thread.join();
    return transferred;
}

// ── Tests ────────────────────────────────────────────────────────────

test "resolveTimeoutSeconds falls back to the default when no value is supplied" {
    const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;
    try std.testing.expectEqual(run_command_timeout_ns, resolveTimeoutSeconds(null, run_command_timeout_ns));
    try std.testing.expectEqual(web_fetch_timeout_ns, resolveTimeoutSeconds(null, web_fetch_timeout_ns));
}

test "resolveTimeoutSeconds converts whole seconds to nanoseconds" {
    const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;
    try std.testing.expectEqual(30 * std.time.ns_per_s, resolveTimeoutSeconds(30, run_command_timeout_ns));
    try std.testing.expectEqual(2 * std.time.ns_per_s, resolveTimeoutSeconds(2, web_fetch_timeout_ns));
}

test "resolveTimeoutSeconds clamps values below the floor to one second" {
    const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;
    try std.testing.expectEqual(std.time.ns_per_s, resolveTimeoutSeconds(0, run_command_timeout_ns));
    try std.testing.expectEqual(std.time.ns_per_s, resolveTimeoutSeconds(-10, run_command_timeout_ns));
}

test "resolveTimeoutSeconds clamps values above the ceiling to five minutes" {
    const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;
    try std.testing.expectEqual(300 * std.time.ns_per_s, resolveTimeoutSeconds(999999999, run_command_timeout_ns));
}

test "httpGetTimed returns TimedOut when the server never responds" {
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
            // Hold the connection open past the client timeout, then close.
            self.io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
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

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/never", .{port});
    defer std.testing.allocator.free(url);

    const result = httpGetTimed(std.testing.allocator, std.testing.io, url, 100 * std.time.ns_per_ms);
    try std.testing.expectError(error.TimedOut, result);

    // Wait for the server thread to finish before tearing down the socket so
    // the abandoned fetch thread can settle against a closed connection.
    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    thread.join();
    ctx.server.deinit(std.testing.io);
}

const HttpGetTestCtx = struct {
    io: std.Io,
    server: std.Io.net.Server,
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
        request.respond(self.body, .{}) catch return;
    }
};

fn listenForHttpGetTest(io: std.Io) !std.Io.net.Server {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    return std.Io.net.IpAddress.listen(&address, io, .{}) catch |err| {
        std.debug.print("listen failed: {s}\n", .{@errorName(err)});
        return error.ListenFailed;
    };
}

fn waitForHttpGetTestServer(ctx: *HttpGetTestCtx, thread: std.Thread, server: *std.Io.net.Server) void {
    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    thread.join();
    server.deinit(std.testing.io);
}

test "httpGet returns the response body from a local server" {
    var server = try listenForHttpGetTest(std.testing.io);
    var ctx = HttpGetTestCtx{ .io = std.testing.io, .server = server, .body = "get body" };
    const thread = try std.Thread.spawn(.{}, HttpGetTestCtx.serve, .{&ctx});

    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/get", .{port});
    defer std.testing.allocator.free(url);

    const body = try httpGet(std.testing.allocator, std.testing.io, url);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("get body", body);

    waitForHttpGetTestServer(&ctx, thread, &server);
}

test "httpGet returns an empty string for an empty response body" {
    var server = try listenForHttpGetTest(std.testing.io);
    var ctx = HttpGetTestCtx{ .io = std.testing.io, .server = server, .body = "" };
    const thread = try std.Thread.spawn(.{}, HttpGetTestCtx.serve, .{&ctx});

    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/empty", .{port});
    defer std.testing.allocator.free(url);

    const body = try httpGet(std.testing.allocator, std.testing.io, url);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("", body);

    waitForHttpGetTestServer(&ctx, thread, &server);
}

const HttpDownloadTestCtx = struct {
    io: std.Io,
    server: std.Io.net.Server,
    body: []const u8,
    status: std.http.Status = .ok,
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

fn withDownloadServer(dir: std.Io.Dir, body: []const u8, status: std.http.Status, f: anytype) !void {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch |err| {
        std.debug.print("listen failed: {s}\n", .{@errorName(err)});
        return error.ListenFailed;
    };
    var ctx = HttpDownloadTestCtx{ .io = std.testing.io, .server = server, .body = body, .status = status };
    const thread = try std.Thread.spawn(.{}, HttpDownloadTestCtx.serve, .{&ctx});

    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/download", .{port});
    defer std.testing.allocator.free(url);

    errdefer server.deinit(std.testing.io);
    try f(url, dir);

    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    thread.join();
    server.deinit(std.testing.io);
}

test "httpDownloadFile downloads the body to the destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try withDownloadServer(tmp.dir, "downloaded payload", .ok, struct {
        fn call(url: []const u8, dir: std.Io.Dir) !void {
            try httpDownloadFile(std.testing.allocator, std.testing.io, url, dir, "dl.bin");
            const data = try dir.readFileAlloc(std.testing.io, "dl.bin", std.testing.allocator, std.Io.Limit.limited(1024));
            defer std.testing.allocator.free(data);
            try std.testing.expectEqualStrings("downloaded payload", data);
        }
    }.call);
}

test "httpDownloadFile fails and cleans up on an HTTP error status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try withDownloadServer(tmp.dir, "not found", .not_found, struct {
        fn call(url: []const u8, dir: std.Io.Dir) !void {
            try std.testing.expectError(error.HttpNotOk, httpDownloadFile(std.testing.allocator, std.testing.io, url, dir, "dl.bin"));
            try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "dl.bin", .{}));
        }
    }.call);
}

test "httpDownloadFile rejects an empty download" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try withDownloadServer(tmp.dir, "", .ok, struct {
        fn call(url: []const u8, dir: std.Io.Dir) !void {
            try std.testing.expectError(error.TruncatedDownload, httpDownloadFile(std.testing.allocator, std.testing.io, url, dir, "dl.bin"));
            try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "dl.bin", .{}));
        }
    }.call);
}

test "httpGetTimed returns the body from a local server" {
    var server = try listenForHttpGetTest(std.testing.io);
    var ctx = HttpGetTestCtx{ .io = std.testing.io, .server = server, .body = "timed body" };
    const thread = try std.Thread.spawn(.{}, HttpGetTestCtx.serve, .{&ctx});

    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/timed", .{port});
    defer std.testing.allocator.free(url);

    const body = try httpGetTimed(std.testing.allocator, std.testing.io, url, 5 * std.time.ns_per_s);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("timed body", body);

    waitForHttpGetTestServer(&ctx, thread, &server);
}
