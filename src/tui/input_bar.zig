const std = @import("std");
const ansi = @import("ansi.zig");
const width = @import("markdown/width.zig");
const SpinLock = @import("../core/type_ahead.zig").SpinLock;

/// The bar shown during chat loops, and the lock over everything written to
/// the terminal while it is up.
pub var global: InputBar = .{};
pub var screen_lock: SpinLock = .{};

/// The `>` input row pinned to the bottom of the terminal while the agent
/// works. A scroll region keeps streamed output above it, with one empty row
/// between the two.
pub const InputBar = struct {
    out: ?*std.Io.Writer = null,
    active: bool = false,
    /// Up between `enter` and `leave`, even while the window is too small to
    /// show the bar, so it can come back when the window grows.
    wanted: bool = false,
    rows: usize = 0,
    cols: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    cursor: usize = 0,
    queued: usize = 0,
    hint: bool = false,

    pub const text_capacity = 8192;
    const reserved_rows = 2;
    const min_rows = 4;
    const min_cols = 10;
    const hint_text = "(Press Esc again to cancel)";
    /// Index then reverse index, once per reserved row.
    const make_room = "\x1bD\x1bD\x1bM\x1bM";

    fn fits(rows: usize, cols: usize) bool {
        return rows >= min_rows and cols >= min_cols;
    }

    /// Enters the bar if the terminal is big enough to spare the rows.
    pub fn enter(self: *InputBar, rows: usize, cols: usize) !void {
        const out = self.out orelse return;
        self.wanted = true;
        if (self.active or !fits(rows, cols)) return;
        self.active = true;
        self.rows = rows;
        self.cols = cols;
        // Index then reverse index, once per reserved row, scrolls up if the
        // cursor is on a row about to be reserved, without moving its column.
        // Setting a region homes the cursor, so it is saved around that.
        try out.print(make_room ++ "\x1b7\x1b[1;{d}r\x1b8", .{rows - reserved_rows});
        try self.paint();
    }

    pub fn leave(self: *InputBar) !void {
        self.wanted = false;
        try self.release();
    }

    fn release(self: *InputBar) !void {
        if (!self.active) return;
        const out = self.out orelse return;
        self.active = false;
        try out.print("\x1b7\x1b[r\x1b[{d};1H\x1b[J\x1b8", .{self.rows - reserved_rows + 1});
        try out.flush();
    }

    /// Shows a new state; an unchanged one writes nothing.
    pub fn draw(self: *InputBar, text: []const u8, cursor: usize, queued: usize, hint: bool) !void {
        if (!self.active) return;
        const kept = text[0..@min(text.len, text_capacity)];
        if (std.mem.eql(u8, kept, self.text[0..self.text_len]) and cursor == self.cursor and queued == self.queued and hint == self.hint) return;
        @memcpy(self.text[0..kept.len], kept);
        self.text_len = kept.len;
        self.cursor = @min(cursor, kept.len);
        self.queued = queued;
        self.hint = hint;
        try self.paint();
    }

    /// Puts the bar back after something erased the screen below the cursor.
    pub fn repaint(self: *InputBar) !void {
        if (self.active) try self.paint();
    }

    pub fn resize(self: *InputBar, rows: usize, cols: usize) !void {
        if (!self.wanted) return;
        const out = self.out orelse return;
        if (!fits(rows, cols)) return self.release();
        if (!self.active) return self.enter(rows, cols);
        self.rows = rows;
        self.cols = cols;
        // Shrinking can leave the cursor below the new region, where output
        // would no longer scroll, so room is made without a region in the
        // way. Old output can also land on the row that has to stay empty.
        try out.print("\x1b7\x1b[r\x1b8" ++ make_room ++ "\x1b7\x1b[1;{d}r\x1b[{d};1H\x1b[2K\x1b8", .{ rows - reserved_rows, rows - 1 });
        try self.paint();
    }

    fn paint(self: *InputBar) !void {
        const out = self.out orelse return;
        var prefix_buffer: [32]u8 = undefined;
        const counted = std.fmt.bufPrint(&prefix_buffer, "({d} queued) > ", .{self.queued}) catch "> ";
        const prefix = if (self.queued > 0 and counted.len + min_cols <= self.cols) counted else "> ";
        const available = self.cols - prefix.len - 1;

        try out.print("\x1b7\x1b[{d};1H\x1b[2K{s}", .{ self.rows, prefix });
        if (self.text_len == 0 and self.hint) {
            if (hint_text.len <= available) try out.print(ansi.dim ++ hint_text ++ ansi.reset, .{});
        } else {
            try self.paintText(out, available);
        }
        try out.writeAll("\x1b8");
        try out.flush();
    }

    /// Paints the part of the text around the cursor that fits, with the
    /// cursor's cell in reverse video.
    fn paintText(self: *InputBar, out: *std.Io.Writer, available: usize) !void {
        const text = self.text[0..self.text_len];
        var start = self.cursor;
        while (start > 0) {
            var previous = start - 1;
            while (previous > 0 and text[previous] & 0xC0 == 0x80) previous -= 1;
            if (width.displayWidth(text[previous..self.cursor]) + 1 > available) break;
            start = previous;
        }

        const under_end = codePointEnd(text, self.cursor);
        var end = under_end;
        while (end < text.len) {
            const next = codePointEnd(text, end);
            if (width.displayWidth(text[start..next]) > available) break;
            end = next;
        }

        const under = if (under_end > self.cursor) text[self.cursor..under_end] else " ";
        try out.print("{s}\x1b[7m{s}\x1b[27m{s}", .{ text[start..self.cursor], under, text[under_end..end] });
    }
};

