const std = @import("std");
const ansi = @import("ansi.zig");

pub const TokenClass = enum { plain, comment, string, number, keyword };

/// A run of a line, as byte offsets into it.
pub const Token = struct { start: usize, end: usize, class: TokenClass };

/// What a line leaves open for the next one.
pub const State = enum { normal, block_comment, multiline_string };

const Delimiters = struct { open: []const u8, close: []const u8 };

pub const Language = struct {
    /// Lower-case, without the dot.
    extensions: []const []const u8,
    line_comments: []const []const u8 = &.{},
    block_comment: ?Delimiters = null,
    /// Single-line string delimiters, one byte each.
    quotes: []const u8 = "\"",
    /// A delimiter that both opens and closes a string spanning lines.
    multiline_string: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    case_insensitive_keywords: bool = false,
};

const zig_language = Language{
    .extensions = &.{ "zig", "zon" },
    .line_comments = &.{"//"},
    .quotes = "\"'",
    .keywords = &.{
        "addrspace",   "align",     "allowzero",   "and",       "anyframe", "anytype", "asm",    "break",
        "callconv",    "catch",     "comptime",    "const",     "continue", "defer",   "else",   "enum",
        "errdefer",    "error",     "export",      "extern",    "fn",       "for",     "if",     "inline",
        "linksection", "noalias",   "noinline",    "nosuspend", "opaque",   "or",      "orelse", "packed",
        "pub",         "resume",    "return",      "struct",    "suspend",  "switch",  "test",   "threadlocal",
        "try",         "union",     "unreachable", "var",       "volatile", "while",   "true",   "false",
        "null",        "undefined",
    },
};

const sql_language = Language{
    .extensions = &.{"sql"},
    .line_comments = &.{"--"},
    .block_comment = .{ .open = "/*", .close = "*/" },
    .quotes = "'",
    .case_insensitive_keywords = true,
    .keywords = &.{
        "select", "from",  "where",    "insert", "into",  "values",  "update",  "set",     "delete",     "create",
        "table",  "drop",  "alter",    "join",   "inner", "left",    "right",   "outer",   "on",         "group",
        "by",     "order", "having",   "limit",  "as",    "and",     "or",      "not",     "null",       "is",
        "in",     "like",  "distinct", "union",  "index", "primary", "key",     "foreign", "references", "default",
        "case",   "when",  "then",     "else",   "end",   "exists",  "between", "count",   "sum",        "avg",
    },
};

const languages = [_]*const Language{ &zig_language, &sql_language };

/// The language for a path's extension, case-insensitively, or null.
pub fn languageForPath(path: []const u8) ?*const Language {
    const base_start = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| i + 1 else 0;
    const base = path[base_start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot + 1 ..];
    var buf: [16]u8 = undefined;
    if (ext.len == 0 or ext.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, ext);
    for (languages) |lang| {
        for (lang.extensions) |candidate| {
            if (std.mem.eql(u8, candidate, lower)) return lang;
        }
    }
    return null;
}

pub fn colorFor(class: TokenClass) []const u8 {
    return switch (class) {
        .plain => "",
        .comment => ansi.dim,
        .string => ansi.yellow,
        .number => ansi.cyan,
        .keyword => ansi.magenta,
    };
}

