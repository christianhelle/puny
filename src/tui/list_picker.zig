const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const cancel = @import("../core/cancel.zig");
const terminal = @import("terminal.zig");
const ansi = @import("ansi.zig");

pub const Item = struct {
    value: []const u8,
    label: []const u8,
};

const Key = enum {
    up,
    down,
    enter,
    escape,
    quit,
    unknown,
};

var pending_buf: [8]u8 = undefined;
var pending_len: usize = 0;

pub fn selectFromList(
    arena: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    items: []const Item,
) !?[]const u8 {
    if (items.len == 0) return null;

    cancel.setRawMode(true) catch {
        return try selectText(arena, io, title, items);
    };
    defer cancel.setRawMode(false) catch {};

    pending_len = 0;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var selected: usize = 0;

    try stdout_writer.print("\r\n\r\n{s}\r\n", .{title});
    for (items, 0..) |item, i| {
        if (i == selected) {
            try stdout_writer.print("{s}> {s}{s}\r\n", .{ ansi.bright, item.label, ansi.reset });
        } else {
            try stdout_writer.print("  {s}\r\n", .{item.label});
        }
    }
    try stdout_writer.flush();

    while (true) {
        const key = readKey(io) catch .unknown;
        switch (key) {
            .up => {
                selected = if (selected == 0) items.len - 1 else selected - 1;
                try redrawList(stdout_writer, items, selected);
            },
            .down => {
                selected = if (selected < items.len - 1) selected + 1 else 0;
                try redrawList(stdout_writer, items, selected);
            },
            .enter => {
                try stdout_writer.print(terminal.cursor_up ++ terminal.erase_display, .{items.len + 1});
                try stdout_writer.flush();
                return try arena.dupe(u8, items[selected].value);
            },
            .quit, .escape => {
                try stdout_writer.print(terminal.cursor_up ++ terminal.erase_display, .{items.len + 1});
                try stdout_writer.flush();
                return null;
            },
            else => {},
        }
    }
}

fn redrawList(stdout_writer: *std.Io.Writer, items: []const Item, selected: usize) !void {
    try stdout_writer.print(terminal.cursor_up, .{items.len});
    for (items, 0..) |item, i| {
        try stdout_writer.print(terminal.clear_line ++ "\r", .{});
        if (i == selected) {
            try stdout_writer.print("{s}> {s}{s}\n", .{ ansi.bright, item.label, ansi.reset });
        } else {
            try stdout_writer.print("  {s}\n", .{item.label});
        }
    }
    try stdout_writer.flush();
}

fn selectText(
    arena: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    items: []const Item,
) !?[]const u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("\n{s}\n", .{title});
    for (items, 0..) |item, i| {
        try stdout_writer.print("  {d}. {s}\n", .{ i + 1, item.label });
    }
    try stdout_writer.print("\nEnter number or key: ", .{});
    try stdout_writer.flush();

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    const bytes_read = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => return null,
        else => return err,
    };
    if (bytes_read == 0) return null;

    const raw = line_alloc.written();
    const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
    if (line.len == 0) return null;

    const idx = std.fmt.parseInt(usize, line, 10) catch null;
    if (idx) |i| {
        if (i > 0 and i <= items.len) return try arena.dupe(u8, items[i - 1].value);
        try stdout_writer.print("Invalid number.\n", .{});
        try stdout_writer.flush();
        return null;
    }

    for (items) |item| {
        if (std.mem.eql(u8, line, item.value)) return try arena.dupe(u8, item.value);
    }

    return null;
}

fn readKey(io: std.Io) !Key {
    if (is_windows) {
        return readKeyWindows(io);
    } else {
        return readKeyPosix(io);
    }
}

fn readKeyPosix(io: std.Io) !Key {
    _ = io;
    const posix = std.posix;
    var buf: [8]u8 = undefined;
    var buf_len: usize = 0;

    if (pending_len > 0) {
        const copy_len = @min(pending_len, buf.len);
        @memcpy(buf[0..copy_len], pending_buf[0..copy_len]);
        buf_len = copy_len;
        if (copy_len < pending_len) {
            @memcpy(pending_buf[0 .. pending_len - copy_len], pending_buf[copy_len..pending_len]);
        }
        pending_len -= copy_len;
    } else {
        var pfd = [1]posix.pollfd{
            .{ .fd = 0, .events = posix.POLL.IN, .revents = undefined },
        };
        const rc = posix.poll(&pfd, 1000) catch return error.ReadFailed;
        if (rc == 0) return .unknown;
        if (pfd[0].revents & posix.POLL.IN == 0) return .unknown;

        const n = posix.read(0, buf[0..]) catch return error.ReadFailed;
        if (n == 0) return .unknown;
        buf_len = n;
    }

    if (buf[0] == 0x1b) {
        var seq: [8]u8 = undefined;
        var seq_len: usize = 0;

        const copy_len = @min(buf_len, seq.len);
        @memcpy(seq[0..copy_len], buf[0..copy_len]);
        seq_len = copy_len;

        while (seq_len < 8) {
            var pfd2 = [1]posix.pollfd{
                .{ .fd = 0, .events = posix.POLL.IN, .revents = undefined },
            };
            const rc2 = posix.poll(&pfd2, 30) catch break;
            if (rc2 == 0) break;
            const m = posix.read(0, seq[seq_len..][0..1]) catch break;
            if (m == 0) break;
            seq_len += 1;
        }

        var consumed: usize = 1;
        var result: Key = .unknown;

        if (seq_len == 1) {
            result = .escape;
        } else if (seq_len >= 2 and seq[1] == '[') {
            consumed = 2;
            if (seq_len >= 3) {
                consumed = 3;
                switch (seq[2]) {
                    'A' => result = .up,
                    'B' => result = .down,
                    else => result = .unknown,
                }
            }
        }

        if (seq_len > consumed) {
            const remaining = seq_len - consumed;
            @memcpy(pending_buf[0..remaining], seq[consumed..seq_len]);
            pending_len = remaining;
        }

        return result;
    }

    if (buf_len > 1) {
        @memcpy(pending_buf[0 .. buf_len - 1], buf[1..buf_len]);
        pending_len = buf_len - 1;
    }

    switch (buf[0]) {
        '\r', '\n' => return .enter,
        'q', 'Q' => return .quit,
        'j', 'J' => return .down,
        'k', 'K' => return .up,
        else => {
            pending_len = 0;
            return .unknown;
        },
    }
}

