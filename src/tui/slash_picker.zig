//! Inline slash-command and skill picker for the chat prompt.
//!
//! A submodal in the shape of `file_picker.zig`: it draws below the prompt
//! row, owns the keyboard until the user accepts or backs out, and erases
//! itself on every exit path. The difference is that it edits no buffer of its
//! own — the filter never reaches the editor until an entry is accepted, so
//! cancelling leaves the prompt exactly as the user typed it.

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const completion = @import("completion.zig");
const line_editor = @import("input/line_editor.zig");
const terminal = @import("terminal.zig");
const text_width = @import("markdown/width.zig");

/// Maximum number of list rows shown at once.
const max_visible = 20;

/// Columns reserved for the selection marker in front of each row.
const marker_width = 2;

/// Blank columns between the name column and the description column.
const column_gap = 2;

/// What the picker decided. `text` is owned by the picker's arena and copied
/// by the caller if it needs to outlive the call.
pub const Outcome = union(enum) {
    /// There was nothing to offer, so the slash belongs in the prompt as text.
    no_items,
    /// The user backed out; the prompt keeps whatever it had.
    cancelled,
    /// The user accepted an entry.
    accepted: Accepted,
};

/// What the picker decided. `text` is owned by the picker's arena and copied
/// by the caller if it needs to outlive the call.
pub const Accepted = struct {
    /// Text to insert into the prompt.
    text: []const u8,
    /// True when the user pressed Enter, so the caller submits the prompt.
    submit: bool,
};

/// Builds the text a completion inserts: the name, plus one trailing space
/// when the command takes an argument.
///
/// A command that takes no argument must not get the space: `parse("/quit ")`
/// does not match `/quit` and falls through to the skill branch, so the line
/// would be sent to the model as a prompt instead of quitting.
pub fn buildInsertion(allocator: std.mem.Allocator, item: completion.Item) std.mem.Allocator.Error![]const u8 {
    if (!item.takes_arg) return allocator.dupe(u8, item.name);
    return std.fmt.allocPrint(allocator, "{s} ", .{item.name});
}

/// Fills `out` with the indices of the items whose name matches `query`, in
/// list order, so the catalog keeps its curated ordering while filtering.
pub fn collectMatches(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(usize),
    items: []const completion.Item,
    query: []const u8,
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    for (items, 0..) |item, i| {
        if (completion.matches(query, item)) try out.append(allocator, i);
    }
}

/// Scrolls the visible window just enough to keep `selected` on screen.
fn scrollOffset(selected: usize, offset: usize) usize {
    if (selected < offset) return selected;
    if (selected >= offset + max_visible) return selected - max_visible + 1;
    return offset;
}

/// Width of the name column: the widest `name` plus `hint` across the whole
/// list, including the marker, so every description starts on the same
/// column.
fn nameColumnWidth(items: []const completion.Item) usize {
    var widest: usize = 0;
    for (items) |item| {
        var cells = marker_width + text_width.displayWidth(item.name);
        if (item.hint.len > 0) cells += 1 + text_width.displayWidth(item.hint);
        widest = @max(widest, cells);
    }
    return widest + column_gap;
}

/// Writes `text` truncated to `limit` display columns, without splitting a
/// code point. A truncated string ends with an ellipsis.
fn writeTruncated(writer: *std.Io.Writer, text: []const u8, limit: usize) !void {
    if (limit == 0) return;
    if (text_width.displayWidth(text) <= limit) return writer.writeAll(text);

    var budget = limit - 1;
    var i: usize = 0;
    while (i < text.len) {
        const decoded = text_width.decodeAt(text, i);
        const cells = if (decoded.cp) |cp| text_width.codePointWidth(cp) else 1;
        if (cells > budget) break;
        budget -= cells;
        i += decoded.len;
    }
    try writer.writeAll(text[0..i]);
    try writer.writeAll("\u{2026}");
}

