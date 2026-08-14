const std = @import("std");
const ansi = @import("../ansi.zig");
const text_width = @import("width.zig");
const table = @import("table.zig");

pub const codePointWidth = text_width.codePointWidth;
pub const displayWidth = text_width.displayWidth;
pub const ansiVisibleWidth = text_width.ansiVisibleWidth;
pub const isTableLine = table.isTableLine;
pub const isSeparatorRow = table.isSeparatorRow;
pub const renderTable = table.renderTable;

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
            const rl = try renderLine(allocator, line, in_code_block);
            defer if (rl.output) |o| allocator.free(o);
            switch (rl.kind) {
                .code_fence_open => in_code_block = true,
                .code_fence_close => in_code_block = false,
                else => {},
            }

            if (rl.output) |out| {
                try result.appendSlice(allocator, out);
                continue;
            }

            // Table candidate: collect the run of consecutive table lines and
            // render it as a bordered table, falling back to plain paragraphs
            // when the run does not form a valid table.
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
        }

        return result.toOwnedSlice(allocator);
    }
};

/// How a single complete line should be handled by a markdown consumer.
pub const RenderKind = enum {
    /// A rendered line ready to display (owned `output`).
    text,
    /// The line opened a fenced code block (its `output` is the header line).
    code_fence_open,
    /// The line closed a fenced code block (its `output` is the reset line).
    code_fence_close,
    /// The line could be part of a table; the caller must decide with lookahead.
    table_candidate,
};

pub const RenderLine = struct {
    kind: RenderKind,
    output: ?[]const u8 = null,
};

/// Render one complete line. `in_code_block` carries the fenced-code state.
/// The returned `output` (when present) is owned by the caller and ends with
/// a trailing newline.
pub fn renderLine(allocator: std.mem.Allocator, line: []const u8, in_code_block: bool) !RenderLine {
    if (in_code_block) {
        if (std.mem.startsWith(u8, line, "```")) {
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{ansi.reset});
            return .{ .kind = .code_fence_close, .output = output };
        }
        const output = try std.fmt.allocPrint(allocator, "{s}{s}{s}\n", .{ ansi.cyan, line, ansi.reset });
        return .{ .kind = .text, .output = output };
    }

    if (std.mem.startsWith(u8, line, "```")) {
        const lang = trimLeft(line[3..], " \t");
        const output = if (lang.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s} code block:{s}\n", .{ ansi.dim, lang, ansi.reset })
        else
            try std.fmt.allocPrint(allocator, "{s}code block:{s}\n", .{ ansi.dim, ansi.reset });
        return .{ .kind = .code_fence_open, .output = output };
    }

    if (isTableLine(line)) {
        return .{ .kind = .table_candidate };
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
            const output = try std.fmt.allocPrint(allocator, "{s}{s}{s}\n", .{ ansi.bright, content, ansi.reset });
            return .{ .kind = .text, .output = output };
        }
    }

    // Blockquotes
    if (std.mem.startsWith(u8, trimmed, ">")) {
        const content = trimLeft(trimmed[1..], " ");
        const rendered = try renderInline(allocator, content);
        defer allocator.free(rendered);
        const output = try std.fmt.allocPrint(allocator, "{s}\u{2502} {s}{s}\n", .{ ansi.dim, ansi.reset, rendered });
        return .{ .kind = .text, .output = output };
    }

    // Unordered lists
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
        const content = trimLeft(trimmed[2..], " ");
        const rendered = try renderInline(allocator, content);
        defer allocator.free(rendered);
        const output = try std.fmt.allocPrint(allocator, "  {s}\u{2022} {s}{s}\n", .{ ansi.dim, ansi.reset, rendered });
        return .{ .kind = .text, .output = output };
    }

    // Regular paragraph with inline formatting
    const rendered = try renderInline(allocator, trimmed);
    defer allocator.free(rendered);
    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{rendered});
    return .{ .kind = .text, .output = output };
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

pub fn renderInline(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
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

test "Markdown strips leading whitespace from plain text" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "   indented text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("indented text\n", result);
}

test "Markdown strips leading whitespace from plain text with multiple lines" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "   first line\n   second line");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("first line\nsecond line\n", result);
}

test "Markdown preserves leading whitespace in code blocks" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "```\n   indented code\n```");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "   indented code") != null);
}

test "renderInline handles backtick matching" {
    try std.testing.expectEqual(@as(?usize, 5), findMatchingBacktick("`code` rest", 1));
    try std.testing.expect(findMatchingBacktick("`code rest", 1) == null);
}

test "renderInline handles bold matching" {
    try std.testing.expectEqual(@as(usize, 6), findBoldEnd("**bold** rest", 2));
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

test "Markdown handles a data row wider than the separator" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "| A | B |\n|---|---|\n| 1 | 2 | 3 |");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
}

test "renderLine renders headings bright" {
    const rl = try renderLine(std.testing.allocator, "# Title", false);
    defer if (rl.output) |o| std.testing.allocator.free(o);
    try std.testing.expectEqual(RenderKind.text, rl.kind);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}Title{s}\n", .{ ansi.bright, ansi.reset });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, rl.output.?);
}

test "renderLine opens code fences" {
    const rl = try renderLine(std.testing.allocator, "```zig", false);
    defer if (rl.output) |o| std.testing.allocator.free(o);
    try std.testing.expectEqual(RenderKind.code_fence_open, rl.kind);
    try std.testing.expect(std.mem.indexOf(u8, rl.output.?, "zig code block:") != null);
}

test "renderLine renders code lines inside code blocks" {
    const rl = try renderLine(std.testing.allocator, "fn main() {}", true);
    defer if (rl.output) |o| std.testing.allocator.free(o);
    try std.testing.expectEqual(RenderKind.text, rl.kind);
    try std.testing.expect(std.mem.indexOf(u8, rl.output.?, ansi.cyan) != null);
}

test "renderLine closes code fences" {
    const rl = try renderLine(std.testing.allocator, "```", true);
    defer if (rl.output) |o| std.testing.allocator.free(o);
    try std.testing.expectEqual(RenderKind.code_fence_close, rl.kind);
    try std.testing.expectEqualStrings("\n", trimLeft(rl.output.?, ansi.reset));
}

test "renderLine flags table candidates" {
    const rl = try renderLine(std.testing.allocator, "| a | b |", false);
    try std.testing.expectEqual(RenderKind.table_candidate, rl.kind);
    try std.testing.expect(rl.output == null);
}

test "renderLine renders plain paragraphs" {
    const rl = try renderLine(std.testing.allocator, "plain text", false);
    defer if (rl.output) |o| std.testing.allocator.free(o);
    try std.testing.expectEqual(RenderKind.text, rl.kind);
    try std.testing.expectEqualStrings("plain text\n", rl.output.?);
}

test "render handles mixed text and table content" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator,
        \\Here is some text.
        \\
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\More text here.
    );
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Here is some text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "More text here") != null);
}
