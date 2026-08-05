const std = @import("std");
const retry = @import("../core/retry.zig");

pub fn dupeString(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

pub fn ownedSliceOrEmpty(list: *std.ArrayList(u8), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    if (list.items.len == 0) return "";
    return try list.toOwnedSlice(allocator);
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

pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    if (child.stdout) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stdout.appendSlice(allocator, buffer[0..n]);
        }
    }

    if (child.stderr) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stderr.appendSlice(allocator, buffer[0..n]);
        }
    }

    const term = try child.wait(io);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    switch (term) {
        .exited => |code| {
            try result.appendSlice(allocator, "Exit code: ");
            var buf: [32]u8 = undefined;
            const n = try std.fmt.bufPrint(&buf, "{d}", .{code});
            try result.appendSlice(allocator, n);
        },
        else => {
            try result.appendSlice(allocator, "Terminated\n");
        },
    }

    if (stdout.items.len > 0) {
        try result.appendSlice(allocator, "STDOUT:\n");
        try result.appendSlice(allocator, stdout.items);
        try result.append(allocator, '\n');
    }
    if (stderr.items.len > 0) {
        try result.appendSlice(allocator, "STDERR:\n");
        try result.appendSlice(allocator, stderr.items);
        try result.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&result, allocator);
}

/// Timeout applied to shell-backed tools that do not accept a model-supplied
/// timeout parameter (git_status, git_diff, grep_search).
pub const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;

/// Default timeout applied to web_fetch when the model does not provide one.
pub const web_fetch_timeout_ns: i96 = 15 * std.time.ns_per_s;

/// How long the caller waits after requesting a timed-out command be
/// terminated before abandoning the worker thread. Long enough for a kill to
/// land while still bounding the total wall time of a timed-out tool call.
const kill_grace_ns: i96 = 2 * std.time.ns_per_s;

const RunCommandShared = struct {
    io: std.Io,
    argv: [][]const u8,
    cwd: ?[]const u8,
    done: *std.Io.Event,
    ack: *std.Io.Event,
    cancel: std.atomic.Value(bool),
    result: anyerror![]const u8,
    arena: std.heap.ArenaAllocator,
};

/// Number of timed-out `runCommandTimed` calls whose worker thread was
/// abandoned because the child could not be terminated within the grace
/// period. Test-only observability; production code never reads it.
var test_run_command_worker_detached: usize = 0;

fn runCommandThread(shared: *RunCommandShared) void {
    shared.result = runCommandInArena(shared.arena.allocator(), shared.io, shared.argv, shared.cwd, &shared.cancel);
    shared.done.set(shared.io);
    shared.ack.waitUncancelable(shared.io);
    shared.arena.deinit();
}

fn runCommandInArena(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    cancel: *std.atomic.Value(bool),
) anyerror![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var timed_out = false;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    if (child.stdout) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            if (cancel.load(.acquire)) {
                timed_out = true;
                break;
            }
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stdout.appendSlice(allocator, buffer[0..n]);
        }
    }

    if (!timed_out) if (child.stderr) |file| {
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            if (cancel.load(.acquire)) {
                timed_out = true;
                break;
            }
            const n = try reader.interface.readSliceShort(&buffer);
            if (n == 0) break;
            try stderr.appendSlice(allocator, buffer[0..n]);
        }
    };

    if (timed_out) {
        child.kill(io);
        return error.TimedOut;
    }

    const term = try child.wait(io);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    switch (term) {
        .exited => |code| {
            try result.appendSlice(allocator, "Exit code: ");
            var buf: [32]u8 = undefined;
            const n = try std.fmt.bufPrint(&buf, "{d}", .{code});
            try result.appendSlice(allocator, n);
        },
        else => {
            try result.appendSlice(allocator, "Terminated\n");
        },
    }

    if (stdout.items.len > 0) {
        try result.appendSlice(allocator, "STDOUT:\n");
        try result.appendSlice(allocator, stdout.items);
        try result.append(allocator, '\n');
    }
    if (stderr.items.len > 0) {
        try result.appendSlice(allocator, "STDERR:\n");
        try result.appendSlice(allocator, stderr.items);
        try result.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&result, allocator);
}

