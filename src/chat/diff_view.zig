const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const diff = @import("../tui/diff.zig");
const highlight = @import("../tui/highlight.zig");
const openai = @import("../providers/openai.zig");
const helpers = @import("../tools/helpers.zig");
const text_width = @import("../tui/markdown/width.zig");

/// Unchanged lines shown on each side of a change.
pub const context_lines = 2;

/// Rows of diff shown per tool call; a footer row may follow.
pub const max_rows = 20;

const tab_width = 4;

pub const Rendered = struct { text: []const u8, rows: usize };

/// Set once at startup; capture does nothing while it is false.
pub var enabled: bool = false;

/// An explicit `--diff` / `--no-diff` wins; otherwise diffs show only when
/// stdout is a terminal, so piped output stays as it was.
pub fn resolveEnabled(flag: ?bool, stdout_is_tty: bool) bool {
    return flag orelse stdout_is_tty;
}

const max_file_bytes = 1024 * 1024;

/// A file as it was before a tool changed it.
pub const Snapshot = struct { path: []const u8, before: []const u8 };

/// Reads the file a write_file or edit_file call is about to change. Returns
/// null when diffs are off, the call is for another tool or its arguments
/// have no path, or the file exists but can't be read. A missing file is a
/// new file: its content before is empty.
pub fn capture(arena: std.mem.Allocator, io: std.Io, tool_call: openai.ToolCall) ?Snapshot {
    if (!enabled) return null;
    const name = tool_call.function.name;
    if (!std.mem.eql(u8, name, "write_file") and !std.mem.eql(u8, name, "edit_file")) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, tool_call.function.arguments, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path_value = parsed.value.object.get("path") orelse return null;
    if (path_value != .string) return null;
    const path = arena.dupe(u8, path_value.string) catch return null;

    const before = helpers.readFileAlloc(arena, io, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return null,
    };
    return .{ .path = path, .before = before };
}

/// Diffs the snapshot against the file as it is now. Empty when the file
/// can't be read or didn't change, which covers a failed or blocked tool.
pub fn render(arena: std.mem.Allocator, io: std.Io, snapshot: Snapshot, columns: usize) !Rendered {
    const after = helpers.readFileAlloc(arena, io, snapshot.path, max_file_bytes) catch return .{ .text = "", .rows = 0 };
    return renderDiff(arena, snapshot.path, snapshot.before, after, columns);
}

fn isBinary(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text);
}

/// Tabs become spaces and control characters are scrubbed, so file content
/// can't drive the terminal.
fn prepareLines(arena: std.mem.Allocator, lines: []const []const u8) ![]const []const u8 {
    const prepared = try arena.alloc([]const u8, lines.len);
    for (lines, prepared) |line, *slot| {
        var copy: std.ArrayList(u8) = .empty;
        for (line) |byte| {
            if (byte == 0x09) {
                try copy.appendNTimes(arena, ' ', tab_width);
            } else {
                try copy.append(arena, byte);
            }
        }
        ansi.scrubControls(copy.items);
        slot.* = copy.items;
    }
    return prepared;
}

/// The lexer state at the start of each line, so a line inside a comment
/// that opened above it still shows as one.
fn startStates(arena: std.mem.Allocator, lang: ?*const highlight.Language, lines: []const []const u8) ![]highlight.State {
    const states = try arena.alloc(highlight.State, lines.len);
    var scratch: std.ArrayList(highlight.Token) = .empty;
    var state: highlight.State = .normal;
    for (lines, states) |line, *slot| {
        slot.* = state;
        scratch.clearRetainingCapacity();
        state = try highlight.tokenize(arena, lang, line, state, &scratch);
    }
    return states;
}

