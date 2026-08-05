const std = @import("std");
const version = @import("../version.zig");

/// Maximum number of bytes loaded from a local file or remote URL.
pub const max_prompt_bytes: usize = 10 * 1024 * 1024;

/// Timeout applied to remote prompt fetches.
pub const remote_timeout_ns: i96 = 30 * std.time.ns_per_s;

/// Error payload of `Outcome`. `message` is always non-null; when `owned` is
/// true it was allocated with the loader's allocator and must be freed by the
/// caller, when false it is a static string that must not be freed.
pub const Error = struct {
    message: []const u8,
    owned: bool,
};

/// Result of loading a prompt from a file or URL. `.ok` content has
/// surrounding whitespace trimmed; `.err` is a human-readable reason suitable
/// for `Failed to load prompt from <source>: <reason>`.
pub const Outcome = union(enum) {
    ok: []const u8,
    err: Error,
};

/// Returns true when `source` looks like an http:// or https:// URL.
pub fn isHttpUrl(source: []const u8) bool {
    const uri = std.Uri.parse(source) catch return false;
    if (uri.scheme.len == 0) return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https");
}

/// Loads a prompt from a local file or remote URL. Never fails: every failure
/// is reported through `Outcome.err`.
pub fn load(allocator: std.mem.Allocator, io: std.Io, source: []const u8) Outcome {
    return loadWithLimit(allocator, io, source, max_prompt_bytes);
}

fn loadWithLimit(allocator: std.mem.Allocator, io: std.Io, source: []const u8, limit: usize) Outcome {
    if (isHttpUrl(source)) {
        return loadRemote(allocator, io, source, limit, remote_timeout_ns);
    }
    return loadLocal(allocator, io, source, limit);
}

fn loadLocal(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) Outcome {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(limit)) catch |err| {
        return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Failed to read prompt file: {s}", .{@errorName(err)}) };
    };
    return finalize(allocator, data);
}

const FetchShared = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    user_agent: []const u8,
    limit: usize,
    event: *std.Io.Event,
    result: FetchResult,
};

const FetchResult = union(enum) {
    ok: []u8,
    err: Error,
};

fn loadRemote(allocator: std.mem.Allocator, io: std.Io, url: []const u8, limit: usize, timeout_ns: i96) Outcome {
    const user_agent = allocPrintOr(allocator, "puny", "puny/{s}", .{version.version});

    const shared = allocator.create(FetchShared) catch {
        if (user_agent.owned) allocator.free(user_agent.message);
        return .{ .err = dupeOr(allocator, "Out of memory") };
    };
    // The event must outlive this frame: on timeout the fetch thread keeps
    // running and signals it after we have returned.
    const event = allocator.create(std.Io.Event) catch {
        allocator.destroy(shared);
        if (user_agent.owned) allocator.free(user_agent.message);
        return .{ .err = dupeOr(allocator, "Out of memory") };
    };
    event.* = .unset;
    shared.* = .{
        .allocator = allocator,
        .io = io,
        .url = url,
        .user_agent = user_agent.message,
        .limit = limit,
        .event = event,
        .result = undefined,
    };

    const thread = std.Thread.spawn(.{}, fetchThread, .{shared}) catch |err| {
        allocator.destroy(event);
        allocator.destroy(shared);
        if (user_agent.owned) allocator.free(user_agent.message);
        return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Failed to start fetch: {s}", .{@errorName(err)}) };
    };

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake,
    } };
    event.waitTimeout(io, timeout) catch |err| switch (err) {
        error.Timeout => {
            // Deliberate leak: the fetch thread may still be running and holds
            // references to shared, event, and user_agent, all heap-allocated
            // so it never touches this stack frame after we return. This is
            // the pre-existing behaviour (the startup path exits immediately);
            // the leak is bounded and reclaimed by the arena on normal paths.
            return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Request timed out after {d} seconds", .{@divTrunc(timeout_ns, std.time.ns_per_s)}) };
        },
        else => |e| {
            thread.join();
            allocator.destroy(event);
            allocator.destroy(shared);
            if (user_agent.owned) allocator.free(user_agent.message);
            return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Request failed: {s}", .{@errorName(e)}) };
        },
    };

    thread.join();
    const result = shared.result;
    allocator.destroy(event);
    allocator.destroy(shared);
    if (user_agent.owned) allocator.free(user_agent.message);

    return switch (result) {
        .ok => |body| finalize(allocator, body),
        .err => |e| .{ .err = e },
    };
}

