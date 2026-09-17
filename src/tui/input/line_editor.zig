const std = @import("std");
const markdown = @import("../markdown/markdown.zig");
const prompt_history = @import("../../prompts/history.zig");
const terminal = @import("../terminal.zig");
const prompts = @import("../../prompts/prompts.zig");
const ansi = @import("../ansi.zig");

/// Line editor state for the raw-mode prompt. Mutations to the buffer redraw
/// the entire input area (all wrapped rows) instead of echoing bytes, so
/// editing works when the prompt spans multiple terminal rows.
pub const LineEditor = struct {
    line_alloc: *std.Io.Writer.Allocating,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
    /// Terminal width in columns. When unknown (e.g. piped stdout), the
    /// editor falls back to legacy single-row echo behavior.
    width: ?usize,
    /// Rows from the prompt row down to the row the cursor rests on. With
    /// the cursor at the end this counts an extra row when the text ends
    /// exactly at the right edge, where a forced wrap leaves the cursor on a
    /// fresh continuation row.
    cursor_rows: usize,
    /// Byte offset of the cursor in the buffer, always on a code point
    /// boundary.
    cursor: usize = 0,
    /// When false, `@` is inserted literally instead of opening the file
    /// picker, for plain prompts such as a URL or an API key.
    mentions_enabled: bool = true,

    pub fn init(
        line_alloc: *std.Io.Writer.Allocating,
        stdout_writer: *std.Io.Writer,
        history: ?*prompt_history.History,
        width: ?usize,
    ) LineEditor {
        // Terminals narrower than the prompt column cannot host a redraw
        // cursor model; fall back to legacy echo like an unknown width.
        const start_col = markdown.displayWidth(prompts.prompt_text) + 1;
        const usable_width = if (width) |w| if (w < start_col) null else w else null;
        return .{
            .line_alloc = line_alloc,
            .stdout_writer = stdout_writer,
            .history = history,
            .width = usable_width,
            .cursor_rows = 1,
        };
    }

    pub fn append(self: *LineEditor, byte: u8) !void {
        var single = [1]u8{byte};
        try self.appendSlice(&single);
    }

    /// Inserts a run of bytes (typically one complete UTF-8 code point) at
    /// the cursor and redraws once, so multi-byte input never flashes a
    /// redraw containing an incomplete sequence.
    pub fn appendSlice(self: *LineEditor, bytes: []const u8) !void {
        const old_len = self.line_alloc.written().len;
        try self.line_alloc.writer.writeAll(bytes);
        const text = self.line_alloc.written();
        std.mem.copyBackwards(u8, text[self.cursor + bytes.len ..], text[self.cursor..old_len]);
        @memcpy(text[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
        if (self.width == null) {
            try self.stdout_writer.writeAll(bytes);
            try self.stdout_writer.flush();
            return;
        }
        try self.redraw();
    }

    pub fn backspace(self: *LineEditor) !void {
        const written = self.line_alloc.written();
        if (written.len == 0) return;
        const n = backspaceLen(written);
        const deleted = written[written.len - n ..];
        self.line_alloc.shrinkRetainingCapacity(written.len - n);
        self.cursor = self.line_alloc.written().len;
        if (self.width == null) {
            // Erase every column the deleted code point occupied.
            const echo_width = deletedCodePointWidth(deleted);
            for (0..echo_width) |_| try self.stdout_writer.writeAll(terminal.backspace_echo);
            try self.stdout_writer.flush();
            return;
        }
        try self.redraw();
    }

    /// Bytes to remove from the end of `text` so that a complete UTF-8 code
    /// point is deleted: walks back over continuation bytes and removes them
    /// together with the preceding lead byte. Falls back to a single byte
    /// when the trailing byte is not a valid lead byte.
    fn backspaceLen(text: []const u8) usize {
        var n: usize = 1;
        while (n < text.len and text[text.len - n] & 0xC0 == 0x80) n += 1;
        return n;
    }

    /// Offset just past the code point starting at `pos`, skipping any
    /// continuation bytes so the cursor never splits a UTF-8 sequence.
    fn nextCodePointEnd(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var end = pos + 1;
        while (end < text.len and text[end] & 0xC0 == 0x80) end += 1;
        return end;
    }

    /// Display width of the code point removed by backspace, used by the
    /// legacy echo path. Invalid UTF-8 renders as a single replacement column.
    fn deletedCodePointWidth(deleted: []const u8) usize {
        const seq_len = std.unicode.utf8ByteSequenceLength(deleted[0]) catch return 1;
        if (seq_len > deleted.len) return 1;
        const cp = std.unicode.utf8Decode(deleted[0..seq_len]) catch return 1;
        return markdown.codePointWidth(cp);
    }

    pub fn historyPrevious(self: *LineEditor) !void {
        const h = self.history orelse return;
        const current = self.line_alloc.written();
        const replacement = h.previous(current) orelse h.currentDraft() orelse return;
        try self.replace(replacement);
    }

    pub fn historyNext(self: *LineEditor) !void {
        const h = self.history orelse return;
        const replacement = h.next() orelse h.currentDraft() orelse return;
        try self.replace(replacement);
    }

    /// Moves the cursor one code point to the left.
    pub fn moveLeft(self: *LineEditor) !void {
        if (self.cursor == 0) return;
        try self.moveTo(self.cursor - backspaceLen(self.line_alloc.written()[0..self.cursor]));
    }

    /// Moves the cursor one code point to the right.
    pub fn moveRight(self: *LineEditor) !void {
        try self.moveTo(nextCodePointEnd(self.line_alloc.written(), self.cursor));
    }

    pub fn moveHome(self: *LineEditor) !void {
        try self.moveTo(0);
    }

    pub fn moveEnd(self: *LineEditor) !void {
        try self.moveTo(self.line_alloc.written().len);
    }

    fn moveTo(self: *LineEditor, pos: usize) !void {
        if (pos == self.cursor) return;
        self.cursor = pos;
        try self.redraw();
    }

    fn replace(self: *LineEditor, text: []const u8) !void {
        self.line_alloc.clearRetainingCapacity();
        try self.line_alloc.writer.writeAll(text);
        self.cursor = text.len;
        if (self.width == null) {
            try self.stdout_writer.writeAll(terminal.move_to_line_start);
            try self.stdout_writer.writeAll(terminal.clear_to_end_of_line);
            try self.stdout_writer.print("{s} {s}", .{ prompts.prompt_text, text });
            try self.stdout_writer.flush();
            return;
        }
        try self.redraw();
    }

    /// Clears every row the input currently occupies and reprints the prompt
    /// and buffer, then moves the terminal cursor back to the edit cursor
    /// when it is not at the end of the text.
    pub fn redraw(self: *LineEditor) !void {
        const width = self.width orelse return;
        try self.stdout_writer.writeByte('\r');
        if (self.cursor_rows > 1) {
            try self.stdout_writer.print(terminal.cursor_up, .{self.cursor_rows - 1});
        }
        try self.stdout_writer.writeAll(terminal.erase_display);
        try self.stdout_writer.print("{s} ", .{prompts.prompt_text});
        try writeMentionHighlighted(self.stdout_writer, self.line_alloc.written());

        const text = self.line_alloc.written();
        const start_col = markdown.displayWidth(prompts.prompt_text) + 1;
        const info = rowsNeeded(start_col, width, text);
        if (info.ends_at_edge) {
            // Force the auto-wrap with a space so the cursor never rests in
            // the terminal's pending-wrap state. Some terminals cancel the
            // pending wrap when they receive a carriage return instead of
            // materializing it, which would make the next cursor-up move one
            // row too far and erase the line above the prompt.
            try self.stdout_writer.writeByte(' ');
        }
        const end_rows = info.rows + @intFromBool(info.ends_at_edge);
        if (self.cursor == text.len) {
            self.cursor_rows = end_rows;
        } else {
            // A prefix ending at the edge puts the cursor at the start of the
            // next row, where the following code point is drawn.
            const prefix = rowsNeeded(start_col, width, text[0..self.cursor]);
            const cursor_rows = prefix.rows + @intFromBool(prefix.ends_at_edge);
            const col = if (prefix.ends_at_edge) 0 else prefix.col;
            if (end_rows > cursor_rows) {
                try self.stdout_writer.print(terminal.cursor_up, .{end_rows - cursor_rows});
            }
            try self.stdout_writer.print(terminal.cursor_to_column, .{col + 1});
            self.cursor_rows = cursor_rows;
        }
        try self.stdout_writer.flush();
    }
};

pub const RowsInfo = struct {
    /// Physical terminal rows the input area occupies.
    rows: usize,
    /// True when the text ends exactly at the right edge of the terminal,
    /// leaving the cursor in the pending-wrap state.
    ends_at_edge: bool,
    /// Zero-based column just past the last code point on the final row.
    col: usize,
};

/// Computes how many terminal rows `text` occupies when it starts at
/// `start_col` (the column after the prompt) on a terminal `width` columns
/// wide. Wide code points that do not fit on the current row wrap to the
/// next one, mirroring terminal auto-wrap.
pub fn rowsNeeded(start_col: usize, width: usize, text: []const u8) RowsInfo {
    var col = start_col;
    var rows: usize = 1;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp_width = if (seq_len > 1 and i + seq_len <= text.len)
            markdown.codePointWidth(std.unicode.utf8Decode(text[i..][0..seq_len]) catch 1)
        else
            1;
        if (col + cp_width > width) {
            rows += 1;
            col = cp_width;
        } else {
            col += cp_width;
        }
        i += seq_len;
    }
    return .{ .rows = rows, .ends_at_edge = col == width, .col = col };
}

/// Writes `text` to `writer`, wrapping attached-file mentions in the
/// mention color so they stand out in the prompt. A mention is an `@` at the
/// start of the line or after whitespace, running through the following
/// non-whitespace bytes.
fn writeMentionHighlighted(writer: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const at_mention = text[i] == '@' and (i == 0 or std.ascii.isWhitespace(text[i - 1]));
        if (at_mention) {
            try writer.writeAll(ansi.green);
            try writer.writeByte('@');
            i += 1;
            while (i < text.len and !std.ascii.isWhitespace(text[i])) : (i += 1) {
                try writer.writeByte(text[i]);
            }
            try writer.writeAll(ansi.reset);
        } else {
            try writer.writeByte(text[i]);
            i += 1;
        }
    }
}

