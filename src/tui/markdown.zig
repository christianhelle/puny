const std = @import("std");
const ansi = @import("ansi.zig");

const Alignment = enum { left, center, right };

const tc = struct {
    const top_left = "┌";
    const top = "─";
    const top_junction = "┬";
    const top_right = "┐";
    const left = "│";
    const separator_left = "├";
    const separator = "┼";
    const separator_right = "┤";
    const bottom_left = "└";
    const bottom_junction = "┴";
    const bottom_right = "┘";
};

pub const Markdown = struct {
    pub fn init() Markdown {
        return .{};
    }

    pub fn render(_: *const Markdown, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var all_lines = std.ArrayList([]const u8).empty;
        defer all_lines.deinit(allocator);
        {
            var line_iter = std.mem.splitScalar(u8, text, '\n');
            while (line_iter.next()) |raw_line| {
                try all_lines.append(allocator, trimRight(raw_line, " \t\r"));
            }
        }

        var in_code_block = false;
        var i: usize = 0;
        while (i < all_lines.items.len) : (i += 1) {
            const line = all_lines.items[i];
            if (in_code_block) {
                if (std.mem.startsWith(u8, line, "```")) {
                    try result.appendSlice(allocator, ansi.reset);
                    try result.appendSlice(allocator, "\n");
                    in_code_block = false;
                } else {
                    try result.appendSlice(allocator, ansi.cyan);
                    try result.appendSlice(allocator, line);
                    try result.appendSlice(allocator, ansi.reset);
                    try result.appendSlice(allocator, "\n");
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, "```")) {
                in_code_block = true;
                const lang = trimLeft(line[3..], " \t");
                try result.appendSlice(allocator, ansi.dim);
                if (lang.len > 0) {
                    try result.appendSlice(allocator, lang);
                    try result.appendSlice(allocator, " code block:");
                } else {
                    try result.appendSlice(allocator, "code block:");
                }
                try result.appendSlice(allocator, ansi.reset);
                try result.appendSlice(allocator, "\n");
                continue;
            }

            const trimmed = trimLeft(line, " \t");

            // Headings
            if (std.mem.startsWith(u8, trimmed, "#")) {
                var hash_count: usize = 0;
                for (trimmed) |c| {
                    if (c == '#') hash_count += 1 else break;
                }
                if (hash_count <= 6 and hash_count >= 1 and trimmed.len > hash_count and trimmed[hash_count] == ' ') {
                    const content = trimLeft(trimmed[hash_count..], " ");
                    try result.appendSlice(allocator, ansi.bright);
                    try result.appendSlice(allocator, content);
                    try result.appendSlice(allocator, ansi.reset);
                    try result.appendSlice(allocator, "\n");
                    continue;
                }
            }

            // Blockquotes
            if (std.mem.startsWith(u8, trimmed, ">")) {
                const content = trimLeft(trimmed[1..], " ");
                try result.appendSlice(allocator, ansi.dim);
                try result.appendSlice(allocator, "\u{2502} ");
                try result.appendSlice(allocator, ansi.reset);
                try result.appendSlice(allocator, try renderInline(allocator, content));
                try result.appendSlice(allocator, "\n");
                continue;
            }

            // Unordered lists
            if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
                const content = trimLeft(trimmed[2..], " ");
                try result.appendSlice(allocator, "  ");
                try result.appendSlice(allocator, ansi.dim);
                try result.appendSlice(allocator, "\u{2022} ");
                try result.appendSlice(allocator, ansi.reset);
                try result.appendSlice(allocator, try renderInline(allocator, content));
                try result.appendSlice(allocator, "\n");
                continue;
            }

            // Tables
            if (isTableLine(line)) {
                const start = i;
                while (i + 1 < all_lines.items.len and isTableLine(all_lines.items[i + 1])) {
                    i += 1;
                }
                const table_lines = all_lines.items[start .. i + 1];
                if (renderTable(allocator, table_lines, 80)) |rendered| {
                    try result.appendSlice(allocator, rendered);
                    allocator.free(rendered);
                } else |_| {
                    for (table_lines) |tl| {
                        try result.appendSlice(allocator, try renderInline(allocator, tl));
                        try result.appendSlice(allocator, "\n");
                    }
                }
                continue;
            }

            // Regular paragraph with inline formatting
            const rendered = try renderInline(allocator, line);
            try result.appendSlice(allocator, rendered);
            try result.appendSlice(allocator, "\n");
        }

        return result.items;
    }
};

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

