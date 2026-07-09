const std = @import("std");
const zz = @import("zigzag");
const chat = @import("../chat.zig");

/// Manages a prompt input bar at the bottom of the terminal.
/// The conversation area above is preserved.
/// Uses zz.Terminal for raw mode and cursor positioning.

var global_model_name: []const u8 = "";
var global_working_dir: []const u8 = "";
var global_git_branch: []const u8 = "";
var global_session_stats: ?*const chat.SessionStats = null;

pub fn setModelName(name: []const u8) void { global_model_name = name; }
pub fn setWorkingDir(dir: []const u8) void { global_working_dir = dir; }
pub fn setGitBranch(branch: []const u8) void { global_git_branch = branch; }
pub fn setSessionStats(stats: ?*const chat.SessionStats) void { global_session_stats = stats; }

fn formatTokenCount(count: i64, buf: *[16]u8) []const u8 {
    if (count >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(count)) / 1_000_000.0}) catch "?";
    }
    if (count >= 1000) {
        return std.fmt.bufPrint(buf, "{d:.1}k", .{@as(f64, @floatFromInt(count)) / 1000.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{count}) catch "0";
}

fn buildHeader(buf: *[256]u8) []const u8 {
    var pos: usize = 0;
    const w = struct {
        fn write(b: *[256]u8, p: *usize, s: []const u8) void {
            const remaining = b.len - p.*;
            const n = @min(s.len, remaining);
            @memcpy(b[p.*..][0..n], s[0..n]);
            p.* += n;
        }
    }.write;
    w(buf, &pos, "Model: ");
    w(buf, &pos, global_model_name);
    if (global_git_branch.len > 0) {
        w(buf, &pos, " | (");
        w(buf, &pos, global_git_branch);
        w(buf, &pos, ")");
    }
    w(buf, &pos, " | ");
    w(buf, &pos, global_working_dir);
    if (global_session_stats) |stats| {
        var in_b: [16]u8 = undefined;
        var out_b: [16]u8 = undefined;
        const in_str = formatTokenCount(stats.input_tokens, &in_b);
        const out_str = formatTokenCount(stats.output_tokens, &out_b);
        w(buf, &pos, " | ");
        w(buf, &pos, "\u{2191}");
        w(buf, &pos, in_str);
        w(buf, &pos, " ");
        w(buf, &pos, "\u{2193}");
        w(buf, &pos, out_str);
    }
    return buf[0..pos];
}

pub const InputResult = union(enum) {
    submitted: []const u8,
    cancelled,
    quit,
};

/// Number of rows reserved for the prompt input area at the bottom.
const prompt_rows: u16 = 6;

/// Read a multi-line prompt from the user.
/// The prompt bar is rendered at the bottom of the terminal.
/// Layout (from bottom up):
///   input line 3    (rows-1)
///   input line 2    (rows-2)
///   input line 1    (rows-3)
///   header          (rows-4): Model: ... | ↑X ↓Y
///   separator       (rows-5): ───────────────
///   blank gap       (rows-6): (space between conversation and prompt bar)
pub fn readInput(
    persistent: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    terminal: *zz.Terminal,
    cols: u16,
    rows: u16,
) InputResult {
    if (rows < prompt_rows + 1) return .cancelled;

    const gap_row = rows -| 6;
    const sep_row = rows -| 5;
    const header_row = rows -| 4;
    const input_row_1 = rows -| 3;
    const input_row_2 = rows -| 2;
    const input_row_3 = rows -| 1;

    // Drain any pending input from the terminal buffer
    // Prevents stale key events (e.g., from model picker) from triggering actions
    var drain_buf: [256]u8 = undefined;
    while (true) {
        const n = terminal.readInput(&drain_buf, 0) catch break;
        if (n == 0) break;
    }

    var text_area = zz.TextArea.init(persistent);
    defer text_area.deinit();
    text_area.setSize(cols, 3);

    // Render initial prompt area
    renderPrompt(terminal, &text_area, arena, cols, gap_row, sep_row, header_row, input_row_1, input_row_2, input_row_3) catch return .quit;

    var input_buf: [256]u8 = undefined;
    var first_esc_ts: ?std.Io.Clock.Timestamp = null;

    while (true) {
        const n = terminal.readInput(&input_buf, -1) catch continue;
        if (n == 0) continue;

        // Handle Escape at byte level — Windows console may send Escape differently
        // than expected by the keyboard parser (e.g., as part of a sequence)
        if (n >= 1 and input_buf[0] == 0x1b) {
            // If it's a CSI sequence (\x1b[), delegate to the keyboard parser
            if (n >= 2 and input_buf[1] == '[') {
                // CSI sequence — let the parser handle it
            } else {
                // Standalone or double Escape
                if (n >= 2 and input_buf[1] == 0x1b) {
                    return .quit;
                }
                const now = std.Io.Clock.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).raw.nanoseconds;
                    if (elapsed >= 0 and elapsed <= 500 * std.time.ns_per_ms) {
                        return .quit;
                    }
                }
                first_esc_ts = now;
                text_area.setValue("") catch {};
                renderPrompt(terminal, &text_area, arena, cols, gap_row, sep_row, header_row, input_row_1, input_row_2, input_row_3) catch return .quit;
                continue;
            }
        }
        first_esc_ts = null;

        const events = zz.input.keyboard.parseAll(arena, input_buf[0..n]) catch continue;

        for (events) |event| {
            switch (event) {
                .key => |k| {
                    // Ctrl+C → quit
                    if (k.modifiers.ctrl and k.key == .char and k.key.char == 'c') {
                        return .quit;
                    }
                    // Ctrl+D → cancel
                    if (k.modifiers.ctrl and k.key == .char and k.key.char == 'd') {
                        return .cancelled;
                    }

                    // Escape handling
                    if (k.key == .escape) {
                        const now = std.Io.Clock.Timestamp.now(io, .awake);
                        if (first_esc_ts) |first| {
                            const elapsed = first.durationTo(now).raw.nanoseconds;
                            if (elapsed >= 0 and elapsed <= 500 * std.time.ns_per_ms) {
                                return .quit;
                            }
                        }
                        first_esc_ts = now;
                        // Single escape: clear input
                        text_area.setValue("") catch {};
                        renderPrompt(terminal, &text_area, arena, cols, gap_row, sep_row, header_row, input_row_1, input_row_2, input_row_3) catch return .quit;
                        continue;
                    }
                    first_esc_ts = null;

                    // Enter (no shift) → submit
                    if (k.key == .enter and !k.modifiers.shift) {
                        const text = text_area.getValue(persistent) catch "";
                        // Clear all prompt rows and move cursor above them
                        clearPromptArea(terminal, rows) catch {};
                        return .{ .submitted = text };
                    }
                    // All other keys → TextArea
                    text_area.handleKey(k);
                    renderPrompt(terminal, &text_area, arena, cols, gap_row, sep_row, header_row, input_row_1, input_row_2, input_row_3) catch return .quit;
                },
                .mouse => {},
                .none => {},
            }
        }
    }
}

