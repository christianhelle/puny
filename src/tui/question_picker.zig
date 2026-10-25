const std = @import("std");
const list_picker = @import("list_picker.zig");
const terminal = @import("terminal.zig");
const ansi = @import("ansi.zig");
const text_width = @import("markdown/width.zig");
const input = @import("input.zig");
const FakeScreen = @import("fake_screen.zig").FakeScreen;

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

const chose_prefix = "The user chose: ";
const answered_prefix = "The user answered: ";
const dismissed_result = "The user dismissed the choices and will answer in their next message. End your turn now.";

/// The ask_user tool result that reports `answer` back to the model.
pub fn toolResult(arena: std.mem.Allocator, answer: Answer) ![]const u8 {
    return switch (answer) {
        .picked => |text| std.fmt.allocPrint(arena, chose_prefix ++ "{s}", .{text}),
        .typed => |text| std.fmt.allocPrint(arena, answered_prefix ++ "{s}", .{text}),
        .cancelled => dismissed_result,
    };
}

/// Whether `result` came from `toolResult`, meaning ask_user reached the
/// picker and printed its answer row, rather than failing before it.
pub fn isAnswerResult(result: []const u8) bool {
    return std.mem.startsWith(u8, result, chose_prefix) or
        std.mem.startsWith(u8, result, answered_prefix) or
        std.mem.eql(u8, result, dismissed_result);
}

const hint = "Arrow keys to move, Enter to select, 'q' to dismiss";
const typed_prompt = "Your answer: ";

/// Asks `question` and lets the user pick one of `options` or type their
/// own answer, then replaces the picker with one `↳ answer` row under the
/// tool call line. Without a terminal to ask on, reports it as dismissed.
pub fn ask(arena: std.mem.Allocator, io: std.Io, question: []const u8, options: []const []const u8, recommended: ?[]const u8) !Answer {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    return askOn(Console, arena, io, &stdout_file_writer.interface, question, options, recommended);
}

/// Terminal access behind `askOn`; tests substitute a fake.
const Console = struct {
    fn isTty(io: std.Io) bool {
        return std.Io.File.stdin().isTty(io) catch false;
    }

    fn width() usize {
        return terminal.terminalWidth() orelse 80;
    }

    fn select(arena: std.mem.Allocator, io: std.Io, stdout_writer: *std.Io.Writer, title: []const u8, items: []const list_picker.Item) !?[]const u8 {
        // The picker writes through its own stdout writer.
        try stdout_writer.flush();
        return list_picker.selectFromList(arena, io, title, items);
    }

    const readLine = input.readLineSimple;
};

