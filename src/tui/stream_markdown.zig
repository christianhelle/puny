const std = @import("std");
const ansi = @import("ansi.zig");
const markdown = @import("markdown.zig");
const terminal = @import("terminal.zig");

/// Renders markdown to a terminal in real time as content chunks arrive.
///
/// Completed lines are rendered with full markdown formatting and committed to
/// the screen incrementally, carrying fenced-code and table state across
/// chunks. The in-progress final line (the tail) is shown live and repainted
/// as it grows, so the output converges to what a one-shot `markdown.render`
/// of the full text would produce.
pub const StreamRenderer = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    terminal_width: usize,

    content: std.ArrayList(u8),
    consumed: usize,
    in_code_block: bool,
    pending_run: std.ArrayList([]const u8),
    table: ?OpenTable,

    rows_printed: usize,
    pending_rows: usize,
    pending_trailing_newline: bool,
    finished: bool,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, terminal_width: usize) StreamRenderer {
        return .{
            .allocator = allocator,
            .writer = writer,
            .terminal_width = if (terminal_width > 0) terminal_width else 80,
            .content = .empty,
            .consumed = 0,
            .in_code_block = false,
            .pending_run = .empty,
            .table = null,
            .rows_printed = 0,
            .pending_rows = 0,
            .pending_trailing_newline = false,
            .finished = false,
        };
    }

    pub fn deinit(self: *StreamRenderer) void {
        self.content.deinit(self.allocator);
        self.freeRun();
        self.pending_run.deinit(self.allocator);
        self.closeTable();
    }

    /// Feed the next chunk of raw content.
    pub fn push(self: *StreamRenderer, text: []const u8) !void {
        if (self.finished) return;
        try self.content.appendSlice(self.allocator, text);

        const has_lines = std.mem.indexOfScalar(u8, self.content.items[self.consumed..], '\n') != null;
        if (has_lines) {
            try self.erasePending();
            while (try self.takeNextLine()) |line| {
                try self.processLine(line);
            }
            try self.updatePending();
        } else {
            // No new complete line; the in-progress tail simply grew. Append it
            // to the screen instead of erasing and rewriting the whole tail.
            try self.appendTailGrowth(text);
        }
        try self.writer.flush();
    }

    /// Commit the final partial line so the display matches a full render,
    /// leaving only committed content on screen.
    pub fn finish(self: *StreamRenderer) !void {
        if (self.finished) return;
        self.finished = true;

        try self.erasePending();

        const tail = self.content.items[self.consumed..];
        if (tail.len > 0) {
            const line = trimRight(tail, " \t\r");
            try self.processLine(line);
        }

        if (self.pending_run.items.len > 0) {
            try self.commitRunAsParagraphs();
        }

        self.closeTable();
        try self.erasePending();
    }

    /// Total screen rows currently occupied by content.
    pub fn contentRows(self: *const StreamRenderer) usize {
        return self.rows_printed + self.pending_rows;
    }

    fn takeNextLine(self: *StreamRenderer) !?[]const u8 {
        const rest = self.content.items[self.consumed..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        const line = rest[0..nl];
        self.consumed += nl + 1;
        return trimRight(line, " \t\r");
    }

    fn processLine(self: *StreamRenderer, line: []const u8) !void {
        if (self.table != null) {
            if (markdown.isTableLine(line)) {
                const t = &self.table.?;
                try t.lines.append(self.allocator, try self.allocator.dupe(u8, line));
                try self.repaintTable();
                return;
            }
            self.closeTable();
        }

        if (self.pending_run.items.len > 0) {
            if (markdown.isTableLine(line)) {
                if (self.pending_run.items.len == 1 and markdown.isSeparatorRow(line)) {
                    const header = self.pending_run.items[0];
                    if (try self.tryOpenTable(header, line)) {
                        _ = self.pending_run.orderedRemove(0);
                        return;
                    }
                    try self.pending_run.append(self.allocator, try self.allocator.dupe(u8, line));
                    return;
                }
                try self.pending_run.append(self.allocator, try self.allocator.dupe(u8, line));
                return;
            }
            try self.commitRunAsParagraphs();
        }

        const rl = try markdown.renderLine(self.allocator, line, self.in_code_block);
        defer if (rl.output) |o| self.allocator.free(o);
        switch (rl.kind) {
            .code_fence_open => self.in_code_block = true,
            .code_fence_close => self.in_code_block = false,
            .table_candidate => {
                try self.pending_run.append(self.allocator, try self.allocator.dupe(u8, line));
                return;
            },
            .text => {},
        }
        if (rl.output) |out| try self.printCommitted(out);
    }

    fn tryOpenTable(self: *StreamRenderer, header: []const u8, sep: []const u8) !bool {
        const sep_dupe = try self.allocator.dupe(u8, sep);
        var lines = std.ArrayList([]const u8).empty;
        errdefer lines.deinit(self.allocator);
        try lines.append(self.allocator, header);
        try lines.append(self.allocator, sep_dupe);

    const rendered = markdown.renderTable(self.allocator, lines.items, self.terminal_width) catch {
        self.allocator.free(sep_dupe);
        lines.deinit(self.allocator);
        return false;
    };
    defer self.allocator.free(rendered);

    self.table = .{ .lines = lines, .start_row = self.rows_printed };
    try self.applyTableRepaint(rendered);
    return true;
}

    fn commitRunAsParagraphs(self: *StreamRenderer) !void {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        for (self.pending_run.items) |line| {
            const rendered = try markdown.renderInline(self.allocator, line);
            defer self.allocator.free(rendered);
            try out.appendSlice(self.allocator, rendered);
            try out.append(self.allocator, '\n');
        }
        try self.printCommitted(out.items);
        self.freeRun();
    }

    fn freeRun(self: *StreamRenderer) void {
        for (self.pending_run.items) |line| self.allocator.free(line);
        self.pending_run.clearRetainingCapacity();
    }

    fn closeTable(self: *StreamRenderer) void {
        if (self.table) |*t| {
            for (t.lines.items) |line| self.allocator.free(line);
            t.lines.deinit(self.allocator);
        }
        self.table = null;
    }

    fn repaintTable(self: *StreamRenderer) !void {
        const t = &self.table.?;
        const rendered = try markdown.renderTable(self.allocator, t.lines.items, self.terminal_width);
        defer self.allocator.free(rendered);
        try self.applyTableRepaint(rendered);
    }

    fn applyTableRepaint(self: *StreamRenderer, rendered: []const u8) !void {
        const t = &self.table.?;

        const up = self.rows_printed + self.pending_rows - t.start_row;
        if (up > 0) {
            try self.writer.print(terminal.cursor_up, .{up});
        }
        try self.writer.writeAll(terminal.move_to_line_start);
        try self.writer.writeAll(terminal.erase_display);

        try terminal.writeWithCRLF(self.writer, rendered);
        try self.writer.flush();

        t.rows = countRows(rendered, self.terminal_width);
        self.rows_printed = t.start_row + t.rows;
        self.pending_rows = 0;
    }

    fn updatePending(self: *StreamRenderer) !void {
        const rendered = try self.renderPendingRegion();
        defer self.allocator.free(rendered);
        try self.erasePending();
        if (rendered.len > 0) {
            try terminal.writeWithCRLF(self.writer, rendered);
        }
        self.pending_rows = countRows(rendered, self.terminal_width);
        self.pending_trailing_newline = rendered.len > 0 and rendered[rendered.len - 1] == '\n';
    }

    /// The in-progress tail grew without completing a line: append the new bytes
    /// to the screen (styled as code when inside a fence) rather than erasing
    /// and rewriting the whole tail. Keeps per-chunk output proportional to the
    /// chunk, not to the accumulated tail.
    fn appendTailGrowth(self: *StreamRenderer, text: []const u8) !void {
        const cleaned = trimRight(text, "\r");
        if (cleaned.len == 0) return;
        if (self.in_code_block) {
            try self.writer.print("{s}{s}{s}", .{ ansi.cyan, cleaned, ansi.reset });
        } else {
            try self.writer.writeAll(cleaned);
        }
        self.pending_rows = self.pendingRegionRows();
        self.pending_trailing_newline = false;
    }

    fn pendingRegionRows(self: *StreamRenderer) usize {
        var rows: usize = 0;
        for (self.pending_run.items) |line| {
            const rendered = markdown.renderInline(self.allocator, line) catch continue;
            defer self.allocator.free(rendered);
            rows += countRows(rendered, self.terminal_width);
        }
        const tail = trimRight(self.content.items[self.consumed..], "\r");
        rows += rowCountForLine(markdown.ansiVisibleWidth(tail), self.terminal_width);
        return rows;
    }

    fn renderPendingRegion(self: *StreamRenderer) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        for (self.pending_run.items) |line| {
            const rendered = try markdown.renderInline(self.allocator, line);
            defer self.allocator.free(rendered);
            try out.appendSlice(self.allocator, rendered);
            try out.append(self.allocator, '\n');
        }
        try self.appendTail(&out);
        return out.toOwnedSlice(self.allocator);
    }

    fn appendTail(self: *StreamRenderer, out: *std.ArrayList(u8)) !void {
        const tail = trimRight(self.content.items[self.consumed..], "\r");
        if (tail.len == 0) return;
        if (self.in_code_block) {
            try out.appendSlice(self.allocator, ansi.cyan);
            try out.appendSlice(self.allocator, tail);
            try out.appendSlice(self.allocator, ansi.reset);
        } else {
            try out.appendSlice(self.allocator, tail);
        }
    }

    fn erasePending(self: *StreamRenderer) !void {
        if (self.pending_rows == 0) return;
        const up = if (self.pending_trailing_newline) self.pending_rows else self.pending_rows - 1;
        if (up > 0) {
            try self.writer.print(terminal.cursor_up, .{up});
        }
        try self.writer.writeAll(terminal.move_to_line_start);
        try self.writer.writeAll(terminal.erase_display);
        self.pending_rows = 0;
        self.pending_trailing_newline = false;
    }

    fn printCommitted(self: *StreamRenderer, rendered: []const u8) !void {
        if (rendered.len == 0) return;
        try terminal.writeWithCRLF(self.writer, rendered);
        self.rows_printed += countRows(rendered, self.terminal_width);
    }
};