fn push(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator, start: usize, end: usize, class: TokenClass) !void {
    if (end <= start) return;
    const mergeable = class == .plain or class == .comment or class == .string;
    if (mergeable and tokens.items.len > 0) {
        const last = &tokens.items[tokens.items.len - 1];
        if (last.class == class and last.end == start) {
            last.end = end;
            return;
        }
    }
    try tokens.append(allocator, .{ .start = start, .end = end, .class = class });
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isKeyword(lang: *const Language, word: []const u8) bool {
    for (lang.keywords) |kw| {
        const same = if (lang.case_insensitive_keywords) std.ascii.eqlIgnoreCase(kw, word) else std.mem.eql(u8, kw, word);
        if (same) return true;
    }
    return false;
}

/// Appends tokens that cover `line` without gaps and returns the state the
/// next line starts in. Without a language the line is one plain token.
pub fn tokenize(
    allocator: std.mem.Allocator,
    lang_opt: ?*const Language,
    line: []const u8,
    state: State,
    tokens: *std.ArrayList(Token),
) std.mem.Allocator.Error!State {
    const lang = lang_opt orelse {
        try push(tokens, allocator, 0, line.len, .plain);
        return .normal;
    };
    var current = state;
    var i: usize = 0;
    scan: while (i < line.len) {
        switch (current) {
            .block_comment => {
                const close = (lang.block_comment orelse {
                    current = .normal;
                    continue :scan;
                }).close;
                if (std.mem.indexOfPos(u8, line, i, close)) |at| {
                    try push(tokens, allocator, i, at + close.len, .comment);
                    i = at + close.len;
                    current = .normal;
                } else {
                    try push(tokens, allocator, i, line.len, .comment);
                    i = line.len;
                }
                continue :scan;
            },
            .multiline_string => {
                const close = lang.multiline_string orelse {
                    current = .normal;
                    continue :scan;
                };
                if (std.mem.indexOfPos(u8, line, i, close)) |at| {
                    try push(tokens, allocator, i, at + close.len, .string);
                    i = at + close.len;
                    current = .normal;
                } else {
                    try push(tokens, allocator, i, line.len, .string);
                    i = line.len;
                }
                continue :scan;
            },
            .normal => {},
        }
        for (lang.line_comments) |marker| {
            if (std.mem.startsWith(u8, line[i..], marker)) {
                try push(tokens, allocator, i, line.len, .comment);
                break :scan;
            }
        }
        if (lang.block_comment) |block| {
            if (std.mem.startsWith(u8, line[i..], block.open)) {
                current = .block_comment;
                const body = i + block.open.len;
                try push(tokens, allocator, i, body, .comment);
                i = body;
                continue :scan;
            }
        }
        if (lang.multiline_string) |delimiter| {
            if (std.mem.startsWith(u8, line[i..], delimiter)) {
                current = .multiline_string;
                const body = i + delimiter.len;
                try push(tokens, allocator, i, body, .string);
                i = body;
                continue :scan;
            }
        }
        const c = line[i];
        if (std.mem.indexOfScalar(u8, lang.quotes, c) != null) {
            var j = i + 1;
            while (j < line.len) {
                if (line[j] == '\\') {
                    j += 2;
                } else if (line[j] == c) {
                    j += 1;
                    break;
                } else {
                    j += 1;
                }
            }
            const end = @min(j, line.len);
            try push(tokens, allocator, i, end, .string);
            i = end;
            continue :scan;
        }
        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_' or line[j] == '.')) j += 1;
            try push(tokens, allocator, i, j, .number);
            i = j;
            continue :scan;
        }
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < line.len and isIdentPart(line[j])) j += 1;
            try push(tokens, allocator, i, j, if (isKeyword(lang, line[i..j])) .keyword else .plain);
            i = j;
            continue :scan;
        }
        try push(tokens, allocator, i, i + 1, .plain);
        i += 1;
    }
    return current;
}

fn expectTokens(lang: ?*const Language, line: []const u8, expected: []const struct { []const u8, TokenClass }) !void {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(std.testing.allocator);
    _ = try tokenize(std.testing.allocator, lang, line, .normal, &tokens);
    errdefer for (tokens.items) |t| std.debug.print("{s} {any}\n", .{ line[t.start..t.end], t.class });
    try std.testing.expectEqual(expected.len, tokens.items.len);
    var pos: usize = 0;
    for (expected, tokens.items) |want, got| {
        try std.testing.expectEqual(pos, got.start);
        try std.testing.expectEqualStrings(want[0], line[got.start..got.end]);
        try std.testing.expectEqual(want[1], got.class);
        pos = got.end;
    }
    try std.testing.expectEqual(line.len, pos);
}

test "languageForPath finds a language by extension" {
    try std.testing.expect(languageForPath("src/main.zig") != null);
    try std.testing.expect(languageForPath("a/b/App.ZIG") != null);
    try std.testing.expect(languageForPath("a\\b\\q.sql") != null);
}

test "languageForPath returns null for unknown or missing extensions" {
    try std.testing.expect(languageForPath("notes.txt") == null);
    try std.testing.expect(languageForPath("Makefile") == null);
    try std.testing.expect(languageForPath("dir.zig/readme") == null);
    try std.testing.expect(languageForPath("") == null);
}

test "tokenize without a language is one plain token" {
    try expectTokens(null, "const x = 1;", &.{.{ "const x = 1;", .plain }});
}

test "tokenize an empty line has no tokens" {
    try expectTokens(languageForPath("a.zig"), "", &.{});
}

test "tokenize classifies keywords, numbers and strings" {
    try expectTokens(languageForPath("a.zig"), "const x = 42; // hi", &.{
        .{ "const", .keyword },
        .{ " x = ", .plain },
        .{ "42", .number },
        .{ "; ", .plain },
        .{ "// hi", .comment },
    });
    try expectTokens(languageForPath("a.zig"), "f(\"a b\")", &.{
        .{ "f(", .plain },
        .{ "\"a b\"", .string },
        .{ ")", .plain },
    });
}