/// Writes `text` clipped to `limit` display columns and then pads it out to
/// `target` columns, so the next column starts at a fixed position.
/// Renders one row: the marker, the name, the hint, then the description,
/// all clipped so a wide description never wraps onto the next row and
/// desyncs the cursor arithmetic.
fn renderRow(writer: *std.Io.Writer, item: completion.Item, selected: bool, name_column: usize, width: usize) !void {
    const name_cells = text_width.displayWidth(item.name);
    const hint_cells = text_width.displayWidth(item.hint);
    const has_hint = item.hint.len > 0;

    if (selected) {
        try writer.writeAll(ansi.bright);
        try writer.writeAll("> ");
    } else {
        try writer.writeAll("  ");
    }

    // The name and hint columns are clipped only when the terminal is too
    // narrow to hold them plus a single description column.
    const name_room = if (width > marker_width + column_gap) width - marker_width - column_gap else 1;
    const name_limit = @min(name_room, if (width > marker_width) width - marker_width else 1);
    try writeTruncated(writer, item.name, name_limit);

    var used = marker_width + @min(name_cells, name_limit);
    const column_target = @min(name_column, width);

    if (has_hint) {
        try writer.writeByte(' ');
        try writer.writeAll(ansi.dim);
        const hint_room = if (width > used + 1) width - used - 1 else 1;
        try writeTruncated(writer, item.hint, hint_room);
        try writer.writeAll(ansi.reset);
        if (selected) try writer.writeAll(ansi.bright);
        used += 1 + @min(hint_cells, hint_room);
    }

    if (item.description.len > 0 and width > used) {
        if (column_target > used) try writer.splatByteAll(' ', column_target - used);
        used = @max(used, column_target);
        try writer.writeAll(ansi.dim);
        try writeTruncated(writer, item.description, if (width > used) width - used else 0);
        try writer.writeAll(ansi.reset);
        if (selected) try writer.writeAll(ansi.bright);
    }

    if (selected) try writer.writeAll(ansi.reset);
    try writer.writeAll("\r\n");
}

/// Draws the picker below the prompt row and tracks how many rows it occupies
/// so a later redraw or cleanup can reposition the cursor.
fn render(
    writer: *std.Io.Writer,
    query: []const u8,
    items: []const completion.Item,
    match_indices: []const usize,
    selected: usize,
    offset: usize,
    drawn: *usize,
    width: usize,
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

    try writer.writeAll(ansi.bright);
    try writer.writeByte('/');
    try writer.writeAll(query);
    try writer.writeAll(ansi.reset);
    try writer.writeAll("  ");
    try writer.writeAll(ansi.dim);
    if (query.len == 0) {
        try writer.writeAll("type to filter");
    } else {
        try writer.print("{d} match(es)", .{match_indices.len});
    }
    try writer.writeAll(ansi.reset);
    try writer.writeAll("\r\n");

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

    const name_column = nameColumnWidth(items);
    const visible = @min(max_visible, match_indices.len - offset);
    for (0..visible) |i| {
        const idx = offset + i;
        try renderRow(writer, items[match_indices[idx]], idx == selected, name_column, width);
    }
    drawn.* = 1 + visible;
    try writer.flush();
}

/// Erases the picker and returns the cursor to the input row so the editor's
/// own redraw can restore the prompt line.
fn cleanup(writer: *std.Io.Writer, drawn: usize) !void {
    try writer.print(terminal.cursor_up, .{drawn});
    try writer.writeAll(terminal.erase_display);
    try writer.print(terminal.cursor_up, .{1});
    try writer.writeByte('\r');
    try writer.flush();
}

/// Announces, completes, or declines a `/` typed on an empty prompt. Returns
/// true when the user pressed Enter on an entry, so the caller submits the
/// line. A done picker has already erased its overlay, so a cancel only needs
/// the prompt reprinted, leaving the text exactly as the user typed it.
pub fn completeSlash(allocator: std.mem.Allocator, io: std.Io, editor: *line_editor.LineEditor) !bool {
    switch (try open(allocator, io, editor)) {
        .accepted => |result| {
            defer allocator.free(result.text);
            try editor.appendSlice(result.text);
            return result.submit;
        },
        .cancelled => {
            try editor.redraw();
            return false;
        },
        .no_items => {
            // Nothing to offer, so the slash belongs in the prompt as text.
            try editor.append('/');
            return false;
        },
    }
}

