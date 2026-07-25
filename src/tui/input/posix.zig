const std = @import("std");
const common = @import("./common.zig");
const prompt_history = @import("../../prompts/history.zig");
const sigint = @import("../../core/sigint.zig");
const terminal = @import("../terminal.zig");

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

pub fn readLinePosix(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_buffer: *std.ArrayList(u8),
    cursor: *usize,
    history: ?*prompt_history.History,
    allocator: std.mem.Allocator,
) !common.ReadLineResult {
    const posix = std.posix;
    var first_esc_ts: ?std.Io.Timestamp = null;
    var buf: [1]u8 = undefined;

    while (true) {
        const n = posix.read(0, &buf) catch return error.ReadFailed;
        if (n == 0) return .eof;

        const byte = buf[0];
        switch (byte) {
            '\r', '\n' => {
                first_esc_ts = null;
                return .{ .submitted = line_buffer.items };
            },
            terminal.control.bs, terminal.control.del => {
                first_esc_ts = null;
                try common.backspaceAndRedraw(line_buffer, cursor, stdout_writer);
            },
            terminal.control.etx => {
                sigint.trigger();
                return .interrupted;
            },
            terminal.control.eot => {
                first_esc_ts = null;
                return .cancelled;
            },
            terminal.control.esc => {
                if (try readByteWithTimeout(terminal.escape_sequence_timeout_ms)) |next| {
                    first_esc_ts = null;
                    if (next == terminal.csi_leader) {
                        try handleCsiSequence(line_buffer, cursor, stdout_writer, history, allocator);
                        continue;
                    }
                    if (next == 'O') {
                        try handleSs3Sequence(line_buffer, cursor, stdout_writer, history, allocator);
                        continue;
                    }
                    try common.insertAndRedraw(next, line_buffer, cursor, stdout_writer, allocator);
                    continue;
                }

                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) return .cancelled;
                }
                first_esc_ts = now;
            },
            terminal.control.soh => {
                first_esc_ts = null;
                try common.moveCursorToStart(line_buffer, cursor, stdout_writer);
            },
            terminal.control.enq => {
                first_esc_ts = null;
                try common.moveCursorToEnd(line_buffer, cursor, stdout_writer);
            },
            terminal.control.ht => {
                first_esc_ts = null;
                if (cursor.* == line_buffer.items.len) {
                    try common.appendChar('\t', line_buffer, cursor, stdout_writer, allocator);
                } else {
                    try common.insertAndRedraw('\t', line_buffer, cursor, stdout_writer, allocator);
                }
            },
            terminal.control.nak => {
                first_esc_ts = null;
                try common.deleteWordBackwardAndRedraw(line_buffer, cursor, stdout_writer);
            },
            else => if (terminal.isIgnoredControlByte(byte)) {
                first_esc_ts = null;
            } else {
                first_esc_ts = null;
                if (cursor.* == line_buffer.items.len) {
                    try common.appendChar(byte, line_buffer, cursor, stdout_writer, allocator);
                } else {
                    try common.insertAndRedraw(byte, line_buffer, cursor, stdout_writer, allocator);
                }
            },
        }
    }
}

fn handleCsiSequence(
    line_buffer: *std.ArrayList(u8),
    cursor: *usize,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
    allocator: std.mem.Allocator,
) !void {
    var param_str: [16]u8 = undefined;
    var param_len: usize = 0;
    var final_byte: u8 = 0;

    while (true) {
        const b = try readByteWithTimeout(terminal.escape_sequence_timeout_ms) orelse return;
        if (b == ';' or std.ascii.isDigit(b)) {
            if (param_len < param_str.len) {
                param_str[param_len] = b;
                param_len += 1;
            }
        } else {
            final_byte = b;
            break;
        }
    }

    switch (final_byte) {
        'A' => try common.historyPreviousAndRedraw(line_buffer, cursor, stdout_writer, history, allocator),
        'B' => try common.historyNextAndRedraw(line_buffer, cursor, stdout_writer, history, allocator),
        'C' => try common.moveCursorRight(line_buffer, cursor, stdout_writer),
        'D' => try common.moveCursorLeft(line_buffer, cursor, stdout_writer),
        'H' => try common.moveCursorToStart(line_buffer, cursor, stdout_writer),
        'F' => try common.moveCursorToEnd(line_buffer, cursor, stdout_writer),
        '~' => {
            if (std.mem.eql(u8, param_str[0..param_len], "3")) {
                try common.deleteForwardAndRedraw(line_buffer, cursor, stdout_writer);
            } else if (std.mem.eql(u8, param_str[0..param_len], "1") or std.mem.eql(u8, param_str[0..param_len], "7")) {
                try common.moveCursorToStart(line_buffer, cursor, stdout_writer);
            } else if (std.mem.eql(u8, param_str[0..param_len], "4") or std.mem.eql(u8, param_str[0..param_len], "8")) {
                try common.moveCursorToEnd(line_buffer, cursor, stdout_writer);
            }
        },
        else => {},
    }
}

fn handleSs3Sequence(
    line_buffer: *std.ArrayList(u8),
    cursor: *usize,
    stdout_writer: *std.Io.Writer,
    history: ?*prompt_history.History,
    allocator: std.mem.Allocator,
) !void {
    const final_byte = try readByteWithTimeout(terminal.escape_sequence_timeout_ms) orelse return;
    switch (final_byte) {
        'A' => try common.historyPreviousAndRedraw(line_buffer, cursor, stdout_writer, history, allocator),
        'B' => try common.historyNextAndRedraw(line_buffer, cursor, stdout_writer, history, allocator),
        'C' => try common.moveCursorRight(line_buffer, cursor, stdout_writer),
        'D' => try common.moveCursorLeft(line_buffer, cursor, stdout_writer),
        'H' => try common.moveCursorToStart(line_buffer, cursor, stdout_writer),
        'F' => try common.moveCursorToEnd(line_buffer, cursor, stdout_writer),
        else => {},
    }
}

fn readByteWithTimeout(timeout_ms: i32) !?u8 {
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
