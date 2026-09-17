const std = @import("std");
const builtin = @import("builtin");
const common = @import("./common.zig");
const keys = @import("./keys.zig");
const line_editor = @import("./line_editor.zig");
const mention = @import("./mention.zig");
const sigint = @import("../../core/sigint.zig");

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

pub fn readLineWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *line_editor.LineEditor,
) !common.ReadLineResult {
    if (comptime builtin.os.tag != .windows) unreachable;

    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
    const hStdin = windows.GetStdHandle(STD_INPUT_HANDLE);
    var first_esc_ts: ?std.Io.Timestamp = null;
    var pending_high: ?u16 = null;

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
        const alt = (key_event.dwControlKeyState & (windows.LEFT_ALT_PRESSED | windows.RIGHT_ALT_PRESSED)) != 0;
        const word = ctrl or alt;

        if (vk != windows.VK_ESCAPE) first_esc_ts = null;
        switch (vk) {
            windows.VK_RETURN => {
                try editor.moveEnd();
                return .{ .submitted = editor.line_alloc.written() };
            },
            windows.VK_BACK => {
                pending_high = null;
                if (word) try editor.deleteWordBackward() else try editor.backspace();
            },
            windows.VK_DELETE => try editor.handleKey(if (word) .delete_word_forward else .delete),
            windows.VK_ESCAPE => {
                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) {
                        try editor.moveEnd();
                        return .cancelled;
                    }
                }
                first_esc_ts = now;
            },
            windows.VK_UP => try editor.handleKey(.up),
            windows.VK_DOWN => try editor.handleKey(.down),
            windows.VK_LEFT => try editor.handleKey(if (word) .word_left else .left),
            windows.VK_RIGHT => try editor.handleKey(if (word) .word_right else .right),
            windows.VK_HOME => try editor.handleKey(.home),
            windows.VK_END => try editor.handleKey(.end),
            else => {
                const ch = key_event.uChar.UnicodeChar;
                if (ch == 3 and ctrl) {
                    try editor.moveEnd();
                    sigint.trigger();
                    return .interrupted;
                }
                // Ctrl+letter shortcuts arrive as C0 control characters.
                if (ctrl and ch < 32) switch (ch) {
                    0x01 => try editor.moveHome(),
                    0x02 => try editor.moveLeft(),
                    0x04 => if (editor.line_alloc.written().len == 0) return .cancelled else try editor.deleteForward(),
                    0x05 => try editor.moveEnd(),
                    0x06 => try editor.moveRight(),
                    0x0B => try editor.killToEnd(),
                    0x15 => try editor.killToStart(),
                    0x17 => try editor.deleteWhitespaceWordBackward(),
                    else => {},
                };
                if (alt and !ctrl) if (keys.altByteFromVirtualKey(vk, ch)) |byte| {
                    const key = keys.decodeAlt(byte);
                    if (key != .unknown) {
                        try editor.handleKey(key);
                        continue;
                    }
                };
                if (ch >= 32 and ch != 127) {
                    if (std.unicode.utf16IsHighSurrogate(ch)) {
                        pending_high = ch;
                    } else if (std.unicode.utf16IsLowSurrogate(ch)) {
                        if (pending_high) |high| {
                            pending_high = null;
                            const pair = [2]u16{ high, ch };
                            const cp = std.unicode.utf16DecodeSurrogatePair(&pair) catch continue;
                            try appendScalar(editor, cp);
                        }
                    } else {
                        pending_high = null;
                        if (ch < 0x80) {
                            if (ch == '@' and mention.isTrigger(editor.line_alloc.written()[0..editor.cursor])) {
                                try mention.insertMention(allocator, io, editor);
                            } else {
                                try editor.append(@intCast(ch));
                            }
                        } else {
                            try appendScalar(editor, ch);
                        }
                    }
                }
            },
        }
    }
}

/// Encodes a Unicode scalar as UTF-8 and appends it as one slice so the
/// editor redraws once instead of per byte.
fn appendScalar(editor: *line_editor.LineEditor, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);
    try editor.appendSlice(buf[0..len]);
}

const windows = if (builtin.os.tag == .windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;

    pub const VK_RETURN: u16 = 0x0D;
    pub const VK_BACK: u16 = 0x08;
    pub const VK_ESCAPE: u16 = 0x1B;
    pub const VK_END: u16 = 0x23;
    pub const VK_HOME: u16 = 0x24;
    pub const VK_LEFT: u16 = 0x25;
    pub const VK_UP: u16 = 0x26;
    pub const VK_RIGHT: u16 = 0x27;
    pub const VK_DOWN: u16 = 0x28;
    pub const VK_DELETE: u16 = 0x2E;
    pub const KEY_EVENT: u16 = 0x0001;
    pub const LEFT_CTRL_PRESSED: DWORD = 0x0008;
    pub const RIGHT_CTRL_PRESSED: DWORD = 0x0004;
    pub const RIGHT_ALT_PRESSED: DWORD = 0x0001;
    pub const LEFT_ALT_PRESSED: DWORD = 0x0002;

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