/// Keys the picker understands. `tab` accepts and keeps editing, `enter`
/// accepts and submits.
pub const Key = union(enum) {
    up,
    down,
    tab,
    enter,
    escape,
    backspace,
    char: u8,
    unknown,
};

/// Decides what a key does to the picker's state.
pub const Step = union(enum) {
    /// Nothing changed.
    ignore,
    /// The filter changed and the list must be redrawn.
    redraw,
    /// Accept the selection, submitting the prompt when `submit` is set.
    accept: struct { submit: bool },
    /// Close the picker, leaving the prompt untouched.
    cancel,
};

/// The picker's state machine, separate from terminal I/O so the key handling
/// is testable directly. `filter` owns its bytes through `allocator`.
pub const State = struct {
    filter: std.ArrayList(u8) = .empty,
    selected: usize = 0,
    offset: usize = 0,
    match_indices: std.ArrayList(usize) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
        self.match_indices.deinit(allocator);
    }

    pub fn init(allocator: std.mem.Allocator, items: []const completion.Item) std.mem.Allocator.Error!State {
        var state = State{};
        errdefer state.deinit(allocator);
        try collectMatches(allocator, &state.match_indices, items, "");
        return state;
    }

    /// The item the selection points at, or null when nothing matches.
    pub fn selectedItem(self: *const State, items: []const completion.Item) ?completion.Item {
        if (self.match_indices.items.len == 0) return null;
        return items[self.match_indices.items[self.selected]];
    }

    /// Applies one key. `items` is the unfiltered list the state filters over.
    pub fn apply(self: *State, allocator: std.mem.Allocator, items: []const completion.Item, key: Key) std.mem.Allocator.Error!Step {
        switch (key) {
            .up => {
                if (self.match_indices.items.len == 0) return .ignore;
                self.selected = if (self.selected == 0) self.match_indices.items.len - 1 else self.selected - 1;
                self.offset = scrollOffset(self.selected, self.offset);
                return .redraw;
            },
            .down => {
                if (self.match_indices.items.len == 0) return .ignore;
                self.selected = if (self.selected + 1 < self.match_indices.items.len) self.selected + 1 else 0;
                self.offset = scrollOffset(self.selected, self.offset);
                return .redraw;
            },
            .char => |byte| {
                try self.filter.append(allocator, byte);
                self.selected = 0;
                self.offset = 0;
                try collectMatches(allocator, &self.match_indices, items, self.filter.items);
                return .redraw;
            },
            .backspace => {
                // Backspacing past the slash that opened the picker closes it,
                // so an accidental `/` costs exactly one keystroke.
                if (self.filter.items.len == 0) return .cancel;
                _ = self.filter.pop();
                self.selected = 0;
                self.offset = 0;
                try collectMatches(allocator, &self.match_indices, items, self.filter.items);
                return .redraw;
            },
            .tab => {
                if (self.match_indices.items.len == 0) return .ignore;
                return .{ .accept = .{ .submit = false } };
            },
            .enter => {
                if (self.match_indices.items.len == 0) return .ignore;
                return .{ .accept = .{ .submit = true } };
            },
            .escape, .unknown => return .cancel,
        }
    }
};

