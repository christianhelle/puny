const std = @import("std");
const cancel = @import("../../core/cancel.zig");
const common = @import("./common.zig");
const keys = @import("./keys.zig");
const line_editor = @import("./line_editor.zig");
const mention = @import("./mention.zig");
const sigint = @import("../../core/sigint.zig");
const terminal = @import("../terminal.zig");

const double_tap_window_ns: i96 = 500 * std.time.ns_per_ms;

pub fn readLinePosix(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *line_editor.LineEditor,
) !common.ReadLineResult {
    const posix = std.posix;
    var first_esc_ts: ?std.Io.Timestamp = null;
    var buf: [1]u8 = undefined;

    while (true) {
        const n = posix.read(0, &buf) catch return error.ReadFailed;
        if (n == 0) return .eof;

        const byte = buf[0];
        if (byte != terminal.control.esc) first_esc_ts = null;
        switch (byte) {
            '\r', '\n' => {
                try editor.moveEnd();
                return .{ .submitted = editor.line_alloc.written() };
            },
            terminal.control.del => try editor.backspace(),
            // Ctrl+Backspace, unless the terminal's Backspace itself sends ^H.
            terminal.control.bs => if (cancel.eraseIsCtrlH()) try editor.backspace() else try editor.deleteWordBackward(),
            terminal.control.etx => {
                try editor.moveEnd();
                sigint.trigger();
                return .interrupted;
            },
            // Ctrl+D deletes forward, and cancels only on an empty prompt.
            terminal.control.eot => if (editor.line_alloc.written().len == 0) return .cancelled else try editor.deleteForward(),
            terminal.control.soh => try editor.moveHome(),
            terminal.control.stx => try editor.moveLeft(),
            terminal.control.enq => try editor.moveEnd(),
            terminal.control.ack => try editor.moveRight(),
            terminal.control.vt => try editor.killToEnd(),
            terminal.control.nak => try editor.killToStart(),
            terminal.control.etb => try editor.deleteWhitespaceWordBackward(),
            terminal.control.esc => {
                // Try to interpret an escape sequence (arrow keys, etc.).
                // If nothing follows within a short window, treat as Esc.
                if (try readByteWithTimeout(terminal.escape_sequence_timeout_ms)) |next| {
                    first_esc_ts = null;
                    switch (next) {
                        // A second Esc inside the probe window is the second
                        // tap, unless a CSI follows (rxvt's Alt+arrow).
                        terminal.control.esc => {
                            const after = try readByteWithTimeout(terminal.escape_sequence_timeout_ms) orelse {
                                try editor.moveEnd();
                                return .cancelled;
                            };
                            if (after == terminal.csi_leader) try editor.handleKey(keys.withAlt(try readCsi()));
                        },
                        terminal.csi_leader => try editor.handleKey(try readCsi()),
                        terminal.ss3_leader => {
                            const final = try readByteWithTimeout(terminal.escape_sequence_timeout_ms) orelse continue;
                            try editor.handleKey(keys.decodeSs3(final));
                        },
                        else => {
                            const key = keys.decodeAlt(next);
                            if (key != .unknown) {
                                try editor.handleKey(key);
                            } else if (!terminal.isIgnoredControlByte(next)) {
                                // Not a recognized escape sequence; inject the byte as input.
                                try editor.append(next);
                            }
                        },
                    }
                    continue;
                }

                const now = std.Io.Timestamp.now(io, .awake);
                if (first_esc_ts) |first| {
                    const elapsed = first.durationTo(now).nanoseconds;
                    if (elapsed >= 0 and elapsed <= double_tap_window_ns) {
                        try editor.moveEnd();
                        return .cancelled;
                    }
                }
                first_esc_ts = now;
            },
            else => if (terminal.isIgnoredControlByte(byte)) {
                // Unbound control keys do nothing.
            } else if (byte == '@' and mention.isTrigger(editor.line_alloc.written()[0..editor.cursor])) {
                try mention.insertMention(allocator, io, editor);
            } else {
                try editor.append(byte);
            },
        }
    }
}

/// Reads the rest of a CSI sequence after `ESC [` and decodes it. Parameter
/// bytes beyond the buffer are consumed but dropped.
fn readCsi() !keys.Key {
    var params: [16]u8 = undefined;
    var len: usize = 0;
    while (try readByteWithTimeout(terminal.escape_sequence_timeout_ms)) |byte| {
        // Parameter and intermediate bytes run from 0x20 to 0x3F; anything
        // else ends the sequence.
        if (byte < 0x20 or byte > 0x3F) return keys.decodeCsi(params[0..len], byte);
        if (len < params.len) {
            params[len] = byte;
            len += 1;
        }
    }
    return .unknown;
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
