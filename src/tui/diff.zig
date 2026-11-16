const std = @import("std");

/// Splits `text` on '\n', stripping a trailing '\r' from each line and
/// dropping the empty piece after a final newline. Slices point into `text`.
pub fn splitLines(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        var line = text[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try lines.append(allocator, line);
        start = end + 1;
    }
    return lines.toOwnedSlice(allocator);
}

test "splitLines splits on newlines" {
    const lines = try splitLines(std.testing.allocator, "a\nb\nc");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("c", lines[2]);
}

test "splitLines drops the empty piece after a trailing newline" {
    const lines = try splitLines(std.testing.allocator, "a\nb\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "splitLines keeps interior blank lines" {
    const lines = try splitLines(std.testing.allocator, "a\n\nb\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("", lines[1]);
}

test "splitLines strips carriage returns" {
    const lines = try splitLines(std.testing.allocator, "a\r\nb\r\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
}

test "splitLines of empty text has no lines" {
    const lines = try splitLines(std.testing.allocator, "");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

pub const Kind = enum { context, add, remove };

pub const Line = struct {
    kind: Kind,
    /// 0-based index into the old lines; null for an added line.
    old_index: ?usize,
    /// 0-based index into the new lines; null for a removed line.
    new_index: ?usize,
};

/// Largest `old * new` middle the LCS table is built for; beyond it the
/// middle is shown as all removed then all added.
const max_lcs_cells: usize = 1_000_000;

/// Edit script from `old` to `new`, in display order. Inside a run of
/// changes every removed line comes before the added lines.
pub fn diffLines(allocator: std.mem.Allocator, old: []const []const u8, new: []const []const u8) std.mem.Allocator.Error![]Line {
    return diffLinesLimited(allocator, old, new, max_lcs_cells);
}

fn diffLinesLimited(allocator: std.mem.Allocator, old: []const []const u8, new: []const []const u8, max_cells: usize) std.mem.Allocator.Error![]Line {
    var script: std.ArrayList(Line) = .empty;
    errdefer script.deinit(allocator);

    var prefix: usize = 0;
    while (prefix < old.len and prefix < new.len and std.mem.eql(u8, old[prefix], new[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and
        std.mem.eql(u8, old[old.len - 1 - suffix], new[new.len - 1 - suffix])) suffix += 1;

    for (0..prefix) |i| try script.append(allocator, .{ .kind = .context, .old_index = i, .new_index = i });

    const old_mid = old[prefix .. old.len - suffix];
    const new_mid = new[prefix .. new.len - suffix];
    if (old_mid.len * new_mid.len <= max_cells) {
        try appendLcs(allocator, &script, old_mid, new_mid, prefix);
    } else {
        for (0..old_mid.len) |i| try script.append(allocator, .{ .kind = .remove, .old_index = prefix + i, .new_index = null });
        for (0..new_mid.len) |j| try script.append(allocator, .{ .kind = .add, .old_index = null, .new_index = prefix + j });
    }

    for (0..suffix) |k| try script.append(allocator, .{
        .kind = .context,
        .old_index = old.len - suffix + k,
        .new_index = new.len - suffix + k,
    });
    return script.toOwnedSlice(allocator);
}

fn appendLcs(
    allocator: std.mem.Allocator,
    script: *std.ArrayList(Line),
    old: []const []const u8,
    new: []const []const u8,
    offset: usize,
) std.mem.Allocator.Error!void {
    const m = old.len;
    const n = new.len;
    const width = n + 1;
    // table[i * width + j] is the LCS length of old[i..] and new[j..].
    const table = try allocator.alloc(u32, (m + 1) * width);
    defer allocator.free(table);
    @memset(table, 0);
    var i = m;
    while (i > 0) {
        i -= 1;
        var j = n;
        while (j > 0) {
            j -= 1;
            table[i * width + j] = if (std.mem.eql(u8, old[i], new[j]))
                table[(i + 1) * width + j + 1] + 1
            else
                @max(table[(i + 1) * width + j], table[i * width + j + 1]);
        }
    }

    var removes: std.ArrayList(Line) = .empty;
    defer removes.deinit(allocator);
    var adds: std.ArrayList(Line) = .empty;
    defer adds.deinit(allocator);

    var a: usize = 0;
    var b: usize = 0;
    while (a < m or b < n) {
        if (a < m and b < n and std.mem.eql(u8, old[a], new[b])) {
            try script.appendSlice(allocator, removes.items);
            try script.appendSlice(allocator, adds.items);
            removes.clearRetainingCapacity();
            adds.clearRetainingCapacity();
            try script.append(allocator, .{ .kind = .context, .old_index = offset + a, .new_index = offset + b });
            a += 1;
            b += 1;
        } else if (b >= n or (a < m and table[(a + 1) * width + b] >= table[a * width + b + 1])) {
            try removes.append(allocator, .{ .kind = .remove, .old_index = offset + a, .new_index = null });
            a += 1;
        } else {
            try adds.append(allocator, .{ .kind = .add, .old_index = null, .new_index = offset + b });
            b += 1;
        }
    }
    try script.appendSlice(allocator, removes.items);
    try script.appendSlice(allocator, adds.items);
}

fn kindsOf(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8) ![]u8 {
    const old = try splitLines(allocator, old_text);
    defer allocator.free(old);
    const new = try splitLines(allocator, new_text);
    defer allocator.free(new);
    const script = try diffLines(allocator, old, new);
    defer allocator.free(script);
    const out = try allocator.alloc(u8, script.len);
    for (script, 0..) |line, i| out[i] = switch (line.kind) {
        .context => ' ',
        .add => '+',
        .remove => '-',
    };
    return out;
}

fn expectKinds(expected: []const u8, old_text: []const u8, new_text: []const u8) !void {
    const got = try kindsOf(std.testing.allocator, old_text, new_text);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "diffLines of identical text is all context" {
    try expectKinds("   ", "a\nb\nc\n", "a\nb\nc\n");
}

test "diffLines detects a pure insert" {
    try expectKinds(" + ", "a\nc\n", "a\nb\nc\n");
}

test "diffLines detects a pure delete" {
    try expectKinds(" - ", "a\nb\nc\n", "a\nc\n");
}

test "diffLines puts removes before adds in a replacement" {
    try expectKinds(" -+ ", "a\nb\nc\n", "a\nX\nc\n");
}

test "diffLines handles a change on the first line" {
    try expectKinds("-+  ", "a\nb\nc\n", "X\nb\nc\n");
}

test "diffLines handles a change on the last line" {
    try expectKinds("  -+", "a\nb\nc\n", "a\nb\nX\n");
}

test "diffLines of a new file is all adds" {
    try expectKinds("++", "", "a\nb\n");
}

test "diffLines of a emptied file is all removes" {
    try expectKinds("--", "a\nb\n", "");
}

test "diffLines gives CRLF the same script as LF" {
    try expectKinds(" -+ ", "a\r\nb\r\nc\r\n", "a\nX\nc\n");
}

test "diffLines tracks line indexes" {
    const old = [_][]const u8{ "a", "b" };
    const new = [_][]const u8{ "a", "X", "Y" };
    const script = try diffLines(std.testing.allocator, &old, &new);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqual(@as(usize, 4), script.len);
    try std.testing.expectEqual(@as(?usize, 0), script[0].old_index);
    try std.testing.expectEqual(@as(?usize, 0), script[0].new_index);
    try std.testing.expectEqual(@as(?usize, 1), script[1].old_index);
    try std.testing.expectEqual(@as(?usize, null), script[1].new_index);
    try std.testing.expectEqual(@as(?usize, null), script[2].old_index);
    try std.testing.expectEqual(@as(?usize, 1), script[2].new_index);
    try std.testing.expectEqual(@as(?usize, 2), script[3].new_index);
}

test "diffLines keeps lines the two sides share in a changed middle" {
    try expectKinds(" -+  +  ", "a\nb\nc\nd\ne\nf\n", "a\nB\nc\nd\nD\ne\nf\n");
}

test "diffLines falls back to remove-all add-all for huge middles" {
    const old = [_][]const u8{ "a", "x", "y", "b" };
    const new = [_][]const u8{ "a", "y", "x", "b" };
    const script = try diffLinesLimited(std.testing.allocator, &old, &new, 1);
    defer std.testing.allocator.free(script);
    const want = [_]Kind{ .context, .remove, .remove, .add, .add, .context };
    try std.testing.expectEqual(want.len, script.len);
    for (want, script) |k, line| try std.testing.expectEqual(k, line.kind);
}