const OpenTable = struct {
    lines: std.ArrayList([]const u8),
    start_row: usize,
    rows: usize = 0,
};

/// Number of terminal rows `text` occupies, wrapping at `width` columns.
/// A trailing newline does not add an extra empty row.
fn countRows(text: []const u8, width: usize) usize {
    var rows: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            rows += rowCountForLine(markdown.ansiVisibleWidth(text[line_start..i]), width);
            line_start = i + 1;
        }
    }
    if (line_start < text.len) {
        rows += rowCountForLine(markdown.ansiVisibleWidth(text[line_start..]), width);
    }
    return rows;
}

fn rowCountForLine(vis_width: usize, width: usize) usize {
    if (width == 0) return 1;
    return @max(@as(usize, 1), (vis_width + width - 1) / width);
}

fn trimRight(s: []const u8, chars: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        var found = false;
        for (chars) |c| {
            if (s[end - 1] == c) {
                found = true;
                break;
            }
        }
        if (!found) break;
        end -= 1;
    }
    return s[0..end];
}

/// Strip SGR escape sequences, matching what the FakeScreen keeps in rows.
fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and text[i] != 'm') i += 1;
                if (i < text.len) i += 1;
            }
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// --- Tests ---

test "countRows accounts for terminal wrapping" {
    try std.testing.expectEqual(@as(usize, 1), countRows("hello\n", 10));
    try std.testing.expectEqual(@as(usize, 2), countRows("abcdefghijklm\n", 10));
    try std.testing.expectEqual(@as(usize, 2), countRows("abc", 2));
    try std.testing.expectEqual(@as(usize, 1), countRows("\n", 10));
    try std.testing.expectEqual(@as(usize, 3), countRows("a\nb\nc\n", 10));
    try std.testing.expectEqual(@as(usize, 0), countRows("", 10));
}

