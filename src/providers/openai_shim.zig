const std = @import("std");
const client = @import("client.zig");
const openai_models = @import("openai/models.zig");
const runtime = @import("openai/runtime.zig");
const cancel_reader = @import("openai/cancel_reader.zig");

pub const Model = openai_models.Model;
pub const ListModelsResponse = openai_models.ListModelsResponse;

pub const Client = client.Client;

// List models via OpenAI-compatible endpoint, lenient parsing for opencode
pub fn listModels(c: *Client) !client.Owned(ListModelsResponse) {
    // Use raw fetch then lenient parse
    const allocator = c.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/v1/models", .{c.base_url});
    var raw = try client.requestRaw(c, std.http.Method.GET, uri_buf.written(), null);
    errdefer raw.deinit();
    if (raw.status.class() != .success) {
        if (client.isAuthFailure(raw.status)) client.printAuthHint(c.io);
        raw.deinit();
        return error.ResponseError;
    }
    // Try generated parsing first
    const body = try allocator.dupe(u8, raw.body);
    errdefer allocator.free(body);
    if (std.json.parseFromSlice(ListModelsResponse, allocator, body, .{ .ignore_unknown_fields = true })) |parsed| {
        raw.deinit();
        return .{ .allocator = allocator, .body = body, .parsed = parsed };
    } else |_| {
        // Fallback to lenient parsing for opencode minimal responses
        allocator.free(body);
        const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, raw.body, .{ .ignore_unknown_fields = true });
        defer parsed_value.deinit();
        const data = parsed_value.value.object.get("data") orelse {
            raw.deinit();
            return error.ResponseParseError;
        };
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);
        var models: std.ArrayList(Model) = .empty;
        for (data.array.items) |item| {
            const id = if (item.object.get("id")) |v| v.string else continue;
            const owned_by = if (item.object.get("owned_by")) |v| v.string else "opencode";
            const object = if (item.object.get("object")) |v| v.string else "model";
            const created = if (item.object.get("created")) |v| v.integer else 0;
            try models.append(arena.allocator(), .{
                .id = try arena.allocator().dupe(u8, id),
                .owned_by = try arena.allocator().dupe(u8, owned_by),
                .object = try arena.allocator().dupe(u8, object),
                .created = created,
            });
        }
        const result = std.json.Parsed(ListModelsResponse){
            .arena = arena,
            .value = .{ .object = "list", .data = try models.toOwnedSlice(arena.allocator()) },
        };
        const owned_body = try allocator.dupe(u8, raw.body);
        raw.deinit();
        return .{ .allocator = allocator, .body = owned_body, .parsed = result };
    }
}

pub fn toSharedModels(owned: *client.Owned(ListModelsResponse)) !client.Owned(client.ModelsList) {
    const allocator = owned.allocator;
    const source = owned.value();
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();
    var models = try arena_alloc.alloc(client.Model, source.data.len);
    for (source.data, 0..) |m, i| {
        models[i] = .{
            .id = try arena_alloc.dupe(u8, m.id),
            .display_name = try arena_alloc.dupe(u8, m.id),
            .provider = try arena_alloc.dupe(u8, m.owned_by),
            .context_length = 0,
        };
    }
    owned.deinit();
    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{ .arena = arena, .value = .{ .models = models } },
    };
}

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
    if (c.organization) |org| {
        try headers.append(allocator, .{ .name = "OpenAI-Organization", .value = org });
    }
    if (c.project) |proj| {
        try headers.append(allocator, .{ .name = "OpenAI-Project", .value = proj });
    }
    for (c.default_headers) |h| {
        try headers.append(allocator, h);
    }
    return auth_header;
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

pub fn chatStreaming(c: *Client, request: @import("openai.zig").ChatRequest, callback: @import("openai.zig").StreamCallback) !void {
    // Delegate to the existing hand-written implementation but via the generated runtime's SSE parser.
    // This thin wrapper ensures the provider uses the generated contracts for model listing
    // while reusing the proven streaming logic for chat (which is covered by generated runtime).
    const openai = @import("openai.zig");
    const client_ptr: *client.Client = @ptrCast(c);
    return openai.chatStreaming(client_ptr, request, callback);
}

pub fn createChatCompletionStreaming(c: *Client, requestBody: anytype, callback: anytype, cancellation_token: ?*runtime.CancellationToken) !void {
    const allocator = c.allocator;
    const payload = try stringifyStreamRequest(allocator, requestBody);
    defer allocator.free(payload);
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try appendClientHeaders(allocator, &headers, c, "application/json", "text/event-stream");
    defer if (auth_header) |v| allocator.free(v);
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

test "toSharedModels copies openai models" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[{"id":"alpha","object":"model","created":123,"owned_by":"opencode"}]}
    ;
    const parsed = try std.json.parseFromSlice(ListModelsResponse, allocator, json, .{ .ignore_unknown_fields = true });
    var owned = client.Owned(ListModelsResponse){ .allocator = allocator, .body = try allocator.dupe(u8, json), .parsed = parsed };
    var shared = try toSharedModels(&owned);
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("alpha", shared.value().models[0].id);
    try std.testing.expectEqualStrings("opencode", shared.value().models[0].provider);
}