test "editor append without width echoes the byte" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var editor = LineEditor.init(&line_alloc, &output.writer, null, null);
    try editor.append('a');
    try editor.append('b');

    try std.testing.expectEqualStrings("ab", line_alloc.written());
    try std.testing.expectEqualStrings("ab", output.written());
}

test "editor backspace without width erases with backspace echo" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var editor = LineEditor.init(&line_alloc, &output.writer, null, null);
    try editor.append('x');
    output.clearRetainingCapacity();

    try editor.backspace();
    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("\x08 \x08", output.written());
}

test "rowsNeeded empty text occupies one row" {
    const info = rowsNeeded(2, 10, "");
    try std.testing.expectEqual(@as(usize, 1), info.rows);
    try std.testing.expect(!info.ends_at_edge);
}

test "rowsNeeded short text fits on one row" {
    const info = rowsNeeded(2, 10, "hello");
    try std.testing.expectEqual(@as(usize, 1), info.rows);
    try std.testing.expect(!info.ends_at_edge);
}

test "rowsNeeded text ending exactly at the right edge flags pending wrap" {
    const info = rowsNeeded(2, 10, "abcdefgh");
    try std.testing.expectEqual(@as(usize, 1), info.rows);
    try std.testing.expect(info.ends_at_edge);
}

