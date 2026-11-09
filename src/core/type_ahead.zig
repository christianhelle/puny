const std = @import("std");

/// Collects what the user types while the agent is busy. Keystrokes arrive one
/// byte at a time and complete lines wait here until the chat loop takes them.
///
/// Not locked: the cancel monitor thread is the only writer while it runs, and
/// `cancel.stop` joins that thread before the main thread reads the buffer.
pub const TypeAhead = struct {
    allocator: std.mem.Allocator,
    partial: std.ArrayList(u8) = .empty,
    lines: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) TypeAhead {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TypeAhead) void {
        self.partial.deinit(self.allocator);
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    /// Takes one input byte. Running out of memory drops the keystroke, since
    /// the monitor thread has nobody to report the failure to.
    pub fn feed(self: *TypeAhead, byte: u8) void {
        switch (byte) {
            '\r', '\n' => self.completeLine() catch {},
            0x7f, 0x08 => self.deleteCodePoint(),
            else => self.partial.append(self.allocator, byte) catch {},
        }
    }

    fn deleteCodePoint(self: *TypeAhead) void {
        // UTF-8 continuation bytes look like 0b10xxxxxx; the lead byte does not.
        while (self.partial.pop()) |removed| {
            if (removed & 0xC0 != 0x80) break;
        }
    }

    fn completeLine(self: *TypeAhead) !void {
        defer self.partial.clearRetainingCapacity();
        const text = std.mem.trim(u8, self.partial.items, &std.ascii.whitespace);
        if (text.len == 0) return;
        const line = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(line);
        try self.lines.append(self.allocator, line);
    }

    /// Hands over the completed lines, oldest first. The caller owns them.
    pub fn takeLines(self: *TypeAhead, allocator: std.mem.Allocator) ![]const []const u8 {
        const taken = try allocator.alloc([]const u8, self.lines.items.len);
        for (self.lines.items, taken) |line, *copy| copy.* = try allocator.dupe(u8, line);
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.clearRetainingCapacity();
        return taken;
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

test "a blank line is not queued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer = TypeAhead.init(std.testing.allocator);
    defer buffer.deinit();

    feedAll(&buffer, "\r   \n");

    try std.testing.expectEqual(@as(usize, 0), (try buffer.takeLines(arena_state.allocator())).len);
}
