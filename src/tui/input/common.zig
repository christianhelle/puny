const std = @import("std");
const prompt_history = @import("../../prompts/history.zig");
const terminal = @import("../terminal.zig");

pub const ReadLineResult = union(enum) {
    submitted: []const u8,
    cancelled,
    interrupted,
    eof,
};

pub fn readLineCanonical(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_buffer: *std.ArrayList(u8),
    stdin_buffer: []u8,
    allocator: std.mem.Allocator,
) !ReadLineResult {
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var temp = std.Io.Writer.Allocating.init(allocator);
    defer temp.deinit();

    const bytes_read = stdin_reader.streamDelimiterLimit(&temp.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {
            try stdout_writer.print("\nInput too long (max {d} bytes).\n", .{stdin_buffer.len});
            return .eof;
        },
        else => return err,
    };
    if (bytes_read == 0) return .eof;

    const raw_message = temp.written();
    const result = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r')
        raw_message[0 .. raw_message.len - 1]
    else
        raw_message;
    try line_buffer.appendSlice(allocator, result);
    return .{ .submitted = line_buffer.items };
}

fn promptPrefixLen() usize {
    return "Prompt: ".len;
}

fn visualLineCount(text: []const u8, term_width: usize) usize {
    if (term_width == 0) return 1;
    const prefix = promptPrefixLen();
    if (text.len == 0) return 1;

    var visual_lines: usize = 1;
    var col: usize = prefix;

    var i: usize = 0;
    while (i < text.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + byte_len > text.len) break;

        const cp = std.unicode.utf8Decode(text[i..][0..byte_len]) catch {
            col += 1;
            i += 1;
            continue;
        };
        const cw: usize = if (cp == '\n') 0 else 1;

        if (cp == '\n') {
            visual_lines += 1;
            col = 0;
        } else if (col + cw > term_width) {
            visual_lines += 1;
            col = cw;
        } else {
            col += cw;
        }

        i += byte_len;
    }

    return visual_lines;
}

fn cursorVisualPosition(text: []const u8, byte_offset: usize, term_width: usize) struct { row: usize, col: usize } {
    const prefix = promptPrefixLen();
    if (byte_offset == 0 or text.len == 0) return .{ .row = 0, .col = prefix };

    var visual_row: usize = 0;
    var visual_col: usize = prefix;

    var i: usize = 0;
    while (i < byte_offset and i < text.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + byte_len > text.len) break;

        const cp = std.unicode.utf8Decode(text[i..][0..byte_len]) catch {
            if (visual_col + 1 > term_width) {
                visual_row += 1;
                visual_col = 1;
            } else {
                visual_col += 1;
            }
            i += 1;
            continue;
        };
        const cw: usize = if (cp == '\n') 0 else 1;

        if (cp == '\n') {
            visual_row += 1;
            visual_col = 0;
        } else if (visual_col + cw > term_width) {
            visual_row += 1;
            visual_col = cw;
        } else {
            visual_col += cw;
        }

        i += byte_len;
    }

    return .{ .row = visual_row, .col = visual_col };
}

pub fn redrawPrompt(line_buffer: *const std.ArrayList(u8), cursor: usize, stdout_writer: *std.Io.Writer) !void {
    const term_width = terminal.terminalWidth();
    const text = line_buffer.items;

    try stdout_writer.writeAll(terminal.restore_cursor);
    try stdout_writer.writeAll("\r");
    try stdout_writer.writeAll(terminal.clear_to_end_of_screen);
    try stdout_writer.print("Prompt: {s}", .{text});

    const total_lines = visualLineCount(text, term_width);
    const pos = cursorVisualPosition(text, cursor, term_width);
    const lines_from_bottom = total_lines - 1 - pos.row;
    if (lines_from_bottom > 0) {
        try stdout_writer.print("\x1b[{d}A", .{lines_from_bottom});
    }
    try stdout_writer.print("\x1b[{d}G", .{pos.col + 1});
    try stdout_writer.flush();
}

pub fn appendChar(char: u8, line_buffer: *std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    try line_buffer.append(allocator, char);
    cursor.* += 1;
    try stdout_writer.writeByte(char);
    try stdout_writer.flush();
}

pub fn insertAndRedraw(char: u8, line_buffer: *std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    try line_buffer.insert(allocator, cursor.*, char);
    cursor.* += 1;
    try redrawPrompt(line_buffer, cursor.*, stdout_writer);
}

