const std = @import("std");
const version = @import("../version.zig");

/// Maximum number of bytes loaded from a local file or remote URL.
pub const max_prompt_bytes: usize = 10 * 1024 * 1024;

/// Timeout applied to remote prompt fetches.
pub const remote_timeout_ns: i96 = 30 * std.time.ns_per_s;

/// Result of loading a prompt from a file or URL.
///
/// Both payloads are allocated with the caller-provided allocator. `.ok`
/// content has surrounding whitespace trimmed; `.err` is a human-readable
/// reason suitable for `Failed to load prompt from <source>: <reason>`.
pub const Outcome = union(enum) {
    ok: []const u8,
    err: []const u8,
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
        return loadRemote(allocator, io, source, limit);
    }
    return loadLocal(allocator, io, source, limit);
}

fn loadLocal(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) Outcome {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(limit)) catch |err| {
        return .{ .err = allocPrintOr(allocator, "Failed to read prompt file: {s}", .{@errorName(err)}) };
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
    err: []const u8,
};

fn loadRemote(allocator: std.mem.Allocator, io: std.Io, url: []const u8, limit: usize) Outcome {
    const user_agent = std.fmt.allocPrint(allocator, "puny/{s}", .{version.version}) catch "puny";
    defer allocator.free(user_agent);

    const shared = allocator.create(FetchShared) catch {
        return .{ .err = "Out of memory" };
    };
    var event: std.Io.Event = .unset;
    shared.* = .{
        .allocator = allocator,
        .io = io,
        .url = url,
        .user_agent = user_agent,
        .limit = limit,
        .event = &event,
        .result = undefined,
    };

    const thread = std.Thread.spawn(.{}, fetchThread, .{shared}) catch |err| {
        allocator.destroy(shared);
        return .{ .err = allocPrintOr(allocator, "Failed to start fetch: {s}", .{@errorName(err)}) };
    };

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = remote_timeout_ns },
        .clock = .awake,
    } };
    event.waitTimeout(io, timeout) catch |err| switch (err) {
        error.Timeout => {
            // The fetch thread is deliberately leaked: the process exits
            // immediately after this failure path.
            return .{ .err = allocPrintOr(allocator, "Request timed out after {d} seconds", .{@divTrunc(remote_timeout_ns, std.time.ns_per_s)}) };
        },
        else => |e| {
            thread.join();
            allocator.destroy(shared);
            return .{ .err = allocPrintOr(allocator, "Request failed: {s}", .{@errorName(e)}) };
        },
    };

    thread.join();
    defer allocator.destroy(shared);

    return switch (shared.result) {
        .ok => |body| finalize(allocator, body),
        .err => |msg| .{ .err = msg },
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
        return .{ .err = allocPrintOr(allocator, "Invalid URL: {s}", .{@errorName(err)}) };
    };

    var req = client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch |err| {
        return .{ .err = allocPrintOr(allocator, "Request failed: {s}", .{@errorName(err)}) };
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        return .{ .err = allocPrintOr(allocator, "Request failed: {s}", .{@errorName(err)}) };
    };

    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        return .{ .err = allocPrintOr(allocator, "Request failed: {s}", .{@errorName(err)}) };
    };

    if (response.head.status.class() != .success) {
        return .{ .err = allocPrintOr(allocator, "HTTP {d} {s}", .{ @intFromEnum(response.head.status), @tagName(response.head.status) }) };
    }

    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = reader.allocRemaining(allocator, std.Io.Limit.limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => return .{ .err = allocPrintOr(allocator, "Response exceeds {d} byte limit", .{limit}) },
        else => |e| return .{ .err = allocPrintOr(allocator, "Failed to read response: {s}", .{@errorName(e)}) },
    };
    return .{ .ok = body };
}

/// Takes ownership of `data`, trims surrounding whitespace, and returns the
/// trimmed content in its own allocation.
fn finalize(allocator: std.mem.Allocator, data: []u8) Outcome {
    const trimmed = std.mem.trim(u8, data, &std.ascii.whitespace);
    const owned = allocator.dupe(u8, trimmed) catch {
        allocator.free(data);
        return .{ .err = "Out of memory" };
    };
    allocator.free(data);
    return .{ .ok = owned };
}

fn allocPrintOr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "Failed to load prompt";
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
        .err => |msg| {
            defer std.testing.allocator.free(msg);
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
        .err => |msg| {
            defer std.testing.allocator.free(msg);
            try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "Failed to read prompt file"));
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
        .err => |msg| {
            defer std.testing.allocator.free(msg);
            try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "StreamTooLong"));
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
    if (ctx.done.load(.acquire)) thread.join();
    ctx.server.deinit(std.testing.io);

    switch (outcome) {
        .ok => |content| {
            defer std.testing.allocator.free(content);
            try std.testing.expectEqualStrings("remote prompt content", content);
        },
        .err => |msg| {
            defer std.testing.allocator.free(msg);
            std.debug.print("remote load failed: {s}\n", .{msg});
            return error.UnexpectedFailure;
        },
    }
}