test "rowsNeeded text wraps to a second row" {
    const info = rowsNeeded(2, 10, "abcdefghi");
    try std.testing.expectEqual(@as(usize, 2), info.rows);
    try std.testing.expect(!info.ends_at_edge);
}

test "rowsNeeded multi-row text ending exactly at the right edge" {
    const info = rowsNeeded(2, 10, "abcdefghijklmnopqr");
    try std.testing.expectEqual(@as(usize, 2), info.rows);
    try std.testing.expect(info.ends_at_edge);
}

test "rowsNeeded wide code point straddling the boundary wraps" {
    const info = rowsNeeded(2, 10, "abcdefg😀");
    try std.testing.expectEqual(@as(usize, 2), info.rows);
    try std.testing.expect(!info.ends_at_edge);
}

test "rowsNeeded wide code point filling the row exactly flags pending wrap" {
    const info = rowsNeeded(2, 10, "abcdef😀");
    try std.testing.expectEqual(@as(usize, 1), info.rows);
    try std.testing.expect(info.ends_at_edge);
}

test "editor append redraws the prompt and buffer on one row" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.append('a');
    out.clearRetainingCapacity();
    try editor.append('b');

    try std.testing.expectEqualStrings("ab", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[J> ab", out.written());
}

test "editor append past the right edge redraws both rows" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    for ("abcdefgh") |ch| try editor.append(ch);
    out.clearRetainingCapacity();
    try editor.append('i');

    try std.testing.expectEqualStrings("abcdefghi", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefghi", out.written());
}

test "editor backspace erases the last char and redraws one row" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    for ("abc") |ch| try editor.append(ch);
    out.clearRetainingCapacity();
    try editor.backspace();

    try std.testing.expectEqualStrings("ab", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[J> ab", out.written());
}

test "editor backspace from the second row clears both rows" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    for ("abcdefghi") |ch| try editor.append(ch);
    out.clearRetainingCapacity();
    try editor.backspace();

    try std.testing.expectEqualStrings("abcdefgh", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefgh ", out.written());
}

test "editor backspace keeps deleting across the wrap boundary" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    for ("abcdefgh") |ch| try editor.append(ch);
    out.clearRetainingCapacity();
    try editor.backspace();

    try std.testing.expectEqualStrings("abcdefg", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefg", out.written());
}

test "editor backspace is a no-op on an empty buffer" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.backspace();

    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("", out.written());
}

test "editor backspace deletes a complete two-byte code point" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, null);
    try editor.append(0xC3);
    try editor.append(0xA9);
    out.clearRetainingCapacity();
    try editor.backspace();

    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("\x08 \x08", out.written());
}

