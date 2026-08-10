const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const cancel = @import("../core/cancel.zig");
const openai = @import("../providers/openai.zig");
const retry = @import("../core/retry.zig");

pub const ChatRetryOutcome = union(enum) {
    success,
    cancelled,
    failed: anyerror,
};

pub fn runChatWithRetry(
    prov: anytype,
    request: openai.ChatRequest,
    callback: openai.StreamCallback,
    io: std.Io,
    random: std.Random,
    stdout_writer: *std.Io.Writer,
) !ChatRetryOutcome {
    var retry_count: usize = 0;
    const cfg = retry.default_config;

    var cancel_stderr_buf: [128]u8 = undefined;
    var cancel_stderr_fw: std.Io.File.Writer = .init(.stderr(), io, &cancel_stderr_buf);
    const cancel_stderr = &cancel_stderr_fw.interface;

    while (true) {
        cancel.reset();
        cancel.start(io, cancel_stderr) catch {};

        // Drop partial state from the failed attempt so a retry does not
        // duplicate streamed content or usage in the accumulator.
        if (retry_count > 0) callback.reset();

        if (prov.chatStreaming(request, callback)) |_| {
            cancel.stop();
            return .success;
        } else |err| {
            cancel.stop();

            if (err == error.Canceled) return .cancelled;

            if (!retry.isTransientError(err)) {
                try stdout_writer.print("\nChat failed: {}\n", .{err});
                try stdout_writer.flush();
                return .{ .failed = err };
            }

            retry_count += 1;
            if (retry_count >= cfg.max_retries) {
                try stdout_writer.print("\nChat failed after {d} retries: {}\n", .{ cfg.max_retries, err });
                try stdout_writer.flush();
                return .{ .failed = err };
            }

            var delay_ms: u64 = cfg.base_delay_ms;
            var i: usize = 1;
            while (i < retry_count) : (i += 1) delay_ms *= 2;
            delay_ms += random.intRangeAtMost(u64, 0, cfg.jitter_max_ms);

            io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
        }
    }
}