fn renderSeparator(w: *std.Io.Writer, cols: u16) !void {
    const sep: []const u8 = "\u{2500}";
    var sep_buf: [512]u8 = undefined;
    var pos: usize = 0;
    while (pos < cols and pos + sep.len <= sep_buf.len) {
        @memcpy(sep_buf[pos..][0..sep.len], sep);
        pos += sep.len;
    }
    try w.print("\x1b[2K{s}", .{sep_buf[0..pos]});
}

fn renderPrompt(
    terminal: *zz.Terminal,
    text_area: *const zz.TextArea,
    arena: std.mem.Allocator,
    cols: u16,
    gap_row: u16,
    sep_row: u16,
    header_row: u16,
    input_row_1: u16,
    input_row_2: u16,
    input_row_3: u16,
) !void {
    var hdr_buf: [256]u8 = undefined;
    const header = buildHeader(&hdr_buf);
    const w = terminal.writer();

    // Gap line (blank, just clear it)
    try terminal.moveTo(gap_row, 0);
    try w.print("\x1b[2K", .{});

    // Separator line
    try terminal.moveTo(sep_row, 0);
    try renderSeparator(w, cols);

    // Header line
    try terminal.moveTo(header_row, 0);
    try w.print("\x1b[2K{s}", .{header});

    // Input lines — TextArea.view renders all 3 lines
    const text_view = text_area.view(arena) catch "";
    var line_iter = std.mem.splitScalar(u8, text_view, '\n');

    // Line 1
    try terminal.moveTo(input_row_1, 0);
    const line1 = line_iter.next() orelse "";
    try w.print("\x1b[2K{s}", .{line1});

    // Line 2
    try terminal.moveTo(input_row_2, 0);
    const line2 = line_iter.next() orelse "";
    try w.print("\x1b[2K{s}", .{line2});

    // Line 3
    try terminal.moveTo(input_row_3, 0);
    const line3 = line_iter.next() orelse "";
    try w.print("\x1b[2K{s}", .{line3});

    // Cursor at the first input line
    try terminal.moveTo(input_row_1, 0);
    try terminal.flush();
}

fn clearPromptArea(terminal: *zz.Terminal, rows: u16) !void {
    const w = terminal.writer();
    const gap_row = rows -| 6;
    const sep_row = rows -| 5;
    const header_row = rows -| 4;
    const input_row_1 = rows -| 3;
    const input_row_2 = rows -| 2;
    const input_row_3 = rows -| 1;

    // Clear all 6 prompt rows
    try terminal.moveTo(gap_row, 0);
    try w.print("\x1b[2K", .{});
    try terminal.moveTo(sep_row, 0);
    try w.print("\x1b[2K", .{});
    try terminal.moveTo(header_row, 0);
    try w.print("\x1b[2K", .{});
    try terminal.moveTo(input_row_1, 0);
    try w.print("\x1b[2K", .{});
    try terminal.moveTo(input_row_2, 0);
    try w.print("\x1b[2K", .{});
    try terminal.moveTo(input_row_3, 0);
    try w.print("\x1b[2K", .{});

    // Leave cursor at the bottom — main loop adds spacing before the response
    try terminal.flush();
}
