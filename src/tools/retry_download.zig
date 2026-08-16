const std = @import("std");
const retry = @import("../core/retry.zig");

/// Downloads a file with retries on transient errors, using the default retry config.
/// The download function itself is provided by the caller, which keeps this module
/// free of network I/O and testable with a mock.
pub fn retryDownload(
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

var fast_test_attempts: usize = 0;
var fast_test_fail_first: bool = false;
var fast_test_error: anyerror = error.InvalidArgument;

fn fastTestDownload(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_dir: std.Io.Dir, dest_name: []const u8) anyerror!void {
    _ = allocator;
    _ = url;
    fast_test_attempts += 1;
    if (fast_test_fail_first and fast_test_attempts == 1) return fast_test_error;
    var file = try dest_dir.createFile(io, dest_name, .{});
    file.close(io);
}

fn fastTestRandom() std.Random {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    return random_source.interface();
}

test "retryDownload succeeds on the first attempt" {
    fast_test_attempts = 0;
    fast_test_fail_first = false;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", fastTestRandom(), fastTestDownload);
    try std.testing.expectEqual(@as(usize, 1), fast_test_attempts);

    var file = try tmp_dir.dir.openFile(std.testing.io, "test.zip", .{});
    file.close(std.testing.io);
}

test "retryDownload fails immediately on a non-transient error" {
    fast_test_attempts = 0;
    fast_test_fail_first = true;
    fast_test_error = error.InvalidArgument;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expectError(error.InvalidArgument, retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", fastTestRandom(), fastTestDownload));
    try std.testing.expectEqual(@as(usize, 1), fast_test_attempts);
}

test "retryDownload removes the partial file after a failed attempt" {
    fast_test_attempts = 0;
    fast_test_fail_first = true;
    fast_test_error = error.InvalidArgument;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var file = try tmp_dir.dir.createFile(std.testing.io, "test.zip", .{});
    file.close(std.testing.io);

    try std.testing.expectError(error.InvalidArgument, retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", fastTestRandom(), fastTestDownload));
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.openFile(std.testing.io, "test.zip", .{}));
}
