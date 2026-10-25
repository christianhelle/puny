const std = @import("std");
const list_picker = @import("list_picker.zig");
const terminal = @import("terminal.zig");
const ansi = @import("ansi.zig");

/// Value of the trailing item that lets the user type an answer the
/// options don't cover.
pub const other_value = "\x00other";

/// Picker items for a multiple choice question: each option in the order
/// given, the one matching `recommended` labelled as such, then "Other".
pub fn answerItems(arena: std.mem.Allocator, options: []const []const u8, recommended: ?[]const u8) ![]const list_picker.Item {
    const items = try arena.alloc(list_picker.Item, options.len + 1);
    for (options, 0..) |option, i| {
        const is_recommended = if (recommended) |r| std.mem.eql(u8, r, option) else false;
        items[i] = .{
            .value = option,
            .label = if (is_recommended) try std.fmt.allocPrint(arena, "{s} (recommended)", .{option}) else option,
        };
    }
    items[options.len] = .{ .value = other_value, .label = "Other (type your own answer)" };
    return items;
}

/// How the user responded to a multiple choice question.
pub const Answer = union(enum) {
    picked: []const u8,
    typed: []const u8,
    cancelled,
};

/// The ask_user tool result that reports `answer` back to the model.
pub fn toolResult(arena: std.mem.Allocator, answer: Answer) ![]const u8 {
    return switch (answer) {
        .picked => |text| std.fmt.allocPrint(arena, "The user chose: {s}", .{text}),
        .typed => |text| std.fmt.allocPrint(arena, "The user answered: {s}", .{text}),
        .cancelled => "The user dismissed the choices and will answer in their next message. End your turn now.",
    };
}

const hint = "Arrow keys to move, Enter to select, 'q' to dismiss";
const typed_prompt = "Your answer: ";

/// Asks `question` and lets the user pick one of `options` or type their
/// own answer, then replaces the picker with one `↳ answer` row under the
/// tool call line. Without a terminal to ask on, reports it as dismissed.
pub fn ask(arena: std.mem.Allocator, io: std.Io, question: []const u8, options: []const []const u8, recommended: ?[]const u8) !Answer {
    if (!(std.Io.File.stdin().isTty(io) catch false)) return .cancelled;

    // The picker draws in raw mode, where a bare newline doesn't return the
    // carriage, so the question goes on one (possibly wrapping) line.
    const one_line_question = try std.mem.replaceOwned(u8, arena, question, "\n", " ");
    const title = try std.fmt.allocPrint(arena, "{s}\r\n{s}{s}{s}", .{ one_line_question, ansi.dim, hint, ansi.reset });
    const items = try answerItems(arena, options, recommended);
    const selected = try list_picker.selectFromList(arena, io, title, items);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    const width = terminal.terminalWidth() orelse 80;

    const answer: Answer = if (selected) |value|
        if (std.mem.eql(u8, value, other_value)) try readTypedAnswer(arena, io, stdout_writer, width) else .{ .picked = value }
    else
        .cancelled;

    // The picker leaves the cursor on the last row of its title, which sits
    // one blank row below the tool call line. The echo takes that blank row.
    const title_rows = rowsFor(one_line_question, width) + rowsFor(hint, width);
    try stdout_writer.print(terminal.cursor_up ++ terminal.move_to_line_start ++ terminal.erase_display, .{title_rows});
    try stdout_writer.print("{s}↳ {s}{s}", .{ ansi.dim, echoText(answer, width -| 4), ansi.reset });
    try stdout_writer.flush();
    return answer;
}

/// Reads one line typed on the picker's last title row and returns the
/// cursor to the start of that row. An empty line dismisses the question.
fn readTypedAnswer(arena: std.mem.Allocator, io: std.Io, stdout_writer: *std.Io.Writer, width: usize) !Answer {
    try stdout_writer.print(terminal.clear_line ++ "{s}", .{typed_prompt});
    try stdout_writer.flush();

    var line: std.Io.Writer.Allocating = .init(arena);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    _ = stdin_file_reader.interface.streamDelimiterLimit(&line.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {},
        else => return err,
    };

    // The terminal echoed the prompt, the text and the Enter that ended it.
    const echoed = try std.fmt.allocPrint(arena, "{s}{s}", .{ typed_prompt, line.written() });
    try stdout_writer.print(terminal.cursor_up ++ terminal.move_to_line_start, .{rowsFor(echoed, width)});

    const text = std.mem.trim(u8, line.written(), &std.ascii.whitespace);
    return if (text.len == 0) .cancelled else .{ .typed = text };
}

/// Terminal rows that one line of `text` occupies at `width` columns,
/// treating each character as one column.
pub fn rowsFor(text: []const u8, width: usize) usize {
    const columns = std.unicode.utf8CountCodepoints(text) catch text.len;
    return @max(std.math.divCeil(usize, columns, @max(width, 1)) catch 1, 1);
}

/// The answer as echoed under the question, cut to at most `max_bytes` so
/// it never wraps: the indicator rewinds a counted number of rows.
pub fn echoText(answer: Answer, max_bytes: usize) []const u8 {
    const text = switch (answer) {
        .picked, .typed => |t| t,
        .cancelled => "cancelled",
    };
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

test "answerItems lists the options, marks the recommended one and offers Other last" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const items = try answerItems(arena_state.allocator(), &.{ "SQLite", "Postgres" }, "Postgres");
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("SQLite", items[0].value);
    try std.testing.expectEqualStrings("SQLite", items[0].label);
    try std.testing.expectEqualStrings("Postgres", items[1].value);
    try std.testing.expectEqualStrings("Postgres (recommended)", items[1].label);
    try std.testing.expectEqualStrings(other_value, items[2].value);
    try std.testing.expectEqualStrings("Other (type your own answer)", items[2].label);
}

test "toolResult tells the model which answer the user gave" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("The user chose: Postgres", try toolResult(arena, .{ .picked = "Postgres" }));
    try std.testing.expectEqualStrings("The user answered: use DuckDB", try toolResult(arena, .{ .typed = "use DuckDB" }));
    try std.testing.expectEqualStrings(
        "The user dismissed the choices and will answer in their next message. End your turn now.",
        try toolResult(arena, .cancelled),
    );
}

test "echoText shows the answer and fits it on one terminal row" {
    try std.testing.expectEqualStrings("Postgres", echoText(.{ .picked = "Postgres" }, 80));
    try std.testing.expectEqualStrings("use Duck", echoText(.{ .typed = "use DuckDB" }, 8));
    try std.testing.expectEqualStrings("cancelled", echoText(.cancelled, 80));
    // Never splits a multi-byte character.
    try std.testing.expectEqualStrings("caf", echoText(.{ .typed = "café" }, 4));
}

test "rowsFor counts the terminal rows a line of text wraps onto" {
    try std.testing.expectEqual(@as(usize, 1), rowsFor("", 80));
    try std.testing.expectEqual(@as(usize, 1), rowsFor("Which database?", 80));
    const full_row: [80]u8 = @splat('x');
    const one_over: [81]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, 1), rowsFor(&full_row, 80));
    try std.testing.expectEqual(@as(usize, 2), rowsFor(&one_over, 80));
    // Counts characters, not bytes: four two-byte characters fit four columns.
    try std.testing.expectEqual(@as(usize, 1), rowsFor("éééé", 4));
}
