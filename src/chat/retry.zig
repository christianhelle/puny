const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const cancel = @import("../core/cancel.zig");
const openai = @import("../providers/openai.zig");
const http_client = @import("../providers/client.zig");
const redact = @import("redact.zig");
const retry = @import("../core/retry.zig");

pub const ChatRetryOutcome = union(enum) {
    success,
    cancelled,
    failed: anyerror,
};

pub fn runChatWithRetry(
    prov: anytype,
    allocator: std.mem.Allocator,
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
                try printChatFailure(prov, allocator, stdout_writer, err, null);
                try stdout_writer.flush();
                return .{ .failed = err };
            }

            retry_count += 1;
            if (retry_count >= cfg.max_retries) {
                try printChatFailure(prov, allocator, stdout_writer, err, cfg.max_retries);
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

fn printChatFailure(prov: anytype, allocator: std.mem.Allocator, writer: *std.Io.Writer, err: anyerror, retries: ?usize) !void {
    if (retries) |count| {
        try writer.print("\nChat failed after {d} retries: ", .{count});
    } else {
        try writer.writeAll("\nChat failed: ");
    }

    if (err == error.ResponseError) {
        if (lastHttpFailure(prov)) |failure| {
            const message = try formatHttpFailure(allocator, failure);
            defer allocator.free(message);
            try writer.writeAll(message);
            try writer.writeByte('\n');
            return;
        }
    }

    try writer.print("{}\n", .{err});
}

fn lastHttpFailure(prov: anytype) ?*const http_client.HttpFailure {
    const ProviderType = @typeInfo(@TypeOf(prov)).pointer.child;
    if (comptime @hasDecl(ProviderType, "lastHttpFailure")) {
        return prov.lastHttpFailure();
    }
    return null;
}

fn formatHttpFailure(allocator: std.mem.Allocator, failure: *const http_client.HttpFailure) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    try output.writer.print("HTTP {d} ", .{@intFromEnum(failure.status)});
    try writeStatusName(&output.writer, @tagName(failure.status));

    if (try responseMessage(allocator, failure.body)) |message| {
        defer allocator.free(message);
        try output.writer.writeAll(": ");
        try output.writer.writeAll(message);
    }

    return output.toOwnedSlice();
}

fn responseMessage(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
        return sanitizeMessage(allocator, trimmed);
    defer parsed.deinit();

    const message = extractMessage(parsed.value) orelse trimmed;
    return sanitizeMessage(allocator, message);
}

fn extractMessage(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("error")) |error_value| {
        if (error_value == .object) {
            if (error_value.object.get("message")) |message| {
                if (message == .string) return message.string;
            }
        } else if (error_value == .string) {
            return error_value.string;
        }
    }
    if (value.object.get("message")) |message| {
        if (message == .string) return message.string;
    }
    return null;
}

fn sanitizeMessage(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    const formatted = redact.formatBody(allocator, message);
    defer if (formatted.owned) allocator.free(formatted.text);

    const max_len = 512;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var pending_space = false;
    var truncated = false;
    var index: usize = 0;

    while (index < formatted.text.len) {
        const byte = formatted.text[index];
        if (byte == '\n' or byte == '\r' or byte == '\t' or byte == ' ') {
            pending_space = output.items.len > 0;
            index += 1;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            index += 1;
            continue;
        }

        const sequence_len = if (byte < 0x80)
            1
        else
            std.unicode.utf8ByteSequenceLength(byte) catch {
                index += 1;
                continue;
            };
        if (index + sequence_len > formatted.text.len) {
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(formatted.text[index..][0..sequence_len]) catch {
            index += 1;
            continue;
        };
        if (codepoint >= 0x80 and codepoint <= 0x9f) {
            index += sequence_len;
            continue;
        }

        const required = sequence_len + @intFromBool(pending_space);
        if (output.items.len + required > max_len - 3) {
            truncated = true;
            break;
        }
        if (pending_space) {
            try output.append(allocator, ' ');
            pending_space = false;
        }
        try output.appendSlice(allocator, formatted.text[index .. index + sequence_len]);
        index += sequence_len;
    }

    if (truncated) {
        try output.appendSlice(allocator, "...");
    }
    if (output.items.len == 0) return null;
    return try output.toOwnedSlice(allocator);
}

fn writeStatusName(writer: *std.Io.Writer, status_name: []const u8) !void {
    var capitalize = true;
    for (status_name) |byte| {
        if (byte == '_') {
            try writer.writeByte(' ');
            capitalize = true;
        } else {
            try writer.writeByte(if (capitalize) std.ascii.toUpper(byte) else byte);
            capitalize = false;
        }
    }
}

test "formatHttpFailure extracts and sanitizes an API error message" {
    const failure = http_client.HttpFailure{
        .status = .internal_server_error,
        .body = @constCast("{\"error\":{\"message\":\"failed\\napi_key=secret-value\"}}"),
    };

    const formatted = try formatHttpFailure(std.testing.allocator, &failure);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(
        "HTTP 500 Internal Server Error: failed api_key=************",
        formatted,
    );
}

test "formatHttpFailure keeps truncated Unicode messages valid UTF-8" {
    var body: [600]u8 = undefined;
    for (0..200) |i| {
        body[i * 3] = 0xe2;
        body[i * 3 + 1] = 0x82;
        body[i * 3 + 2] = 0xac;
    }
    const failure = http_client.HttpFailure{
        .status = .bad_gateway,
        .body = &body,
    };

    const formatted = try formatHttpFailure(std.testing.allocator, &failure);
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.unicode.utf8ValidateSlice(formatted));
    try std.testing.expect(formatted.len <= 512 + "HTTP 502 Bad Gateway: ".len);
    try std.testing.expect(std.mem.endsWith(u8, formatted, "..."));
}

test "formatHttpFailure drops invalid Unicode sequences" {
    var body = [_]u8{ 'b', 'a', 'd', ':', ' ', 0xed, 0xa0, 0x80, ' ', 'o', 'k' };
    const failure = http_client.HttpFailure{
        .status = .bad_gateway,
        .body = &body,
    };

    const formatted = try formatHttpFailure(std.testing.allocator, &failure);
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.unicode.utf8ValidateSlice(formatted));
    try std.testing.expectEqualStrings("HTTP 502 Bad Gateway: bad: ok", formatted);
}

test "formatHttpFailure drops Unicode terminal control characters" {
    var body = [_]u8{ 'b', 'a', 'd', ':', ' ', 0xc2, 0x9b, '2', 'J', ' ', 'o', 'k' };
    const failure = http_client.HttpFailure{
        .status = .bad_gateway,
        .body = &body,
    };

    const formatted = try formatHttpFailure(std.testing.allocator, &failure);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("HTTP 502 Bad Gateway: bad: 2J ok", formatted);
}