fn codePointEnd(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    var end = index + 1;
    while (end < text.len and text[end] & 0xC0 == 0x80) end += 1;
    return end;
}

/// Stdout for everything except the bar. Writes take `lock`, so the monitor
/// thread's bar updates cannot land inside them, and repaint the bar after
/// erasing the screen, which ignores the scroll region.
pub const ScreenWriter = struct {
    interface: std.Io.Writer,
    inner: *std.Io.Writer,
    bar: *InputBar,
    lock: *SpinLock,

    pub fn init(inner: *std.Io.Writer, bar: *InputBar, lock: *SpinLock, buffer: []u8) ScreenWriter {
        return .{
            .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } },
            .inner = inner,
            .bar = bar,
            .lock = lock,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ScreenWriter = @fieldParentPtr("interface", w);
        self.lock.lock();
        defer self.lock.unlock();

        const buffered = w.buffered();
        if (buffered.len > 0) {
            // Holding back an unfinished sequence keeps it whole. With only
            // that tail left, more of the write joins it in the buffer; a
            // flush has nothing more to add, so the tail then goes out.
            const safe = safeLength(buffered);
            if (safe == 0 and w.end < w.buffer.len) {
                if (incoming(data, splat)) |bytes| {
                    const count = @min(bytes.len, w.buffer.len - w.end);
                    @memcpy(w.buffer[w.end..][0..count], bytes[0..count]);
                    w.end += count;
                    return count;
                }
            }
            const count = if (safe > 0) safe else buffered.len;
            try self.writeOut(buffered[0..count]);
            _ = w.consume(count);
            return 0;
        }

        // Everything goes through the buffer so it gets the same treatment.
        const bytes = incoming(data, splat) orelse return 0;
        return fill(w, bytes);
    }

    /// The next bytes of the write being drained, if any.
    fn incoming(data: []const []const u8, splat: usize) ?[]const u8 {
        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len > 0) return bytes;
        }
        const last = data[data.len - 1];
        return if (splat > 0 and last.len > 0) last else null;
    }

    fn fill(w: *std.Io.Writer, bytes: []const u8) usize {
        const count = @min(bytes.len, w.buffer.len);
        @memcpy(w.buffer[0..count], bytes[0..count]);
        w.end = count;
        return count;
    }

    fn writeOut(self: *ScreenWriter, bytes: []const u8) std.Io.Writer.Error!void {
        try self.inner.writeAll(bytes);
        const erased = std.mem.indexOf(u8, bytes, "\x1b[J") != null or
            std.mem.indexOf(u8, bytes, "\x1b[0J") != null or
            std.mem.indexOf(u8, bytes, "\x1b[2J") != null;
        if (erased and self.bar.active) return self.bar.repaint();
        try self.inner.flush();
    }
};

/// How much of `bytes` can be written without ending inside an escape
/// sequence or a UTF-8 code point, where the bar's output would corrupt it.
pub fn safeLength(bytes: []const u8) usize {
    // Terminal sequences are short, so only the tail can hold an open one.
    const window_start = bytes.len -| 32;
    if (std.mem.lastIndexOfScalar(u8, bytes[window_start..], 0x1b)) |offset| {
        const at = window_start + offset;
        if (!escapeComplete(bytes[at..])) return at;
    }

    var index = bytes.len;
    while (index > 0 and bytes.len - index < 4) {
        index -= 1;
        const byte = bytes[index];
        if (byte & 0xC0 == 0x80) continue;
        const expected = std.unicode.utf8ByteSequenceLength(byte) catch return bytes.len;
        return if (bytes.len - index < expected) index else bytes.len;
    }
    return bytes.len;
}

