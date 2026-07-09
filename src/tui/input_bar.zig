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

/// Read a multi-line prompt from the user.
/// The prompt bar is rendered at the bottom of the terminal.
/// Uses raw mode for key-by-key input.
pub fn readInput(
    persistent: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    terminal: *zz.Terminal,
    cols: u16,
    rows: u16,
) InputResult {
    // Layout: 2 rows at bottom for prompt
    //   row (rows-2): header line
    //   row (rows-1): text input line
    const header_row = rows -| 2;
    const input_row = rows -| 1;

    var text_area = zz.TextArea.init(persistent);
    defer text_area.deinit();
    text_area.setSize(cols, 1);

    // Render initial prompt area
    renderPrompt(terminal, &text_area, arena, cols, header_row, input_row) catch return .quit;

    var input_buf: [256]u8 = undefined;
    var first_esc_ts: ?std.Io.Clock.Timestamp = null;

    while (true) {
        const n = terminal.readInput(&input_buf, -1) catch |err| switch (err) {
            error.ProcessFdQuotaExceeded, error.SystemResources, error.Unexpected => return .quit,
            else => return .quit,
        };
        if (n == 0) return .quit;

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
                        renderPrompt(terminal, &text_area, arena, cols, header_row, input_row) catch return .quit;
                        continue;
                    }
                    first_esc_ts = null;

                    // Enter (no shift) → submit
                    if (k.key == .enter and !k.modifiers.shift) {
                        const text = text_area.getValue(persistent) catch "";
                        // Clear prompt area
                        clearPromptArea(terminal, rows) catch {};
                        return .{ .submitted = text };
                    }
                    // All other keys → TextArea
                    text_area.handleKey(k);
                    renderPrompt(terminal, &text_area, arena, cols, header_row, input_row) catch return .quit;
                },
                .mouse => {},
                .none => {},
            }
        }
    }
}

fn renderPrompt(
    terminal: *zz.Terminal,
    text_area: *const zz.TextArea,
    arena: std.mem.Allocator,
    cols: u16,
    header_row: u16,
    input_row: u16,
) !void {
    _ = cols;
    var hdr_buf: [256]u8 = undefined;
    const header = buildHeader(&hdr_buf);
    const w = terminal.writer();

    // Header line
    try terminal.moveTo(header_row, 0);
    try w.print("\x1b[2K{s}", .{header});

    // Input line
    const text_view = text_area.view(arena) catch "";
    try terminal.moveTo(input_row, 0);
    try w.print("\x1b[2K{s}", .{text_view});

    // Cursor at input position
    try terminal.moveTo(input_row, 0);
    try terminal.flush();
}

fn clearPromptArea(terminal: *zz.Terminal, rows: u16) !void {
    const w = terminal.writer();
    const header_row = rows -| 2;
    const input_row = rows -| 1;

    try terminal.moveTo(header_row, 0);
    try w.print("\x1b[2K", .{});
    try terminal.moveTo(input_row, 0);
    try w.print("\x1b[2K", .{});
    try terminal.flush();
}