/// Runs the picker to completion against a key source. `keys` needs a
/// `read() Key` method, so tests script keys instead of driving the terminal.
/// Returns null when the user backed out.
fn runPicker(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    keys: anytype,
    items: []const completion.Item,
    width: usize,
) !?Accepted {
    var state = try State.init(arena, items);
    defer state.deinit(arena);

    var drawn: usize = 0;
    try render(writer, state.filter.items, items, state.match_indices.items, state.selected, state.offset, &drawn, width);

    // Runs until the user accepts with Tab or Enter, or backs out with Esc,
    // Ctrl+C, Ctrl+D, or by backspacing past the slash that opened it.
    while (true) {
        switch (try state.apply(arena, items, keys.read())) {
            .ignore => {},
            .redraw => try render(writer, state.filter.items, items, state.match_indices.items, state.selected, state.offset, &drawn, width),
            .cancel => {
                try cleanup(writer, drawn);
                return null;
            },
            .accept => |decision| {
                const item = state.selectedItem(items) orelse {
                    try cleanup(writer, drawn);
                    return null;
                };
                try cleanup(writer, drawn);
                return Accepted{ .text = try buildInsertion(arena, item), .submit = decision.submit };
            },
        }
    }
}

/// Opens the picker for the editor's completion source, assuming the terminal
/// is already in raw mode. `no_items` means the caller should treat the slash
/// as literal text; `cancelled` means the prompt must be redrawn unchanged.
pub fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *line_editor.LineEditor,
) !Outcome {
    const source = editor.slash orelse return .no_items;

    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const items = source.items(scratch) catch return .no_items;
    if (items.len == 0) return .no_items;

    // The picker draws below the terminal cursor, so start it under the last
    // wrapped row instead of over the text after a mid-line cursor.
    try editor.parkAtInputEnd();

    const accepted = if (scripted()) |s| blk: {
        var out = std.Io.Writer.Allocating.init(scratch);
        break :blk try runPicker(allocator, &out.writer, s, items, screenWidth());
    } else blk: {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
        var reader = KeyReader{};
        break :blk try runPicker(allocator, &stdout_file_writer.interface, &reader, items, screenWidth());
    };

    return if (accepted) |result| .{ .accepted = result } else .cancelled;
}

/// Columns the picker may draw in.
fn screenWidth() usize {
    return terminal.terminalWidth() orelse 80;
}

/// Reads keys straight from the terminal, interpreting the same escape
/// sequences as `file_picker.KeyReader` plus Tab.
const KeyReader = struct {
    pending: [8]u8 = undefined,
    pending_len: usize = 0,

    fn read(self: *KeyReader) Key {
        return if (builtin.os.tag == .windows) self.readWindows() else self.readPosix();
    }

    fn readPosix(self: *KeyReader) Key {
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
            const n = posix.read(0, buf[0..]) catch return .unknown;
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

        return decodeByte(buf[0]);
    }

    fn readWindows(self: *KeyReader) Key {
        _ = self;
        if (comptime builtin.os.tag != .windows) unreachable;
        const win = windows_api;
        const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
        const hStdin = win.GetStdHandle(STD_INPUT_HANDLE);

        while (true) {
            var record: win.INPUT_RECORD = undefined;
            var events_read: win.DWORD = 0;
            if (win.ReadConsoleInputW(hStdin, &record, 1, &events_read) == .FALSE) return .unknown;
            if (events_read == 0) continue;
            if (record.EventType != win.KEY_EVENT) continue;
            if (record.Event.KeyEvent.bKeyDown == .FALSE) continue;

            switch (record.Event.KeyEvent.wVirtualKeyCode) {
                win.VK_UP => return .up,
                win.VK_DOWN => return .down,
                win.VK_TAB => return .tab,
                win.VK_RETURN => return .enter,
                win.VK_ESCAPE => return .escape,
                win.VK_BACK => return .backspace,
                else => {
                    const ch = record.Event.KeyEvent.uChar.UnicodeChar;
                    if (ch >= 32 and ch < 0x80) return Key{ .char = @intCast(ch) };
                    return .unknown;
                },
            }
        }
    }
};

/// Maps a single input byte to a picker key.
fn decodeByte(byte: u8) Key {
    return switch (byte) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        0x08, 0x7f => .backspace,
        0x03, 0x04 => .escape,
        else => if (byte >= 32) Key{ .char = byte } else .unknown,
    };
}

