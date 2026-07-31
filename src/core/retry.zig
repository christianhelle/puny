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
