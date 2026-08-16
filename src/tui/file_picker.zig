const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const ansi = @import("ansi.zig");

/// Cap on the number of files collected so walking a huge repository cannot
/// exhaust memory before the user has even started typing.
const max_files = 4096;

/// Maximum number of list rows shown at once.
const max_visible = 20;

/// Directory depth beyond which the walker stops descending.
const max_depth = 32;

/// Case-insensitive substring match used to filter file paths as the user
/// types. An empty query matches every path.
pub fn matches(query: []const u8, path: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > path.len) return false;
    var i: usize = 0;
    while (i + query.len <= path.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(query, path[i .. i + query.len])) return true;
    }
    return false;
}

/// Returns only the paths from `files` that match `query`. The returned slice
/// aliases the entries of `files` (no copies are made of the path strings).
pub fn filterFiles(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    query: []const u8,
) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);
    for (files) |path| {
        if (matches(query, path)) try result.append(allocator, path);
    }
    return result.toOwnedSlice(allocator);
}

/// True when a directory should not be descended into while collecting files:
/// hidden dot-directories plus common build/dependency folders.
fn isIgnoredDir(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '.') return true;
    const ignored = [_][]const u8{ "node_modules", "zig-cache", "zig-out", "target", "dist", "build" };
    for (ignored) |i| {
        if (std.mem.eql(u8, name, i)) return true;
    }
    return false;
}

/// Platform path separator used to detect a leading "./" prefix.
const path_sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';

/// Normalizes a walked path for display: strips a leading "./" and, on
/// Windows, replaces backslashes with forward slashes so mentions stay
/// portable across platforms.
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const strip: usize = if (path.len >= 2 and path[0] == '.' and (path[1] == path_sep or path[1] == '/')) 2 else 0;
    const body = path[strip..];
    if (builtin.os.tag == .windows) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (body) |c| {
            try out.append(allocator, if (c == '\\') '/' else c);
        }
        return out.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, body);
}

/// Recursively collects regular files under `root_path`, skipping ignored
/// directories. Returns a sorted, allocator-owned list of normalized paths.
pub fn collectFiles(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) ![][]const u8 {
    const cwd = std.Io.Dir.cwd();
    var root = try cwd.openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!isIgnoredDir(entry.basename) and entry.depth() < max_depth) {
                    try walker.enter(io, entry);
                }
            },
            .file => {
                if (list.items.len >= max_files) break;
                const normalized = try normalizePath(allocator, entry.path);
                errdefer allocator.free(normalized);
                try list.append(allocator, normalized);
            },
            else => {},
        }
    }

    std.mem.sort([]const u8, list.items, {}, lessThanPath);
    return list.toOwnedSlice(allocator);
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Opens an interactive, searchable file picker. Assumes the terminal is
/// already in raw mode (it is invoked from within the prompt's read loop).
/// Returns the selected path (allocated from `arena`), or null when cancelled.
pub fn pickFile(arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_alloc = scratch.allocator();

    const files = collectFiles(scratch_alloc, io, ".") catch return null;
    if (files.len == 0) return null;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const writer = &stdout_file_writer.interface;

    var query: std.ArrayList(u8) = .empty;
    var match_indices: std.ArrayList(usize) = .empty;

    var selected: usize = 0;
    var offset: usize = 0;
    var drawn: usize = 0;

    try rebuildMatches(scratch_alloc, &match_indices, files, query.items);
    try render(writer, query.items, files, match_indices.items, selected, offset, &drawn);

    var reader = KeyReader{};
    while (true) {
        const key = reader.read(io) catch .unknown;
        switch (key) {
            .up => {
                if (match_indices.items.len == 0) continue;
                selected = if (selected == 0) match_indices.items.len - 1 else selected - 1;
                offset = scrollOffset(selected, offset);
                try render(writer, query.items, files, match_indices.items, selected, offset, &drawn);
            },
            .down => {
                if (match_indices.items.len == 0) continue;
                selected = if (selected + 1 < match_indices.items.len) selected + 1 else 0;
                offset = scrollOffset(selected, offset);
                try render(writer, query.items, files, match_indices.items, selected, offset, &drawn);
            },
            .backspace => {
                if (query.items.len == 0) continue;
                _ = query.pop();
                selected = 0;
                offset = 0;
                try rebuildMatches(scratch_alloc, &match_indices, files, query.items);
                try render(writer, query.items, files, match_indices.items, selected, offset, &drawn);
            },
            .char => |c| {
                try query.append(scratch_alloc, c);
                selected = 0;
                offset = 0;
                try rebuildMatches(scratch_alloc, &match_indices, files, query.items);
                try render(writer, query.items, files, match_indices.items, selected, offset, &drawn);
            },
            .enter => {
                try cleanup(writer, drawn);
                if (match_indices.items.len == 0) return null;
                const chosen: []const u8 = try arena.dupe(u8, files[match_indices.items[selected]]);
                return chosen;
            },
            .escape => {
                try cleanup(writer, drawn);
                return null;
            },
            .unknown => {},
        }
    }
}