fn fetchThread(shared: *FetchShared) void {
    defer shared.event.set(shared.io);
    shared.result = doFetch(shared.allocator, shared.io, shared.url, shared.user_agent, shared.limit);
}

fn doFetch(allocator: std.mem.Allocator, io: std.Io, url_str: []const u8, user_agent: []const u8, limit: usize) FetchResult {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url_str) catch |err| {
        return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Invalid URL: {s}", .{@errorName(err)}) };
    };

    var req = client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch |err| {
        return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Request failed: {s}", .{@errorName(err)}) };
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Request failed: {s}", .{@errorName(err)}) };
    };

    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Request failed: {s}", .{@errorName(err)}) };
    };

    if (response.head.status.class() != .success) {
        return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "HTTP {d} {s}", .{ @intFromEnum(response.head.status), @tagName(response.head.status) }) };
    }

    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = reader.allocRemaining(allocator, std.Io.Limit.limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Response exceeds {d} byte limit", .{limit}) },
        else => |e| return .{ .err = allocPrintOr(allocator, "Failed to load prompt", "Failed to read response: {s}", .{@errorName(e)}) },
    };
    return .{ .ok = body };
}

/// Takes ownership of `data`, trims surrounding whitespace, and returns the
/// trimmed content in its own allocation.
fn finalize(allocator: std.mem.Allocator, data: []u8) Outcome {
    const trimmed = std.mem.trim(u8, data, &std.ascii.whitespace);
    const owned = allocator.dupe(u8, trimmed) catch {
        allocator.free(data);
        return .{ .err = dupeOr(allocator, "Out of memory") };
    };
    allocator.free(data);
    return .{ .ok = owned };
}

/// Formats `fmt` with `args`, or falls back to a copy of `fallback` when the
/// allocation fails. The returned error reports ownership so callers never
/// free a non-heap string.
fn allocPrintOr(allocator: std.mem.Allocator, fallback: []const u8, comptime fmt: []const u8, args: anytype) Error {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return dupeOr(allocator, fallback);
    return .{ .message = message, .owned = true };
}

/// Duplicates `text`, or reports a static fallback when even that allocation
/// fails. Ownership is tracked so callers can free safely.
fn dupeOr(allocator: std.mem.Allocator, text: []const u8) Error {
    const owned = allocator.dupe(u8, text) catch return .{ .message = text, .owned = false };
    return .{ .message = owned, .owned = true };
}

test "isHttpUrl accepts http and https case-insensitively" {
    try std.testing.expect(isHttpUrl("http://example.com/prompt.md"));
    try std.testing.expect(isHttpUrl("https://example.com/prompt.md"));
    try std.testing.expect(isHttpUrl("HTTPS://EXAMPLE.COM/SPEC.MD"));
    try std.testing.expect(isHttpUrl("http://127.0.0.1:8080/x"));
}

test "isHttpUrl rejects non-http schemes and plain paths" {
    try std.testing.expect(!isHttpUrl("file:///tmp/prompt.md"));
    try std.testing.expect(!isHttpUrl("ftp://example.com/prompt.md"));
    try std.testing.expect(!isHttpUrl("/abs/path/prompt.md"));
    try std.testing.expect(!isHttpUrl("relative/prompt.md"));
    try std.testing.expect(!isHttpUrl("C:\\prompt.md"));
    try std.testing.expect(!isHttpUrl(""));
}

test "allocPrintOr returns an owned freeable message on success" {
    const err = allocPrintOr(std.testing.allocator, "Failed to load prompt", "Failed to read prompt file: {s}", .{"OutOfMemory"});
    try std.testing.expect(err.owned);
    defer std.testing.allocator.free(err.message);
    try std.testing.expectEqualStrings("Failed to read prompt file: OutOfMemory", err.message);
}

