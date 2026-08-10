const std = @import("std");
const run_command = @import("run_command.zig");

pub const runCommand = run_command.runCommand;
pub const runCommandTimed = run_command.runCommandTimed;
pub const ownedSliceOrEmpty = run_command.ownedSliceOrEmpty;

pub fn dupeString(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_size: usize) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_size));
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try list.appendSlice(allocator, entry.name);
        try list.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&list, allocator);
}

/// Timeout applied to shell-backed tools that do not accept a model-supplied
/// timeout parameter (git_status, git_diff, grep_search).
pub const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;

/// Default timeout applied to execute_shell when the model does not provide
/// one. Generous for real work (builds, test suites) while still a hard bound
/// so the agent can never hang on a single command.
pub const execute_shell_timeout_ns: i96 = 120 * std.time.ns_per_s;

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

test "resolveTimeoutSeconds falls back to the default when no value is supplied" {
    try std.testing.expectEqual(run_command_timeout_ns, resolveTimeoutSeconds(null, run_command_timeout_ns));
    try std.testing.expectEqual(web_fetch_timeout_ns, resolveTimeoutSeconds(null, web_fetch_timeout_ns));
}

test "resolveTimeoutSeconds converts whole seconds to nanoseconds" {
    try std.testing.expectEqual(30 * std.time.ns_per_s, resolveTimeoutSeconds(30, run_command_timeout_ns));
    try std.testing.expectEqual(2 * std.time.ns_per_s, resolveTimeoutSeconds(2, web_fetch_timeout_ns));
}

test "resolveTimeoutSeconds clamps values below the floor to one second" {
    try std.testing.expectEqual(std.time.ns_per_s, resolveTimeoutSeconds(0, run_command_timeout_ns));
    try std.testing.expectEqual(std.time.ns_per_s, resolveTimeoutSeconds(-10, run_command_timeout_ns));
}

test "resolveTimeoutSeconds clamps values above the ceiling to five minutes" {
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

test "dupeString returns an empty string without allocating" {
    try std.testing.expectEqualStrings("", try dupeString(std.testing.allocator, ""));
    const duped = try dupeString(std.testing.allocator, "hello");
    defer std.testing.allocator.free(duped);
    try std.testing.expectEqualStrings("hello", duped);
    try std.testing.expect(duped.ptr != "hello".ptr);
}

test "ownedSliceOrEmpty returns an empty string for an empty list" {
    var list: std.ArrayList(u8) = .empty;
    try std.testing.expectEqualStrings("", try ownedSliceOrEmpty(&list, std.testing.allocator));
}

test "ownedSliceOrEmpty takes ownership of a non-empty list" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "abc");
    const owned = try ownedSliceOrEmpty(&list, std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("abc", owned);
}

test "writeFile readFileAlloc and listDirectory round-trip" {
    const path = "puny-test-helpers-rt.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try writeFile(std.testing.io, path, "payload");
    const content = try readFileAlloc(std.testing.allocator, std.testing.io, path, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("payload", content);

    const listing = try listDirectory(std.testing.allocator, std.testing.io, ".");
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, path) != null);
}

test "readFileAlloc rejects content larger than the limit" {
    const path = "puny-test-helpers-big.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try writeFile(std.testing.io, path, "123456789");
    try std.testing.expectError(error.StreamTooLong, readFileAlloc(std.testing.allocator, std.testing.io, path, 4));
}