fn rebuildMatches(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(usize),
    files: []const []const u8,
    query: []const u8,
) !void {
    out.clearRetainingCapacity();
    for (files, 0..) |path, i| {
        if (matches(query, path)) try out.append(allocator, i);
    }
}

fn scrollOffset(selected: usize, offset: usize) usize {
    if (selected < offset) return selected;
    if (selected >= offset + max_visible) return selected - max_visible + 1;
    return offset;
}

/// Renders the picker below the current input line and tracks how many rows
/// it occupies so a later redraw or cleanup can reposition the cursor.
fn render(
    writer: *std.Io.Writer,
    query: []const u8,
    files: []const []const u8,
    match_indices: []const usize,
    selected: usize,
    offset: usize,
    drawn: *usize,
) !void {
    if (drawn.* > 0) {
        // Return to the first picker row and erase the previous list so a
        // shorter result set never leaves stale rows behind.
        try writer.print(terminal.cursor_up, .{drawn.*});
        try writer.writeAll(terminal.erase_display);
    } else {
        // First draw: move from the input line to the row below it.
        try writer.writeAll("\r\n");
    }

    if (query.len == 0) {
        try writer.writeAll(ansi.bright);
        try writer.writeByte('@');
        try writer.writeAll(ansi.reset);
        try writer.writeAll("  ");
        try writer.writeAll(ansi.dim);
        try writer.writeAll("type to filter files");
        try writer.writeAll(ansi.reset);
        try writer.writeAll("\r\n");
    } else {
        try writer.writeAll(ansi.bright);
        try writer.writeByte('@');
        try writer.writeAll(query);
        try writer.writeAll(ansi.reset);
        try writer.writeAll("  ");
        try writer.writeAll(ansi.dim);
        try writer.print("{d} match(es)", .{match_indices.len});
        try writer.writeAll(ansi.reset);
        try writer.writeAll("\r\n");
    }

    if (match_indices.len == 0) {
        try writer.writeAll("  ");
        try writer.writeAll(ansi.dim);
        try writer.writeAll("no matches");
        try writer.writeAll(ansi.reset);
        try writer.writeAll("\r\n");
        drawn.* = 2;
        try writer.flush();
        return;
    }

    const visible = @min(max_visible, match_indices.len - offset);
    for (0..visible) |i| {
        const idx = offset + i;
        const path = files[match_indices[idx]];
        if (idx == selected) {
            try writer.writeAll(ansi.bright);
            try writer.writeAll("> ");
            try writer.writeAll(path);
            try writer.writeAll(ansi.reset);
        } else {
            try writer.writeAll("  ");
            try writer.writeAll(path);
        }
        try writer.writeAll("\r\n");
    }
    drawn.* = 1 + visible;
    try writer.flush();
}

/// Erases the picker and returns the cursor to the input row (one row above
/// the picker) so the editor's own redraw can restore the prompt line.
fn cleanup(writer: *std.Io.Writer, drawn: usize) !void {
    // Move to the first picker row and erase it and everything below it.
    try writer.print(terminal.cursor_up, .{drawn});
    try writer.writeAll(terminal.erase_display);
    // Step back up to the input row and reset the column.
    try writer.print(terminal.cursor_up, .{1});
    try writer.writeByte('\r');
    try writer.flush();
}

const Key = union(enum) {
    up,
    down,
    enter,
    escape,
    backspace,
    char: u8,
    unknown,
};