test "tokenize treats an identifier containing a keyword as plain" {
    try expectTokens(languageForPath("a.zig"), "constant", &.{.{ "constant", .plain }});
}

test "tokenize keeps an escaped quote inside the string" {
    try expectTokens(languageForPath("a.zig"), "\"a\\\"b\" x", &.{
        .{ "\"a\\\"b\"", .string },
        .{ " x", .plain },
    });
}

test "tokenize ends an unterminated string at the end of the line" {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(std.testing.allocator);
    const next = try tokenize(std.testing.allocator, languageForPath("a.zig"), "x = \"abc", .normal, &tokens);
    try std.testing.expectEqual(State.normal, next);
    try std.testing.expectEqual(TokenClass.string, tokens.items[tokens.items.len - 1].class);
}

test "tokenize does not read digits inside identifiers as numbers" {
    try expectTokens(languageForPath("a.zig"), "x1 y2z", &.{.{ "x1 y2z", .plain }});
}

test "tokenize matches SQL keywords case-insensitively" {
    try expectTokens(languageForPath("q.sql"), "select 'a' from t", &.{
        .{ "select", .keyword },
        .{ " ", .plain },
        .{ "'a'", .string },
        .{ " ", .plain },
        .{ "from", .keyword },
        .{ " t", .plain },
    });
}

test "colorFor leaves plain text uncoloured" {
    try std.testing.expectEqualStrings("", colorFor(.plain));
    try std.testing.expect(colorFor(.keyword).len > 0);
    try std.testing.expect(colorFor(.comment).len > 0);
}

fn tokensAndState(lang: *const Language, line: []const u8, state: State, out: *std.ArrayList(Token)) !State {
    return tokenize(std.testing.allocator, lang, line, state, out);
}

test "a block comment can open on one line and close on a later one" {
    const sql = languageForPath("q.sql").?;
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(std.testing.allocator);

    var state = try tokensAndState(sql, "x /* open", .normal, &tokens);
    try std.testing.expectEqual(State.block_comment, state);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqual(TokenClass.comment, tokens.items[1].class);

    tokens.clearRetainingCapacity();
    state = try tokensAndState(sql, "still comment", .block_comment, &tokens);
    try std.testing.expectEqual(State.block_comment, state);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqual(TokenClass.comment, tokens.items[0].class);

    tokens.clearRetainingCapacity();
    state = try tokensAndState(sql, "close */ select", .block_comment, &tokens);
    try std.testing.expectEqual(State.normal, state);
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqual(TokenClass.comment, tokens.items[0].class);
    try std.testing.expectEqual(TokenClass.keyword, tokens.items[2].class);
}

test "a block comment that closes on its own line leaves the state normal" {
    try expectTokens(languageForPath("q.sql"), "/* a */ b", &.{
        .{ "/* a */", .comment },
        .{ " b", .plain },
    });
}

const test_backtick = Language{ .extensions = &.{"x"}, .multiline_string = "`" };
const test_triple = Language{ .extensions = &.{"y"}, .quotes = "\"'", .multiline_string = "\"\"\"" };

test "a multiline string can span lines" {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(std.testing.allocator);

    var state = try tokensAndState(&test_backtick, "a `b", .normal, &tokens);
    try std.testing.expectEqual(State.multiline_string, state);
    try std.testing.expectEqual(TokenClass.string, tokens.items[tokens.items.len - 1].class);

    tokens.clearRetainingCapacity();
    state = try tokensAndState(&test_backtick, "c` d", .multiline_string, &tokens);
    try std.testing.expectEqual(State.normal, state);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqual(TokenClass.string, tokens.items[0].class);
    try std.testing.expectEqual(TokenClass.plain, tokens.items[1].class);
}

test "a triple quote opens a multiline string before a plain quote does" {
    try expectTokens(&test_triple, "\"\"\"x\"\"\" y", &.{
        .{ "\"\"\"x\"\"\"", .string },
        .{ " y", .plain },
    });
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(std.testing.allocator);
    const state = try tokensAndState(&test_triple, "z = \"\"\"doc", .normal, &tokens);
    try std.testing.expectEqual(State.multiline_string, state);
}

test "tokens cover the whole line without gaps in every state" {
    const line = "a /* b */ \"c\" 1 // d";
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(std.testing.allocator);
    for ([_]State{ .normal, .block_comment }) |state| {
        tokens.clearRetainingCapacity();
        _ = try tokensAndState(languageForPath("q.sql").?, line, state, &tokens);
        var pos: usize = 0;
        for (tokens.items) |t| {
            try std.testing.expectEqual(pos, t.start);
            pos = t.end;
        }
        try std.testing.expectEqual(line.len, pos);
    }
}
