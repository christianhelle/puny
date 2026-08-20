// Thin shim around openapi2zig generated OpenAI modules.
// Avoids importing openai/client.zig because its generated usage endpoints
// declare a parameter named `models` that collides with the file-level
// `const models = @import("models.zig")`.

const std = @import("std");
const openai_models = @import("models.zig");
const runtime = @import("runtime.zig");
const cancel_reader = @import("cancel_reader.zig");

pub const Client = @import("../client.zig").Client;

fn appendClientHeaders(allocator: std.mem.Allocator, headers: *std.ArrayList(std.http.Header), c: *Client, content_type: ?[]const u8, accept: []const u8) !?[]u8 {
    if (content_type) |ct| {
        try headers.append(allocator, .{ .name = "Content-Type", .value = ct });
    }
    try headers.append(allocator, .{ .name = "Accept", .value = accept });

    var auth_header: ?[]u8 = null;
    if (c.api_key.len > 0) {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{c.api_key});
        try headers.append(allocator, .{ .name = "Authorization", .value = auth_header.? });
    }
    if (c.organization) |organization| {
        try headers.append(allocator, .{ .name = "OpenAI-Organization", .value = organization });
    }
    if (c.project) |project| {
        try headers.append(allocator, .{ .name = "OpenAI-Project", .value = project });
    }
    for (c.default_headers) |header| {
        try headers.append(allocator, header);
    }
    return auth_header;
}

fn requestRaw(c: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8) !runtime.RawResponse {
    const allocator = c.allocator;
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const content_type: ?[]const u8 = if (payload != null) "application/json" else null;
    const auth_header = try appendClientHeaders(allocator, &headers, c, content_type, "application/json");
    defer if (auth_header) |value| allocator.free(value);

    if (c.http_observer) |obs| {
        if (obs.onRequest) |cb| cb(obs.ctx, method, url, headers.items, payload);
    }

    const uri = try std.Uri.parse(url);
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const start = std.Io.Clock.awake.now(c.io);
    const result = c.http.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .extra_headers = headers.items,
        .payload = payload,
        .response_writer = &response_body.writer,
    }) catch |err| {
        if (c.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, method, url, @errorName(err));
        }
        return err;
    };
    const elapsed_ns = @as(u64, @intCast(start.untilNow(c.io, .awake).nanoseconds));

    const body = try response_body.toOwnedSlice();

    if (c.http_observer) |obs| {
        if (obs.onResponse) |cb| cb(obs.ctx, method, url, result.status, &.{}, body, elapsed_ns);
    }

    return .{
        .allocator = allocator,
        .status = result.status,
        .body = body,
    };
}

fn stringifyStreamRequest(allocator: std.mem.Allocator, requestBody: anytype) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(requestBody, .{ .emit_null_optional_fields = false }, &buf.writer);

    const written = buf.written();
    if (written.len > 0 and written[written.len - 1] == '}') {
        return try std.mem.concat(allocator, u8, &.{
            written[0 .. written.len - 1],
            ",\"stream\":true,\"stream_options\":{\"include_usage\":true}}",
        });
    }
    return buf.toOwnedSlice();
}

pub fn createChatCompletionStreaming(
    c: *Client,
    requestBody: anytype,
    callback: anytype,
    cancellation_token: ?*runtime.CancellationToken,
) !void {
    return createChatCompletionStreamingRaw(c, requestBody, callback, cancellation_token);
}

pub fn createChatCompletionStreamingEvents(
    comptime Event: type,
    c: *Client,
    requestBody: anytype,
    callback: anytype,
    cancellation_token: ?*runtime.CancellationToken,
) !void {
    const Callback = @TypeOf(callback.*);
    var typed_callback: runtime.TypedSseCallback(Event, Callback) = .{
        .allocator = c.allocator,
        .callback = callback,
    };

    return createChatCompletionStreamingRaw(c, requestBody, &typed_callback, cancellation_token);
}

fn createChatCompletionStreamingRaw(
    c: *Client,
    requestBody: anytype,
    callback: anytype,
    cancellation_token: ?*runtime.CancellationToken,
) !void {

    const allocator = c.allocator;
    const payload = try stringifyStreamRequest(allocator, requestBody);
    defer allocator.free(payload);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try appendClientHeaders(allocator, &headers, c, "application/json", "text/event-stream");
    defer if (auth_header) |value| allocator.free(value);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{c.base_url});
    defer allocator.free(url);

    if (c.http_observer) |obs| {
        if (obs.onRequest) |cb| cb(obs.ctx, .POST, url, headers.items, payload);
    }

    const uri = try std.Uri.parse(url);
    try runtime.checkCancellation(cancellation_token);

    const start = std.Io.Clock.awake.now(c.io);
    var req = c.http.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers.items,
    }) catch |err| {
        if (c.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
        }
        return err;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var request_body = try req.sendBodyUnflushed(&.{});
    try request_body.writer.writeAll(payload);
    try request_body.end();
    try req.connection.?.flush();
    try runtime.checkCancellation(cancellation_token);

    var response = req.receiveHead(&.{}) catch |err| {
        if (c.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
        }
        return err;
    };
    const elapsed_ns = @as(u64, @intCast(start.untilNow(c.io, .awake).nanoseconds));
    if (response.head.status.class() != .success) {
        if (c.http_observer) |obs| {
            if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, "", elapsed_ns);
        }
        return error.ResponseError;
    }

    if (c.http_observer) |obs| {
        if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, "", elapsed_ns);
    }

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    var cancelable_reader_buffer: [1]u8 = undefined;
    var cancelable_reader = cancel_reader.CancelableReader.init(response_reader, &cancelable_reader_buffer);
    const reader = &cancelable_reader.reader;

    runtime.parseSseReader(allocator, reader, callback, cancellation_token) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse err,
        else => return err,
    };
}