test "editor backspace deletes a complete three-byte code point" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, null);
    for ([_]u8{ 0xE4, 0xB8, 0xAD }) |byte| try editor.append(byte);
    out.clearRetainingCapacity();
    try editor.backspace();

    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("\x08 \x08\x08 \x08", out.written());
}

test "editor backspace removes only the incomplete lead byte" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, null);
    try editor.append(0xC3);
    out.clearRetainingCapacity();
    try editor.backspace();

    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("\x08 \x08", out.written());
}

test "editor backspace redraws after deleting a wide code point" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("ab中");
    out.clearRetainingCapacity();
    try editor.backspace();

    try std.testing.expectEqualStrings("ab", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[J> ab", out.written());
}

test "editor appendSlice redraws once for multi-byte input" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("é");
    out.clearRetainingCapacity();
    try editor.appendSlice("中");

    try std.testing.expectEqualStrings("é中", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[J> é中", out.written());
}

test "editor init ignores widths narrower than the prompt column" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 1);
    try editor.append('a');

    try std.testing.expectEqualStrings("a", line_alloc.written());
    try std.testing.expectEqualStrings("a", out.written());
}

test "editor historyPrevious replaces the buffer and clears wrapped rows" {
    const allocator = std.testing.allocator;
    var history = prompt_history.History.init(allocator, "");
    defer history.deinit();
    try history.add("short");

    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, &history, 10);
    for ("abcdefghi") |ch| try editor.append(ch);
    out.clearRetainingCapacity();
    try editor.historyPrevious();

    try std.testing.expectEqualStrings("short", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> short", out.written());
}

