const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");
const common = @import("input/common.zig");
const line_editor = @import("input/line_editor.zig");
const posix = @import("input/posix.zig");
const prompt_history = @import("../prompts/history.zig");
const prompts = @import("../prompts/prompts.zig");
const terminal = @import("terminal.zig");
const windows_impl = @import("input/windows.zig");

pub const ReadLineResult = common.ReadLineResult;

pub fn readLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
    history: ?*prompt_history.History,
) !ReadLineResult {
    line_alloc.clearRetainingCapacity();
    if (history) |h| h.resetNavigation();

    try printPrompt(stdout_writer);

    cancel.setRawMode(true) catch {
        // Terminal does not support raw mode (e.g., piped stdin). Fall back
        // to canonical single-line input; Esc cancellation is unavailable.
        const result = try common.readLineCanonical(io, stdout_writer, line_alloc, stdin_buffer);
        const stdin_is_tty = std.Io.File.stdin().isTty(io) catch false;
        return endCanonicalPromptRow(stdout_writer, result, stdin_is_tty);
    };
    defer cancel.setRawMode(false) catch {};

    var editor = line_editor.LineEditor.init(line_alloc, stdout_writer, history, terminal.terminalWidth());
    const result = if (builtin.os.tag == .windows)
        try windows_impl.readLineWindows(allocator, io, &editor)
    else
        try posix.readLinePosix(allocator, io, &editor);
    return endPromptRow(stdout_writer, result);
}

/// Output before the prompt ends its own line, so one newline leaves a single
/// blank line above the prompt.
fn printPrompt(stdout_writer: *std.Io.Writer) !void {
    try stdout_writer.print("\n{s} ", .{prompts.prompt_text});
    try stdout_writer.flush();
}

/// Raw input leaves the cursor at the end of the prompt row. Ending that row,
/// as the terminal's own echo does for canonical input, lets whatever prints
/// next start on a fresh line. A cancelled prompt is re-shown by the caller.
fn endPromptRow(stdout_writer: *std.Io.Writer, result: ReadLineResult) !ReadLineResult {
    if (result != .cancelled) {
        try stdout_writer.writeAll("\r\n");
        try stdout_writer.flush();
    }
    return result;
}

/// A terminal in canonical mode echoes the Enter that submits a line, but
/// nothing echoes piped input or EOF, so end the prompt row only then.
fn endCanonicalPromptRow(stdout_writer: *std.Io.Writer, result: ReadLineResult, stdin_is_tty: bool) !ReadLineResult {
    if (stdin_is_tty and result == .submitted) return result;
    return endPromptRow(stdout_writer, result);
}

/// Reads a single line from stdin without printing a prompt, echoing input
/// itself in raw mode. Some terminals (Warp's ConPTY on Windows) never deliver
/// a line to a canonical-mode console read, so canonical input is only the
/// fallback when raw mode is unavailable (e.g., piped stdin).
/// Returns the line, or null on EOF, cancel, or interrupt.
pub fn readLineSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !?[]const u8 {
    return readPlainLine(Console, allocator, io, stdout_writer, line_alloc, stdin_buffer);
}

/// Terminal access behind `readPlainLine`; tests substitute a fake.
const Console = struct {
    const setRawMode = cancel.setRawMode;
    const readCanonical = readLineSimpleCanonical;

    fn readRaw(allocator: std.mem.Allocator, io: std.Io, editor: *line_editor.LineEditor) !ReadLineResult {
        return if (builtin.os.tag == .windows) windows_impl.readLineWindows(allocator, io, editor) else posix.readLinePosix(allocator, io, editor);
    }
};