fn askOn(
    comptime C: type,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    question: []const u8,
    options: []const []const u8,
    recommended: ?[]const u8,
) !Answer {
    if (!C.isTty(io)) {
        // Still leave the one answer row the chat loop counts on.
        try stdout_writer.print("\n{s}↳ {s}{s}", .{ ansi.dim, echoText(.cancelled, 80), ansi.reset });
        try stdout_writer.flush();
        return .cancelled;
    }

    // The picker draws in raw mode, where a bare newline doesn't return the
    // carriage, so the question goes on one (possibly wrapping) line.
    const one_line_question = try std.mem.replaceOwned(u8, arena, question, "\n", " ");
    const title = try std.fmt.allocPrint(arena, "{s}\r\n{s}{s}{s}", .{ one_line_question, ansi.dim, hint, ansi.reset });
    const items = try answerItems(arena, options, recommended);
    const selected = try C.select(arena, io, stdout_writer, title, items);

    const width = C.width();

    const answer: Answer = if (selected) |value|
        if (std.mem.eql(u8, value, other_value)) try readTypedAnswer(C, arena, io, stdout_writer, width) else .{ .picked = value }
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
fn readTypedAnswer(comptime C: type, arena: std.mem.Allocator, io: std.Io, stdout_writer: *std.Io.Writer, width: usize) !Answer {
    try stdout_writer.print(terminal.clear_line ++ "{s}", .{typed_prompt});
    try stdout_writer.flush();

    var line: std.Io.Writer.Allocating = .init(arena);
    var stdin_buffer: [4096]u8 = undefined;
    const submitted = try C.readLine(arena, io, stdout_writer, &line, &stdin_buffer);

    // The prompt and the text are on screen. Submitting also moved the
    // cursor below them; Esc left it on their last row.
    const echoed = try std.fmt.allocPrint(arena, "{s}{s}", .{ typed_prompt, line.written() });
    const rows_up = if (submitted != null) rowsFor(echoed, width) else rowsFor(echoed, width) - 1;
    if (rows_up > 0) try stdout_writer.print(terminal.cursor_up, .{rows_up});
    try stdout_writer.writeAll(terminal.move_to_line_start);

    const text = std.mem.trim(u8, submitted orelse "", &std.ascii.whitespace);
    return if (text.len == 0) .cancelled else .{ .typed = text };
}

/// Terminal rows that one line of `text` occupies at `width` columns,
/// counted in display cells. A wide character that doesn't fit the cell left
/// on a row wraps whole onto the next one, as terminals do.
pub fn rowsFor(text: []const u8, width: usize) usize {
    const columns = @max(width, 1);
    var rows: usize = 1;
    var column: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq_len, text.len);
        const cells = if (std.unicode.utf8Decode(text[i..end])) |cp| text_width.codePointWidth(cp) else |_| 1;
        i = end;
        if (column + cells > columns) {
            rows += 1;
            column = 0;
        }
        column += cells;
    }
    return rows;
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

test "rowsFor counts wide characters as two cells" {
    // 41 CJK characters take 82 cells, so they wrap at 80 columns.
    const question = "数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数数";
    try std.testing.expectEqual(@as(usize, 2), rowsFor(question, 80));
    // A wide character that doesn't fit the cell left on a row wraps whole.
    try std.testing.expectEqual(@as(usize, 2), rowsFor("a数", 2));
    // Combining marks take no cell of their own.
    try std.testing.expectEqual(@as(usize, 1), rowsFor("e\u{0301}e\u{0301}", 2));
}

/// Stands in for the terminal: draws and clears the picker the way
/// `list_picker.selectFromList` does, and echoes typed text like the line
/// editor.
const FakeConsole = struct {
    var tty = true;
    var columns: usize = 80;
    /// Value the picker returns; null when the user pressed q or Esc.
    var picked: ?[]const u8 = null;
    var typed: []const u8 = "";
    /// Whether Enter ended the typed line, rather than Esc.
    var submitted = true;

    fn reset() void {
        tty = true;
        columns = 80;
        picked = null;
        typed = "";
        submitted = true;
    }

    fn isTty(_: std.Io) bool {
        return tty;
    }

    fn width() usize {
        return columns;
    }

    fn select(_: std.mem.Allocator, _: std.Io, stdout_writer: *std.Io.Writer, title: []const u8, items: []const list_picker.Item) !?[]const u8 {
        try stdout_writer.print("\r\n\r\n{s}\r\n", .{title});
        for (items) |item| try stdout_writer.print("  {s}\r\n", .{item.label});
        try stdout_writer.print(terminal.move_to_line_start ++ terminal.cursor_up ++ terminal.erase_display, .{items.len + 1});
        return picked;
    }

    fn readLine(_: std.mem.Allocator, _: std.Io, stdout_writer: *std.Io.Writer, line: *std.Io.Writer.Allocating, _: []u8) !?[]const u8 {
        try line.writer.writeAll(typed);
        try stdout_writer.writeAll(typed);
        if (!submitted) return null;
        try stdout_writer.writeAll("\r\n");
        return line.written();
    }
};

/// Screen left after asking, below a tool call line, with `FakeConsole`.
const AskedScreen = struct {
    answer: Answer,
    text: []const u8,
    cursor_row: usize,
};

