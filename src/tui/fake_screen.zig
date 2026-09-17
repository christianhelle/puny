const std = @import("std");

/// A minimal screen model that interprets the escape sequences the renderer
/// emits, so tests can assert on the final visible layout.
pub const FakeScreen = struct {
    rows: std.ArrayList(std.ArrayList(u8)) = .empty,
    cur_row: usize = 0,
    cur_col: usize = 0,
    /// Columns before printed text wraps to the next row; null never wraps.
    width: ?usize = null,

    pub fn deinit(self: *FakeScreen, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*r| r.deinit(allocator);
        self.rows.deinit(allocator);
    }

    pub fn feed(self: *FakeScreen, allocator: std.mem.Allocator, data: []const u8) !void {
        var i: usize = 0;
        while (i < data.len) {
            const c = data[i];
            if (c == 0x1b) {
                i += 1;
                if (i >= data.len) break;
                if (data[i] == '[') {
                    i += 1;
                    var num: usize = 0;
                    var has_num = false;
                    while (i < data.len) {
                        const b = data[i];
                        if (b >= '0' and b <= '9') {
                            num = num * 10 + (b - '0');
                            has_num = true;
                            i += 1;
                        } else if (b == ';' or b == ':') {
                            i += 1;
                        } else break;
                    }
                    if (i < data.len) {
                        const final = data[i];
                        i += 1;
                        switch (final) {
                            'A' => self.cur_row -|= if (has_num) num else 1,
                            'B' => self.cur_row = @min(self.rows.items.len, self.cur_row + (if (has_num) num else 1)),
                            'G' => self.cur_col = 0,
                            'J' => try self.eraseToEnd(allocator),
                            'K' => {
                                while (self.rows.items.len <= self.cur_row) {
                                    try self.rows.append(allocator, .empty);
                                }
                                const row = &self.rows.items[self.cur_row];
                                // CSI 2 K clears the whole line; otherwise erase from the cursor.
                                const keep = if (has_num and num == 2) 0 else self.cur_col;
                                if (row.items.len > keep) row.shrinkRetainingCapacity(keep);
                            },
                            'M' => {
                                if (self.cur_row < self.rows.items.len) {
                                    var row = self.rows.orderedRemove(self.cur_row);
                                    row.deinit(allocator);
                                }
                            },
                            'm' => {},
                            else => {},
                        }
                    }
                }
                continue;
            }
            if (c == '\r') {
                self.cur_col = 0;
            } else if (c == '\n') {
                self.cur_row += 1;
                self.cur_col = 0;
            } else if (c & 0xC0 == 0x80) {
                // UTF-8 continuation bytes belong to the column already taken.
                if (self.cur_row < self.rows.items.len) {
                    try self.rows.items[self.cur_row].append(allocator, c);
                }
            } else {
                if (self.width) |w| {
                    if (self.cur_col >= w) {
                        self.cur_row += 1;
                        self.cur_col = 0;
                    }
                }
                while (self.rows.items.len <= self.cur_row) {
                    try self.rows.append(allocator, .empty);
                }
                const row = &self.rows.items[self.cur_row];
                while (row.items.len < self.cur_col) try row.append(allocator, ' ');
                try row.append(allocator, c);
                self.cur_col += 1;
            }
            i += 1;
        }
    }

    fn eraseToEnd(self: *FakeScreen, allocator: std.mem.Allocator) !void {
        while (self.rows.items.len <= self.cur_row) {
            try self.rows.append(allocator, .empty);
        }
        const row = &self.rows.items[self.cur_row];
        if (row.items.len > self.cur_col) row.shrinkRetainingCapacity(self.cur_col);
        for (self.rows.items[self.cur_row + 1 ..]) |*r| r.deinit(allocator);
        try self.rows.resize(allocator, self.cur_row + 1);
    }

    pub fn toText(self: *FakeScreen, allocator: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        var last_non_empty: usize = 0;
        for (self.rows.items, 0..) |row, idx| {
            if (row.items.len > 0) last_non_empty = idx + 1;
        }
        for (self.rows.items[0..last_non_empty], 0..) |row, idx| {
            if (idx > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, row.items);
        }
        return out.toOwnedSlice(allocator);
    }
};

test "FakeScreen handles dangling escapes, cursor moves, and erases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = FakeScreen{};
    defer screen.deinit(arena);

    try screen.feed(arena, "a\nbc\x1b[1A");
    try screen.feed(arena, "X");
    try screen.feed(arena, "\x1b[1B");
    try screen.feed(arena, "Y\x1b");
    try screen.feed(arena, "\x1b[");
    try screen.feed(arena, "\x1b[2K");
    try screen.feed(arena, "\x1b[1B");
    try screen.feed(arena, "\x1b[0J");
    try screen.feed(arena, "\x1b[3;5A");

    const text = try screen.toText(arena);
    defer arena.free(text);
    // CSI 2 K wiped the "bcY" row; the padded "X" stays on the first row.
    try std.testing.expectEqualStrings("a X", text);
}

test "FakeScreen deletes the cursor row and shifts later rows up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = FakeScreen{};
    defer screen.deinit(arena);

    try screen.feed(arena, "one\ntwo\nthree\x1b[1A\x1b[M");

    const text = try screen.toText(arena);
    try std.testing.expectEqualStrings("one\nthree", text);
}

test "FakeScreen wraps printed text at its width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = FakeScreen{ .width = 3 };
    defer screen.deinit(arena);

    try screen.feed(arena, "abcdef\nxyz\r\n→ab");

    const text = try screen.toText(arena);
    try std.testing.expectEqualStrings("abc\ndef\nxyz\n→ab", text);
}

test "FakeScreen clears to the end of the line or the whole line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = FakeScreen{};
    defer screen.deinit(arena);

    // Erase from the cursor, then the whole line, then on a row not drawn yet.
    try screen.feed(arena, "abcdef\nxy\x1b[1A\x1b[K");
    try screen.feed(arena, "\x1b[1B\x1b[2K");
    try screen.feed(arena, "\n\n\x1b[Kz");

    const text = try screen.toText(arena);
    try std.testing.expectEqualStrings("ab\n\n\nz", text);
}