const KeyReader = struct {
    pending: [8]u8 = undefined,
    pending_len: usize = 0,

    fn read(self: *KeyReader, io: std.Io) !Key {
        if (builtin.os.tag == .windows) return self.readWindows(io);
        return self.readPosix(io);
    }

    fn readPosix(self: *KeyReader, io: std.Io) !Key {
        _ = io;
        const posix = std.posix;
        var buf: [8]u8 = undefined;
        var buf_len: usize = 0;

        if (self.pending_len > 0) {
            const copy_len = @min(self.pending_len, buf.len);
            @memcpy(buf[0..copy_len], self.pending[0..copy_len]);
            buf_len = copy_len;
            if (copy_len < self.pending_len) {
                @memcpy(self.pending[0 .. self.pending_len - copy_len], self.pending[copy_len..self.pending_len]);
            }
            self.pending_len -= copy_len;
        } else {
            const n = posix.read(0, buf[0..]) catch return error.ReadFailed;
            if (n == 0) return .unknown;
            buf_len = n;
        }

        if (buf[0] == 0x1b) {
            var seq: [8]u8 = undefined;
            var seq_len: usize = 0;
            const copy_len = @min(buf_len, seq.len);
            @memcpy(seq[0..copy_len], buf[0..copy_len]);
            seq_len = copy_len;

            while (seq_len < 8) {
                var pfd = [1]posix.pollfd{
                    .{ .fd = 0, .events = posix.POLL.IN, .revents = undefined },
                };
                const rc = posix.poll(&pfd, 30) catch break;
                if (rc == 0) break;
                const m = posix.read(0, seq[seq_len..][0..1]) catch break;
                if (m == 0) break;
                seq_len += 1;
            }

            var consumed: usize = 1;
            var result: Key = .escape;
            if (seq_len == 1) {
                result = .escape;
            } else if (seq_len >= 2 and seq[1] == '[') {
                consumed = 2;
                if (seq_len >= 3) {
                    consumed = 3;
                    result = switch (seq[2]) {
                        'A' => .up,
                        'B' => .down,
                        else => .unknown,
                    };
                } else {
                    result = .unknown;
                }
            }

            if (seq_len > consumed) {
                const remaining = seq_len - consumed;
                @memcpy(self.pending[0..remaining], seq[consumed..seq_len]);
                self.pending_len = remaining;
            }
            return result;
        }

        if (buf_len > 1) {
            @memcpy(self.pending[0 .. buf_len - 1], buf[1..buf_len]);
            self.pending_len = buf_len - 1;
        }

        return switch (buf[0]) {
            '\r', '\n' => .enter,
            0x08, 0x7f => .backspace,
            0x03, 0x04 => .escape,
            else => if (buf[0] >= 32) Key{ .char = buf[0] } else .unknown,
        };
    }

    fn readWindows(self: *KeyReader, io: std.Io) !Key {
        _ = self;
        _ = io;
        if (comptime builtin.os.tag != .windows) unreachable;
        const win = windows_api;
        const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
        const hStdin = win.GetStdHandle(STD_INPUT_HANDLE);

        while (true) {
            var record: win.INPUT_RECORD = undefined;
            var events_read: win.DWORD = 0;
            if (win.ReadConsoleInputW(hStdin, &record, 1, &events_read) == .FALSE) return error.ReadFailed;
            if (events_read == 0) continue;
            if (record.EventType != win.KEY_EVENT) continue;
            if (record.Event.KeyEvent.bKeyDown == .FALSE) continue;

            const vk = record.Event.KeyEvent.wVirtualKeyCode;
            switch (vk) {
                win.VK_UP => return .up,
                win.VK_DOWN => return .down,
                win.VK_RETURN => return .enter,
                win.VK_ESCAPE => return .escape,
                win.VK_BACK => return .backspace,
                else => {
                    const ch = record.Event.KeyEvent.uChar.UnicodeChar;
                    if (ch >= 32 and ch < 0x80) {
                        return Key{ .char = @intCast(ch) };
                    }
                    return .unknown;
                },
            }
        }
    }
};

const windows_api = if (builtin.os.tag == .windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;

    pub const VK_RETURN: u16 = 0x0D;
    pub const VK_BACK: u16 = 0x08;
    pub const VK_ESCAPE: u16 = 0x1B;
    pub const VK_UP: u16 = 0x26;
    pub const VK_DOWN: u16 = 0x28;
    pub const KEY_EVENT: u16 = 0x0001;

    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: BOOL,
        wRepeatCount: u16,
        wVirtualKeyCode: u16,
        wVirtualScanCode: u16,
        uChar: extern union {
            UnicodeChar: u16,
            AsciiChar: u8,
        },
        dwControlKeyState: DWORD,
    };

    pub const INPUT_RECORD = extern struct {
        EventType: u16,
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
        },
    };

    pub extern "kernel32" fn GetStdHandle(dwStdHandle: DWORD) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: *INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) BOOL;
} else void{};

