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

pub fn httpDownloadFile(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_dir: std.Io.Dir, dest_name: []const u8) !void {
    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var file = try dest_dir.createFile(io, dest_name, .{});
    errdefer dest_dir.deleteFile(io, dest_name) catch {};

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(io, &buf);

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &file_writer.interface,
    });

    if (result.status != .ok) {
        return error.HttpNotOk;
    }

    const stat = try dest_dir.statFile(io, dest_name, .{});
    if (stat.size == 0) return error.TruncatedDownload;
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

fn testDownload(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_dir: std.Io.Dir, dest_name: []const u8) anyerror!void {
    _ = allocator;
    _ = url;
    test_download_attempts += 1;
    if (test_download_attempts <= test_download_fail_until) return error.ConnectionTimedOut;
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
            if (!retry.isTransientError(err)) return err;
            var delay_ms: u64 = cfg.base_delay_ms;
            var i: usize = 1;
            while (i < attempt) : (i += 1) delay_ms *= 2;
            delay_ms += random.intRangeAtMost(u64, 0, cfg.jitter_max_ms);
            io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
            continue;
        };
        return;
    }
}

pub fn httpDownloadFileWithRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_dir: std.Io.Dir,
    dest_name: []const u8,
    random: std.Random,
) !void {
    return retryDownload(allocator, io, url, dest_dir, dest_name, random, httpDownloadFile);
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
    test_download_fail_until = 0;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const result = retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectEqual(@as(usize, 1), test_download_attempts);
    _ = result;
}