/// Writes one prepared line, coloured by token and cut to `avail` cells so
/// the row never wraps.
fn writeCode(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    lang: ?*const highlight.Language,
    line: []const u8,
    state: highlight.State,
    avail: usize,
) !void {
    const cut = text_width.prefixFitting(line, avail);
    var tokens: std.ArrayList(highlight.Token) = .empty;
    _ = try highlight.tokenize(arena, lang, line, state, &tokens);
    for (tokens.items) |token| {
        if (token.start >= cut.len) break;
        const text = line[token.start..@min(token.end, cut.len)];
        const color = highlight.colorFor(token.class);
        if (color.len == 0) {
            try writer.writeAll(text);
        } else {
            try writer.writeAll(color);
            try writer.writeAll(text);
            try writer.writeAll(ansi.reset);
        }
    }
}

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
    if (isBinary(before) or isBinary(after)) return .{ .text = "", .rows = 0 };
    // Compare the lines as written, so an edit that looks the same once tabs
    // and control characters are replaced still shows. The prepared copies
    // keep the same line numbers and are only used for drawing.
    const raw_old = try diff.splitLines(arena, before);
    const raw_new = try diff.splitLines(arena, after);
    const old = try prepareLines(arena, raw_old);
    const new = try prepareLines(arena, raw_new);
    const lang = highlight.languageForPath(path);
    const old_states = try startStates(arena, lang, old);
    const new_states = try startStates(arena, lang, new);
    const script = try diff.diffLines(arena, raw_old, raw_new);

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
    // Gutter: three spaces, the number, then " m ". One cell stays free so a
    // full row never wraps.
    const gutter = 3 + width + 3;
    // A gutter that doesn't fit would wrap every row, and the rows are
    // counted one each, so show nothing rather than a broken diff.
    if (columns -| 1 < gutter) return .{ .text = "", .rows = 0 };
    const avail = (columns -| 1) - gutter;
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
            const footer = try std.fmt.allocPrint(arena, "… {d} more {s}", .{ remaining, if (remaining == 1) "line" else "lines" });
            try writer.writeAll(ansi.dim);
            try writer.writeAll(text_width.prefixFitting(footer, (columns -| 1) -| (3 + width + 1)));
            try writer.writeAll(ansi.reset);
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
                try writeCode(arena, writer, lang, new[line.new_index.?], new_states[line.new_index.?], avail);
            },
            .remove => {
                try writer.writeAll(ansi.red);
                try writeNumber(writer, line.old_index.? + 1, width);
                try writer.writeAll(" -" ++ ansi.reset ++ " ");
                try writeCode(arena, writer, lang, old[line.old_index.?], old_states[line.old_index.?], avail);
            },
            .add => {
                try writer.writeAll(ansi.green);
                try writeNumber(writer, line.new_index.? + 1, width);
                try writer.writeAll(" +" ++ ansi.reset ++ " ");
                try writeCode(arena, writer, lang, new[line.new_index.?], new_states[line.new_index.?], avail);
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

test "renderDiff expands tabs to four spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(arena_state.allocator(), "a.txt", "", "\tx\n", 80);
    try std.testing.expectEqualStrings("\n   " ++ green ++ "1 +" ++ reset ++ "     x", rendered.text);
}

test "renderDiff never prints escape sequences from file content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(arena_state.allocator(), "a.txt", "", "a\x1b[2Jb\r\x07\n", 80);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered.text, '\x07') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered.text, '\r') == null);
}

test "renderDiff cuts long lines so no row wraps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendNTimes(arena, 'x', 100);
    try text.append(arena, '\n');
    for (0..20) |_| try text.appendSlice(arena, "caf\u{e9} \u{4e2d}\u{6587}");
    try text.append(arena, '\n');
    const rendered = try renderDiff(arena, "a.txt", "", text.items, 30);
    var it = std.mem.splitScalar(u8, rendered.text[1..], '\n');
    var seen: usize = 0;
    while (it.next()) |row| {
        try std.testing.expect(text_width.ansiVisibleWidth(row) <= 29);
        seen += 1;
    }
    try std.testing.expectEqual(rendered.rows, seen);
}

test "renderDiff skips binary content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nul = try renderDiff(arena, "a.bin", "a\n", "a\x00b\n", 80);
    try std.testing.expectEqual(@as(usize, 0), nul.rows);
    const invalid = try renderDiff(arena, "a.bin", "a\n", "a\xff\xfe\n", 80);
    try std.testing.expectEqual(@as(usize, 0), invalid.rows);
}

test "renderDiff row count matches the newlines in the text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try numberedLines(arena, 20, &.{});
    const after = try numberedLines(arena, 20, &.{ 2, 19 });
    const rendered = try renderDiff(arena, "a.txt", before, after, 80);
    try std.testing.expectEqual(rendered.rows, std.mem.count(u8, rendered.text, "\n"));
}

test "renderDiff highlights keywords for a known language" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(arena_state.allocator(), "a.zig", "", "const x = 1; // hi\n", 80);
    try std.testing.expectEqualStrings(
        "\n   " ++ green ++ "1 +" ++ reset ++ " " ++
            ansi.magenta ++ "const" ++ reset ++ " x = " ++ ansi.cyan ++ "1" ++ reset ++ "; " ++ ansi.dim ++ "// hi" ++ reset,
        rendered.text,
    );
}

test "renderDiff leaves unknown languages uncoloured" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(arena_state.allocator(), "a.txt", "", "const x = 1;\n", 80);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, ansi.magenta) == null);
}

test "renderDiff dims context lines inside a multi-line comment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try renderDiff(
        arena_state.allocator(),
        "q.sql",
        "/* start\nmiddle\nend */\nx\ny\n",
        "/* start\nmiddle\nend */\nX\ny\n",
        80,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "   " ++ dim ++ "middle" ++ reset) != null);
}

test "renderDiff colours removed lines with the old side's lexer state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // The old file is inside a comment on line 2; the new file closes it first.
    const rendered = try renderDiff(
        arena_state.allocator(),
        "q.sql",
        "/* a\nselect\n*/\nz\n",
        "/* a */\nselect x\nz\n",
        80,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "-" ++ reset ++ " " ++ dim ++ "select" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "+" ++ reset ++ " " ++ ansi.magenta ++ "select" ++ reset) != null);
}