const windows_api = if (builtin.os.tag == .windows) struct {
    pub const BOOL = std.os.windows.BOOL;
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;

    pub const VK_RETURN: u16 = 0x0D;
    pub const VK_BACK: u16 = 0x08;
    pub const VK_TAB: u16 = 0x09;
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

test "buildInsertion appends a space only for commands that take an argument" {
    const items = [_]completion.Item{
        .{ .name = "/model", .hint = "[id]", .description = "Switch to another model", .kind = .command, .takes_arg = true },
        .{ .name = "/help", .hint = "", .description = "Show this help message", .kind = .command, .takes_arg = false },
        .{ .name = "/grill-me", .hint = "", .description = "Interview", .kind = .skill, .takes_arg = false },
    };
    const with_arg = try buildInsertion(std.testing.allocator, items[0]);
    defer std.testing.allocator.free(with_arg);
    try std.testing.expectEqualStrings("/model ", with_arg);

    const bare = try buildInsertion(std.testing.allocator, items[1]);
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("/help", bare);

    const skill = try buildInsertion(std.testing.allocator, items[2]);
    defer std.testing.allocator.free(skill);
    try std.testing.expectEqualStrings("/grill-me", skill);
}

test "matching filters by name and keeps catalog order" {
    const items = [_]completion.Item{
        .{ .name = "/quit", .hint = "", .description = "Exit Puny", .kind = .command, .takes_arg = false },
        .{ .name = "/model", .hint = "[id]", .description = "Switch", .kind = .command, .takes_arg = true },
        .{ .name = "/compact", .hint = "", .description = "Summarize", .kind = .command, .takes_arg = false },
    };
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(std.testing.allocator);

    try collectMatches(std.testing.allocator, &out, &items, "mod");
    try std.testing.expectEqualSlices(usize, &.{1}, out.items);

    try collectMatches(std.testing.allocator, &out, &items, "o");
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, out.items);

    try collectMatches(std.testing.allocator, &out, &items, "");
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, out.items);

    try collectMatches(std.testing.allocator, &out, &items, "zzz");
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "scrollOffset keeps the selection inside the visible window" {
    try std.testing.expectEqual(@as(usize, 5), scrollOffset(5, 5));
    try std.testing.expectEqual(@as(usize, 3), scrollOffset(3, 5));
    try std.testing.expectEqual(@as(usize, 6), scrollOffset(25, 5));
    try std.testing.expectEqual(@as(usize, 1), scrollOffset(max_visible, 0));
    try std.testing.expectEqual(@as(usize, 0), scrollOffset(max_visible - 1, 0));
}

test "render shows the filter header, the match count and the highlighted row" {
    const items = [_]completion.Item{
        .{ .name = "/model", .hint = "", .description = "", .kind = .command, .takes_arg = true },
        .{ .name = "/modx", .hint = "", .description = "", .kind = .command, .takes_arg = false },
    };
    const indices = [_]usize{ 0, 1 };

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var drawn: usize = 0;
    try render(&out.writer, "mod", &items, &indices, 0, 0, &drawn, 80);

    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "2 match(es)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> /model") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  /modx") != null);
    try std.testing.expectEqual(@as(usize, 3), drawn);
}

test "render shows the type-to-filter hint for an empty query" {
    const items = [_]completion.Item{
        .{ .name = "/help", .hint = "", .description = "Show this help message", .kind = .command, .takes_arg = false },
    };
    const indices = [_]usize{0};
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var drawn: usize = 0;
    try render(&out.writer, "", &items, &indices, 0, 0, &drawn, 80);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "type to filter") != null);
    try std.testing.expectEqual(@as(usize, 2), drawn);
}

test "render reports no matches and tracks the row count" {
    const indices = [_]usize{};
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var drawn: usize = 0;
    try render(&out.writer, "zzz", &.{}, &indices, 0, 0, &drawn, 80);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "no matches") != null);
    try std.testing.expectEqual(@as(usize, 2), drawn);
}