test "matches returns true for an empty query" {
    try std.testing.expect(matches("", "anything/at/all.zig"));
}

test "matches is case-insensitive" {
    try std.testing.expect(matches("READ", "src/readme.md"));
    try std.testing.expect(matches("read", "src/README.md"));
}

test "matches finds substrings anywhere in the path" {
    try std.testing.expect(matches("pick", "src/tui/file_picker.zig"));
    try std.testing.expect(matches("file_picker", "src/tui/file_picker.zig"));
    try std.testing.expect(matches(".zig", "src/tui/file_picker.zig"));
}

test "matches returns false when the query is absent" {
    try std.testing.expect(!matches("models", "src/tui/file_picker.zig"));
}

test "matches returns false when the query is longer than the path" {
    try std.testing.expect(!matches("src/tui/file_picker.zig/extra", "src/tui/file_picker.zig"));
}

test "filterFiles keeps only matching paths" {
    const files = [_][]const u8{ "src/main.zig", "src/tui/input.zig", "tests/main_test.zig" };
    const result = try filterFiles(std.testing.allocator, &files, "tui");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("src/tui/input.zig", result[0]);
}

test "filterFiles returns everything for an empty query" {
    const files = [_][]const u8{ "a.zig", "b.zig", "c.zig" };
    const result = try filterFiles(std.testing.allocator, &files, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "normalizePath strips a leading ./ prefix" {
    const out = try normalizePath(std.testing.allocator, "./src/main.zig");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("src/main.zig", out);
}

test "normalizePath leaves bare paths untouched on non-Windows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const out = try normalizePath(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("src/main.zig", out);
}

fn containsPath(files: []const []const u8, needle: []const u8) bool {
    for (files) |f| {
        if (std.mem.eql(u8, f, needle)) return true;
    }
    return false;
}

fn freeFiles(allocator: std.mem.Allocator, files: [][]const u8) void {
    for (files) |f| allocator.free(f);
    allocator.free(files);
}

test "collectFiles finds files under the working directory" {
    const path_a = "puny-test-picker-a.txt";
    const path_b = "puny-test-picker-b.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path_a) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path_b) catch {};

    {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(std.testing.io, path_a, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "a");
    }
    {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(std.testing.io, path_b, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "b");
    }

    const files = try collectFiles(std.testing.allocator, std.testing.io, ".");
    defer freeFiles(std.testing.allocator, files);

    try std.testing.expect(containsPath(files, path_a));
    try std.testing.expect(containsPath(files, path_b));
}

test "render starts below the input line on the first draw" {
    const files = [_][]const u8{ "a.zig", "b.zig" };
    const match_indices = [_]usize{ 0, 1 };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var drawn: usize = 0;
    try render(&out.writer, "", &files, &match_indices, 0, 0, &drawn);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\r\n"));
    try std.testing.expectEqual(@as(usize, 3), drawn); // header + 2 rows
}

test "render redraws in place without appending a stray newline" {
    const files = [_][]const u8{ "a.zig", "b.zig" };
    const match_indices = [_]usize{ 0, 1 };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var drawn: usize = 3; // previous picker occupied 3 rows
    try render(&out.writer, "b", &files, &match_indices, 0, 0, &drawn);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\x1b[3A\x1b[J"));
}

test "cleanup erases the picker and returns to the input row" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try cleanup(&out.writer, 3);
    try std.testing.expectEqualStrings("\x1b[3A\x1b[J\x1b[1A\r", out.written());
}

test "render shows the type-to-filter hint for an empty query" {
    const files = [_][]const u8{ "a.zig", "b.zig" };
    const match_indices = [_]usize{ 0, 1 };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var drawn: usize = 0;
    try render(&out.writer, "", &files, &match_indices, 0, 0, &drawn);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "type to filter files") != null);
    try std.testing.expectEqual(@as(usize, 3), drawn);
}

test "render shows the match count for a non-empty query" {
    const files = [_][]const u8{ "a.zig", "b.zig" };
    const match_indices = [_]usize{ 1 };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var drawn: usize = 0;
    try render(&out.writer, "b", &files, &match_indices, 0, 0, &drawn);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "1 match(es)") != null);
    try std.testing.expectEqual(@as(usize, 2), drawn);
}

