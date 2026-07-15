const std = @import("std");

///////////////////////////////////////////
// Generated Zig structures from OpenAPI
///////////////////////////////////////////

pub const ListModelsResponse = struct {
    models: []const ModelInfo,
};

pub const LoadedInstance = struct {
    id: []const u8,
    config: LoadedInstanceConfig,
};

pub const ModelInfoCapabilitiesReasoning = struct {
    allowed_options: []const []const u8,
    default: []const u8,
};

pub const ModelInfoCapabilities = struct {
    trained_for_tool_use: ?bool = null,
    reasoning: ?ModelInfoCapabilitiesReasoning = null,
    vision: ?bool = null,
};

pub const ModelInfoQuantization = struct {
    name: []const u8,
    bits_per_weight: f64,
};

pub const ModelInfo = struct {
    params_string: ?[]const u8 = null,
    publisher: []const u8,
    key: []const u8,
    format: []const u8,
    variants: ?[]const []const u8 = null,
    selected_variant: ?[]const u8 = null,
    display_name: []const u8,
    size_bytes: i64,
    architecture: ?[]const u8 = null,
    max_context_length: i64,
    capabilities: ?ModelInfoCapabilities = null,
    loaded_instances: []const LoadedInstance,
    quantization: ?ModelInfoQuantization = null,
    description: ?[]const u8 = null,
    type: []const u8,
};

pub const LoadedInstanceConfig = struct {
    context_length: i64,
    num_experts: ?i64 = null,
    flash_attention: ?bool = null,
    eval_batch_size: ?i64 = null,
    parallel: ?i64 = null,
    offload_kv_cache_to_gpu: ?bool = null,
};

pub fn Owned(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        body: []u8,
        parsed: std.json.Parsed(T),

        pub fn deinit(self: *@This()) void {
            self.parsed.deinit();
            self.allocator.free(self.body);
        }

        pub fn value(self: *@This()) *T {
            return &self.parsed.value;
        }
    };
}

pub const RawResponse = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.body);
    }
};

pub const ParseErrorResponse = struct {
    raw: RawResponse,
    error_name: []const u8,
};

pub fn ApiResult(comptime T: type) type {
    return union(enum) {
        ok: Owned(T),
        api_error: RawResponse,
        parse_error: ParseErrorResponse,

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .ok => |*value| value.deinit(),
                .api_error => |*value| value.deinit(),
                .parse_error => |*value| value.raw.deinit(),
            }
        }
    };
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http: std.http.Client,
    api_key: []const u8,
    base_url: []const u8 = "",
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,
    default_headers: []const std.http.Header = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http = .{ .allocator = allocator, .io = io },
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub fn withBaseUrl(self: *Client, base_url: []const u8) void {
        self.base_url = base_url;
    }
};

pub fn requestRaw(client: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8) !RawResponse {
    return requestRawWithContentType(client, method, url, payload, "application/json");
}

pub fn requestRawWithContentType(client: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8, content_type_value: []const u8) !RawResponse {
    const allocator = client.allocator;
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const content_type: ?[]const u8 = if (payload != null) content_type_value else null;
    const auth_header = try appendClientHeaders(allocator, &headers, client, content_type, "application/json");
    defer if (auth_header) |value| allocator.free(value);

    const uri = try std.Uri.parse(url);
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.http.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .extra_headers = headers.items,
        .payload = payload,
        .response_writer = &response_body.writer,
    });

    return .{
        .allocator = allocator,
        .status = result.status,
        .body = try response_body.toOwnedSlice(),
    };
}

pub fn parseRawResponse(comptime T: type, raw: RawResponse) !ApiResult(T) {
    if (raw.status.class() != .success) return .{ .api_error = raw };
    const parsed = std.json.parseFromSlice(T, raw.allocator, raw.body, .{ .ignore_unknown_fields = true }) catch |err| {
        return .{ .parse_error = .{ .raw = raw, .error_name = @errorName(err) } };
    };
    return .{ .ok = .{ .allocator = raw.allocator, .body = raw.body, .parsed = parsed } };
}

const max_sse_line_size = 256 * 1024;
const max_sse_event_size = 1024 * 1024;

pub fn parseSseReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, callback: anytype) !void {
    var line_buf: std.Io.Writer.Allocating = .init(allocator);
    defer line_buf.deinit();

    var event_data: std.Io.Writer.Allocating = .init(allocator);
    defer event_data.deinit();

    while (true) {
        line_buf.clearRetainingCapacity();

        _ = reader.streamDelimiterLimit(&line_buf.writer, '\n', .limited(max_sse_line_size)) catch |err| switch (err) {
            error.StreamTooLong => return error.SseLineTooLong,
            error.ReadFailed => return err,
            error.WriteFailed => return err,
        };

        const ended_with_delimiter = blk: {
            const byte = reader.peekByte() catch |err| switch (err) {
                error.EndOfStream => break :blk false,
                error.ReadFailed => return err,
            };
            if (byte == '\n') {
                _ = try reader.takeByte();
                break :blk true;
            }
            break :blk false;
        };

        if (try processSseLine(&event_data, line_buf.written(), callback)) return;
        if (!ended_with_delimiter) break;
    }

    _ = try dispatchSseEvent(&event_data, callback);
}