test "render redraws in place once something was drawn" {
    const items = [_]completion.Item{
        .{ .name = "/help", .hint = "", .description = "", .kind = .command, .takes_arg = false },
    };
    const indices = [_]usize{0};
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var drawn: usize = 3;
    try render(&out.writer, "", &items, &indices, 0, 0, &drawn, 80);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\x1b[3A\x1b[J"));
}

/// Visible width of `text` as rendered, in display cells: colour escapes are
/// skipped and each code point counts its own width.
fn visibleWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = skipEscape(text, i);
            continue;
        }
        const decoded = text_width.decodeAt(text, i);
        const cells = if (decoded.cp) |cp| text_width.codePointWidth(cp) else 1;
        width += cells;
        i += decoded.len;
    }
    return width;
}

test "render never writes a row wider than the terminal" {
    const long: [120]u8 = @splat('x');
    const items = [_]completion.Item{
        .{ .name = "/help", .hint = "[path|url]", .description = &long, .kind = .command, .takes_arg = false },
    };
    const indices = [_]usize{0};
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var drawn: usize = 0;
    try render(&out.writer, "", &items, &indices, 0, 0, &drawn, 30);

    var rows = std.mem.splitScalar(u8, out.written(), '\n');
    while (rows.next()) |row| {
        try std.testing.expect(visibleWidth(row) <= 31);
    }
}



/// Index just past the CSI sequence starting at `start`.
fn skipEscape(text: []const u8, start: usize) usize {
    var i = start + 1;
    if (i < text.len and text[i] == '[') {
        i += 1;
        while (i < text.len and !std.ascii.isAlphabetic(text[i])) i += 1;
        if (i < text.len) i += 1;
    }
    return i;
}

test "render lays descriptions on one column and truncates with an ellipsis" {
    const long: [80]u8 = @splat('d');
    const items = [_]completion.Item{
        .{ .name = "/a", .hint = "[id]", .description = "short", .kind = .command, .takes_arg = true },
        .{ .name = "/bb", .hint = "", .description = &long, .kind = .command, .takes_arg = false },
    };
    const indices = [_]usize{ 0, 1 };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var drawn: usize = 0;
    try render(&out.writer, "", &items, &indices, 0, 0, &drawn, 40);

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2026}") != null);

    // Both descriptions must start at the same visible column.
    const first = visibleColumn(text, std.mem.indexOf(u8, text, "short").?);
    const second = visibleColumn(text, std.mem.indexOf(u8, text, "dddd").?);
    try std.testing.expectEqual(first, second);
}

/// Visible column of `index`, counting from the start of its own row and
/// ignoring colour escapes.
fn visibleColumn(text: []const u8, index: usize) usize {
    const row_start = (std.mem.lastIndexOf(u8, text[0..index], "\n") orelse return 0) + 1;
    var column: usize = 0;
    var i = row_start;
    while (i < index) {
        if (text[i] == 0x1b) {
            i = skipEscape(text, i);
            continue;
        }
        if (text[i] == '\r') {
            i += 1;
            continue;
        }
        column += 1;
        i += 1;
    }
    return column;
}

test "cleanup erases the picker and returns to the input row" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try cleanup(&out.writer, 3);
    try std.testing.expectEqualStrings("\x1b[3A\x1b[J\x1b[1A\r", out.written());
}

test "decodeByte maps the picker's keys" {
    try std.testing.expectEqual(Key.enter, decodeByte('\r'));
    try std.testing.expectEqual(Key.enter, decodeByte('\n'));
    try std.testing.expectEqual(Key.tab, decodeByte('\t'));
    try std.testing.expectEqual(Key.backspace, decodeByte(0x7f));
    try std.testing.expectEqual(Key.backspace, decodeByte(0x08));
    try std.testing.expectEqual(Key.escape, decodeByte(0x03));
    try std.testing.expectEqual(Key.escape, decodeByte(0x04));
    try std.testing.expectEqual(Key.unknown, decodeByte(0x01));
    try std.testing.expectEqual(@as(u8, 'a'), decodeByte('a').char);
}

