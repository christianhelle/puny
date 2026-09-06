//! Startup prompt offering to file a pending crash report as a GitHub issue.

const std = @import("std");
const crash = @import("../core/crash.zig");

/// First segment of a session uuid, enough to recognise the run.
fn shortId(session_id: []const u8) []const u8 {
    return if (session_id.len > 8) session_id[0..8] else session_id;
}

test "shortId abbreviates a session uuid for the prompt" {
    try std.testing.expectEqualStrings("8f14e45f", shortId("8f14e45f-ceea-467a-9dc3-0f0e0b1e1e1e"));
}

test "shortId leaves a short id alone" {
    try std.testing.expectEqualStrings("abc", shortId("abc"));
}