/// A minimal screen model that interprets the escape sequences the renderer
/// emits, so tests can assert on the final visible layout.
const FakeScreen = struct {
    rows: std.ArrayList(std.ArrayList(u8)) = .empty,
    cur_row: usize = 0,
    cur_col: usize = 0,

    fn deinit(self: *FakeScreen, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*r| r.deinit(allocator);
        self.rows.deinit(allocator);
    }

    fn feed(self: *FakeScreen, allocator: std.mem.Allocator, data: []const u8) !void {
        var i: usize = 0;
        while (i < data.len) {
            const c = data[i];
            if (c == 0x1b) {
                i += 1;
                if (i >= data.len) break;
                if (data[i] == '[') {
                    i += 1;
                    var num: usize = 0;
                    var has_num = false;
                    while (i < data.len) {
                        const b = data[i];
                        if (b >= '0' and b <= '9') {
                            num = num * 10 + (b - '0');
                            has_num = true;
                            i += 1;
                        } else if (b == ';' or b == ':') {
                            i += 1;
                        } else break;
                    }
                    if (i < data.len) {
                        const final = data[i];
                        i += 1;
                        switch (final) {
                            'A' => self.cur_row -|= if (has_num) num else 1,
                            'B' => self.cur_row = @min(self.rows.items.len, self.cur_row + (if (has_num) num else 1)),
                            'G' => self.cur_col = 0,
                            'J' => try self.eraseToEnd(allocator),
                            'K' => {
                                const row = &self.rows.items[self.cur_row];
                                try row.resize(allocator, self.cur_col);
                            },
                            'm' => {},
                            else => {},
                        }
                    }
                }
                continue;
            }
            if (c == '\r') {
                self.cur_col = 0;
            } else if (c == '\n') {
                self.cur_row += 1;
                self.cur_col = 0;
            } else {
                while (self.rows.items.len <= self.cur_row) {
                    try self.rows.append(allocator, .empty);
                }
                const row = &self.rows.items[self.cur_row];
                while (row.items.len < self.cur_col) try row.append(allocator, ' ');
                try row.append(allocator, c);
                self.cur_col += 1;
            }
            i += 1;
        }
    }

    fn eraseToEnd(self: *FakeScreen, allocator: std.mem.Allocator) !void {
        while (self.rows.items.len <= self.cur_row) {
            try self.rows.append(allocator, .empty);
        }
        const row = &self.rows.items[self.cur_row];
        try row.resize(allocator, self.cur_col);
        for (self.rows.items[self.cur_row + 1 ..]) |*r| r.deinit(allocator);
        try self.rows.resize(allocator, self.cur_row + 1);
    }

    fn toText(self: *FakeScreen, allocator: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        var last_non_empty: usize = 0;
        for (self.rows.items, 0..) |row, idx| {
            if (row.items.len > 0) last_non_empty = idx + 1;
        }
        for (self.rows.items[0..last_non_empty], 0..) |row, idx| {
            if (idx > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, row.items);
        }
        return out.toOwnedSlice(allocator);
    }
};

