const std = @import("std");
const ansi = @import("ansi.zig");

const bold_start = "\x1b[1m";
const bold_end = "\x1b[22m";
const cyan = "\x1b[36m";

pub const Markdown = struct {
    pub fn init() Markdown {
        return .{};
    }

    pub fn render(_: *const Markdown, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var lines = std.mem.splitScalar(u8, text, '\n');
        var in_code_block = false;

        while (lines.next()) |raw_line| {
            const line = trimRight(raw_line, " \t\r");
            if (in_code_block) {
                if (std.mem.startsWith(u8, line, "```")) {
                    try result.appendSlice(allocator, ansi.reset);
                    try result.appendSlice(allocator, "\n");
                    in_code_block = false;
                } else {
                    try result.appendSlice(allocator, cyan);
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

fn renderInline(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        // Inline code: `...`
        if (text[i] == '`') {
            const end = findMatchingBacktick(text, i + 1);
            if (end) |e| {
                try result.appendSlice(allocator, cyan);
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
                try result.appendSlice(allocator, bold_start);
                try result.appendSlice(allocator, text[i + 2 .. e]);
                try result.appendSlice(allocator, bold_end);
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
    try std.testing.expect(std.mem.indexOf(u8, result, bold_start) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, bold_end) != null);
}

test "Markdown renders inline code" {
    var md = Markdown.init();
    const result = try md.render(std.testing.allocator, "Use `code` here");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, cyan) != null);
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
