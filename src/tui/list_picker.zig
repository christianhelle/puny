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
    left,
    right,
    enter,
    escape,
    quit,
    unknown,
};

var pending_buf: [8]u8 = undefined;
var pending_len: usize = 0;

/// Row/column dimensions of a column-major item grid.
pub const Grid = struct {
    rows: usize,
    cols: usize,

    /// Number of populated rows in `col` (the last column may be partial
    /// when `items_len` isn't an exact multiple of `rows`).
    pub fn rowsInCol(self: Grid, items_len: usize, col: usize) usize {
        if (self.cols == 0) return 0;
        if (col + 1 < self.cols) return self.rows;
        const full_cols_items = (self.cols - 1) * self.rows;
        return items_len - full_cols_items;
    }
};

/// Computes a column-major grid layout for `items_len` items.
///
/// Stays single-column (matching prior behavior) while everything fits in
/// `available_rows`. Once the item count overflows the available rows, it
/// grows into as many columns as needed to fit vertically, then shrinks
/// that column count back down if it wouldn't fit within `terminal_width`
/// (each column occupying `column_width` characters).
pub fn computeGrid(items_len: usize, available_rows: usize, terminal_width: usize, column_width: usize) Grid {
    if (items_len == 0) return .{ .rows = 0, .cols = 0 };

    const rows_cap = @max(available_rows, 1);
    if (items_len <= rows_cap) return .{ .rows = items_len, .cols = 1 };

    var cols = std.math.divCeil(usize, items_len, rows_cap) catch 1;

    const width_cap = if (column_width == 0) cols else @max(terminal_width / column_width, 1);
    if (cols > width_cap) cols = width_cap;

    const rows = std.math.divCeil(usize, items_len, cols) catch items_len;
    return .{ .rows = rows, .cols = cols };
}

test "computeGrid keeps a single column when items fit available rows" {
    const g = computeGrid(5, 20, 80, 10);
    try std.testing.expectEqual(@as(usize, 5), g.rows);
    try std.testing.expectEqual(@as(usize, 1), g.cols);
}

test "computeGrid keeps a single column when items exactly fill available rows" {
    const g = computeGrid(20, 20, 80, 10);
    try std.testing.expectEqual(@as(usize, 20), g.rows);
    try std.testing.expectEqual(@as(usize, 1), g.cols);
}

test "computeGrid grows into multiple columns on overflow" {
    const g = computeGrid(50, 20, 80, 10);
    try std.testing.expectEqual(@as(usize, 3), g.cols);
    try std.testing.expectEqual(@as(usize, 17), g.rows);
}

test "computeGrid clamps columns to fit terminal width" {
    // 50 items, 20 rows would need 3 columns, but width only fits 2.
    const g = computeGrid(50, 20, 25, 12);
    try std.testing.expectEqual(@as(usize, 2), g.cols);
    try std.testing.expectEqual(@as(usize, 25), g.rows);
}

test "computeGrid returns zero grid for an empty item list" {
    const g = computeGrid(0, 20, 80, 10);
    try std.testing.expectEqual(@as(usize, 0), g.rows);
    try std.testing.expectEqual(@as(usize, 0), g.cols);
}

test "computeGrid treats zero available rows as one row" {
    const g = computeGrid(3, 0, 80, 10);
    try std.testing.expectEqual(@as(usize, 3), g.cols);
    try std.testing.expectEqual(@as(usize, 1), g.rows);
}

test "Grid.rowsInCol reports the partial last column" {
    // 7 items, 3 rows, 3 cols -> columns hold 3, 3, 1.
    const g = Grid{ .rows = 3, .cols = 3 };
    try std.testing.expectEqual(@as(usize, 3), g.rowsInCol(7, 0));
    try std.testing.expectEqual(@as(usize, 3), g.rowsInCol(7, 1));
    try std.testing.expectEqual(@as(usize, 1), g.rowsInCol(7, 2));
}

test "Grid.rowsInCol handles a single full column" {
    const g = Grid{ .rows = 5, .cols = 1 };
    try std.testing.expectEqual(@as(usize, 5), g.rowsInCol(5, 0));
}

/// Extra characters reserved per column beyond the label itself: a 2-char
/// "> "/"  " selection prefix plus a 2-space gap before the next column.
const column_padding = 4;

/// Widest column needed to render `items` without truncating any label,
/// including room for the selection prefix and inter-column gap.
pub fn computeColumnWidth(items: []const Item) usize {
    var max_len: usize = 0;
    for (items) |item| max_len = @max(max_len, item.label.len);
    return max_len + column_padding;
}

test "computeColumnWidth returns padding only for an empty list" {
    try std.testing.expectEqual(@as(usize, column_padding), computeColumnWidth(&.{}));
}

test "computeColumnWidth accounts for the longest label" {
    const items = [_]Item{
        .{ .value = "a", .label = "short" },
        .{ .value = "b", .label = "a much longer label" },
        .{ .value = "c", .label = "mid" },
    };
    try std.testing.expectEqual(@as(usize, "a much longer label".len + column_padding), computeColumnWidth(&items));
}

