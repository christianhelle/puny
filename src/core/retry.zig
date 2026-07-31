const std = @import("std");

pub fn isTransientError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        error.ReadTimedOut,
        error.ReadFailed,
        error.WriteFailed,
        error.BrokenPipe,
        error.EndOfStream,
        error.DnsFailed,
        error.NameResolveFailed,
        error.TlsFailure,
        error.TlsAlert,
        error.TlsConnectionClosure,
        error.SslUpgradeFailed,
        error.HttpHeadersInvalid,
        => true,
        else => false,
    };
}

pub fn isDownloadTransientError(err: anyerror) bool {
    return isTransientError(err) or switch (err) {
        error.Unexpected,
        error.SystemResources,
        error.TruncatedDownload,
        error.ZipNoEndRecord,
        error.ZipTruncated,
        error.WrongGzipChecksum,
        error.WrongGzipSize,
        error.CorruptInput,
        => true,
        else => false,
    };
}

pub const Config = struct {
    max_retries: usize,
    base_delay_ms: u64,
    jitter_max_ms: u64,
};

pub const default_config: Config = .{
    .max_retries = 5,
    .base_delay_ms = 500,
    .jitter_max_ms = 250,
};

/// Exponential backoff delay in milliseconds, including jitter, for a retry
/// attempt: `base_delay_ms` for attempts 0 and 1, doubling each subsequent
/// attempt.
pub fn computeDelay(cfg: Config, attempt: usize, random: std.Random) u64 {
    var delay_ms: u64 = cfg.base_delay_ms;
    var i: usize = 1;
    while (i < attempt) : (i += 1) delay_ms = std.math.mul(u64, delay_ms, 2) catch std.math.maxInt(u64);
    const jitter: u64 = random.intRangeAtMost(u64, 0, cfg.jitter_max_ms);
    return std.math.add(u64, delay_ms, jitter) catch std.math.maxInt(u64);
}

test "isTransientError recognizes network and transport errors" {
    const network_errors = [_]anyerror{
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        error.ReadTimedOut,
        error.ReadFailed,
        error.WriteFailed,
        error.BrokenPipe,
        error.EndOfStream,
        error.DnsFailed,
        error.NameResolveFailed,
        error.TlsFailure,
        error.TlsAlert,
        error.TlsConnectionClosure,
        error.SslUpgradeFailed,
        error.HttpHeadersInvalid,
    };
    for (network_errors) |err| {
        try std.testing.expect(isTransientError(err));
    }
}

test "isTransientError rejects generic and archive errors" {
    try std.testing.expect(!isTransientError(error.Unexpected));
    try std.testing.expect(!isTransientError(error.SystemResources));
    try std.testing.expect(!isTransientError(error.TruncatedDownload));
    try std.testing.expect(!isTransientError(error.ZipNoEndRecord));
    try std.testing.expect(!isTransientError(error.ZipTruncated));
}

test "isDownloadTransientError includes all transient plus download-specific errors" {
    try std.testing.expect(isDownloadTransientError(error.ConnectionRefused));
    try std.testing.expect(isDownloadTransientError(error.Unexpected));
    try std.testing.expect(isDownloadTransientError(error.SystemResources));
    try std.testing.expect(isDownloadTransientError(error.TruncatedDownload));
    try std.testing.expect(isDownloadTransientError(error.ZipNoEndRecord));
    try std.testing.expect(isDownloadTransientError(error.ZipTruncated));
    try std.testing.expect(isDownloadTransientError(error.WrongGzipChecksum));
    try std.testing.expect(isDownloadTransientError(error.WrongGzipSize));
    try std.testing.expect(isDownloadTransientError(error.CorruptInput));
    try std.testing.expect(!isDownloadTransientError(error.OutOfMemory));
    try std.testing.expect(!isDownloadTransientError(error.AccessDenied));
    try std.testing.expect(!isDownloadTransientError(error.InvalidArgument));
}

test "computeDelay doubles per attempt with zero jitter" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const cfg: Config = .{ .max_retries = 3, .base_delay_ms = 100, .jitter_max_ms = 0 };
    try std.testing.expectEqual(@as(u64, 100), computeDelay(cfg, 0, random));
    try std.testing.expectEqual(@as(u64, 100), computeDelay(cfg, 1, random));
    try std.testing.expectEqual(@as(u64, 200), computeDelay(cfg, 2, random));
    try std.testing.expectEqual(@as(u64, 400), computeDelay(cfg, 3, random));
}

test "computeDelay saturates exponential doubling at u64 max" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const cfg: Config = .{ .max_retries = 3, .base_delay_ms = 1, .jitter_max_ms = 0 };
    try std.testing.expectEqual(@as(u64, 1) << 63, computeDelay(cfg, 64, random));
    try std.testing.expectEqual(std.math.maxInt(u64), computeDelay(cfg, 65, random));
}

test "computeDelay saturates jitter addition at u64 max" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const cfg: Config = .{ .max_retries = 3, .base_delay_ms = std.math.maxInt(u64), .jitter_max_ms = std.math.maxInt(u64) };
    try std.testing.expectEqual(std.math.maxInt(u64), computeDelay(cfg, 3, random));
}
