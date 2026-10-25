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

const title = "Choose an answer (Use arrow keys to navigate, Enter to select, 'q' to dismiss):";
const typed_prompt = "Your answer: ";

/// Asks the user to pick one of `options` or type their own answer, then
/// replaces the picker with one `↳ answer` row under the tool call line.
/// Without a terminal to ask on, reports the question as dismissed.
pub fn ask(arena: std.mem.Allocator, io: std.Io, options: []const []const u8, recommended: ?[]const u8) !Answer {
    if (!(std.Io.File.stdin().isTty(io) catch false)) return .cancelled;

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

    // The picker leaves the cursor on its title row, one blank row below the
    // tool call line. The echo takes that blank row.
    try stdout_writer.print(terminal.cursor_up ++ terminal.move_to_line_start ++ terminal.erase_display, .{1});
    try stdout_writer.print("{s}↳ {s}{s}", .{ ansi.dim, echoText(answer, width -| 4), ansi.reset });
    try stdout_writer.flush();
    return answer;
}

/// Reads one line typed on the picker's title row and returns the cursor to
/// the start of that row. An empty line counts as dismissing the question.
fn readTypedAnswer(arena: std.mem.Allocator, io: std.Io, stdout_writer: *std.Io.Writer, width: usize) !Answer {
    try stdout_writer.writeAll(typed_prompt);
    try stdout_writer.flush();

    var line: std.Io.Writer.Allocating = .init(arena);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    _ = stdin_file_reader.interface.streamDelimiterLimit(&line.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {},
        else => return err,
    };
    const text = std.mem.trim(u8, line.written(), &std.ascii.whitespace);

    // The terminal echoed the prompt, the text and the Enter that ended it.
    const rows = std.math.divCeil(usize, typed_prompt.len + line.written().len, @max(width, 1)) catch 1;
    try stdout_writer.print(terminal.cursor_up ++ terminal.move_to_line_start, .{@max(rows, 1)});

    return if (text.len == 0) .cancelled else .{ .typed = text };
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