fn readPlainLine(
    comptime C: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !?[]const u8 {
    line_alloc.clearRetainingCapacity();

    C.setRawMode(true) catch {
        return try C.readCanonical(io, line_alloc, stdin_buffer);
    };
    defer C.setRawMode(false) catch {};

    var editor = line_editor.LineEditor.init(line_alloc, stdout_writer, null, null);
    editor.mentions_enabled = false;
    editor.shows_prompt = false;

    return switch (try C.readRaw(allocator, io, &editor)) {
        .submitted => |text| {
            try stdout_writer.writeAll("\r\n");
            try stdout_writer.flush();
            return text;
        },
        .cancelled, .interrupted, .eof => null,
    };
}

fn readLineSimpleCanonical(
    io: std.Io,
    line_alloc: *std.Io.Writer.Allocating,
    stdin_buffer: []u8,
) !?[]const u8 {
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    const bytes_read = stdin_reader.streamDelimiterLimit(&line_alloc.writer, '\n', .limited(stdin_buffer.len)) catch |err| switch (err) {
        error.StreamTooLong => {
            return line_alloc.written();
        },
        else => return err,
    };
    if (bytes_read == 0) return null;

    const raw_message = line_alloc.written();
    const result = if (raw_message.len > 0 and raw_message[raw_message.len - 1] == '\r')
        raw_message[0 .. raw_message.len - 1]
    else
        raw_message;
    return result;
}

/// Scripted stand-in for the terminal used by the `readPlainLine` tests.
const FakeConsole = struct {
    var raw_available = true;
    var raw_enabled = false;
    var raw_result: ReadLineResult = .eof;
    var typed: []const u8 = "";
    var saw_mentions_enabled = true;

    fn reset(result: ReadLineResult) void {
        raw_available = true;
        raw_enabled = false;
        raw_result = result;
        typed = "";
        saw_mentions_enabled = true;
    }

    fn setRawMode(enable: bool) !void {
        if (!raw_available) return error.Unexpected;
        raw_enabled = enable;
    }

    fn readCanonical(_: std.Io, line_alloc: *std.Io.Writer.Allocating, _: []u8) !?[]const u8 {
        try line_alloc.writer.writeAll("canonical");
        return line_alloc.written();
    }

    fn readRaw(_: std.mem.Allocator, _: std.Io, editor: *line_editor.LineEditor) !ReadLineResult {
        try std.testing.expect(raw_enabled);
        saw_mentions_enabled = editor.mentions_enabled;
        try editor.line_alloc.writer.writeAll(typed);
        return switch (raw_result) {
            .submitted => .{ .submitted = editor.line_alloc.written() },
            else => raw_result,
        };
    }
};

test "readPlainLine returns the raw line, ends it with a newline, and restores the terminal" {
    FakeConsole.reset(.{ .submitted = "" });
    FakeConsole.typed = "sk-test@key";
    var line_alloc = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line_alloc.deinit();
    try line_alloc.writer.writeAll("stale");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stdin_buffer: [16]u8 = undefined;

    const line = try readPlainLine(FakeConsole, std.testing.allocator, std.testing.io, &out.writer, &line_alloc, &stdin_buffer);

    try std.testing.expectEqualStrings("sk-test@key", line.?);
    try std.testing.expectEqualStrings("\r\n", out.written());
    try std.testing.expect(!FakeConsole.saw_mentions_enabled);
    try std.testing.expect(!FakeConsole.raw_enabled);
}

test "readPlainLine returns null when the raw read is cancelled, interrupted, or ends" {
    const outcomes = [_]ReadLineResult{ .cancelled, .interrupted, .eof };
    for (outcomes) |outcome| {
        FakeConsole.reset(outcome);
        var line_alloc = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer line_alloc.deinit();
        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer out.deinit();
        var stdin_buffer: [16]u8 = undefined;

        const line = try readPlainLine(FakeConsole, std.testing.allocator, std.testing.io, &out.writer, &line_alloc, &stdin_buffer);

        try std.testing.expect(line == null);
        try std.testing.expectEqualStrings("", out.written());
        try std.testing.expect(!FakeConsole.raw_enabled);
    }
}

test "readPlainLine falls back to canonical input when raw mode is unavailable" {
    FakeConsole.reset(.eof);
    FakeConsole.raw_available = false;
    var line_alloc = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line_alloc.deinit();
    try line_alloc.writer.writeAll("stale");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stdin_buffer: [16]u8 = undefined;

    const line = try readPlainLine(FakeConsole, std.testing.allocator, std.testing.io, &out.writer, &line_alloc, &stdin_buffer);

    try std.testing.expectEqualStrings("canonical", line.?);
    try std.testing.expectEqualStrings("", out.written());
}

test "endPromptRow ends the prompt row unless the input was cancelled" {
    const outcomes = [_]ReadLineResult{ .{ .submitted = "hi" }, .interrupted, .eof, .cancelled };
    const expected = [_][]const u8{ "\r\n", "\r\n", "\r\n", "" };
    for (outcomes, expected) |outcome, written| {
        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer out.deinit();

        const result = try endPromptRow(&out.writer, outcome);

        try std.testing.expectEqual(std.meta.activeTag(outcome), std.meta.activeTag(result));
        try std.testing.expectEqualStrings(written, out.written());
    }
}

test "printPrompt leaves a single blank line above the prompt" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try printPrompt(&out.writer);

    try std.testing.expectEqualStrings("\n" ++ prompts.prompt_text ++ " ", out.written());
}

test "endCanonicalPromptRow ends the row only when the terminal did not echo it" {
    const Case = struct { result: ReadLineResult, stdin_is_tty: bool, written: []const u8 };
    const cases = [_]Case{
        .{ .result = .{ .submitted = "hi" }, .stdin_is_tty = true, .written = "" },
        .{ .result = .{ .submitted = "hi" }, .stdin_is_tty = false, .written = "\r\n" },
        .{ .result = .eof, .stdin_is_tty = true, .written = "\r\n" },
        .{ .result = .eof, .stdin_is_tty = false, .written = "\r\n" },
    };
    for (cases) |case| {
        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer out.deinit();

        const result = try endCanonicalPromptRow(&out.writer, case.result, case.stdin_is_tty);

        try std.testing.expectEqual(std.meta.activeTag(case.result), std.meta.activeTag(result));
        try std.testing.expectEqualStrings(case.written, out.written());
    }
}
