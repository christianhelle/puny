const std = @import("std");
const keys = @import("../tui/input/keys.zig");
const line_editor = @import("../tui/input/line_editor.zig");

/// A lock for the short critical sections shared with the cancel monitor
/// thread. Waiting threads spin, so never hold it across anything slow other
/// than a terminal write.
pub const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

/// Collects what the user types while the agent is busy. Keystrokes arrive one
/// byte at a time on the cancel monitor thread, and complete lines wait here
/// until the chat loop takes them from the main thread.
///
/// The line being typed goes through `LineEditor`, so editing keys behave as
/// they do at the prompt. Its echo is discarded; the input bar shows the text.
pub const TypeAhead = struct {
    allocator: std.mem.Allocator,
    mutex: SpinLock = .{},
    line: std.Io.Writer.Allocating,
    sink: std.Io.Writer.Discarding,
    /// Created on first use: it points into this struct, which must have
    /// reached its final address.
    editor_state: ?line_editor.LineEditor = null,
    lines: std.ArrayList([]u8) = .empty,
    state: enum { text, escape, csi, ss3 } = .text,
    csi_params: [16]u8 = undefined,
    csi_len: usize = 0,
    high_surrogate: ?u16 = null,

    const esc: u8 = 0x1b;

    pub const View = struct { text: []const u8, cursor: usize, queued: usize };

    pub fn init(allocator: std.mem.Allocator) TypeAhead {
        return .{
            .allocator = allocator,
            .line = .init(allocator),
            .sink = .init(&.{}),
        };
    }

    pub fn deinit(self: *TypeAhead) void {
        self.line.deinit();
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    fn editor(self: *TypeAhead) *line_editor.LineEditor {
        if (self.editor_state == null) {
            self.editor_state = line_editor.LineEditor.initWithPrompt(&self.line, &self.sink.writer, null, null, "");
            self.editor_state.?.mentions_enabled = false;
        }
        return &self.editor_state.?;
    }

    /// Takes one input byte. Running out of memory drops the keystroke, since
    /// the monitor thread has nobody to report the failure to.
    pub fn feed(self: *TypeAhead, byte: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.feedLocked(byte) catch {};
    }

    fn feedLocked(self: *TypeAhead, byte: u8) !void {
        switch (self.state) {
            .text => {},
            .escape => switch (byte) {
                esc => return,
                '[' => {
                    self.state = .csi;
                    self.csi_len = 0;
                    return;
                },
                'O' => {
                    self.state = .ss3;
                    return;
                },
                else => {
                    self.state = .text;
                    const key = keys.decodeAlt(byte);
                    if (key != .unknown) return self.editor().handleKey(key);
                },
            },
            .csi => {
                // Parameter and intermediate bytes run from 0x20 to 0x3F;
                // anything else ends the sequence.
                if (byte >= 0x20 and byte <= 0x3F) {
                    if (self.csi_len < self.csi_params.len) {
                        self.csi_params[self.csi_len] = byte;
                        self.csi_len += 1;
                    }
                    return;
                }
                self.state = .text;
                return self.editor().handleKey(keys.decodeCsi(self.csi_params[0..self.csi_len], byte));
            },
            .ss3 => {
                self.state = .text;
                return self.editor().handleKey(keys.decodeSs3(byte));
            },
        }

        const ed = self.editor();
        switch (byte) {
            '\r', '\n' => try self.completeLine(),
            0x7f, 0x08 => try ed.backspace(),
            esc => self.state = .escape,
            0x01 => try ed.moveHome(),
            0x02 => try ed.moveLeft(),
            0x04 => try ed.deleteForward(),
            0x05 => try ed.moveEnd(),
            0x06 => try ed.moveRight(),
            0x0b => try ed.killToEnd(),
            0x15 => try ed.killToStart(),
            0x17 => try ed.deleteWhitespaceWordBackward(),
            else => if (byte >= 0x20) try ed.append(byte),
        }
    }

    /// Call when input goes quiet: an Esc with nothing behind it was the key
    /// itself, so whatever comes next is not an Alt shortcut.
    pub fn settleEscape(self: *TypeAhead) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state == .escape) self.state = .text;
    }

    /// Takes one UTF-16 code unit, as the Windows console reports key presses.
    pub fn feedUtf16(self: *TypeAhead, unit: u16) void {
        if (unit == 0) return;
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return;
        }
        var code_point: u21 = unit;
        if (std.unicode.utf16IsLowSurrogate(unit)) {
            const high = self.high_surrogate orelse return;
            code_point = std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch return;
        }
        self.high_surrogate = null;

        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(code_point, &encoded) catch return;
        for (encoded[0..len]) |byte| self.feed(byte);
    }

    fn clearLine(self: *TypeAhead) void {
        self.line.clearRetainingCapacity();
        self.editor().cursor = 0;
    }

    fn completeLine(self: *TypeAhead) !void {
        defer self.clearLine();
        const text = std.mem.trim(u8, self.line.written(), &std.ascii.whitespace);
        if (text.len == 0) return;
        const line = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(line);
        try self.lines.append(self.allocator, line);
    }

    /// Copies the line being typed into `copy`, keeping its end if too long.
    pub fn snapshot(self: *TypeAhead, copy: []u8) View {
        self.mutex.lock();
        defer self.mutex.unlock();
        const text = self.line.written();
        var start = text.len -| copy.len;
        while (start < text.len and text[start] & 0xC0 == 0x80) start += 1;
        const kept = text[start..];
        @memcpy(copy[0..kept.len], kept);
        return .{
            .text = copy[0..kept.len],
            .cursor = self.editor().cursor -| start,
            .queued = self.lines.items.len,
        };
    }

    /// Hands over the completed lines, oldest first. The caller owns them.
    pub fn takeLines(self: *TypeAhead, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const taken = try allocator.alloc([]const u8, self.lines.items.len);
        for (self.lines.items, taken) |line, *copy| copy.* = try allocator.dupe(u8, line);
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.clearRetainingCapacity();
        return taken;
    }

    /// Hands over everything typed so far as one space-separated string, for
    /// the next prompt to start from. The caller owns it.
    pub fn takeAll(self: *TypeAhead, allocator: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var joined: std.ArrayList(u8) = .empty;
        errdefer joined.deinit(allocator);
        for (self.lines.items) |line| {
            if (joined.items.len > 0) try joined.append(allocator, ' ');
            try joined.appendSlice(allocator, line);
        }
        const unfinished = std.mem.trim(u8, self.line.written(), &std.ascii.whitespace);
        if (unfinished.len > 0) {
            if (joined.items.len > 0) try joined.append(allocator, ' ');
            try joined.appendSlice(allocator, unfinished);
        }
        const result = try joined.toOwnedSlice(allocator);

        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.clearRetainingCapacity();
        self.clearLine();
        self.state = .text;
        return result;
    }
};