fn trimLeft(s: []const u8, chars: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        var found = false;
        for (chars) |c| {
            if (s[start] == c) {
                found = true;
                break;
            }
        }
        if (!found) break;
        start += 1;
    }
    return s[start..];
}

fn isTableLine(line: []const u8) bool {
    const trimmed = trimLeft(line, " \t");
    if (trimmed.len < 2) return false;
    if (trimmed[0] != '|') return false;
    const end = trimRight(trimmed, " \t\r");
    return end.len > 0 and end[end.len - 1] == '|';
}

fn stripOuterPipes(line: []const u8) []const u8 {
    const trimmed = trimLeft(line, " \t");
    var s = trimmed;
    if (s.len > 0 and s[0] == '|') s = s[1..];
    s = trimRight(s, " \t\r");
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    return s;
}

fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        width += 1;
        i += seq_len;
    }
    return width;
}

fn parseAlignment(cell: []const u8) Alignment {
    const trimmed = trimRight(trimLeft(cell, " \t"), " \t");
    if (trimmed.len == 0) return .left;
    const left_colon = trimmed[0] == ':';
    const right_colon = trimmed[trimmed.len - 1] == ':';
    if (left_colon and right_colon) return .center;
    if (right_colon) return .right;
    return .left;
}

fn splitTableLine(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    const inner = stripOuterPipes(line);
    var cells = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, inner, '|');
    while (it.next()) |cell| {
        try cells.append(allocator, trimRight(cell, " \t"));
    }
    return cells.toOwnedSlice(allocator);
}

fn capWidths(widths: []usize, terminal_width: usize) void {
    if (widths.len == 0) return;
    const borders: usize = 3 * widths.len + 1;
    const max_content = if (terminal_width > borders) terminal_width - borders else 0;
    var total: usize = 0;
    for (widths) |w| total += w;
    if (total <= max_content) return;
    var remaining = total - max_content;
    for (widths) |*w| {
        if (remaining == 0) break;
        const min_w: usize = 3;
        if (w.* > min_w) {
            const shrink = @min(remaining, w.* - min_w);
            w.* -= shrink;
            remaining -= shrink;
        }
    }
}

fn wrapCell(allocator: std.mem.Allocator, text: []const u8, width: usize) ![][]const u8 {
    if (width == 0 or text.len == 0) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = text;
        return result;
    }
    var segments = std.ArrayList([]const u8).empty;
    var start: usize = 0;
    while (start < text.len) {
        var end = start;
        var vis_width: usize = 0;
        var last_space: ?usize = null;
        while (end < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
            if (vis_width + 1 > width) break;
            if (text[end] == ' ') last_space = end;
            vis_width += 1;
            end += seq_len;
        }
        if (end >= text.len) {
            try segments.append(allocator, text[start..]);
            break;
        }
        if (last_space) |sp| {
            if (sp > start) {
                try segments.append(allocator, text[start..sp]);
                start = sp + 1;
                continue;
            }
        }
        if (end > start) {
            try segments.append(allocator, text[start..end]);
            start = end;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
            try segments.append(allocator, text[start .. start + seq_len]);
            start += seq_len;
        }
    }
    return segments.toOwnedSlice(allocator);
}

fn renderBorderLine(
    result: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    num_cols: usize,
    col_widths: []const usize,
    left_char: []const u8,
    junction_char: []const u8,
    right_char: []const u8,
) !void {
    try result.appendSlice(allocator, left_char);
    for (col_widths, 0..) |w, i| {
        for (0..w + 2) |_| try result.appendSlice(allocator, tc.top);
        if (i < num_cols - 1) try result.appendSlice(allocator, junction_char);
    }
    try result.appendSlice(allocator, right_char);
    try result.append(allocator, '\n');
}

