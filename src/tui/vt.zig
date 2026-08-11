const std = @import("std");

/// Windows console mode flag that makes the console interpret ANSI escape
/// sequences instead of printing them literally. See
/// `ENABLE_VIRTUAL_TERMINAL_PROCESSING` in the Windows Console docs.
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

/// Returns the console mode with ANSI escape sequence processing enabled,
/// preserving any existing mode flags.
pub fn modeWithAnsi(mode: u32) u32 {
    return mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
}

test "modeWithAnsi sets only the VT processing bit for a zero mode" {
    try std.testing.expectEqual(ENABLE_VIRTUAL_TERMINAL_PROCESSING, modeWithAnsi(0));
}

test "modeWithAnsi preserves existing mode flags" {
    const existing: u32 = 0x0001 | 0x0002;
    try std.testing.expectEqual(existing | ENABLE_VIRTUAL_TERMINAL_PROCESSING, modeWithAnsi(existing));
}

test "modeWithAnsi is idempotent" {
    const once = modeWithAnsi(0x0002);
    try std.testing.expectEqual(once, modeWithAnsi(once));
}
