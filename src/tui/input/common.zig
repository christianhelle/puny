const std = @import("std");
const markdown = @import("../markdown.zig");
const prompt_history = @import("../../prompts/history.zig");
const terminal = @import("../terminal.zig");
const prompts = @import("../../prompts/prompts.zig");

pub const ReadLineResult = union(enum) {
    submitted: []const u8,
    cancelled,
    interrupted,
    eof,
};

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
    /// Rows the input currently occupies on screen, counting an extra row
    /// when the text ends exactly at the right edge (pending wrap).
    cursor_rows: usize,

    pub fn init(
        line_alloc: *std.Io.Writer.Allocating,
        stdout_writer: *std.Io.Writer,
        history: ?*prompt_history.History,
        width: ?usize,
    ) LineEditor {
        return .{
            .line_alloc = line_alloc,
            .stdout_writer = stdout_writer,
            .history = history,
            .width = width,
            .cursor_rows = 1,
        };
    }

    pub fn append(self: *LineEditor, byte: u8) !void {
        try self.line_alloc.writer.writeByte(byte);
        if (self.width == null) {
            try self.stdout_writer.writeByte(byte);
            try self.stdout_writer.flush();
            return;
        }
        try self.redraw();
    }

    pub fn backspace(self: *LineEditor) !void {
        const written = self.line_alloc.written();
        if (written.len == 0) return;
        self.line_alloc.shrinkRetainingCapacity(written.len - 1);
        if (self.width == null) {
            try self.stdout_writer.writeAll(terminal.backspace_echo);
            try self.stdout_writer.flush();
            return;
        }
        try self.redraw();
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

    fn replace(self: *LineEditor, text: []const u8) !void {
        self.line_alloc.clearRetainingCapacity();
        try self.line_alloc.writer.writeAll(text);
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
    /// and buffer, letting the terminal place the cursor after the text.
    fn redraw(self: *LineEditor) !void {
        const width = self.width orelse return;
        // Carriage return first: if the cursor is in pending-wrap state the
        // terminal materializes the wrap, keeping the row arithmetic exact.
        try self.stdout_writer.writeByte('\r');
        if (self.cursor_rows > 1) {
            try self.stdout_writer.print(terminal.cursor_up, .{self.cursor_rows - 1});
        }
        try self.stdout_writer.writeAll(terminal.erase_display);
        try self.stdout_writer.print("{s} {s}", .{ prompts.prompt_text, self.line_alloc.written() });
        try self.stdout_writer.flush();

        const start_col = markdown.displayWidth(prompts.prompt_text) + 1;
        const info = rowsNeeded(start_col, width, self.line_alloc.written());
        self.cursor_rows = info.rows + @intFromBool(info.ends_at_edge);
    }
};

pub const RowsInfo = struct {
    /// Physical terminal rows the input area occupies.
    rows: usize,
    /// True when the text ends exactly at the right edge of the terminal,
    /// leaving the cursor in the pending-wrap state.
    ends_at_edge: bool,
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
    return .{ .rows = rows, .ends_at_edge = col == width };
}

pub fn readLineCanonical(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !ReadLineResult {
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    const bytes_read = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {
            try stdout_writer.print("\nInput too long (max {d} bytes).\n", .{stdin_buffer.len});
            return .eof;
        },
        else => return err,
    };
    if (bytes_read == 0) return .eof;

    const raw_message = line_alloc.written();
    const result = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r')
        raw_message[0 .. raw_message.len - 1]
    else
        raw_message;
    return .{ .submitted = result };
}

pub fn appendAndEcho(byte: u8, line_alloc: *std.Io.Writer.Allocating, stdout_writer: *std.Io.Writer) !void {
    try line_alloc.writer.writeByte(byte);
    try stdout_writer.writeByte(byte);
    try stdout_writer.flush();
}

pub fn backspace(line_alloc: *std.Io.Writer.Allocating, stdout_writer: *std.Io.Writer) !void {
    const written = line_alloc.written();
    if (written.len == 0) return;
    line_alloc.shrinkRetainingCapacity(written.len - 1);
    try stdout_writer.writeAll(terminal.backspace_echo);
    try stdout_writer.flush();
}

pub fn historyPrevious(
    line_alloc: *std.Io.Writer.Allocating,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
) !void {
    const h = history orelse return;
    const current = line_alloc.written();
    const replacement = h.previous(current) orelse h.currentDraft() orelse return;
    try replaceLine(replacement, line_alloc, stdout_writer);
}

pub fn historyNext(
    line_alloc: *std.Io.Writer.Allocating,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
) !void {
    const h = history orelse return;
    const replacement = h.next() orelse h.currentDraft() orelse return;
    try replaceLine(replacement, line_alloc, stdout_writer);
}

pub fn replaceLine(
    text: []const u8,
    line_alloc: *std.Io.Writer.Allocating,
    stdout_writer: *std.Io.Writer,
) !void {
    line_alloc.clearRetainingCapacity();
    try line_alloc.writer.writeAll(text);

    try stdout_writer.writeAll(terminal.move_to_line_start);
    try stdout_writer.writeAll(terminal.clear_to_end_of_line);
    try stdout_writer.print("{s} {s}", .{ prompts.prompt_text, text });
    try stdout_writer.flush();
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
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdefgh", out.written());
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
    try std.testing.expectEqualStrings("\r\x1b[J> abcdefgh", out.written());
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

test "replaceLine updates line_alloc and redraws prompt" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try line_alloc.writer.writeAll("old");
    try replaceLine("new", &line_alloc, &out.writer);

    try std.testing.expectEqualStrings("new", line_alloc.written());
    try std.testing.expectEqualStrings(
        terminal.move_to_line_start ++ terminal.clear_to_end_of_line ++ "> new",
        out.written(),
    );
}

test "historyPrevious and historyNext navigate entries" {
    const allocator = std.testing.allocator;
    var history = prompt_history.History.init(allocator, "");
    defer history.deinit();
    try history.add("first");
    try history.add("second");

    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try historyPrevious(&line_alloc, &out.writer, &history);
    try std.testing.expectEqualStrings("second", line_alloc.written());

    try historyPrevious(&line_alloc, &out.writer, &history);
    try std.testing.expectEqualStrings("first", line_alloc.written());

    try historyNext(&line_alloc, &out.writer, &history);
    try std.testing.expectEqualStrings("second", line_alloc.written());
}

test "appendAndEcho appends to the buffer and echoes the byte" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try appendAndEcho('a', &line_alloc, &output.writer);
    try appendAndEcho('b', &line_alloc, &output.writer);

    try std.testing.expectEqualStrings("ab", line_alloc.written());
    try std.testing.expectEqualStrings("ab", output.written());
}

test "backspace removes the last byte and erases it on screen" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try appendAndEcho('x', &line_alloc, &output.writer);
    output.clearRetainingCapacity();

    try backspace(&line_alloc, &output.writer);
    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("\x08 \x08", output.written());
}

test "backspace is a no-op on an empty buffer" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try backspace(&line_alloc, &output.writer);
    try std.testing.expectEqualStrings("", line_alloc.written());
    try std.testing.expectEqualStrings("", output.written());
}
