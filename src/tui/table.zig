const std = @import("std");
const ansi = @import("ansi.zig");
const text_width = @import("width.zig");

pub const Alignment = enum { left, center, right };

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

pub fn isTableLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 2) return false;
    if (trimmed[0] != '|') return false;
    const end = std.mem.trimEnd(u8, trimmed, " \t\r");
    return end.len > 0 and end[end.len - 1] == '|';
}

/// True when the line is a table delimiter row (only `-` and `:` cells).
pub fn isSeparatorRow(line: []const u8) bool {
    if (!isTableLine(line)) return false;
    const inner = stripOuterPipes(line);
    if (inner.len == 0) return false;
    var it = std.mem.splitScalar(u8, inner, '|');
    var count: usize = 0;
    while (it.next()) |cell| {
        if (!isSeparatorCell(cell)) return false;
        count += 1;
    }
    return count >= 1;
}

fn stripOuterPipes(line: []const u8) []const u8 {
    var s = std.mem.trimStart(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    s = std.mem.trimEnd(u8, s, " \t\r");
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    return s;
}

fn isSeparatorCell(cell: []const u8) bool {
    const trimmed = std.mem.trim(u8, cell, " \t");
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
    const trimmed = std.mem.trim(u8, cell, " \t");
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
        try cells.append(allocator, std.mem.trim(u8, cell, " \t"));
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
            const w = text_width.displayWidth(cell);
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

pub fn renderTable(allocator: std.mem.Allocator, lines: []const []const u8, terminal_width: usize) ![]const u8 {
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
    const sep_len: usize = rows.items[1].len;
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
            if (i >= sep_len or i >= max_cols) break;
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
            const w = text_width.displayWidth(cell);
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

test "isTableLine detects pipe-delimited lines" {
    try std.testing.expect(isTableLine("| a | b |"));
    try std.testing.expect(isTableLine("  | a | b |  "));
    try std.testing.expect(!isTableLine("just text"));
    try std.testing.expect(!isTableLine("a | b"));
}

test "stripOuterPipes removes leading and trailing pipes" {
    try std.testing.expectEqualStrings(" a ", stripOuterPipes("| a |"));
    try std.testing.expectEqualStrings(" a | b ", stripOuterPipes("| a | b |"));
}

test "parseAlignment detects alignment from separator cells" {
    try std.testing.expectEqual(Alignment.left, parseAlignment(":---"));
    try std.testing.expectEqual(Alignment.center, parseAlignment(":---:"));
    try std.testing.expectEqual(Alignment.right, parseAlignment("---:"));
    try std.testing.expectEqual(Alignment.left, parseAlignment("----"));
}

test "isSeparatorRow detects pipe delimiter rows" {
    try std.testing.expect(isSeparatorRow("|---|---|"));
    try std.testing.expect(isSeparatorRow("|:---|:---:|"));
    try std.testing.expect(isSeparatorRow("  | --- | --- |  "));
    try std.testing.expect(!isSeparatorRow("| a | b |"));
    try std.testing.expect(!isSeparatorRow("| --- | not |"));
    try std.testing.expect(!isSeparatorRow("just text"));
    try std.testing.expect(isSeparatorRow("| --- |"));
}