/// Default rows/columns assumed when the terminal size can't be determined,
/// matching the fallback pattern used by `terminal.terminalWidth()`.
const default_available_rows = 20;
const default_terminal_width = 80;

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

    const available_rows = terminal.terminalHeight() orelse default_available_rows;
    const terminal_width = terminal.terminalWidth() orelse default_terminal_width;
    const column_width = computeColumnWidth(items);
    const grid = computeGrid(items.len, available_rows, terminal_width, column_width);

    try stdout_writer.print("\r\n\r\n{s}\r\n", .{title});
    try renderGrid(stdout_writer, items, grid, selected, column_width, true);
    try stdout_writer.flush();

    while (true) {
        const key = readKey(io) catch .unknown;
        const dir: ?GridDir = switch (key) {
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            else => null,
        };
        if (dir) |d| {
            selected = gridStep(selected, items.len, grid, d);
            try stdout_writer.print(terminal.cursor_up, .{grid.rows});
            try renderGrid(stdout_writer, items, grid, selected, column_width, true);
            continue;
        }
        switch (key) {
            .enter => {
                try stdout_writer.print(terminal.cursor_up ++ terminal.erase_display, .{grid.rows + 1});
                try stdout_writer.flush();
                return try arena.dupe(u8, items[selected].value);
            },
            .quit, .escape => {
                try stdout_writer.print(terminal.cursor_up ++ terminal.erase_display, .{grid.rows + 1});
                try stdout_writer.flush();
                return null;
            },
            else => {},
        }
    }
}

/// Direction of a single grid navigation step.
pub const GridDir = enum { up, down, left, right };

/// Computes the new selected linear index after moving `dir` within a
/// column-major `grid` of `items_len` items, given the current `selected`
/// linear index.
///
/// Up/Down wrap within the current column. Left/Right move to the same row
/// in the adjacent column (wrapping around columns), clamping to the last
/// valid row when the target column is shorter (a partial last column).
pub fn gridStep(selected: usize, items_len: usize, grid: Grid, dir: GridDir) usize {
    if (grid.rows == 0 or grid.cols == 0 or items_len == 0) return selected;

    const row = selected % grid.rows;
    const col = selected / grid.rows;

    switch (dir) {
        .up, .down => {
            const rows_in_col = grid.rowsInCol(items_len, col);
            const new_row = switch (dir) {
                .up => if (row == 0) rows_in_col - 1 else row - 1,
                .down => if (row + 1 >= rows_in_col) 0 else row + 1,
                else => unreachable,
            };
            return col * grid.rows + new_row;
        },
        .left, .right => {
            const new_col = switch (dir) {
                .left => if (col == 0) grid.cols - 1 else col - 1,
                .right => if (col + 1 >= grid.cols) 0 else col + 1,
                else => unreachable,
            };
            const rows_in_new_col = grid.rowsInCol(items_len, new_col);
            const new_row = @min(row, rows_in_new_col - 1);
            return new_col * grid.rows + new_row;
        },
    }
}

test "gridStep up/down wrap within a single column" {
    const grid = Grid{ .rows = 3, .cols = 1 };
    try std.testing.expectEqual(@as(usize, 2), gridStep(0, 3, grid, .up));
    try std.testing.expectEqual(@as(usize, 1), gridStep(0, 3, grid, .down));
    try std.testing.expectEqual(@as(usize, 0), gridStep(2, 3, grid, .down));
    try std.testing.expectEqual(@as(usize, 1), gridStep(2, 3, grid, .up));
}

test "gridStep left/right wrap across columns on the same row" {
    // 6 items, 3 rows, 2 cols: col0=[0,1,2], col1=[3,4,5].
    const grid = Grid{ .rows = 3, .cols = 2 };
    try std.testing.expectEqual(@as(usize, 3), gridStep(0, 6, grid, .right));
    try std.testing.expectEqual(@as(usize, 0), gridStep(3, 6, grid, .left));
    try std.testing.expectEqual(@as(usize, 0), gridStep(3, 6, grid, .right));
    try std.testing.expectEqual(@as(usize, 3), gridStep(0, 6, grid, .left));
}

test "gridStep left/right clamps to the last row of a partial column" {
    // 5 items, 3 rows, 2 cols: col0=[0,1,2], col1=[3,4] (partial).
    const grid = Grid{ .rows = 3, .cols = 2 };
    // Selected row 2 (bottom) of col0 moving right lands on col1's last row (row 1).
    try std.testing.expectEqual(@as(usize, 4), gridStep(2, 5, grid, .right));
    // Moving left from that clamped position lands on col0's row 1 (row is preserved, not restored).
    try std.testing.expectEqual(@as(usize, 1), gridStep(4, 5, grid, .left));
}

