const std = @import("std");
const cancel = @import("../../core/cancel.zig");
const common = @import("./common.zig");
const keys = @import("./keys.zig");
const line_editor = @import("./line_editor.zig");
const mention = @import("./mention.zig");
const sigint = @import("../../core/sigint.zig");
const terminal = @import("../terminal.zig");

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

pub fn readLinePosix(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *line_editor.LineEditor,
) !common.ReadLineResult {
    var stdin: StdinSource = .{};
    return readLineFrom(allocator, io, editor, &stdin, cancel.eraseIsCtrlH());
}

/// Edits the prompt from the bytes of `source`, which provides `read()`
/// (blocks; null at end of input), `readWithTimeout(ms)` (null when
/// nothing arrives in time), and `suspendJob()` (returns once the stopped
/// job is continued).
fn readLineFrom(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *line_editor.LineEditor,
    source: anytype,
    erase_is_ctrl_h: bool,
) !common.ReadLineResult {
    var first_esc_ts: ?std.Io.Timestamp = null;

    while (true) {
        const byte = try source.read() orelse return .eof;
        if (byte != terminal.control.esc) first_esc_ts = null;
        switch (byte) {
            '\r', '\n' => {
                try editor.moveEnd();
                return .{ .submitted = editor.line_alloc.written() };
            },
            terminal.control.del => try editor.backspace(),
            // Ctrl+Backspace, unless the terminal's Backspace itself sends ^H.
            terminal.control.bs => if (erase_is_ctrl_h) try editor.backspace() else try editor.deleteWordBackward(),
            terminal.control.etx => {
                try editor.moveEnd();
                sigint.trigger();
                return .interrupted;
            },
            // Raw mode turns the terminal's suspend key off, so stop the job
            // here and bring the prompt back once the shell continues it.
            terminal.control.sub => {
                try editor.leave();
                source.suspendJob();
                try editor.reshow();
            },
            // Ctrl+D deletes forward, and cancels only on an empty prompt.
            terminal.control.eot => if (editor.line_alloc.written().len == 0) return .cancelled else try editor.deleteForward(),
            terminal.control.soh => try editor.moveHome(),
            terminal.control.stx => try editor.moveLeft(),
            terminal.control.enq => try editor.moveEnd(),
            terminal.control.ack => try editor.moveRight(),
            terminal.control.vt => try editor.killToEnd(),
            terminal.control.nak => try editor.killToStart(),
            terminal.control.etb => try editor.deleteWhitespaceWordBackward(),
            terminal.control.esc => {
                // Try to interpret an escape sequence (arrow keys, etc.).
                // If nothing follows within a short window, treat as Esc.
                if (try source.readWithTimeout(terminal.escape_sequence_timeout_ms)) |next| {
                    first_esc_ts = null;
                    switch (next) {
                        // A second Esc inside the probe window is the second
                        // tap, unless a CSI follows (rxvt's Alt+arrow).
                        terminal.control.esc => {
                            if (try source.readWithTimeout(terminal.escape_sequence_timeout_ms) != terminal.csi_leader) {
                                try editor.moveEnd();
                                return .cancelled;
                            }
                            try editor.handleKey(keys.withAlt(try readCsi(source)));
                        },
                        terminal.csi_leader => try editor.handleKey(try readCsi(source)),
                        terminal.ss3_leader => {
                            const final = try source.readWithTimeout(terminal.escape_sequence_timeout_ms) orelse continue;
                            try editor.handleKey(keys.decodeSs3(final));
                        },
                        else => {
                            const key = keys.decodeAlt(next);
                            if (key != .unknown) {
                                try editor.handleKey(key);
                            } else if (!terminal.isIgnoredControlByte(next)) {
                                // Not a recognized escape sequence; inject the byte as input.
                                try editor.append(next);
                            }
                        },
                    }
                    continue;
                }

                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) {
                        try editor.moveEnd();
                        return .cancelled;
                    }
                }
                first_esc_ts = now;
            },
            else => if (terminal.isIgnoredControlByte(byte)) {
                // Unbound control keys do nothing.
            } else if (byte == '@' and mention.isTrigger(editor.line_alloc.written()[0..editor.cursor])) {
                try mention.insertMention(allocator, io, editor);
            } else {
                try editor.append(byte);
            },
        }
    }
}