pub fn backspaceAndRedraw(line_buffer: *std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer) !void {
    if (cursor.* == 0 or cursor.* > line_buffer.items.len) return;
    cursor.* -= 1;
    _ = line_buffer.orderedRemove(cursor.*);
    try redrawPrompt(line_buffer, cursor.*, stdout_writer);
}

pub fn deleteForwardAndRedraw(line_buffer: *std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer) !void {
    if (cursor.* >= line_buffer.items.len) return;
    _ = line_buffer.orderedRemove(cursor.*);
    try redrawPrompt(line_buffer, cursor.*, stdout_writer);
}

fn wordDeleteBackwardCount(text: []const u8, pos: usize) usize {
    if (pos == 0 or pos > text.len) return 0;
    var i = pos;
    while (i > 0 and text[i - 1] == ' ') : (i -= 1) {}
    while (i > 0 and text[i - 1] != ' ') : (i -= 1) {}
    return pos - i;
}

pub fn deleteWordBackwardAndRedraw(line_buffer: *std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer) !void {
    const count = wordDeleteBackwardCount(line_buffer.items, cursor.*);
    if (count == 0) return;
    const start = cursor.* - count;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = line_buffer.orderedRemove(start);
    }
    cursor.* = start;
    try redrawPrompt(line_buffer, cursor.*, stdout_writer);
}

pub fn moveCursorLeft(line_buffer: *const std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer) !void {
    if (cursor.* == 0) return;
    const term_width = terminal.terminalWidth();
    const old_pos = cursorVisualPosition(line_buffer.items, cursor.*, term_width);
    cursor.* -= 1;
    const new_pos = cursorVisualPosition(line_buffer.items, cursor.*, term_width);
    if (new_pos.row < old_pos.row) {
        try stdout_writer.writeAll("\x1b[A");
    }
    try stdout_writer.print("\x1b[{d}G", .{new_pos.col + 1});
    try stdout_writer.flush();
}

pub fn moveCursorRight(line_buffer: *const std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer) !void {
    if (cursor.* >= line_buffer.items.len) return;
    const term_width = terminal.terminalWidth();
    const old_pos = cursorVisualPosition(line_buffer.items, cursor.*, term_width);
    cursor.* += 1;
    const new_pos = cursorVisualPosition(line_buffer.items, cursor.*, term_width);
    if (new_pos.row > old_pos.row) {
        try stdout_writer.writeAll("\x1b[B");
    }
    try stdout_writer.print("\x1b[{d}G", .{new_pos.col + 1});
    try stdout_writer.flush();
}

pub fn moveCursorToStart(line_buffer: *const std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer) !void {
    if (cursor.* == 0) return;
    const term_width = terminal.terminalWidth();
    const old_pos = cursorVisualPosition(line_buffer.items, cursor.*, term_width);
    cursor.* = 0;
    const new_pos = cursorVisualPosition(line_buffer.items, 0, term_width);
    const rows_up = old_pos.row -| new_pos.row;
    if (rows_up > 0) {
        try stdout_writer.print("\x1b[{d}A", .{rows_up});
    }
    try stdout_writer.print("\x1b[{d}G", .{new_pos.col + 1});
    try stdout_writer.flush();
}

pub fn moveCursorToEnd(line_buffer: *const std.ArrayList(u8), cursor: *usize, stdout_writer: *std.Io.Writer) !void {
    const end = line_buffer.items.len;
    if (cursor.* == end) return;
    const term_width = terminal.terminalWidth();
    const old_pos = cursorVisualPosition(line_buffer.items, cursor.*, term_width);
    cursor.* = end;
    const new_pos = cursorVisualPosition(line_buffer.items, end, term_width);
    const rows_down = new_pos.row -| old_pos.row;
    if (rows_down > 0) {
        try stdout_writer.print("\x1b[{d}B", .{rows_down});
    }
    try stdout_writer.print("\x1b[{d}G", .{new_pos.col + 1});
    try stdout_writer.flush();
}

pub fn historyPreviousAndRedraw(
    line_buffer: *std.ArrayList(u8),
    cursor: *usize,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
    allocator: std.mem.Allocator,
) !void {
    const h = history orelse return;
    const current = line_buffer.items;
    const replacement = h.previous(current) orelse h.currentDraft() orelse return;
    try replaceLineAndRedraw(replacement, line_buffer, cursor, stdout_writer, allocator);
}

pub fn historyNextAndRedraw(
    line_buffer: *std.ArrayList(u8),
    cursor: *usize,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
    allocator: std.mem.Allocator,
) !void {
    const h = history orelse return;
    const replacement = h.next() orelse h.currentDraft() orelse return;
    try replaceLineAndRedraw(replacement, line_buffer, cursor, stdout_writer, allocator);
}