/// Runs `argv` in a worker thread and waits up to `timeout_ns` for it to
/// finish. If the deadline passes, the child process is terminated and
/// `error.TimedOut` is returned. The returned output is caller-owned.
pub fn runCommandTimed(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ns: i96,
) ![]const u8 {
    const spawn_ctx = blk: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        // The worker owns everything the command touches from here on: argv,
        // cwd, events, and the result all live in `arena`, which the worker
        // releases when it finishes, so a timed-out call never reads or writes
        // caller-owned memory after returning.
        const shared = arena.allocator().create(RunCommandShared) catch return error.OutOfMemory;
        shared.* = .{
            .io = io,
            .argv = &.{},
            .cwd = null,
            .done = undefined,
            .ack = undefined,
            .cancel = .init(false),
            .result = undefined,
            .arena = arena,
        };

        shared.argv = arena.allocator().alloc([]const u8, argv.len) catch return error.OutOfMemory;
        for (argv, 0..) |arg, i| {
            shared.argv[i] = arena.allocator().dupe(u8, arg) catch return error.OutOfMemory;
        }
        if (cwd) |path| {
            shared.cwd = arena.allocator().dupe(u8, path) catch return error.OutOfMemory;
        }

        shared.done = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.ack = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.done.* = .unset;
        shared.ack.* = .unset;

        const thread = std.Thread.spawn(.{}, runCommandThread, .{shared}) catch |err| return err;
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
            // Ask the worker to terminate the child, then give it a bounded
            // grace period to finish. The worker kills the process itself, so
            // this never races with its own wait.
            shared.cancel.store(true, .release);
            const grace = std.Io.Timeout{ .duration = .{
                .raw = .{ .nanoseconds = kill_grace_ns },
                .clock = .awake,
            } };
            shared.done.waitTimeout(io, grace) catch {
                shared.ack.set(io);
                thread.detach();
                test_run_command_worker_detached += 1;
                return error.TimedOut;
            };
            shared.ack.set(io);
            thread.join();
            return error.TimedOut;
        },
        else => {
            shared.ack.set(io);
            thread.detach();
            test_run_command_worker_detached += 1;
            return error.TimedOut;
        },
    };

    const transferred = if (shared.result) |bytes|
        allocator.dupe(u8, bytes) catch return error.OutOfMemory
    else
        |err| err;
    shared.ack.set(io);
    thread.join();
    return transferred;
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

var test_download_attempts: usize = 0;
var test_download_fail_until: usize = 0;
var test_download_error: anyerror = error.ConnectionTimedOut;

fn testDownload(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_dir: std.Io.Dir, dest_name: []const u8) anyerror!void {
    _ = allocator;
    _ = url;
    test_download_attempts += 1;
    if (test_download_attempts <= test_download_fail_until) return test_download_error;
    var file = try dest_dir.createFile(io, dest_name, .{});
    file.close(io);
}

fn retryDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_dir: std.Io.Dir,
    dest_name: []const u8,
    random: std.Random,
    comptime download_fn: fn (std.mem.Allocator, std.Io, []const u8, std.Io.Dir, []const u8) anyerror!void,
) !void {
    const cfg = retry.default_config;
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        download_fn(allocator, io, url, dest_dir, dest_name) catch |err| {
            dest_dir.deleteFile(io, dest_name) catch {};
            if (attempt > cfg.max_retries) return err;
            if (!retry.isDownloadTransientError(err)) return err;
            const delay_ms = retry.computeDelay(cfg, attempt, random);
            io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
            continue;
        };
        return;
    }
}

test "retryDownload retries transient errors" {
    test_download_attempts = 0;
    test_download_fail_until = 2;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectEqual(@as(usize, 3), test_download_attempts);
    // Verify file exists after successful retry
    var f = try tmp_dir.dir.openFile(std.testing.io, "test.zip", .{});
    f.close(std.testing.io);
}

test "retryDownload fails after exhausting retries" {
    test_download_attempts = 0;
    test_download_fail_until = 999;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const result = retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectError(error.ConnectionTimedOut, result);
}

test "retryDownload fails immediately on non-transient error" {
    test_download_attempts = 0;
    test_download_fail_until = 1;
    test_download_error = error.InvalidArgument;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const result = retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectEqual(@as(usize, 1), test_download_attempts);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "runCommandTimed returns output for a command that finishes within the deadline" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    const output = try runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "hello"));
}