test "allocPrintOr never returns an owned message under allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();

    // allocPrint's growth allocation fails; the fallback allocation would also
    // fail (a failed attempt does not advance the failing allocator), so the
    // error must report itself as unowned rather than asking the caller to
    // free a static string.
    const err = allocPrintOr(allocator, "Failed to load prompt", "Failed to read prompt file: {s}", .{"OutOfMemory"});
    try std.testing.expectEqualStrings("Failed to load prompt", err.message);
    try std.testing.expect(!err.owned);
}

test "load reads a local file and trims surrounding whitespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt.md", .data = "\n  hello from file\n\n" });

    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "prompt.md" });
    defer std.testing.allocator.free(path);

    const outcome = load(std.testing.allocator, std.testing.io, path);
    switch (outcome) {
        .ok => |content| {
            defer std.testing.allocator.free(content);
            try std.testing.expectEqualStrings("hello from file", content);
        },
        .err => |e| {
            defer if (e.owned) std.testing.allocator.free(e.message);
            return error.UnexpectedFailure;
        },
    }
}

test "load reports a missing local file" {
    const path = "definitely-not-here-puny-prompt.md";
    const outcome = load(std.testing.allocator, std.testing.io, path);
    switch (outcome) {
        .ok => |content| {
            defer std.testing.allocator.free(content);
            return error.UnexpectedSuccess;
        },
        .err => |e| {
            defer if (e.owned) std.testing.allocator.free(e.message);
            try std.testing.expect(std.mem.containsAtLeast(u8, e.message, 1, "Failed to read prompt file"));
        },
    }
}

test "load rejects a local file that exceeds the limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var big: [1024]u8 = @splat('x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = big[0..] });

    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "big.txt" });
    defer std.testing.allocator.free(path);

    const outcome = loadWithLimit(std.testing.allocator, std.testing.io, path, 10);
    switch (outcome) {
        .ok => |content| {
            defer std.testing.allocator.free(content);
            return error.UnexpectedSuccess;
        },
        .err => |e| {
            defer if (e.owned) std.testing.allocator.free(e.message);
            try std.testing.expect(std.mem.containsAtLeast(u8, e.message, 1, "StreamTooLong"));
        },
    }
}

test "load fetches a remote prompt and trims it" {
    const Ctx = struct {
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
            var req = http_server.receiveHead() catch return;
            req.respond(self.body, .{}) catch return;
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch |err| {
        std.debug.print("listen failed: {s}\n", .{@errorName(err)});
        return error.ListenFailed;
    };
    const port = server.socket.address.getPort();

    var ctx = Ctx{ .io = std.testing.io, .server = server, .body = "\n  remote prompt content\n\n" };
    const thread = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/prompt.md", .{port});
    defer std.testing.allocator.free(url);

    const outcome = load(std.testing.allocator, std.testing.io, url);

    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 10_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    thread.join();
    ctx.server.deinit(std.testing.io);

    switch (outcome) {
        .ok => |content| {
            defer std.testing.allocator.free(content);
            try std.testing.expectEqualStrings("remote prompt content", content);
        },
        .err => |e| {
            defer if (e.owned) std.testing.allocator.free(e.message);
            std.debug.print("remote load failed: {s}\n", .{e.message});
            return error.UnexpectedFailure;
        },
    }
}

test "load times out on a server that never responds" {
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

    // The timeout path deliberately leaks its heap state, so use an allocator
    // that does not leak-check.
    const outcome = loadRemote(std.heap.page_allocator, std.testing.io, url, max_prompt_bytes, 100 * std.time.ns_per_ms);

    // Wait for the server thread to finish before tearing down the socket.
    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    thread.join();
    ctx.server.deinit(std.testing.io);

    switch (outcome) {
        .ok => |content| {
            std.heap.page_allocator.free(content);
            return error.UnexpectedSuccess;
        },
        .err => |e| {
            defer if (e.owned) std.heap.page_allocator.free(e.message);
            try std.testing.expect(std.mem.containsAtLeast(u8, e.message, 1, "timed out"));
        },
    }
}