test "gridStep is a no-op for a single-item grid" {
    const grid = Grid{ .rows = 1, .cols = 1 };
    inline for ([_]GridDir{ .up, .down, .left, .right }) |dir| {
        try std.testing.expectEqual(@as(usize, 0), gridStep(0, 1, grid, dir));
    }
}

/// Each cell is padded to `column_width` unless it's the last populated
/// column in its row, so single-column layouts render identically to the
/// original one-item-per-line output.
fn renderGrid(stdout_writer: *std.Io.Writer, items: []const Item, grid: Grid, selected: usize, column_width: usize, clear: bool) !void {
    for (0..grid.rows) |r| {
        if (clear) try stdout_writer.print(terminal.clear_line ++ "\r", .{});
        for (0..grid.cols) |c| {
            const idx = c * grid.rows + r;
            if (idx >= items.len) continue;
            const item = items[idx];
            const is_last_in_row = idx + grid.rows >= items.len or c == grid.cols - 1;
            if (idx == selected) {
                try stdout_writer.print("{s}> {s}{s}", .{ ansi.bright, item.label, ansi.reset });
            } else {
                try stdout_writer.print("  {s}", .{item.label});
            }
            if (!is_last_in_row) {
                const printed = item.label.len + 2;
                const pad = if (column_width > printed) column_width - printed else 0;
                try stdout_writer.splatByteAll(' ', pad);
            }
        }
        try stdout_writer.writeAll("\n");
    }
    try stdout_writer.flush();
}

test "renderGrid renders a single column identically to one item per line" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const items = [_]Item{
        .{ .value = "one", .label = "One" },
        .{ .value = "two", .label = "Two" },
    };
    try renderGrid(&out.writer, &items, .{ .rows = 2, .cols = 1 }, 1, computeColumnWidth(&items), false);

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "> Two") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  One") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ansi.bright) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ansi.reset) != null);
}

test "renderGrid lays out multiple columns and pads non-final cells" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    // Column-major: col0 = [A, B], col1 = [C].
    const items = [_]Item{
        .{ .value = "a", .label = "A" },
        .{ .value = "b", .label = "B" },
        .{ .value = "c", .label = "C" },
    };
    const grid = Grid{ .rows = 2, .cols = 2 };
    try renderGrid(&out.writer, &items, grid, 0, computeColumnWidth(&items), false);

    const text = out.written();
    const lines = std.mem.count(u8, text, "\n");
    try std.testing.expectEqual(@as(usize, 2), lines);
    // First row has both column0 ("A") and column1 ("C"); second row only column0 ("B").
    try std.testing.expect(std.mem.indexOf(u8, text, "> A") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "C\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  B\n") != null);
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
                    'C' => result = .right,
                    'D' => result = .left,
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
        'h', 'H' => return .left,
        'l', 'L' => return .right,
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
            win.VK_LEFT => return .left,
            win.VK_RIGHT => return .right,
            win.VK_RETURN => return .enter,
            win.VK_ESCAPE => return .escape,
            else => {
                const ch = record.Event.KeyEvent.uChar.UnicodeChar;
                if (ch == 'q' or ch == 'Q') return .quit;
                if (ch == 'j' or ch == 'J') return .down;
                if (ch == 'k' or ch == 'K') return .up;
                if (ch == 'h' or ch == 'H') return .left;
                if (ch == 'l' or ch == 'L') return .right;
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
    pub const VK_LEFT: u16 = 0x25;
    pub const VK_RIGHT: u16 = 0x27;
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

test "readKeyPosix interprets key bytes from the pending buffer" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const cases = [_]struct {
        bytes: []const u8,
        expected: Key,
    }{
        .{ .bytes = "\x1b[A", .expected = .up },
        .{ .bytes = "\x1b[B", .expected = .down },
        .{ .bytes = "\x1b[C", .expected = .right },
        .{ .bytes = "\x1b[D", .expected = .left },
        .{ .bytes = "\x1b", .expected = .escape },
        .{ .bytes = "\x1bC", .expected = .unknown },
        .{ .bytes = "\r", .expected = .enter },
        .{ .bytes = "\n", .expected = .enter },
        .{ .bytes = "q", .expected = .quit },
        .{ .bytes = "j", .expected = .down },
        .{ .bytes = "k", .expected = .up },
        .{ .bytes = "h", .expected = .left },
        .{ .bytes = "l", .expected = .right },
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    pending_len = 0;
    @memcpy(pending_buf[0..2], "ab");
    pending_len = 2;
    try std.testing.expectEqual(Key.unknown, try readKey(std.testing.io));
    // The unknown key resets the pending buffer, so the extra byte is dropped.
    try std.testing.expectEqual(@as(usize, 0), pending_len);
    pending_len = 0;
}

test "readKeyPosix buffers leftover bytes after an escape sequence" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    pending_len = 0;
    @memcpy(pending_buf[0..4], "\x1b[Aq");
    pending_len = 4;
    try std.testing.expectEqual(Key.up, try readKey(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), pending_len);
    try std.testing.expectEqual(@as(u8, 'q'), pending_buf[0]);
    pending_len = 0;
}
