const std = @import("std");

pub fn isTransientError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.ReadTimedOut,
        error.ReadFailed,
        error.WriteFailed,
        error.DnsFailed,
        error.NameResolveFailed,
        error.TlsFailure,
        error.SslUpgradeFailed,
        error.EndOfStream,
        // Windows: STATUS_LOCAL_DISCONNECT from stale HTTP connection pool entries
        error.Unexpected,
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