fn renderDataRow(
    result: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    row: []const []const u8,
    alignments: []const Alignment,
    col_widths: []const usize,
    is_header: bool,
) !void {
    var wrapped = std.ArrayList([][]const u8).empty;
    defer {
        for (wrapped.items) |sub| allocator.free(sub);
        wrapped.deinit(allocator);
    }
    var max_sub_rows: usize = 1;
    const num_cols = col_widths.len;
    for (row, 0..) |cell, ci| {
        if (ci >= num_cols) break;
        const sub = try wrapCell(allocator, cell, col_widths[ci]);
        try wrapped.append(allocator, sub);
        if (sub.len > max_sub_rows) max_sub_rows = sub.len;
    }
    for (wrapped.items) |*sub| {
        if (sub.len < max_sub_rows) {
            const padded = try allocator.alloc([]const u8, max_sub_rows);
            @memcpy(padded[0..sub.len], sub.*);
            for (sub.len..max_sub_rows) |i| padded[i] = "";
            allocator.free(sub.*);
            sub.* = padded;
        }
    }
    for (0..max_sub_rows) |sub_row| {
        try result.appendSlice(allocator, tc.left);
        try result.append(allocator, ' ');
        for (0..num_cols) |ci| {
            const cell = wrapped.items[ci][sub_row];
            const w = displayWidth(cell);
            const pad = col_widths[ci] -| w;
            if (is_header) try result.appendSlice(allocator, ansi.bright);
            switch (alignments[ci]) {
                .left => {
                    try result.appendSlice(allocator, cell);
                    for (0..pad) |_| try result.append(allocator, ' ');
                },
                .right => {
                    for (0..pad) |_| try result.append(allocator, ' ');
                    try result.appendSlice(allocator, cell);
                },
                .center => {
                    const l = pad / 2;
                    const r = pad - l;
                    for (0..l) |_| try result.append(allocator, ' ');
                    try result.appendSlice(allocator, cell);
                    for (0..r) |_| try result.append(allocator, ' ');
                },
            }
            if (is_header) try result.appendSlice(allocator, ansi.reset);
            if (ci < num_cols - 1) {
                try result.append(allocator, ' ');
                try result.appendSlice(allocator, tc.left);
                try result.append(allocator, ' ');
            }
        }
        try result.append(allocator, ' ');
        try result.appendSlice(allocator, tc.left);
        try result.append(allocator, '\n');
    }
}

fn renderTable(allocator: std.mem.Allocator, lines: []const []const u8, terminal_width: usize) ![]const u8 {
    if (lines.len < 2) return error.TooFewTableLines;
    var rows = std.ArrayList([][]const u8).empty;
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    var max_cols: usize = 0;
    for (lines) |line| {
        const cells = try splitTableLine(allocator, line);
        if (cells.len > max_cols) max_cols = cells.len;
        try rows.append(allocator, cells);
    }
    if (max_cols < 2) return error.TooFewColumns;
    for (rows.items) |*row| {
        if (row.len < max_cols) {
            const expanded = try allocator.alloc([]const u8, max_cols);
            @memcpy(expanded[0..row.len], row.*);
            for (row.len..max_cols) |i| expanded[i] = "";
            allocator.free(row.*);
            row.* = expanded;
        }
    }
    var alignments = try allocator.alloc(Alignment, max_cols);
    defer allocator.free(alignments);
    @memset(alignments, .left);
    if (lines.len >= 2) {
        const sep = rows.items[1];
        for (sep, 0..) |cell, i| {
            if (i >= max_cols) break;
            alignments[i] = parseAlignment(cell);
        }
    }
    var col_widths = try allocator.alloc(usize, max_cols);
    defer allocator.free(col_widths);
    @memset(col_widths, 0);
    for (rows.items, 0..) |row, ri| {
        if (ri == 1) continue;
        for (row, 0..) |cell, ci| {
            if (ci >= max_cols) break;
            const w = displayWidth(cell);
            if (w > col_widths[ci]) col_widths[ci] = w;
        }
    }
    for (col_widths) |*w| {
        if (w.* < 3) w.* = 3;
    }
    capWidths(col_widths, terminal_width);
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try renderBorderLine(&result, allocator, max_cols, col_widths, tc.top_left, tc.top_junction, tc.top_right);
    try renderDataRow(&result, allocator, rows.items[0], alignments, col_widths, true);
    try renderBorderLine(&result, allocator, max_cols, col_widths, tc.separator_left, tc.separator, tc.separator_right);
    for (rows.items[2..]) |row| {
        try renderDataRow(&result, allocator, row, alignments, col_widths, false);
    }
    try renderBorderLine(&result, allocator, max_cols, col_widths, tc.bottom_left, tc.bottom_junction, tc.bottom_right);
    return result.toOwnedSlice(allocator);
}

fn renderInline(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        // Inline code: `...`
        if (text[i] == '`') {
            const end = findMatchingBacktick(text, i + 1);
            if (end) |e| {
                try result.appendSlice(allocator, ansi.cyan);
                try result.appendSlice(allocator, text[i + 1 .. e]);
                try result.appendSlice(allocator, ansi.reset);
                i = e + 1;
                continue;
            }
        }

        // Bold: **...**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            const end = findBoldEnd(text, i + 2);
            if (end) |e| {
                try result.appendSlice(allocator, ansi.bold_start);
                try result.appendSlice(allocator, text[i + 2 .. e]);
                try result.appendSlice(allocator, ansi.bold_end);
                i = e + 2;
                continue;
            }
        }

        try result.append(allocator, text[i]);
        i += 1;
    }

    return result.items;
}