fn askOnFakeScreen(arena: std.mem.Allocator, question: []const u8) !AskedScreen {
    var out = std.Io.Writer.Allocating.init(arena);
    const answer = try askOn(FakeConsole, arena, std.testing.io, &out.writer, question, &.{ "SQLite", "Postgres" }, "Postgres");

    var screen = FakeScreen{ .width = FakeConsole.columns };
    try screen.feed(arena, "🔧 Asking");
    try screen.feed(arena, out.written());
    return .{ .answer = answer, .text = try screen.toText(arena), .cursor_row = screen.cur_row };
}

test "ask replaces the picker with the picked answer under the tool call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    FakeConsole.reset();
    FakeConsole.picked = "Postgres";

    const asked = try askOnFakeScreen(arena_state.allocator(), "Which database?");
    try std.testing.expectEqualStrings("Postgres", asked.answer.picked);
    try std.testing.expectEqualStrings("🔧 Asking\n↳ Postgres", asked.text);
    try std.testing.expectEqual(@as(usize, 1), asked.cursor_row);
}

test "ask replaces the picker and the typed line with the typed answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    FakeConsole.reset();
    FakeConsole.picked = other_value;
    FakeConsole.typed = "  DuckDB ";

    const asked = try askOnFakeScreen(arena_state.allocator(), "Which database?");
    try std.testing.expectEqualStrings("DuckDB", asked.answer.typed);
    try std.testing.expectEqualStrings("🔧 Asking\n↳ DuckDB", asked.text);
    try std.testing.expectEqual(@as(usize, 1), asked.cursor_row);
}

test "ask dismisses the question when the user presses Esc while typing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    FakeConsole.reset();
    FakeConsole.picked = other_value;
    FakeConsole.typed = "Duck";
    FakeConsole.submitted = false;

    const asked = try askOnFakeScreen(arena_state.allocator(), "Which database?");
    try std.testing.expect(asked.answer == .cancelled);
    try std.testing.expectEqualStrings("🔧 Asking\n↳ cancelled", asked.text);
    try std.testing.expectEqual(@as(usize, 1), asked.cursor_row);
}

test "ask dismisses the question when the typed answer is empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    FakeConsole.reset();
    FakeConsole.picked = other_value;
    FakeConsole.typed = "   ";

    const asked = try askOnFakeScreen(arena_state.allocator(), "Which database?");
    try std.testing.expect(asked.answer == .cancelled);
    try std.testing.expectEqualStrings("🔧 Asking\n↳ cancelled", asked.text);
}

test "ask dismisses the question when the user quits the picker" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    FakeConsole.reset();

    const asked = try askOnFakeScreen(arena_state.allocator(), "Which database?");
    try std.testing.expect(asked.answer == .cancelled);
    try std.testing.expectEqualStrings("🔧 Asking\n↳ cancelled", asked.text);
    try std.testing.expectEqual(@as(usize, 1), asked.cursor_row);
}

test "ask dismisses the question without drawing a picker when stdin is not a terminal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    FakeConsole.reset();
    FakeConsole.tty = false;
    FakeConsole.picked = "Postgres";

    const asked = try askOnFakeScreen(arena_state.allocator(), "Which database?");
    try std.testing.expect(asked.answer == .cancelled);
    try std.testing.expectEqualStrings("🔧 Asking\n↳ cancelled", asked.text);
    try std.testing.expectEqual(@as(usize, 1), asked.cursor_row);
}

test "ask clears a question and a typed answer that wrap on a narrow terminal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    FakeConsole.reset();
    // Wide enough for the option labels, which the picker itself can't wrap.
    FakeConsole.columns = 32;
    FakeConsole.picked = other_value;
    FakeConsole.typed = "a much longer answer than fits";

    const asked = try askOnFakeScreen(arena_state.allocator(), "Which database should the app use\nfor sessions?");
    try std.testing.expectEqualStrings("a much longer answer than fits", asked.answer.typed);
    // The echo is cut to fit its row, leaving room for the "↳ " prefix.
    try std.testing.expectEqualStrings("🔧 Asking\n↳ a much longer answer than fi", asked.text);
    try std.testing.expectEqual(@as(usize, 1), asked.cursor_row);
}
