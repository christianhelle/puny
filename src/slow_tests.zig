//! Aggregates the slow test modules that run only under `zig build
//! test-regression`, keeping `zig build test` fast.

test "include retry_download slow tests" {
    _ = @import("retry_download_tests.zig");
}

test "include run_command slow tests" {
    _ = @import("run_command_tests.zig");
}

test "include chat_retry slow tests" {
    _ = @import("chat_retry_tests.zig");
}

test "include shell_timeout slow tests" {
    _ = @import("shell_timeout_tests.zig");
}

test "include models/select slow tests" {
    _ = @import("models/select_tests.zig");
}