fn escapeComplete(sequence: []const u8) bool {
    if (sequence.len < 2) return false;
    if (sequence[1] != '[') return true;
    for (sequence[2..]) |byte| {
        if (byte >= 0x40 and byte <= 0x7E) return true;
    }
    return false;
}

/// Gives a panicking process's shell its whole screen back. Skips the lock,
/// since the panicking thread may hold it.
pub fn emergencyReset(bar: *const InputBar, write: *const fn ([]const u8) void) void {
    if (bar.active) write("\x1b[r");
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("missing {s} in {s}\n", .{ needle, haystack });
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "entering reserves the bottom row and an empty one above it, keeping the cursor where it was" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };

    try bar.enter(24, 80);

    try std.testing.expect(bar.active);
    // Index then reverse index, twice, makes room if the cursor is on a row
    // that is about to be reserved.
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\x1bD\x1bD\x1bM\x1bM\x1b7\x1b[1;22r\x1b8"));
}

test "a terminal too small to spare two rows gets no bar" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };

    try bar.enter(3, 80);

    try std.testing.expect(!bar.active);
    try std.testing.expectEqualStrings("", out.written());
}

test "drawing paints the text on the last row and restores the cursor" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.draw("hello", 5, 0, false);

    const written = out.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b7\x1b[24;1H\x1b[2K> hello"));
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b8"));
}

test "the cursor position is shown in reverse video" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.draw("abc", 1, 0, false);

    try expectContains(out.written(), "> a\x1b[7mb\x1b[27mc");
}

test "queued lines are counted in front of the prompt" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.draw("x", 1, 2, false);

    try expectContains(out.written(), "(2 queued) > x");
}

test "long text scrolls so the cursor stays visible" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 12);
    out.clearRetainingCapacity();

    try bar.draw("abcdefghijklmnopqrstuvwxyz", 26, 0, false);

    try expectContains(out.written(), "> stuvwxyz\x1b[7m ");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "abc") == null);
}

test "the first Esc hint shows on an empty bar" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.draw("", 0, 0, true);

    try expectContains(out.written(), "Press Esc again to cancel");
}

test "drawing the same state twice writes nothing the second time" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    try bar.draw("same", 4, 0, false);
    out.clearRetainingCapacity();

    try bar.draw("same", 4, 0, false);

    try std.testing.expectEqualStrings("", out.written());
}

test "repaint draws the last state again after the screen was erased" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    try bar.draw("kept", 4, 1, false);
    out.clearRetainingCapacity();

    try bar.repaint();

    try expectContains(out.written(), "(1 queued) > kept");
}

test "leaving resets the scroll region and clears the reserved rows" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.leave();

    try std.testing.expect(!bar.active);
    try std.testing.expectEqualStrings("\x1b7\x1b[r\x1b[23;1H\x1b[J\x1b8", out.written());
}

test "resizing moves the region and the bar" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    try bar.draw("typed", 5, 0, false);
    out.clearRetainingCapacity();

    try bar.resize(40, 100);

    try expectContains(out.written(), "\x1b[1;38r\x1b[39;1H\x1b[2K");
    try expectContains(out.written(), "\x1b[40;1H\x1b[2K> typed");
}

test "resizing brings a cursor below the new region back inside it" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.resize(12, 80);

    // Scrolling only moves a cursor below the region if the region is gone,
    // so it is released before making room and set again afterwards.
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\x1b7\x1b[r\x1b8\x1bD\x1bD\x1bM\x1bM\x1b7\x1b[1;10r"));
}

test "shrinking below the minimum drops the bar" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.resize(3, 80);

    try std.testing.expect(!bar.active);
    try expectContains(out.written(), "\x1b[r");
}

test "a bar dropped by a small window comes back when it grows" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    try bar.draw("kept", 4, 0, false);
    try bar.resize(3, 80);
    out.clearRetainingCapacity();

    try bar.resize(24, 80);

    try std.testing.expect(bar.active);
    try expectContains(out.written(), "\x1b[1;22r");
    try expectContains(out.written(), "> kept");
}