fn expectStreamedEqualsBatch(content: []const u8) !void {
    const md = markdown.Markdown.init();
    const rendered = try md.render(std.testing.allocator, content);
    defer std.testing.allocator.free(rendered);
    const stripped = try stripAnsi(std.testing.allocator, rendered);
    defer std.testing.allocator.free(stripped);
    const expected_trimmed = trimRight(stripped, "\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();

    var streamer = StreamRenderer.init(std.testing.allocator, &output.writer, 200);
    defer streamer.deinit();

    var screen = FakeScreen{};
    defer screen.deinit(arena);

    var written_so_far: usize = 0;
    var rest = content;
    while (rest.len > 0) {
        const chunk_len = @min(rest.len, 3);
        try streamer.push(rest[0..chunk_len]);
        rest = rest[chunk_len..];
        const fresh = output.written()[written_so_far..];
        written_so_far = output.written().len;
        try screen.feed(arena, fresh);
    }

    try streamer.finish();
    try screen.feed(arena, output.written()[written_so_far..]);

    const screen_text = try screen.toText(arena);
    defer arena.free(screen_text);
    const screen_trimmed = trimRight(screen_text, "\n");
    try std.testing.expectEqualStrings(expected_trimmed, screen_trimmed);
}

test "stream renderer matches batch render for plain content" {
    try expectStreamedEqualsBatch("Hello world\nSecond line\n");
}

test "stream renderer matches batch render for markdown content chunked" {
    try expectStreamedEqualsBatch(
        "# Title\n\nSome **bold** text and `code`.\n\n- item one\n- item two\n\n> quote\n\n",
    );
}

test "stream renderer matches batch render for code blocks split across chunks" {
    try expectStreamedEqualsBatch("```zig\nfn main() !void {\n}\n```\n");
}

test "stream renderer matches batch render for tables" {
    try expectStreamedEqualsBatch("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n");
}

test "stream renderer matches batch render for trailing partial line" {
    try expectStreamedEqualsBatch("Some text without newline");
}

test "stream renderer matches batch render for long single line chunked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var line = std.ArrayList(u8).empty;
    for (0..200) |_| try line.appendSlice(arena, "word ");
    const content = try std.fmt.allocPrint(arena, "{s}tail", .{line.items});
    try expectStreamedEqualsBatch(content);
}

test "stream renderer matches batch render when content ends mid code block" {
    try expectStreamedEqualsBatch("```zig\nfn main() {}");
}

test "stream renderer matches batch render for lone pipe line" {
    try expectStreamedEqualsBatch("| not a table |\n\nmore text\n");
}

test "stream renderer matches batch render for empty content" {
    try expectStreamedEqualsBatch("");
}