test "render reports two rows when nothing matches" {
    const files = [_][]const u8{ "a.zig", "b.zig" };
    const match_indices = [_]usize{};
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var drawn: usize = 0;
    try render(&out.writer, "zzz", &files, &match_indices, 0, 0, &drawn);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "no matches") != null);
    try std.testing.expectEqual(@as(usize, 2), drawn);
}

test "render highlights the selected row" {
    const files = [_][]const u8{ "a.zig", "b.zig" };
    const match_indices = [_]usize{ 0, 1 };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var drawn: usize = 0;
    try render(&out.writer, "", &files, &match_indices, 1, 0, &drawn);
    const text = out.written();
    const highlight = std.mem.indexOf(u8, text, ansi.bright) orelse return error.TestFailed;
    const row_start = std.mem.indexOf(u8, text, "> b.zig") orelse return error.TestFailed;
    try std.testing.expect(highlight < row_start);
    try std.testing.expect(std.mem.indexOf(u8, text, "  a.zig") != null);
}

test "render with an offset scrolls the visible window" {
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(std.testing.allocator);
    var indices = std.ArrayList(usize).empty;
    defer indices.deinit(std.testing.allocator);
    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |n| std.testing.allocator.free(n);
        names.deinit(std.testing.allocator);
    }
    for (0..25) |i| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "file{d:0>2}.zig", .{i});
        try names.append(std.testing.allocator, name);
        try files.append(std.testing.allocator, name);
        try indices.append(std.testing.allocator, i);
    }

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var drawn: usize = 3;
    try render(&out.writer, "", files.items, indices.items, 5, 5, &drawn);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "file05.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "file24.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "file00.zig") == null);
    try std.testing.expectEqual(@as(usize, 21), drawn);
}

test "scrollOffset keeps the selection inside the visible window" {
    try std.testing.expectEqual(@as(usize, 5), scrollOffset(5, 5));
    try std.testing.expectEqual(@as(usize, 3), scrollOffset(3, 5));
    try std.testing.expectEqual(@as(usize, 6), scrollOffset(25, 5));
}

test "KeyReader interprets plain keys from the pending buffer" {
    var reader = KeyReader{};
    const cases = [_]struct { byte: u8, expected: std.meta.Tag(Key) }{
        .{ .byte = 'x', .expected = .char },
        .{ .byte = 0x08, .expected = .backspace },
        .{ .byte = 0x7f, .expected = .backspace },
        .{ .byte = 0x03, .expected = .escape },
        .{ .byte = 0x04, .expected = .escape },
        .{ .byte = '\r', .expected = .enter },
        .{ .byte = '\n', .expected = .enter },
        .{ .byte = 0x01, .expected = .unknown },
    };
    for (cases) |c| {
        reader.pending_len = 0;
        reader.pending[0] = c.byte;
        reader.pending_len = 1;
        const key = try reader.read(std.testing.io);
        try std.testing.expectEqual(c.expected, std.meta.activeTag(key));
        if (c.expected == .char) {
            try std.testing.expectEqual(c.byte, key.char);
        }
    }
}

test "KeyReader interprets escape sequences from the pending buffer" {
    var reader = KeyReader{};
    const cases = [_]struct { bytes: []const u8, expected: Key }{
        .{ .bytes = "\x1b[A", .expected = .up },
        .{ .bytes = "\x1b[B", .expected = .down },
        .{ .bytes = "\x1b", .expected = .escape },
        .{ .bytes = "\x1b[", .expected = .unknown },
        .{ .bytes = "\x1bX", .expected = .escape },
        .{ .bytes = "\x1b[C", .expected = .unknown },
    };
    for (cases) |c| {
        reader.pending_len = 0;
        @memcpy(reader.pending[0..c.bytes.len], c.bytes);
        reader.pending_len = c.bytes.len;
        try std.testing.expectEqual(c.expected, try reader.read(std.testing.io));
    }
    reader.pending_len = 0;
}

test "KeyReader buffers extra bytes received in one read" {
    var reader = KeyReader{};
    reader.pending[0] = 'a';
    reader.pending[1] = 'b';
    reader.pending_len = 2;

    const key = try reader.read(std.testing.io);
    try std.testing.expectEqual(.char, std.meta.activeTag(key));
    try std.testing.expectEqual(@as(u8, 'a'), key.char);
    try std.testing.expectEqual(@as(usize, 1), reader.pending_len);
    try std.testing.expectEqual(@as(u8, 'b'), reader.pending[0]);
}