pub fn replaceLineAndRedraw(
    text: []const u8,
    line_buffer: *std.ArrayList(u8),
    cursor: *usize,
    stdout_writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) !void {
    line_buffer.clearRetainingCapacity();
    try line_buffer.appendSlice(allocator, text);
    cursor.* = line_buffer.items.len;
    try redrawPrompt(line_buffer, cursor.*, stdout_writer);
}

test "cursorVisualPosition basic positioning" {
    const text = "hello";
    const term_width = 20;
    const prefix = promptPrefixLen();

    var pos = cursorVisualPosition(text, 0, term_width);
    try std.testing.expectEqual(@as(usize, 0), pos.row);
    try std.testing.expectEqual(prefix, pos.col);

    pos = cursorVisualPosition(text, 5, term_width);
    try std.testing.expectEqual(@as(usize, 0), pos.row);
    try std.testing.expectEqual(prefix + 5, pos.col);
}

test "cursorVisualPosition wraps at terminal width" {
    const term_width = 12;
    const prefix = promptPrefixLen();
    var buf: [100]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        buf[i] = 'a';
    }
    const text = buf[0..20];

    var pos = cursorVisualPosition(text, 0, term_width);
    try std.testing.expectEqual(@as(usize, 0), pos.row);
    try std.testing.expectEqual(prefix, pos.col);

    pos = cursorVisualPosition(text, 4, term_width);
    try std.testing.expectEqual(@as(usize, 0), pos.row);
    try std.testing.expectEqual(prefix + 4, pos.col);

    const chars_after_prefix = term_width - prefix;
    pos = cursorVisualPosition(text, chars_after_prefix, term_width);
    try std.testing.expectEqual(@as(usize, 1), pos.row);
    try std.testing.expectEqual(@as(usize, 0), pos.col);
}

test "wordDeleteBackwardCount" {
    try std.testing.expectEqual(@as(usize, 0), wordDeleteBackwardCount("", 0));
    try std.testing.expectEqual(@as(usize, 5), wordDeleteBackwardCount("hello world", 5));
    try std.testing.expectEqual(@as(usize, 6), wordDeleteBackwardCount("hello world", 11));
    try std.testing.expectEqual(@as(usize, 1), wordDeleteBackwardCount("hello ", 6));
}

test "insertAndRedraw appends char" {
    const allocator = std.testing.allocator;
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(allocator);
    var cursor: usize = 0;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try insertAndRedraw('a', &line_buffer, &cursor, &out.writer, allocator);
    try std.testing.expectEqual(@as(usize, 1), cursor);
    try std.testing.expectEqualStrings("a", line_buffer.items);
}

test "backspaceAndRedraw removes before cursor" {
    const allocator = std.testing.allocator;
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(allocator);
    try line_buffer.appendSlice(allocator, "hello");
    var cursor: usize = 5;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try backspaceAndRedraw(&line_buffer, &cursor, &out.writer);
    try std.testing.expectEqual(@as(usize, 4), cursor);
    try std.testing.expectEqualStrings("hell", line_buffer.items);
}

test "deleteWordBackwardAndRedraw deletes word" {
    const allocator = std.testing.allocator;
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(allocator);
    try line_buffer.appendSlice(allocator, "hello world");
    var cursor: usize = 11;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try deleteWordBackwardAndRedraw(&line_buffer, &cursor, &out.writer);
    try std.testing.expectEqual(@as(usize, 6), cursor);
    try std.testing.expectEqualStrings("hello ", line_buffer.items);
}

test "historyPreviousAndRedraw and historyNextAndRedraw navigate entries" {
    const allocator = std.testing.allocator;
    var history = prompt_history.History.init(allocator, "");
    defer history.deinit();

    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(allocator);
    var cursor: usize = 0;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try history.add("first");
    try history.add("second");

    try historyPreviousAndRedraw(&line_buffer, &cursor, &out.writer, &history, allocator);
    try std.testing.expectEqualStrings("second", line_buffer.items);
    try std.testing.expectEqual(line_buffer.items.len, cursor);

    try historyPreviousAndRedraw(&line_buffer, &cursor, &out.writer, &history, allocator);
    try std.testing.expectEqualStrings("first", line_buffer.items);
    try std.testing.expectEqual(line_buffer.items.len, cursor);

    try historyNextAndRedraw(&line_buffer, &cursor, &out.writer, &history, allocator);
    try std.testing.expectEqualStrings("second", line_buffer.items);
    try std.testing.expectEqual(line_buffer.items.len, cursor);
}