fn toolCall(name: []const u8, arguments: []const u8) openai.ToolCall {
    return .{ .id = "call_1", .function = .{ .name = name, .arguments = arguments } };
}

test "capture returns null while diffs are disabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect(capture(arena_state.allocator(), std.testing.io, toolCall("write_file", "{\"path\":\"x\",\"content\":\"\"}")) == null);
}

test "capture ignores tools that do not change files" {
    enabled = true;
    defer enabled = false;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(capture(arena, std.testing.io, toolCall("read_file", "{\"path\":\"build.zig\"}")) == null);
    try std.testing.expect(capture(arena, std.testing.io, toolCall("write_file", "not json")) == null);
    try std.testing.expect(capture(arena, std.testing.io, toolCall("write_file", "{\"content\":\"x\"}")) == null);
    try std.testing.expect(capture(arena, std.testing.io, toolCall("write_file", "{\"path\":3}")) == null);
}

test "render shows a new file as added lines" {
    enabled = true;
    defer enabled = false;
    const path = "puny-test-diff-view-new.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snapshot = capture(arena, std.testing.io, toolCall("write_file", "{\"path\":\"" ++ path ++ "\",\"content\":\"hi\"}")).?;
    try std.testing.expectEqualStrings("", snapshot.before);
    try helpers.writeFile(std.testing.io, path, "hi\n");
    const rendered = try render(arena, std.testing.io, snapshot, 80);
    try std.testing.expectEqual(@as(usize, 1), rendered.rows);
    try std.testing.expectEqualStrings("\n   " ++ green ++ "1 +" ++ reset ++ " hi", rendered.text);
}

test "render shows what an edit changed" {
    enabled = true;
    defer enabled = false;
    const path = "puny-test-diff-view-edit.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try helpers.writeFile(std.testing.io, path, "a\nb\n");
    const snapshot = capture(arena, std.testing.io, toolCall("edit_file", "{\"path\":\"" ++ path ++ "\"}")).?;
    try helpers.writeFile(std.testing.io, path, "a\nX\n");
    const rendered = try render(arena, std.testing.io, snapshot, 80);
    try std.testing.expectEqual(@as(usize, 3), rendered.rows);
}

test "render is empty when the file did not change" {
    enabled = true;
    defer enabled = false;
    const path = "puny-test-diff-view-same.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try helpers.writeFile(std.testing.io, path, "a\n");
    const snapshot = capture(arena, std.testing.io, toolCall("edit_file", "{\"path\":\"" ++ path ++ "\"}")).?;
    const rendered = try render(arena, std.testing.io, snapshot, 80);
    try std.testing.expectEqual(@as(usize, 0), rendered.rows);
}

test "render is empty when the file is missing afterwards" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try render(arena_state.allocator(), std.testing.io, .{ .path = "puny-test-diff-view-missing.txt", .before = "a\n" }, 80);
    try std.testing.expectEqual(@as(usize, 0), rendered.rows);
}

test "resolveEnabled follows the flag, else whether stdout is a terminal" {
    try std.testing.expect(resolveEnabled(true, false));
    try std.testing.expect(!resolveEnabled(false, true));
    try std.testing.expect(resolveEnabled(null, true));
    try std.testing.expect(!resolveEnabled(null, false));
}

test "renderDiff shows an edit that only changes whitespace the screen can't tell apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A Makefile recipe whose tab became four spaces looks the same once tabs
    // are expanded, but the edit breaks it.
    const tabs = try renderDiff(arena, "Makefile", "all:\n\tcc x\n", "all:\n    cc x\n", 80);
    try std.testing.expect(tabs.rows > 0);
    // Control characters are scrubbed to spaces, yet a change between two of
    // them is still a change.
    const controls = try renderDiff(arena, "a.txt", "a\x01b\n", "a\x02b\n", 80);
    try std.testing.expectEqual(@as(usize, 2), controls.rows);
}

fn expectNoRowWraps(text: []const u8, columns: usize) !void {
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, text[1..], '\n');
    while (it.next()) |row| {
        try std.testing.expect(text_width.ansiVisibleWidth(row) <= columns - 1);
    }
}

test "renderDiff clips the footer to a narrow terminal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after = try numberedLines(arena, 30, &.{});
    const rendered = try renderDiff(arena, "a.txt", "", after, 20);
    try std.testing.expect(rendered.rows > 0);
    try expectNoRowWraps(rendered.text, 20);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "more") != null);
}

test "renderDiff shows nothing when the gutter alone would wrap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after = try numberedLines(arena, 30, &.{});
    // Two-digit numbers need a gutter of eight cells plus the spare one.
    const rendered = try renderDiff(arena, "a.txt", "", after, 8);
    try std.testing.expectEqual(@as(usize, 0), rendered.rows);
    try std.testing.expectEqualStrings("", rendered.text);
    const just_fits = try renderDiff(arena, "a.txt", "", after, 9);
    try std.testing.expect(just_fits.rows > 0);
    try expectNoRowWraps(just_fits.text, 9);
}
