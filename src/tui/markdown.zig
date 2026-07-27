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
                const rendered = try renderInline(allocator, content);
                try result.appendSlice(allocator, ansi.dim);
                try result.appendSlice(allocator, "\u{2502} ");
                try result.appendSlice(allocator, ansi.reset);
                try result.appendSlice(allocator, rendered);
                allocator.free(rendered);
                try result.appendSlice(allocator, "\n");
                continue;
            }

            // Unordered lists
            if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
                const content = trimLeft(trimmed[2..], " ");
                try result.appendSlice(allocator, "  ");
                const rendered = try renderInline(allocator, content);
                try result.appendSlice(allocator, ansi.dim);
                try result.appendSlice(allocator, "\u{2022} ");
                try result.appendSlice(allocator, ansi.reset);
                try result.appendSlice(allocator, rendered);
                allocator.free(rendered);
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
                        const rendered = try renderInline(allocator, tl);
                        try result.appendSlice(allocator, rendered);
                        allocator.free(rendered);
                        try result.appendSlice(allocator, "\n");
                    }
                }
                continue;
            }

            // Regular paragraph with inline formatting
            const rendered = try renderInline(allocator, line);
            try result.appendSlice(allocator, rendered);
            allocator.free(rendered);
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

fn isWideCodePoint(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F, // Hangul Jamo
        0x2329, 0x232A, // Angle brackets
        0x2E80...0x303E, // CJK Radicals, Kangxi, CJK Symbols
        0x3040...0x33FF, // Hiragana, Katakana, Bopomofo, CJK Compatibility
        0x3400...0x4DBF, // CJK Extension A
        0x4E00...0x9FFF, // CJK Unified Ideographs
        0xA000...0xA4CF, // Yi
        0xAC00...0xD7AF, // Hangul Syllables
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFE10...0xFE1F, // Vertical forms
        0xFE30...0xFE6F, // CJK Compatibility Forms, Small Form Variants
        0xFF01...0xFF60, // Fullwidth Forms
        0xFFE0...0xFFE6, // Fullwidth Signs
        0x1F000...0x1F9FF, // Mahjong, Domino, Enclosed Alphanumeric, Emoticons, Transport
        0x20000...0x2FFFF, // CJK Extension B–G
        => true,
        else => false,
    };
}

fn isZeroWidthCodePoint(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, // Combining Diacritical Marks
        0x0483...0x0489, // Cyrillic combining marks
        0x0591...0x05BD, // Hebrew combining marks
        0x0610...0x061A, // Arabic combining marks
        0x064B...0x065F, // Arabic combining marks
        0x0670,
        0x06D6...0x06DC,
        0x06DF...0x06E4,
        0x06E7...0x06E8,
        0x06EA...0x06ED,
        0x0711,
        0x0730...0x074A,
        0x07A6...0x07B0,
        0x0901...0x0903, // Devanagari
        0x093C,
        0x093E...0x094D,
        0x0951...0x0954,
        0x0962...0x0963,
        0x0981...0x0983,
        0x09BC,
        0x09BE...0x09C4,
        0x09C7...0x09C8,
        0x09CB...0x09CD,
        0x09D7,
        0x09E2...0x09E3,
        0x0A01...0x0A03,
        0x0A3C,
        0x0A3E...0x0A42,
        0x0A47...0x0A48,
        0x0A4B...0x0A4D,
        0x0A70...0x0A71,
        0x0A81...0x0A83,
        0x0ABC,
        0x0ABE...0x0AC5,
        0x0AC7...0x0AC9,
        0x0ACB...0x0ACD,
        0x0AE2...0x0AE3,
        0x0B01...0x0B03,
        0x0B3C,
        0x0B3E...0x0B43,
        0x0B47...0x0B48,
        0x0B4B...0x0B4D,
        0x0B56...0x0B57,
        0x0B82,
        0x0BBE...0x0BC2,
        0x0BC6...0x0BC8,
        0x0BCA...0x0BCD,
        0x0BD7,
        0x0C01...0x0C03,
        0x0C3E...0x0C44,
        0x0C46...0x0C48,
        0x0C4A...0x0C4D,
        0x0C55...0x0C56,
        0x0C82...0x0C83,
        0x0CBC,
        0x0CBE...0x0CC4,
        0x0CC6...0x0CC8,
        0x0CCA...0x0CCD,
        0x0CD5...0x0CD6,
        0x0D02...0x0D03,
        0x0D3E...0x0D44,
        0x0D46...0x0D48,
        0x0D4A...0x0D4D,
        0x0D57,
        0x0D82...0x0D83,
        0x0DCA,
        0x0DCF...0x0DD4,
        0x0DD6,
        0x0DD8...0x0DDF,
        0x0DF2...0x0DF3,
        0x0E31,
        0x0E34...0x0E3A,
        0x0E47...0x0E4E,
        0x0EB1,
        0x0EB4...0x0EB9,
        0x0EBB...0x0EBC,
        0x0EC8...0x0ECD,
        0x0F18...0x0F19,
        0x0F35,
        0x0F37,
        0x0F39,
        0x0F3E...0x0F3F,
        0x0F71...0x0F84,
        0x0F86...0x0F87,
        0x0F90...0x0F97,
        0x0F99...0x0FBC,
        0x0FC6,
        0x102B...0x103E,
        0x1056...0x1059,
        0x105E...0x1060,
        0x1062...0x1064,
        0x1067...0x106D,
        0x1071...0x1074,
        0x1082...0x108D,
        0x108F,
        0x109A...0x109D,
        0x200B...0x200F, // ZWSP, ZWNJ, ZWJ, LRM, RLM
        0x2028...0x202E,
        0x2060...0x2064, // Word joiner, invisible operators
        0x2066...0x206F,
        0xFE00...0xFE0F, // Variation selectors
        0xFEFF,
        0xFFF9...0xFFFB,
        => true,
        else => false,
    };
}

fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i..]) catch {
            i += seq_len;
            width += 1;
            continue;
        };
        if (isZeroWidthCodePoint(cp)) {
            // width unchanged
        } else if (isWideCodePoint(cp)) {
            width += 2;
        } else {
            width += 1;
        }
        i += seq_len;
    }
    return width;
}

fn isSeparatorCell(cell: []const u8) bool {
    const trimmed = trimRight(trimLeft(cell, " \t"), " \t");
    if (trimmed.len == 0) return false;
    for (trimmed) |c| {
        switch (c) {
            '-', ':' => continue,
            else => return false,
        }
    }
    return true;
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
    errdefer cells.deinit(allocator);
    var it = std.mem.splitScalar(u8, inner, '|');
    while (it.next()) |cell| {
        try cells.append(allocator, trimLeft(trimRight(cell, " \t"), " \t"));
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
    const excess = total - max_content;
    var shrinkable_total: usize = 0;
    for (widths) |w| {
        if (w > 3) shrinkable_total += w - 3;
    }
    if (shrinkable_total == 0) return;
    var remaining = excess;
    for (widths) |*w| {
        if (w.* > 3) {
            const share = (w.* - 3) * excess / shrinkable_total;
            const shrink = @min(share, w.* - 3);
            w.* -= shrink;
            remaining -|= shrink;
        }
    }
    for (widths) |*w| {
        if (remaining == 0) break;
        if (w.* > 3) {
            w.* -= 1;
            remaining -= 1;
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
    defer {
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
    {
        const sep = rows.items[1];
        for (sep, 0..) |cell, i| {
            if (i >= max_cols) break;
            if (!isSeparatorCell(cell)) return error.InvalidTableSeparator;
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

    return result.toOwnedSlice(allocator);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┐") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┘") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "├") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┤") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┼") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┬") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┴") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
}

test "Markdown handles table with empty cells" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| A | B | C |\n|---|---|---|\n| 1 | | 3 |");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "3") != null);
}

test "Markdown treats non-table pipes as plain text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "a | b | c");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a | b | c\n", result);
}

test "Markdown handles lone table line before non-table text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| a |\ntext");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "| a |") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "text") != null);
}

test "Markdown treats single table line as plain text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| not enough lines |");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") == null);
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
    try std.testing.expectEqual(@as(usize, 5), displayWidth("héllo"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("中文"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("😀"));
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
