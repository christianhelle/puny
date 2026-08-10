//! Aggregates the slow test modules that run only under `zig build
//! test-regression`, keeping `zig build test` fast.
const std = @import("std");

test "include retry_download slow tests" {
    _ = @import("retry_download_tests.zig");
}

test "include run_command slow tests" {
    _ = @import("run_command_tests.zig");
}

test "include chat_retry slow tests" {
    _ = @import("chat_retry_tests.zig");
}
