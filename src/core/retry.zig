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

test "isTransientError recognizes download-related errors" {
    const download_errors = [_]anyerror{
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.HttpHeadersInvalid,
        error.Unexpected,
        error.SystemResources,
        error.TlsAlert,
        error.TlsConnectionClosure,
        error.TruncatedDownload,
        error.ZipNoEndRecord,
        error.ZipTruncated,
        error.WrongGzipChecksum,
        error.WrongGzipSize,
        error.CorruptInput,
    };
    for (download_errors) |err| {
        try std.testing.expect(isTransientError(err));
    }
}

test "isTransientError rejects non-transient errors" {
    try std.testing.expect(!isTransientError(error.OutOfMemory));
    try std.testing.expect(!isTransientError(error.AccessDenied));
    try std.testing.expect(!isTransientError(error.FileNotFound));
    try std.testing.expect(!isTransientError(error.InvalidArgument));
}