/// Reads the rest of a CSI sequence after `ESC [` and decodes it. Parameter
/// bytes beyond the buffer are consumed but dropped.
fn readCsi(source: anytype) !keys.Key {
    var params: [16]u8 = undefined;
    var len: usize = 0;
    while (try source.readWithTimeout(terminal.escape_sequence_timeout_ms)) |byte| {
        // Parameter and intermediate bytes run from 0x20 to 0x3F; anything
        // else ends the sequence.
        if (byte < 0x20 or byte > 0x3F) return keys.decodeCsi(params[0..len], byte);
        if (len < params.len) {
            params[len] = byte;
            len += 1;
        }
    }
    return .unknown;
}

/// Reads terminal input from stdin (fd 0).
const StdinSource = struct {
    fn read(_: *StdinSource) !?u8 {
        var buf: [1]u8 = undefined;
        const n = std.posix.read(0, &buf) catch return error.ReadFailed;
        if (n == 0) return null;
        return buf[0];
    }

    fn readWithTimeout(_: *StdinSource, timeout_ms: i32) !?u8 {
        const posix = std.posix;
        var pfd = [1]posix.pollfd{
            .{ .fd = 0, .events = posix.POLL.IN, .revents = undefined },
        };
        const rc = posix.poll(&pfd, timeout_ms) catch return error.ReadFailed;
        if (rc == 0) return null;
        if (pfd[0].revents & posix.POLL.IN == 0) return null;
        var buf: [1]u8 = undefined;
        const n = posix.read(0, &buf) catch return error.ReadFailed;
        if (n == 0) return null;
        return buf[0];
    }

    fn suspendJob(_: *StdinSource) void {
        cancel.suspendJob();
    }
};

/// Scripted terminal input for `readLineFrom`. A null event is a pause long
/// enough for a timed read to give up; a blocking read waits through it.
const TestSource = struct {
    events: []const ?u8,
    pos: usize = 0,
    suspends: usize = 0,

    fn read(self: *TestSource) !?u8 {
        while (self.pos < self.events.len) {
            defer self.pos += 1;
            if (self.events[self.pos]) |byte| return byte;
        }
        return null;
    }

    fn readWithTimeout(self: *TestSource, timeout_ms: i32) !?u8 {
        _ = timeout_ms;
        if (self.pos >= self.events.len) return null;
        defer self.pos += 1;
        return self.events[self.pos];
    }

    fn suspendJob(self: *TestSource) void {
        self.suspends += 1;
    }
};

const pause = [_]?u8{null};

fn input(comptime bytes: []const u8) [bytes.len]?u8 {
    var events: [bytes.len]?u8 = undefined;
    for (bytes, 0..) |byte, i| events[i] = byte;
    return events;
}

fn expectReadLine(
    events: []const ?u8,
    erase_is_ctrl_h: bool,
    expected: std.meta.Tag(common.ReadLineResult),
    expected_text: []const u8,
) !void {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var editor = line_editor.LineEditor.init(&line_alloc, &out.writer, null, 80);
    editor.mentions_enabled = false;
    var source: TestSource = .{ .events = events };
    const result = try readLineFrom(allocator, std.testing.io, &editor, &source, erase_is_ctrl_h);

    try std.testing.expectEqual(expected, std.meta.activeTag(result));
    try std.testing.expectEqualStrings(expected_text, line_alloc.written());
}

test "readLineFrom submits typed text on Enter" {
    try expectReadLine(&input("hello\r"), false, .submitted, "hello");
    try expectReadLine(&input("hi\n"), false, .submitted, "hi");
}

test "readLineFrom returns eof when input ends" {
    try expectReadLine(&input("hi"), false, .eof, "hi");
}

test "readLineFrom deletes a character on Backspace" {
    try expectReadLine(&input("ab\x7f\r"), false, .submitted, "a");
}

test "readLineFrom deletes a word on Ctrl+Backspace unless erase is Ctrl+H" {
    try expectReadLine(&input("one two\x08\r"), false, .submitted, "one ");
    try expectReadLine(&input("one two\x08\r"), true, .submitted, "one tw");
}

test "readLineFrom interrupts on Ctrl+C" {
    defer sigint.clear();
    try expectReadLine(&input("ab\x03"), false, .interrupted, "ab");
    try std.testing.expect(sigint.isTriggered());
}

test "readLineFrom cancels on Ctrl+D only when the prompt is empty" {
    try expectReadLine(&input("\x04"), false, .cancelled, "");
    try expectReadLine(&input("ab\x01\x04\r"), false, .submitted, "b");
}

test "readLineFrom moves the cursor with Ctrl+A, Ctrl+B, Ctrl+E, and Ctrl+F" {
    try expectReadLine(&input("bc\x01a\x05d\x02X\x06Y\r"), false, .submitted, "abcXdY");
}

