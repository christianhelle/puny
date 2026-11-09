const std = @import("std");
const ansi = @import("ansi.zig");
const width = @import("markdown/width.zig");

/// The `>` input row pinned to the bottom of the terminal while the agent
/// works. A scroll region keeps streamed output above it.
pub const InputBar = struct {
    out: ?*std.Io.Writer = null,
    active: bool = false,
    rows: usize = 0,
    cols: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    cursor: usize = 0,
    queued: usize = 0,
    hint: bool = false,

    pub const text_capacity = 8192;
    const min_rows = 3;
    const min_cols = 10;
    const hint_text = "(Press Esc again to cancel)";

    fn fits(rows: usize, cols: usize) bool {
        return rows >= min_rows and cols >= min_cols;
    }

    /// Enters the bar if the terminal is big enough to spare a row.
    pub fn enter(self: *InputBar, rows: usize, cols: usize) !void {
        const out = self.out orelse return;
        if (self.active or !fits(rows, cols)) return;
        self.active = true;
        self.rows = rows;
        self.cols = cols;
        // Index then reverse index scrolls up a row if the cursor is on the
        // last one, without moving its column. Setting a region homes the
        // cursor, so it is saved around that.
        try out.print("\x1bD\x1bM\x1b7\x1b[1;{d}r\x1b8", .{rows - 1});
        try self.paint();
    }

    pub fn leave(self: *InputBar) !void {
        if (!self.active) return;
        const out = self.out orelse return;
        self.active = false;
        try out.print("\x1b7\x1b[r\x1b[{d};1H\x1b[2K\x1b8", .{self.rows});
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
        if (!self.active) return;
        const out = self.out orelse return;
        if (!fits(rows, cols)) return self.leave();
        self.rows = rows;
        self.cols = cols;
        try out.print("\x1b7\x1b[1;{d}r\x1b8", .{rows - 1});
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

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("missing {s} in {s}\n", .{ needle, haystack });
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "entering reserves the bottom row and keeps the cursor where it was" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };

    try bar.enter(24, 80);

    try std.testing.expect(bar.active);
    // Index then reverse index makes room if the cursor is on the last row.
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\x1bD\x1bM\x1b7\x1b[1;23r\x1b8"));
}

test "a terminal too small to spare a row gets no bar" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };

    try bar.enter(2, 80);

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

test "leaving resets the scroll region and clears the row" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.leave();

    try std.testing.expect(!bar.active);
    try std.testing.expectEqualStrings("\x1b7\x1b[r\x1b[24;1H\x1b[2K\x1b8", out.written());
}

test "resizing moves the region and the bar" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    try bar.draw("typed", 5, 0, false);
    out.clearRetainingCapacity();

    try bar.resize(40, 100);

    try expectContains(out.written(), "\x1b[1;39r");
    try expectContains(out.written(), "\x1b[40;1H\x1b[2K> typed");
}

test "shrinking below the minimum drops the bar" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bar: InputBar = .{ .out = &out.writer };
    try bar.enter(24, 80);
    out.clearRetainingCapacity();

    try bar.resize(2, 80);

    try std.testing.expect(!bar.active);
    try expectContains(out.written(), "\x1b[r");
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
