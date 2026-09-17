const std = @import("std");

/// A minimal screen model that interprets the escape sequences the renderer
/// emits, so tests can assert on the final visible layout.
pub const FakeScreen = struct {
    rows: std.ArrayList(std.ArrayList(u8)) = .empty,
    cur_row: usize = 0,
    cur_col: usize = 0,

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
                                const row = &self.rows.items[self.cur_row];
                                try row.resize(allocator, self.cur_col);
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
            } else {
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
        try row.resize(allocator, self.cur_col);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bc") != null);
}