test "editor historyNext restores the draft and clears wrapped rows" {
    const allocator = std.testing.allocator;
    var history = prompt_history.History.init(allocator, "");
    defer history.deinit();
    try history.add("first");

    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, &history, 10);
    for ("abcdefgh") |ch| try editor.append(ch);
    try editor.historyPrevious();
    out.clearRetainingCapacity();
    try editor.historyNext();

    try std.testing.expectEqualStrings("abcdefgh", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[J> abcdefgh ", out.written());
}

test "editor forces the wrap when text ends exactly at the right edge" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    for ("abcdefg") |ch| try editor.append(ch);
    out.clearRetainingCapacity();
    try editor.append('h');

    try std.testing.expectEqualStrings("abcdefgh", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[J> abcdefgh ", out.written());
}

test "editor growth never moves the cursor above the prompt" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    const text = "abcdefghijklmnopqrstuvwxyz";
    // Expected cursor-up rows per append and which appends end at the edge.
    // Derived by hand: width 10, prompt "> " (start col 2) fills row 1 after
    // 8 chars and row 2 after 18 chars.
    const up_rows = [_]usize{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2 };
    for (text, 0..) |ch, i| {
        out.clearRetainingCapacity();
        try editor.append(ch);

        var expected: std.Io.Writer.Allocating = .init(allocator);
        defer expected.deinit();
        try expected.writer.writeByte('\r');
        if (up_rows[i] > 0) {
            try expected.writer.print("\x1b[{d}A", .{up_rows[i]});
        }
        try expected.writer.writeAll("\x1b[J> ");
        try expected.writer.writeAll(text[0 .. i + 1]);
        const char_count = i + 1;
        if (char_count == 8 or char_count == 18) {
            try expected.writer.writeByte(' ');
        }
        try std.testing.expectEqualStrings(expected.written(), out.written());
    }
}

test "editor history navigation without width uses single-row redraw" {
    const allocator = std.testing.allocator;
    var history = prompt_history.History.init(allocator, "");
    defer history.deinit();
    try history.add("first");

    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, &history, null);
    try editor.historyPrevious();

    try std.testing.expectEqualStrings("first", line_alloc.written());
    try std.testing.expectEqualStrings(
        terminal.move_to_line_start ++ terminal.clear_to_end_of_line ++ "> first",
        out.written(),
    );
}

test "writeMentionHighlighted leaves plain text unchanged" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeMentionHighlighted(&out.writer, "hello world");
    try std.testing.expectEqualStrings("hello world", out.written());
}

test "writeMentionHighlighted wraps an @mention in green" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeMentionHighlighted(&out.writer, "@src/main.zig");
    try std.testing.expectEqualStrings("\x1b[32m@src/main.zig\x1b[0m", out.written());
}

test "writeMentionHighlighted highlights mentions after prose" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeMentionHighlighted(&out.writer, "read @src/main.zig now");
    try std.testing.expectEqualStrings("read \x1b[32m@src/main.zig\x1b[0m now", out.written());
}

test "writeMentionHighlighted highlights every mention" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeMentionHighlighted(&out.writer, "@a.zig @b.zig");
    try std.testing.expectEqualStrings("\x1b[32m@a.zig\x1b[0m \x1b[32m@b.zig\x1b[0m", out.written());
}

test "writeMentionHighlighted ignores mid-word at signs" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeMentionHighlighted(&out.writer, "user@example.com a@b");
    try std.testing.expectEqualStrings("user@example.com a@b", out.written());
}

test "writeMentionHighlighted stops the mention at whitespace" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeMentionHighlighted(&out.writer, "@path with space");
    try std.testing.expectEqualStrings("\x1b[32m@path\x1b[0m with space", out.written());
}

test "writeMentionHighlighted handles a trailing at sign" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeMentionHighlighted(&out.writer, "@");
    try std.testing.expectEqualStrings("\x1b[32m@\x1b[0m", out.written());
}