test "a bar that started in a small window appears when it grows" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(3, 80);

    try bar.resize(24, 80);

    try std.testing.expect(bar.active);
}

test "a bar that was left stays away when the window changes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    try bar.leave();
    out.clearRetainingCapacity();

    try bar.resize(40, 80);

    try std.testing.expect(!bar.active);
    try std.testing.expectEqualStrings("", out.written());
}

test "inactive bars write nothing" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };

    try bar.draw("x", 1, 0, false);
    try bar.repaint();
    try bar.leave();

    try std.testing.expectEqualStrings("", out.written());
}

const FakeWrite = struct {
    var last: []const u8 = "";
    fn write(bytes: []const u8) void {
        last = bytes;
    }
};

test "emergencyReset releases the scroll region only when the bar is up" {
    FakeWrite.last = "";
    var bar: InputBar = .{};
    emergencyReset(&bar, FakeWrite.write);
    try std.testing.expectEqualStrings("", FakeWrite.last);

    bar.active = true;
    emergencyReset(&bar, FakeWrite.write);
    try std.testing.expectEqualStrings("\x1b[r", FakeWrite.last);
}

test "safeLength stops before an unfinished escape sequence" {
    try std.testing.expectEqual(@as(usize, 3), safeLength("abc"));
    try std.testing.expectEqual(@as(usize, 2), safeLength("ab\x1b[3"));
    try std.testing.expectEqual(@as(usize, 6), safeLength("ab\x1b[3m"));
    try std.testing.expectEqual(@as(usize, 1), safeLength("x\x1b"));
    try std.testing.expectEqual(@as(usize, 2), safeLength("\x1b7"));
}

test "safeLength stops before an unfinished code point" {
    try std.testing.expectEqual(@as(usize, 2), safeLength("ab\xe2\x82"));
    try std.testing.expectEqual(@as(usize, 5), safeLength("ab\xe2\x82\xac"));
    try std.testing.expectEqual(@as(usize, 0), safeLength("\xf0\x9f"));
}

test "ScreenWriter passes everything through, including writes bigger than its buffer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    var lock: SpinLock = .{};
    var buffer: [8]u8 = undefined;
    var screen = ScreenWriter.init(&out.writer, &bar, &lock, &buffer);

    const text = "a long line \x1b[1mwith style\x1b[0m and caf\xc3\xa9 at the end";
    try screen.interface.writeAll(text);
    try screen.interface.flush();

    try std.testing.expectEqualStrings(text, out.written());
}

const WholeChunks = struct {
    interface: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    split: bool = false,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *WholeChunks = @fieldParentPtr("interface", w);
        for (data) |chunk| {
            if (chunk.len == 0) continue;
            if (safeLength(chunk) != chunk.len or !startsClean(chunk)) self.split = true;
            return chunk.len;
        }
        return 0;
    }

    /// True unless `chunk` opens with the rest of a sequence cut in two.
    fn startsClean(chunk: []const u8) bool {
        return chunk[0] != '[' and chunk[0] & 0xC0 != 0x80;
    }
};

test "ScreenWriter keeps sequences whole across a write bigger than its buffer" {
    var inner: WholeChunks = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    var lock: SpinLock = .{};
    var buffer: [8]u8 = undefined;
    var screen = ScreenWriter.init(&inner.interface, &bar, &lock, &buffer);

    try screen.interface.writeAll("abcdefg\x1b[1mhij caf\xc3\xa9 and more");
    try screen.interface.flush();

    try std.testing.expect(!inner.split);
}

test "ScreenWriter repaints the bar after an erase" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    try bar.draw("kept", 4, 0, false);
    out.clearRetainingCapacity();
    var lock: SpinLock = .{};
    var buffer: [64]u8 = undefined;
    var screen = ScreenWriter.init(&out.writer, &bar, &lock, &buffer);

    try screen.interface.writeAll("x\x1b[Jy");
    try screen.interface.flush();

    try std.testing.expect(std.mem.startsWith(u8, out.written(), "x\x1b[Jy\x1b7\x1b[24;1H"));
    try expectContains(out.written(), "> kept");
}

test "ScreenWriter leaves the bar alone for ordinary output" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();
    var lock: SpinLock = .{};
    var buffer: [64]u8 = undefined;
    var screen = ScreenWriter.init(&out.writer, &bar, &lock, &buffer);

    try screen.interface.writeAll("plain");
    try screen.interface.flush();

    try std.testing.expectEqualStrings("plain", out.written());
}