const test_items = [_]completion.Item{
    .{ .name = "/quit", .hint = "", .description = "Exit Puny", .kind = .command, .takes_arg = false },
    .{ .name = "/model", .hint = "[id]", .description = "Switch to another model", .kind = .command, .takes_arg = true },
    .{ .name = "/headroom", .hint = "", .description = "Something else", .kind = .command, .takes_arg = false },
};

test "the state filters as characters arrive and remembers the selection" {
    var state = try State.init(std.testing.allocator, &test_items);
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), state.match_indices.items.len);

    try expectStep(.redraw, try state.apply(std.testing.allocator, &test_items, .{ .char = 'h' }));
    try std.testing.expectEqual(@as(usize, 1), state.match_indices.items.len);
    try std.testing.expectEqualStrings("/headroom", state.selectedItem(&test_items).?.name);

    try expectStep(.redraw, try state.apply(std.testing.allocator, &test_items, .backspace));
    try std.testing.expectEqual(@as(usize, 3), state.match_indices.items.len);
}

test "the state closes when backspacing past the slash" {
    var state = try State.init(std.testing.allocator, &test_items);
    defer state.deinit(std.testing.allocator);
    try expectStep(.cancel, try state.apply(std.testing.allocator, &test_items, .backspace));
}

test "the state wraps the selection at both ends" {
    var state = try State.init(std.testing.allocator, &test_items);
    defer state.deinit(std.testing.allocator);
    try expectStep(.redraw, try state.apply(std.testing.allocator, &test_items, .up));
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    try expectStep(.redraw, try state.apply(std.testing.allocator, &test_items, .down));
    try std.testing.expectEqual(@as(usize, 0), state.selected);
}

test "tab accepts without submitting and enter accepts and submits" {
    var state = try State.init(std.testing.allocator, &test_items);
    defer state.deinit(std.testing.allocator);
    switch (try state.apply(std.testing.allocator, &test_items, .tab)) {
        .accept => |decision| try std.testing.expect(!decision.submit),
        else => return error.TestExpectedAccept,
    }
    switch (try state.apply(std.testing.allocator, &test_items, .enter)) {
        .accept => |decision| try std.testing.expect(decision.submit),
        else => return error.TestExpectedAccept,
    }
}

test "esc cancels and navigation is inert when nothing matches" {
    var state = try State.init(std.testing.allocator, &test_items);
    defer state.deinit(std.testing.allocator);
    try expectStep(.cancel, try state.apply(std.testing.allocator, &test_items, .escape));

    for ("zzz") |byte| _ = try state.apply(std.testing.allocator, &test_items, .{ .char = byte });
    try std.testing.expectEqual(@as(usize, 0), state.match_indices.items.len);
    try expectStep(.ignore, try state.apply(std.testing.allocator, &test_items, .up));
    try expectStep(.ignore, try state.apply(std.testing.allocator, &test_items, .tab));
    try expectStep(.ignore, try state.apply(std.testing.allocator, &test_items, .enter));
}

fn expectStep(expected: std.meta.Tag(Step), actual: Step) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(actual));
}

/// Scripted key source for `runPicker`.
const TestKeys = struct {
    keys: []const Key,
    next: usize = 0,

    fn read(self: *TestKeys) Key {
        if (self.next >= self.keys.len) return .escape;
        defer self.next += 1;
        return self.keys[self.next];
    }
};

/// Runs `runPicker` over the shared test items. The accepted text is
/// allocated from `allocator`, which the caller uses to free it, matching how
/// `open` hands the result back to the prompt.
fn runScripted(allocator: std.mem.Allocator, keys: []const Key) !?Accepted {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var source = TestKeys{ .keys = keys };
    return runPicker(allocator, &out.writer, &source, &test_items, 80);
}

