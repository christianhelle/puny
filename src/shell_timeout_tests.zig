//! Slow execute_shell tests, run only as part of the regression suite
//! (`zig build test-regression`) so that `zig build test` stays fast.
const std = @import("std");
const shell = @import("tools/shell.zig");

test "execute_shell reports a timeout when the command runs too long" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"sleep 5\",\"timeout_seconds\":1}", .{});
    const output = try shell.execute_shell.execute(arena, std.testing.io, args);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "timed out after 1 seconds"));
}
