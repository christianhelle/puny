const std = @import("std");
const builtin = @import("builtin");

/// Windows console mode flag that makes the console interpret ANSI escape
/// sequences instead of printing them literally. See
/// `ENABLE_VIRTUAL_TERMINAL_PROCESSING` in the Windows Console docs.
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

/// Windows console mode flag required for
/// `ENABLE_VIRTUAL_TERMINAL_PROCESSING` to function correctly. See
/// `ENABLE_PROCESSED_OUTPUT` in the Windows Console docs.
pub const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;

/// Returns the console mode with ANSI escape sequence processing enabled,
/// preserving any existing mode flags.
pub fn modeWithAnsi(mode: u32) u32 {
    return mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
}

test "modeWithAnsi enables processed output and VT processing for a zero mode" {
    try std.testing.expectEqual(ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING, modeWithAnsi(0));
}

test "modeWithAnsi preserves existing mode flags" {
    const existing: u32 = 0x0001 | 0x0002;
    try std.testing.expectEqual(existing | ENABLE_VIRTUAL_TERMINAL_PROCESSING, modeWithAnsi(existing));
}

test "modeWithAnsi is idempotent" {
    const once = modeWithAnsi(0x0002);
    try std.testing.expectEqual(once, modeWithAnsi(once));
}

test "enableAnsi is safe to call on any platform" {
    // Calling enableAnsi() on Windows would mutate the test process console
    // mode and is not restored; the Windows code path is still validated at
    // compile time (the CI regression suite cross-compiles to
    // x86_64-windows-gnu and aarch64-windows-gnu).
    if (builtin.os.tag == .windows) return;
    enableAnsi();
}

/// Enable ANSI escape sequence processing on the stdout and stderr console
/// output handles. No-op on non-Windows platforms and when a handle is not a
/// console (for example, when output is redirected to a file or pipe).
pub fn enableAnsi() void {
    if (builtin.os.tag != .windows) return;
    enableOnHandle(windows.STD_OUTPUT_HANDLE);
    enableOnHandle(windows.STD_ERROR_HANDLE);
}

fn enableOnHandle(handle_id: u32) void {
    const h = windows.GetStdHandle(handle_id);
    if (h == windows.INVALID_HANDLE_VALUE) return;
    var mode: windows.DWORD = undefined;
    if (windows.GetConsoleMode(h, &mode) == .FALSE) return;
    _ = windows.SetConsoleMode(h, modeWithAnsi(mode));
}

const windows = if (builtin.os.tag == .windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;
    pub const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;

    pub const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    pub const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));

    pub extern "kernel32" fn GetStdHandle(dwStdHandle: u32) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
} else void{};