test "runPicker returns the filtered entry on tab and submits on enter" {
    const tabbed = (try runScripted(std.testing.allocator, &.{ .{ .char = 'm' }, .{ .char = 'o' }, .tab })).?;
    defer std.testing.allocator.free(tabbed.text);
    try std.testing.expectEqualStrings("/model ", tabbed.text);
    try std.testing.expect(!tabbed.submit);

    const entered = (try runScripted(std.testing.allocator, &.{ .{ .char = 'q' }, .enter })).?;
    defer std.testing.allocator.free(entered.text);
    try std.testing.expectEqualStrings("/quit", entered.text);
    try std.testing.expect(entered.submit);
}

test "runPicker returns null when the user backs out" {
    try std.testing.expect(try runScripted(std.testing.allocator, &.{ .{ .char = 'm' }, .escape }) == null);
    try std.testing.expect(try runScripted(std.testing.allocator, &.{.backspace}) == null);
    // Running out of scripted keys dismisses the picker.
    try std.testing.expect(try runScripted(std.testing.allocator, &.{.{ .char = 'm' }}) == null);
}

test "runPicker never accepts when nothing matches" {
    try std.testing.expect(try runScripted(std.testing.allocator, &.{ .{ .char = 'z' }, .{ .char = 'z' }, .enter }) == null);
}

test "an arrow key then tab accepts the highlighted entry" {
    const accepted = (try runScripted(std.testing.allocator, &.{ .down, .down, .tab })).?;
    defer std.testing.allocator.free(accepted.text);
    try std.testing.expectEqualStrings("/headroom", accepted.text);
}

/// Keys a test presses in place of the keyboard, so tests can drive the
/// picker through `open` as well as `runPicker`. Mirrors
/// `list_picker.Script`.
pub const Script = struct {
    keys: []const Key,
    next: usize = 0,

    fn read(self: *Script) Key {
        if (self.next >= self.keys.len) return .escape;
        defer self.next += 1;
        return self.keys[self.next];
    }
};

/// The script the picker follows in tests; see `Script`.
pub var script: ?*Script = null;

fn scripted() ?*Script {
    return if (builtin.is_test) script else null;
}

test "open scripts its keys, filters and inserts the accepted command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var line_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var editor = line_editor.LineEditor.init(&line_alloc, &out.writer, null, 80);
    const source = completion.Source{ .ctx = null, .list = fixedItems };
    editor.slash = &source;

    var s = Script{ .keys = &.{ .{ .char = 'm' }, .{ .char = 'o' }, .tab } };
    script = &s;
    defer script = null;

    switch (try open(allocator, std.testing.io, &editor)) {
        .accepted => |result| {
            try std.testing.expectEqualStrings("/model ", result.text);
            try std.testing.expect(!result.submit);
        },
        else => return error.TestExpectedAccept,
    }
    // The picker never touches the prompt itself.
    try std.testing.expectEqual(@as(usize, 0), editor.line_alloc.written().len);
}

test "open reports no items when the source is missing or empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var line_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var editor = line_editor.LineEditor.init(&line_alloc, &out.writer, null, 80);
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .no_items), std.meta.activeTag(try open(allocator, std.testing.io, &editor)));

    const empty = completion.Source{ .ctx = null, .list = noItems };
    editor.slash = &empty;
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .no_items), std.meta.activeTag(try open(allocator, std.testing.io, &editor)));
}

test "open reports a cancel without touching the prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var line_alloc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line_alloc.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var editor = line_editor.LineEditor.init(&line_alloc, &out.writer, null, 80);
    const source = completion.Source{ .ctx = null, .list = fixedItems };
    editor.slash = &source;

    var s = Script{ .keys = &.{.{ .char = 'm' }, .escape} };
    script = &s;
    defer script = null;

    try std.testing.expectEqual(Outcome.cancelled, try open(allocator, std.testing.io, &editor));
    try std.testing.expectEqual(@as(usize, 0), editor.line_alloc.written().len);
}

fn fixedItems(_: ?*anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]completion.Item {
    const items = try allocator.alloc(completion.Item, test_items.len);
    @memcpy(items, &test_items);
    return items;
}

fn noItems(_: ?*anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]completion.Item {
    return allocator.alloc(completion.Item, 0);
}
