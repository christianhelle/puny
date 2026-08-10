//! Slow retryDownload tests, run only as part of the regression suite
//! (`zig build test-regression`) so that `zig build test` stays fast.
const std = @import("std");
const retry_download = @import("tools/retry_download.zig");

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

test "retryDownload retries transient errors" {
    test_download_attempts = 0;
    test_download_fail_until = 2;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try retry_download.retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
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
    const result = retry_download.retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
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
    const result = retry_download.retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectEqual(@as(usize, 1), test_download_attempts);
    try std.testing.expectError(error.InvalidArgument, result);
}