fn findMatchingBacktick(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '`') return i;
    }
    return null;
}

fn findBoldEnd(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == '*' and text[i + 1] == '*') return i;
    }
    return null;
}

test "Markdown renders bold text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "Hello **world**");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, ansi.bold_start) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ansi.bold_end) != null);
}

test "Markdown renders inline code" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "Use `code` here");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, ansi.cyan) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "code") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ansi.reset) != null);
}

test "Markdown renders code blocks" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "Text\n```zig\nfn main() {}\n```\nEnd");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "code block:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fn main") != null);
}

test "Markdown renders unordered lists" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "- item one\n- item two");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\u{2022}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "item one") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "item two") != null);
}

test "Markdown renders headings" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "# Title\n## Subtitle");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Subtitle") != null);
}

test "Markdown renders blockquotes" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "> quoted text");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\u{2502}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "quoted text") != null);
}

test "Markdown handles plain text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "Just plain text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Just plain text\n", result);
}

test "renderInline handles backtick matching" {
    try std.testing.expectEqual(@as(?usize, 5), findMatchingBacktick("`code` rest", 1));
    try std.testing.expect(findMatchingBacktick("`code rest", 1) == null);
}

test "renderInline handles bold matching" {
    try std.testing.expectEqual(@as(?usize, 5), findBoldEnd("**bold** rest", 2));
    try std.testing.expect(findBoldEnd("**bold rest", 2) == null);
}

test "trimRight strips trailing characters" {
    try std.testing.expectEqualStrings("hello", trimRight("hello   ", " "));
    try std.testing.expectEqualStrings("hello", trimRight("hello\t\r", " \t\r"));
    try std.testing.expectEqualStrings("", trimRight("   ", " "));
}

test "trimLeft strips leading characters" {
    try std.testing.expectEqualStrings("hello", trimLeft("   hello", " "));
    try std.testing.expectEqualStrings("hello", trimLeft("\t\rhello", " \t\r"));
    try std.testing.expectEqualStrings("", trimLeft("   ", " "));
}

test "Markdown renders simple table with box-drawing" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| A | B |\n|---|---|\n| 1 | 2 |");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┌') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┐') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '└') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┘') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '│') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '├') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┤') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┼') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┬') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┴') != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ansi.bright) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2") != null);
}

test "Markdown handles column alignment markers" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| L | C | R |\n|:---|:---:|---:|\n| a | b | c |");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┌') != null);
}

test "Markdown handles table with empty cells" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| A | B | C |\n|---|---|---|\n| 1 | | 3 |");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '│') != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "3") != null);
}

test "Markdown treats non-table pipes as plain text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "just | a pipe");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("just | a pipe\n", result);
}

test "Markdown treats single table line as plain text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| not enough lines |");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '┌') == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "| not enough lines |") != null);
}

test "Markdown renders table header in bright style" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| Name | Value |\n|------|-------|\n| x | 42 |");
    defer std.testing.allocator.free(result);
    const bright_pos = std.mem.indexOf(u8, result, ansi.bright) orelse return error.TestFailed;
    const name_pos = std.mem.indexOf(u8, result, "Name") orelse return error.TestFailed;
    try std.testing.expect(bright_pos < name_pos);
}

test "displayWidth counts code points not bytes" {
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "isTableLine detects pipe-delimited lines" {
    try std.testing.expect(isTableLine("| a | b |"));
    try std.testing.expect(isTableLine("  | a | b |  "));
    try std.testing.expect(!isTableLine("just text"));
    try std.testing.expect(!isTableLine("a | b"));
}

test "stripOuterPipes removes leading and trailing pipes" {
    try std.testing.expectEqualStrings(" a ", stripOuterPipes("| a |"));
    try std.testing.expectEqualStrings("a | b", stripOuterPipes("| a | b |"));
}

test "parseAlignment detects alignment from separator cells" {
    try std.testing.expectEqual(Alignment.left, parseAlignment(":---"));
    try std.testing.expectEqual(Alignment.center, parseAlignment(":---:"));
    try std.testing.expectEqual(Alignment.right, parseAlignment("---:"));
    try std.testing.expectEqual(Alignment.left, parseAlignment("----"));
}