test "editor methods work when called out of line" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, null);
    try @call(.never_inline, LineEditor.append, .{ &editor, 'a' });
    try @call(.never_inline, LineEditor.backspace, .{&editor});
    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("a\x08 \x08", out.written());

    try @call(.never_inline, LineEditor.appendSlice, .{ &editor, "xy" });
    try std.testing.expectEqualStrings("xy", line_alloc.written());

    try @call(.never_inline, writeMentionHighlighted, .{ &out.writer, "a @b c" });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[32m@b\x1b[0m") != null);
}

test "editor redraw with multiple cursor rows when called out of line" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    for ("abcdefghi") |ch| try editor.append(ch);
    out.clearRetainingCapacity();
    try @call(.never_inline, LineEditor.redraw, .{&editor});

    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefghi", out.written());
    try std.testing.expectEqual(@as(usize, 2), editor.cursor_rows);
}

test "editor legacy replace path when called out of line" {
    const allocator = std.testing.allocator;
    var history = prompt_history.History.init(allocator, "");
    defer history.deinit();
    try history.add("first");

    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, &history, null);
    try @call(.never_inline, LineEditor.historyPrevious, .{&editor});

    try std.testing.expectEqualStrings("first", line_alloc.written());
    try std.testing.expectEqualStrings(
        terminal.move_to_line_start ++ terminal.clear_to_end_of_line ++ "> first",
        out.written(),
    );
}

test "editor moveLeft redraws and parks the cursor before the last char" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("ac");
    out.clearRetainingCapacity();
    try editor.moveLeft();

    try std.testing.expectEqualStrings("\r\x1b[J> ac\x1b[4G", out.written());
}

test "editor moveLeft is a no-op at the start of the buffer" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.moveLeft();

    try std.testing.expectEqualStrings("", out.written());
}

test "editor moveLeft steps over a whole multi-byte code point" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("a中");
    out.clearRetainingCapacity();
    try editor.moveLeft();

    try std.testing.expectEqualStrings("\r\x1b[J> a中\x1b[4G", out.written());
}

test "editor moveLeft positions the cursor on the second wrapped row" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("abcdefghijk");
    out.clearRetainingCapacity();
    try editor.moveLeft();

    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefghijk\x1b[3G", out.written());
}

test "editor moveLeft from the second row back to the first moves the cursor up" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("abcdefghij");
    for (0..2) |_| try editor.moveLeft();
    out.clearRetainingCapacity();
    // The cursor rests at the start of the second row, so the redraw starts
    // one row up and parks the cursor at the end of the first row.
    try editor.moveLeft();

    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefghij\x1b[1A\x1b[10G", out.written());
}

test "editor moveLeft from text ending at the edge leaves the forced-wrap row" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("abcdefgh");
    out.clearRetainingCapacity();
    try editor.moveLeft();

    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefgh \x1b[1A\x1b[10G", out.written());
}

test "editor append inserts at the cursor and keeps it after the new char" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("ac");
    try editor.moveLeft();
    out.clearRetainingCapacity();
    try editor.append('b');

    try std.testing.expectEqualStrings("abc", line_alloc.written());
    try std.testing.expectEqualStrings("\r\x1b[J> abc\x1b[5G", out.written());
}

test "editor appendSlice inserts a multi-byte code point mid-line" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("ab");
    try editor.moveLeft();
    try editor.appendSlice("中");
    try editor.appendSlice("é");

    try std.testing.expectEqualStrings("a中éb", line_alloc.written());
}

test "editor moveRight steps over a code point and stops at the end" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("a中b");
    try editor.moveLeft();
    try editor.moveLeft();
    out.clearRetainingCapacity();
    try editor.moveRight();
    try std.testing.expectEqualStrings("\r\x1b[J> a中b\x1b[6G", out.written());

    try editor.moveRight();
    out.clearRetainingCapacity();
    try editor.moveRight();
    try std.testing.expectEqualStrings("", out.written());
}

test "editor moveHome and moveEnd jump across wrapped rows" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var editor = LineEditor.init(&line_alloc, &out.writer, null, 10);
    try editor.appendSlice("abcdefghijkl");
    out.clearRetainingCapacity();
    try editor.moveHome();
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefghijkl\x1b[1A\x1b[3G", out.written());

    out.clearRetainingCapacity();
    try editor.moveEnd();
    try std.testing.expectEqualStrings("\r\x1b[J> abcdefghijkl", out.written());
}
