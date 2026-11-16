const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const diff = @import("../tui/diff.zig");

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

    const width = digits(@max(old.len, new.len));
    var out = std.Io.Writer.Allocating.init(arena);
    const writer = &out.writer;
    var rows: usize = 0;
    for (script) |line| {
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
