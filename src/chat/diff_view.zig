const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const diff = @import("../tui/diff.zig");

/// Unchanged lines shown on each side of a change.
pub const context_lines = 2;

/// Rows of diff shown per tool call; a footer row may follow.
pub const max_rows = 20;

pub const Rendered = struct { text: []const u8, rows: usize };

fn digits(n: usize) usize {
    var count: usize = 1;
    var rest = n / 10;
    while (rest > 0) : (rest /= 10) count += 1;
    return count;
}

fn writeNumber(writer: *std.Io.Writer, n: usize, width: usize) !void {
    for (0..width -| digits(n)) |_| try writer.writeByte(' ');
    try writer.print("{d}", .{n});
}

/// Renders the change from `before` to `after` as rows that each start with
/// a newline. Returns no rows when nothing changed.
pub fn renderDiff(arena: std.mem.Allocator, path: []const u8, before: []const u8, after: []const u8, columns: usize) !Rendered {
    _ = path;
    _ = columns;
    const old = try diff.splitLines(arena, before);
    const new = try diff.splitLines(arena, after);
    const script = try diff.diffLines(arena, old, new);

    var changed = false;
    for (script) |line| {
        if (line.kind != .context) changed = true;
    }
    if (!changed) return .{ .text = "", .rows = 0 };

    const visible = try arena.alloc(bool, script.len);
    @memset(visible, false);
    for (script, 0..) |line, i| {
        if (line.kind == .context) continue;
        const first = i -| context_lines;
        const last = @min(script.len - 1, i + context_lines);
        @memset(visible[first .. last + 1], true);
    }

    const width = digits(@max(old.len, new.len));
    var out = std.Io.Writer.Allocating.init(arena);
    const writer = &out.writer;
    var rows: usize = 0;
    var last_shown: ?usize = null;
    for (script, 0..) |line, i| {
        if (!visible[i]) continue;
        const needs_separator = if (last_shown) |previous| i > previous + 1 else false;
        if (rows + @as(usize, if (needs_separator) 2 else 1) > max_rows) {
            var remaining: usize = 0;
            for (visible[i..]) |shown| {
                if (shown) remaining += 1;
            }
            try writer.writeAll("\n   ");
            for (0..width + 1) |_| try writer.writeByte(' ');
            try writer.print(ansi.dim ++ "… {d} more {s}" ++ ansi.reset, .{ remaining, if (remaining == 1) "line" else "lines" });
            rows += 1;
            break;
        }
        if (last_shown) |previous| {
            if (i > previous + 1) {
                try writer.writeAll("\n   ");
                for (0..width + 1) |_| try writer.writeByte(' ');
                try writer.writeAll(ansi.dim ++ "⋮" ++ ansi.reset);
                rows += 1;
            }
        }
        last_shown = i;
        try writer.writeAll("\n   ");
        switch (line.kind) {
            .context => {
                try writer.writeAll(ansi.dim);
                try writeNumber(writer, line.new_index.? + 1, width);
                try writer.writeAll(ansi.reset ++ "   ");
                try writer.writeAll(new[line.new_index.?]);
            },
            .remove => {
                try writer.writeAll(ansi.red);
                try writeNumber(writer, line.old_index.? + 1, width);
                try writer.writeAll(" -" ++ ansi.reset ++ " ");
                try writer.writeAll(old[line.old_index.?]);
            },
            .add => {
                try writer.writeAll(ansi.green);
                try writeNumber(writer, line.new_index.? + 1, width);
                try writer.writeAll(" +" ++ ansi.reset ++ " ");
                try writer.writeAll(new[line.new_index.?]);
            },
        }
        rows += 1;
    }
    return .{ .text = out.written(), .rows = rows };
}

const red = ansi.red;
const green = ansi.green;
const dim = ansi.dim;
const reset = ansi.reset;