test "readLineFrom kills text with Ctrl+W, Ctrl+K, and Ctrl+U" {
    try expectReadLine(&input("one two three\x17\r"), false, .submitted, "one two ");
    try expectReadLine(&input("abcd\x02\x02\x0b\r"), false, .submitted, "ab");
    try expectReadLine(&input("abcd\x02\x02\x15\r"), false, .submitted, "cd");
}

test "readLineFrom ignores unbound control bytes and inserts a literal @ without mentions" {
    try expectReadLine(&input("@a\x07\r"), false, .submitted, "@a");
}

test "readLineFrom applies CSI arrow keys" {
    try expectReadLine(&input("ac\x1b[Db\r"), false, .submitted, "abc");
    try expectReadLine(&input("one two\x1b[1;5DX\r"), false, .submitted, "one Xtwo");
    try expectReadLine(&input("a\x1b[Ab\r"), false, .submitted, "ab");
}

test "readLineFrom drops parameter bytes beyond the CSI buffer" {
    try expectReadLine(&input("ab\x1b[1;11111111111111111111DX\r"), false, .submitted, "aXb");
}

test "readLineFrom ignores a CSI sequence cut off by a pause" {
    try expectReadLine(&(input("a\x1b[") ++ pause ++ input("b\r")), false, .submitted, "ab");
}

test "readLineFrom applies SS3 keys and ignores a truncated SS3 sequence" {
    try expectReadLine(&input("bc\x1bOHa\r"), false, .submitted, "abc");
    try expectReadLine(&(input("a\x1bO") ++ pause ++ input("b\r")), false, .submitted, "ab");
}

test "readLineFrom applies readline Alt shortcuts" {
    try expectReadLine(&input("one two\x1bbX\r"), false, .submitted, "one Xtwo");
}

test "readLineFrom inserts the byte after Esc when it is not a shortcut" {
    try expectReadLine(&input("a\x1bx\r"), false, .submitted, "ax");
    try expectReadLine(&input("a\x1b\x07\r"), false, .submitted, "a");
}

test "readLineFrom cancels on two separate Esc taps" {
    try expectReadLine(&(input("ab\x1b") ++ pause ++ input("\x1b") ++ pause), false, .cancelled, "ab");
}

test "readLineFrom forgets a first Esc tap when another key follows" {
    try expectReadLine(&(input("\x1b") ++ pause ++ input("a\x1b") ++ pause ++ input("\r")), false, .submitted, "a");
}

test "readLineFrom cancels on a double Esc inside the sequence probe" {
    try expectReadLine(&(input("ab\x1b\x1b") ++ pause), false, .cancelled, "ab");
}

test "readLineFrom treats Esc Esc CSI as the Alt-modified key" {
    try expectReadLine(&input("one two\x1b\x1b[DX\r"), false, .submitted, "one Xtwo");
}

test "readLineFrom cancels on a double Esc followed by a non-CSI byte" {
    try expectReadLine(&input("a\x1b\x1bz\r"), false, .cancelled, "a");
}

test "readLineFrom suspends on Ctrl+Z and reshows the prompt on a fresh line" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var editor = line_editor.LineEditor.init(&line_alloc, &out.writer, null, 80);
    editor.mentions_enabled = false;
    var source: TestSource = .{ .events = &input("ab\x1ac\r") };
    const result = try readLineFrom(allocator, std.testing.io, &editor, &source, false);

    try std.testing.expectEqualStrings("abc", result.submitted);
    try std.testing.expectEqual(@as(usize, 1), source.suspends);
    try std.testing.expectEqualStrings("\r\x1b[J> a\r\x1b[J> ab\r\n\r\x1b[J> ab\r\x1b[J> abc", out.written());
}

test "readLineFrom reshows the prompt after Ctrl+Z when the terminal width is unknown" {
    const allocator = std.testing.allocator;
    var line_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var editor = line_editor.LineEditor.init(&line_alloc, &out.writer, null, null);
    editor.mentions_enabled = false;
    var source: TestSource = .{ .events = &input("ac\x02\x1ab\r") };
    const result = try readLineFrom(allocator, std.testing.io, &editor, &source, false);

    try std.testing.expectEqualStrings("abc", result.submitted);
    try std.testing.expectEqual(@as(usize, 1), source.suspends);
    try std.testing.expectEqualStrings("ac\x1b[1D\r\n> ac\x1b[1D\x1b[1Dabc\x1b[K\x1b[1D\x1b[1C", out.written());
}
