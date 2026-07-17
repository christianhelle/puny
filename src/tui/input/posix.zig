const std = @import("std");
const common = @import("./common.zig");
const prompt_history = @import("../../prompts/history.zig");
const sigint = @import("../../core/sigint.zig");
const terminal = @import("../terminal.zig");

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

pub fn readLinePosix(
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    line_alloc: *std.Io.Writer.Allocating,
    history: ?*prompt_history.History,
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
                return .{ .submitted = line_alloc.written() };
            },
            terminal.control.bs, terminal.control.del => {
                first_esc_ts = null;
                try common.backspace(line_alloc, stdout_writer);
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
                // Try to interpret an escape sequence (arrow keys, etc.).
                // If nothing follows within a short window, treat as Esc.
                if (try readByteWithTimeout(terminal.escape_sequence_timeout_ms)) |next| {
                    first_esc_ts = null;
                    if (next == terminal.csi_leader) {
                        // CSI sequence: consume parameter bytes and the final byte.
                        var final_byte: u8 = 0;
                        while (true) {
                            const param = try readByteWithTimeout(terminal.escape_sequence_timeout_ms) orelse break;
                            if (!std.ascii.isDigit(param) and param != ';') {
                                final_byte = param;
                                break;
                            }
                        }
                        switch (final_byte) {
                            'A' => try common.historyPrevious(line_alloc, stdout_writer, history),
                            'B' => try common.historyNext(line_alloc, stdout_writer, history),
                            else => {},
                        }
                        continue;
                    }
                    // Not a recognized escape sequence; inject the byte as input.
                    try common.appendAndEcho(next, line_alloc, stdout_writer);
                    continue;
                }

                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) return .cancelled;
                }
                first_esc_ts = now;
            },
            else => if (terminal.isIgnoredControlByte(byte)) {
                first_esc_ts = null;
            } else {
                first_esc_ts = null;
                try common.appendAndEcho(byte, line_alloc, stdout_writer);
            },
        }
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