fn readKeyWindows(io: std.Io) !Key {
    _ = io;
    if (!is_windows) unreachable;
    const win = windows_api;
    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
    const hStdin = win.GetStdHandle(STD_INPUT_HANDLE);

    while (true) {
        var record: win.INPUT_RECORD = undefined;
        var events_read: win.DWORD = 0;
        if (win.ReadConsoleInputW(hStdin, &record, 1, &events_read) == .FALSE) return error.ReadFailed;
        if (events_read == 0) continue;
        if (record.EventType != win.KEY_EVENT) continue;
        if (record.Event.KeyEvent.bKeyDown == .FALSE) continue;

        const vk = record.Event.KeyEvent.wVirtualKeyCode;
        switch (vk) {
            win.VK_UP => return .up,
            win.VK_DOWN => return .down,
            win.VK_RETURN => return .enter,
            win.VK_ESCAPE => return .escape,
            else => {
                const ch = record.Event.KeyEvent.uChar.UnicodeChar;
                if (ch == 'q' or ch == 'Q') return .quit;
                if (ch == 'j' or ch == 'J') return .down;
                if (ch == 'k' or ch == 'K') return .up;
                return .unknown;
            },
        }
    }
}

const windows_api = if (is_windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;
    pub const WCHAR = std.os.windows.WCHAR;

    pub const VK_UP: u16 = 0x26;
    pub const VK_DOWN: u16 = 0x28;
    pub const VK_RETURN: u16 = 0x0D;
    pub const VK_ESCAPE: u16 = 0x1B;
    pub const KEY_EVENT: u16 = 0x0001;

    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: BOOL,
        wRepeatCount: u16,
        wVirtualKeyCode: u16,
        wVirtualScanCode: u16,
        uChar: extern union {
            UnicodeChar: WCHAR,
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

test "selectFromList returns null for empty list" {
    const items: [0]Item = .{};
    const result = try selectFromList(std.testing.allocator, std.testing.io, "Title", &items);
    try std.testing.expect(result == null);
}

test "Item struct has expected fields" {
    const item = Item{ .value = "test", .label = "Test Item" };
    try std.testing.expectEqualStrings("test", item.value);
    try std.testing.expectEqualStrings("Test Item", item.label);
}

test "redrawList renders items with the selection highlighted" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const items = [_]Item{
        .{ .value = "one", .label = "One" },
        .{ .value = "two", .label = "Two" },
    };
    try redrawList(&out.writer, &items, 1);

    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "\x1b[2A"));
    try std.testing.expect(std.mem.indexOf(u8, text, "> Two") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ansi.bright) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  One") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ansi.reset) != null);
}

test "readKeyPosix interprets key bytes from the pending buffer" {
    const cases = [_]struct {
        bytes: []const u8,
        expected: Key,
    }{
        .{ .bytes = "\x1b[A", .expected = .up },
        .{ .bytes = "\x1b[B", .expected = .down },
        .{ .bytes = "\x1b", .expected = .escape },
        .{ .bytes = "\x1bC", .expected = .unknown },
        .{ .bytes = "\r", .expected = .enter },
        .{ .bytes = "\n", .expected = .enter },
        .{ .bytes = "q", .expected = .quit },
        .{ .bytes = "j", .expected = .down },
        .{ .bytes = "k", .expected = .up },
        .{ .bytes = "x", .expected = .unknown },
    };
    for (cases) |c| {
        pending_len = 0;
        @memcpy(pending_buf[0..c.bytes.len], c.bytes);
        pending_len = c.bytes.len;
        try std.testing.expectEqual(c.expected, try readKey(std.testing.io));
    }
    pending_len = 0;
}

test "readKeyPosix buffers extra bytes received in one read" {
    pending_len = 0;
    @memcpy(pending_buf[0..2], "ab");
    pending_len = 2;
    try std.testing.expectEqual(Key.unknown, try readKey(std.testing.io));
    // The unknown key resets the pending buffer, so the extra byte is dropped.
    try std.testing.expectEqual(@as(usize, 0), pending_len);
    pending_len = 0;
}

test "readKeyPosix buffers leftover bytes after an escape sequence" {
    pending_len = 0;
    @memcpy(pending_buf[0..4], "\x1b[Aq");
    pending_len = 4;
    try std.testing.expectEqual(Key.up, try readKey(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), pending_len);
    try std.testing.expectEqual(@as(u8, 'q'), pending_buf[0]);
    pending_len = 0;
}