fn feedAll(buffer: *TypeAhead, bytes: []const u8) void {
    for (bytes) |byte| buffer.feed(byte);
}

test "Enter queues the typed line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "also fix the tests\r");

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("also fix the tests", lines[0]);
}

test "Backspace removes a whole UTF-8 code point" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "caf\xc3\xa9\x7fe\r");

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqualStrings("cafe", lines[0]);
}

test "Backspace on an empty line does nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "\x7f\x08ok\r");

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqualStrings("ok", lines[0]);
}

test "control bytes stay out of the text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "a\x03b\x1ac\x07d\r");

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqualStrings("abcd", lines[0]);
}

test "keys that do not edit leave no escape sequence in the text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "a\x1b[Ab\x1b[1;5Bc\x1bOPd\r");

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqualStrings("abcd", lines[0]);
}

test "a lone Esc does not swallow the text after it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "\x1b\x1bhello\r");

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqualStrings("hello", lines[0]);
}

test "takeLines returns oldest first and leaves the unfinished line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "first\rsecond\rstill typ");

    const lines = try buffer.takeLines(arena);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("first", lines[0]);
    try std.testing.expectEqualStrings("second", lines[1]);
    try std.testing.expectEqual(@as(usize, 0), (try buffer.takeLines(arena)).len);

    feedAll(&buffer, "ing\r");
    try std.testing.expectEqualStrings("still typing", (try buffer.takeLines(arena))[0]);
}