test "renderDiff shows a replaced line with old and new numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(arena_state.allocator(), "a.txt", "a\nb\nc\n", "a\nX\nc\n", 80);
    try std.testing.expectEqualStrings(
        "\n   " ++ dim ++ "1" ++ reset ++ "   a" ++
            "\n   " ++ red ++ "2 -" ++ reset ++ " b" ++
            "\n   " ++ green ++ "2 +" ++ reset ++ " X" ++
            "\n   " ++ dim ++ "3" ++ reset ++ "   c",
        rendered.text,
    );
    try std.testing.expectEqual(@as(usize, 4), rendered.rows);
}

test "renderDiff shows a new file as added lines from line 1" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(arena_state.allocator(), "a.txt", "", "a\nb\n", 80);
    try std.testing.expectEqualStrings(
        "\n   " ++ green ++ "1 +" ++ reset ++ " a" ++
            "\n   " ++ green ++ "2 +" ++ reset ++ " b",
        rendered.text,
    );
    try std.testing.expectEqual(@as(usize, 2), rendered.rows);
}

test "renderDiff of unchanged content is empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(arena_state.allocator(), "a.txt", "a\nb\n", "a\nb\n", 80);
    try std.testing.expectEqualStrings("", rendered.text);
    try std.testing.expectEqual(@as(usize, 0), rendered.rows);
}

test "renderDiff pads line numbers to the widest number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var before: std.ArrayList(u8) = .empty;
    for (1..11) |i| try before.print(arena, "l{d}\n", .{i});
    const rendered = try renderDiff(arena, "a.txt", "", before.items, 80);
    try std.testing.expect(std.mem.startsWith(u8, rendered.text, "\n   " ++ green ++ " 1 +" ++ reset ++ " l1"));
}

fn numberedLines(arena: std.mem.Allocator, count: usize, replace: []const usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (1..count + 1) |i| {
        const changed = std.mem.indexOfScalar(usize, replace, i) != null;
        try out.print(arena, "{s}{d}\n", .{ if (changed) "NEW" else "line", i });
    }
    return out.items;
}

test "renderDiff shows two lines of context around a change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try numberedLines(arena, 10, &.{});
    const after = try numberedLines(arena, 10, &.{5});
    const rendered = try renderDiff(arena, "a.txt", before, after, 80);
    try std.testing.expectEqual(@as(usize, 6), rendered.rows);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "line2") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "line3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "line7") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "line8") == null);
}

test "renderDiff separates distant changes with a vertical ellipsis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try numberedLines(arena, 20, &.{});
    const after = try numberedLines(arena, 20, &.{ 2, 19 });
    const rendered = try renderDiff(arena, "a.txt", before, after, 80);
    try std.testing.expectEqual(@as(usize, 11), rendered.rows);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "\n      " ++ dim ++ "⋮" ++ reset) != null);
}

test "renderDiff joins hunks whose context touches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try numberedLines(arena, 10, &.{});
    const after = try numberedLines(arena, 10, &.{ 2, 6 });
    const rendered = try renderDiff(arena, "a.txt", before, after, 80);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "⋮") == null);
}

test "renderDiff caps the rows and counts the lines left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after = try numberedLines(arena, 30, &.{});
    const rendered = try renderDiff(arena, "a.txt", "", after, 80);
    try std.testing.expectEqual(@as(usize, 21), rendered.rows);
    try std.testing.expect(std.mem.endsWith(u8, rendered.text, "\n      " ++ dim ++ "… 10 more lines" ++ reset));
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "line20") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "line21") == null);
}

test "renderDiff footer says line when one is left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after = try numberedLines(arena, 21, &.{});
    const rendered = try renderDiff(arena, "a.txt", "", after, 80);
    try std.testing.expect(std.mem.endsWith(u8, rendered.text, "… 1 more line" ++ reset));
}

test "renderDiff shows exactly the cap without a footer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after = try numberedLines(arena, 20, &.{});
    const rendered = try renderDiff(arena, "a.txt", "", after, 80);
    try std.testing.expectEqual(@as(usize, 20), rendered.rows);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "more line") == null);
}