fn processSseLine(event_data: *std.Io.Writer.Allocating, raw_line: []const u8, callback: anytype) !bool {
    const line = std.mem.trimEnd(u8, raw_line, "\r");
    if (line.len == 0) return try dispatchSseEvent(event_data, callback);
    if (line[0] == ':') return false;

    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const field = line[0..colon];
    if (!std.mem.eql(u8, field, "data")) return false;

    var value = line[colon + 1 ..];
    if (value.len > 0 and value[0] == ' ') value = value[1..];
    const separator_len: usize = if (event_data.written().len == 0) 0 else 1;
    if (event_data.written().len + separator_len + value.len > max_sse_event_size) return error.SseEventTooLong;
    if (separator_len != 0) try event_data.writer.writeByte('\n');
    try event_data.writer.writeAll(value);
    return false;
}

fn dispatchSseEvent(event_data: *std.Io.Writer.Allocating, callback: anytype) !bool {
    const data = event_data.written();
    if (data.len == 0) return false;
    defer event_data.clearRetainingCapacity();

    if (std.mem.eql(u8, data, "[DONE]")) return true;
    try callback.event(data);
    return false;
}

pub fn appendClientHeaders(allocator: std.mem.Allocator, headers: *std.ArrayList(std.http.Header), client: *Client, content_type: ?[]const u8, accept: []const u8) !?[]u8 {
    if (content_type) |ct| {
        try headers.append(allocator, .{ .name = "Content-Type", .value = ct });
    }
    try headers.append(allocator, .{ .name = "Accept", .value = accept });

    var auth_header: ?[]u8 = null;
    if (client.api_key.len > 0) {
        const scheme = "Bearer";
        auth_header = try std.fmt.allocPrint(allocator, "{s} {s}", .{ scheme, client.api_key });
        try headers.append(allocator, .{ .name = "Authorization", .value = auth_header.? });
    }
    if (client.organization) |organization| {
        try headers.append(allocator, .{ .name = "OpenAI-Organization", .value = organization });
    }
    if (client.project) |project| {
        try headers.append(allocator, .{ .name = "OpenAI-Project", .value = project });
    }
    for (client.default_headers) |header| {
        try headers.append(allocator, header);
    }
    return auth_header;
}

/////////////////
// Summary:
// List your models
//
// Description:
// Get a list of available models on your system, including both LLMs and embedding models.
//
pub fn listModels(client: *Client) !Owned(ListModelsResponse) {
    var result = try listModelsResult(client);
    switch (result) {
        .ok => |ok| return ok,
        .api_error => |*err| {
            if (isAuthFailure(err.status)) printAuthHint(client.io);
            err.deinit();
            return error.ResponseError;
        },
        .parse_error => |*err| {
            err.raw.deinit();
            return error.ResponseParseError;
        },
    }
}

fn isAuthFailure(status: std.http.Status) bool {
    return status == .unauthorized or status == .forbidden;
}

pub fn printAuthHint(io: std.Io) void {
    var buf: [256]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stderr(), io, &buf);
    fw.interface.print("Authentication failed. Configure an API key with --api-key, PUNY_API_KEY, or --reconfigure.\n", .{}) catch {};
    fw.interface.flush() catch {};
}

pub fn listModelsRaw(client: *Client) !RawResponse {
    const allocator = client.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/api/v1/models", .{client.base_url});
    const payload: ?[]const u8 = null;

    return requestRaw(client, std.http.Method.GET, uri_buf.written(), payload);
}

pub fn listModelsResult(client: *Client) !ApiResult(ListModelsResponse) {
    return parseRawResponse(ListModelsResponse, try listModelsRaw(client));
}

test "appendClientHeaders sends Authorization header with scheme and key" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .http = undefined,
        .api_key = "my-secret-key",
    };

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth_header = try appendClientHeaders(allocator, &headers, &client, "application/json", "application/json");
    defer if (auth_header) |value| allocator.free(value);

    try std.testing.expectEqual(@as(usize, 3), headers.items.len);
    const auth = findHeader(headers.items, "Authorization");
    try std.testing.expect(auth != null);
    const expected = try std.fmt.allocPrint(allocator, "{s} {s}", .{ "Bearer", "my-secret-key" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, auth.?.value);
}

test "appendClientHeaders omits Authorization header when api key is empty" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .http = undefined,
        .api_key = "",
    };

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth_header = try appendClientHeaders(allocator, &headers, &client, "application/json", "application/json");
    defer if (auth_header) |value| allocator.free(value);

    const auth = findHeader(headers.items, "Authorization");
    try std.testing.expect(auth == null);
}

fn findHeader(headers: []const std.http.Header, name: []const u8) ?std.http.Header {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, name)) return header;
    }
    return null;
}