test "takeAll joins completed lines and the unfinished line, then empties the buffer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "first\rsecond\rthi");

    try std.testing.expectEqualStrings("first second thi", try buffer.takeAll(arena));
    try std.testing.expectEqualStrings("", try buffer.takeAll(arena));
}

test "takeAll with only an unfinished line has no stray separator" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "only this");

    try std.testing.expectEqualStrings("only this", try buffer.takeAll(arena_state.allocator()));
}

test "feedUtf16 encodes console characters and ignores keys without one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    // 0 is what the console reports for keys like the arrows.
    for ([_]u16{ 'c', 0, 'a', 'f', 0x00e9, '\r' }) |unit| buffer.feedUtf16(unit);

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqualStrings("caf\xc3\xa9", lines[0]);
}

test "feedUtf16 joins a surrogate pair into one code point" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    for ([_]u16{ 0xd83d, 0xde00, '\r' }) |unit| buffer.feedUtf16(unit);

    const lines = try buffer.takeLines(arena_state.allocator());
    try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", lines[0]);
}

test "arrow keys move the cursor so text can be inserted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "ac\x1b[Db\x1b[Cd\r");

    try std.testing.expectEqualStrings("abcd", (try buffer.takeLines(arena_state.allocator()))[0]);
}

test "line editing keys work like the prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "bc\x01a\r");
    try std.testing.expectEqualStrings("abc", (try buffer.takeLines(arena))[0]);
    feedAll(&buffer, "gone\x15kept\r");
    try std.testing.expectEqualStrings("kept", (try buffer.takeLines(arena))[0]);
    feedAll(&buffer, "one two\x17x\r");
    try std.testing.expectEqualStrings("one x", (try buffer.takeLines(arena))[0]);
    feedAll(&buffer, "abc\x1b[D\x1b[D\x1b[3~\r");
    try std.testing.expectEqualStrings("ac", (try buffer.takeLines(arena))[0]);
}

test "a completed line leaves the editor empty at column zero" {
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();
    var copy: [64]u8 = undefined;

    feedAll(&buffer, "done\rne");

    const view = buffer.snapshot(&copy);
    try std.testing.expectEqualStrings("ne", view.text);
    try std.testing.expectEqual(@as(usize, 2), view.cursor);
    try std.testing.expectEqual(@as(usize, 1), view.queued);
}

test "a blank line is not queued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "\r   \n");

    try std.testing.expectEqual(@as(usize, 0), (try buffer.takeLines(arena_state.allocator())).len);
}

test "Alt shortcuts edit like the prompt instead of typing letters" {
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();
    for ("one two") |byte| buffer.feed(byte);
    for ("\x1bb") |byte| buffer.feed(byte);
    for ("\x1bd") |byte| buffer.feed(byte);
    buffer.feed('\r');

    const lines = try buffer.takeLines(std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqualStrings("one", lines[0]);
}

test "Alt+Backspace deletes a word" {
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();
    for ("one two\x1b\x7f\r") |byte| buffer.feed(byte);

    const lines = try buffer.takeLines(std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqualStrings("one", lines[0]);
}

test "a letter typed after a lone Esc is text, not an Alt shortcut" {
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();
    buffer.feed(0x1b);
    buffer.settleEscape();
    for ("b\r") |byte| buffer.feed(byte);

    const lines = try buffer.takeLines(std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqualStrings("b", lines[0]);
}
