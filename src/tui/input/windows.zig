const std = @import("std");
const builtin = @import("builtin");
const common = @import("./common.zig");
const prompt_history = @import("../../prompts/history.zig");
const sigint = @import("../../core/sigint.zig");

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

pub fn readLineWindows(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    history: ?*prompt_history.History,
) !common.ReadLineResult {
    if (comptime builtin.os.tag != .windows) unreachable;

    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
    const hStdin = windows.GetStdHandle(STD_INPUT_HANDLE);
    var first_esc_ts: ?std.Io.Timestamp = null;

    while (true) {
        var record: windows.INPUT_RECORD = undefined;
        var events_read: windows.DWORD = 0;
        if (windows.ReadConsoleInputW(hStdin, &record, 1, &events_read) == .FALSE) return error.ReadFailed;
        if (events_read == 0) continue;
        if (record.EventType != windows.KEY_EVENT) continue;
        if (record.Event.KeyEvent.bKeyDown == .FALSE) continue;

        const key_event = record.Event.KeyEvent;
        const vk = key_event.wVirtualKeyCode;
        const ctrl = (key_event.dwControlKeyState & (windows.LEFT_CTRL_PRESSED | windows.RIGHT_CTRL_PRESSED)) != 0;

        switch (vk) {
            windows.VK_RETURN => {
                first_esc_ts = null;
                return .{ .submitted = line_alloc.written() };
            },
            windows.VK_BACK => {
                first_esc_ts = null;
                try common.backspace(line_alloc, stdout_writer);
            },
            windows.VK_ESCAPE => {
                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) return .cancelled;
                }
                first_esc_ts = now;
            },
            windows.VK_UP => {
                first_esc_ts = null;
                try common.historyPrevious(line_alloc, stdout_writer, history);
            },
            windows.VK_DOWN => {
                first_esc_ts = null;
                try common.historyNext(line_alloc, stdout_writer, history);
            },
            else => {
                first_esc_ts = null;
                const ch = key_event.uChar.UnicodeChar;
                if (ch == 3 and ctrl) {
                    sigint.trigger();
                    return .interrupted;
                }
                if (ch >= 32 and ch < 127) {
                    try common.appendAndEcho(@intCast(ch), line_alloc, stdout_writer);
                }
            },
        }
    }
}

const windows = if (builtin.os.tag == .windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;

    pub const VK_RETURN: u16 = 0x0D;
    pub const VK_BACK: u16 = 0x08;
    pub const VK_ESCAPE: u16 = 0x1B;
    pub const VK_UP: u16 = 0x26;
    pub const VK_DOWN: u16 = 0x28;
    pub const KEY_EVENT: u16 = 0x0001;
    pub const LEFT_CTRL_PRESSED: DWORD = 0x0008;
    pub const RIGHT_CTRL_PRESSED: DWORD = 0x0004;

    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: BOOL,
        wRepeatCount: u16,
        wVirtualKeyCode: u16,
        wVirtualScanCode: u16,
        uChar: extern union {
            UnicodeChar: u16,
            AsciiChar: u8,
        },
        dwControlKeyState: DWORD,
    };

    pub const INPUT_RECORD = extern struct {
        EventType: u16,
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
        },
    };

    pub extern "kernel32" fn GetStdHandle(dwStdHandle: DWORD) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: *INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) BOOL;
} else void{};
