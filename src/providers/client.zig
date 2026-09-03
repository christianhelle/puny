const std = @import("std");
const builtin = @import("builtin");
const version = @import("../version.zig");

///////////////////////////////////////////
// Shared app model-list types
///////////////////////////////////////////

/// Provider-agnostic model descriptor used by the app UI and selection logic.
pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
    provider: []const u8,
    context_length: i64,
};

pub const ModelsList = struct {
    models: []const Model,
};

/// Returns true when `s` is a valid UTF-8 byte sequence.
pub fn isValidUtf8(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return false;
        if (i + len > s.len) return false;
        _ = std.unicode.utf8Decode(s[i..][0..len]) catch return false;
        i += len;
    }
    return true;
}

///////////////////////////////////////////
// HTTP client primitives
///////////////////////////////////////////

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

pub const HttpFailure = struct {
    status: std.http.Status,
    body: []u8,
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

pub const ClientConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    http_observer: ?HttpObserver = null,
    session_id: ?[]const u8 = null,
};

pub const HttpObserver = struct {
    ctx: ?*anyopaque,
    onRequest: ?*const fn (ctx: ?*anyopaque, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) void,
    onResponse: ?*const fn (ctx: ?*anyopaque, method: std.http.Method, url: []const u8, status: std.http.Status, headers: []const std.http.Header, body: []const u8, duration_ns: u64) void,
    onError: ?*const fn (ctx: ?*anyopaque, method: std.http.Method, url: []const u8, err_name: []const u8) void,
    on_chunk: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http: std.http.Client,
    api_key: []const u8,
    base_url: []const u8 = "",
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,
    default_headers: []const std.http.Header = &.{},
    /// Stable per-conversation id sent as the OpenCode session header.
    session_id: ?[]const u8 = null,
    http_observer: ?HttpObserver = null,
    last_http_failure: ?HttpFailure = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http = .{ .allocator = allocator, .io = io },
            .api_key = api_key,
            .http_observer = null,
        };
    }

    pub fn deinit(self: *Client) void {
        self.clearLastHttpFailure();
        self.http.deinit();
    }

    pub fn withBaseUrl(self: *Client, base_url: []const u8) void {
        self.base_url = base_url;
    }

    pub fn setConfig(self: *Client, config: ClientConfig) void {
        if (config.base_url) |url| self.withBaseUrl(url);
        if (config.api_key) |key| self.api_key = key;
        if (config.http_observer) |obs| self.http_observer = obs;
        if (config.session_id) |id| self.session_id = id;
    }

    /// The OpenCode session header to send, or null when this client carries
    /// no usable session id.
    pub fn sessionHeader(self: *const Client) ?std.http.Header {
        const session_id = self.session_id orelse return null;
        const value = sessionHeaderValue(session_id);
        if (value.len == 0) return null;
        return .{ .name = session_header_name, .value = value };
    }

    pub fn clearLastHttpFailure(self: *Client) void {
        if (self.last_http_failure) |failure| self.allocator.free(failure.body);
        self.last_http_failure = null;
    }

    pub fn lastHttpFailure(self: *const Client) ?*const HttpFailure {
        return if (self.last_http_failure) |*failure| failure else null;
    }
};

pub const HttpFailureCapture = struct {
    allocator: std.mem.Allocator,
    downstream: ?HttpObserver,
    failure: ?HttpFailure = null,
    capture_error: ?anyerror = null,

    pub fn init(client: *Client) HttpFailureCapture {
        return .{
            .allocator = client.allocator,
            .downstream = client.http_observer,
        };
    }

    pub fn deinit(self: *HttpFailureCapture) void {
        if (self.failure) |failure| self.allocator.free(failure.body);
    }

    pub fn observer(self: *HttpFailureCapture) HttpObserver {
        return .{
            .ctx = self,
            .onRequest = onRequest,
            .onResponse = onResponse,
            .onError = onError,
            .on_chunk = onChunk,
        };
    }

    pub fn commit(self: *HttpFailureCapture, client: *Client) !void {
        if (self.capture_error) |err| return err;
        client.clearLastHttpFailure();
        client.last_http_failure = self.failure;
        self.failure = null;
    }

    fn onRequest(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) void {
        const self: *HttpFailureCapture = @ptrCast(@alignCast(ctx.?));
        if (self.downstream) |downstream| {
            if (downstream.onRequest) |callback| callback(downstream.ctx, method, url, headers, body);
        }
    }

    fn onResponse(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, status: std.http.Status, headers: []const std.http.Header, body: []const u8, duration_ns: u64) void {
        const self: *HttpFailureCapture = @ptrCast(@alignCast(ctx.?));
        if (status.class() != .success and self.capture_error == null) {
            if (self.allocator.dupe(u8, body)) |owned_body| {
                if (self.failure) |failure| self.allocator.free(failure.body);
                self.failure = .{ .status = status, .body = owned_body };
            } else |err| {
                self.capture_error = err;
            }
        }
        if (self.downstream) |downstream| {
            if (downstream.onResponse) |callback| callback(downstream.ctx, method, url, status, headers, body, duration_ns);
        }
    }

    fn onError(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, err_name: []const u8) void {
        const self: *HttpFailureCapture = @ptrCast(@alignCast(ctx.?));
        if (self.downstream) |downstream| {
            if (downstream.onError) |callback| callback(downstream.ctx, method, url, err_name);
        }
    }

    fn onChunk(ctx: ?*anyopaque, data: []const u8) void {
        const self: *HttpFailureCapture = @ptrCast(@alignCast(ctx.?));
        if (self.downstream) |downstream| {
            if (downstream.on_chunk) |callback| callback(downstream.ctx, data);
        }
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

    if (client.http_observer) |obs| {
        if (obs.onRequest) |cb| cb(obs.ctx, method, url, headers.items, payload);
    }

    const uri = try std.Uri.parse(url);
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const start = std.Io.Clock.awake.now(client.io);
    const result = client.http.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .extra_headers = headers.items,
        .payload = payload,
        .response_writer = &response_body.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch |err| {
        if (client.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, method, url, @errorName(err));
        }
        return err;
    };
    const elapsed_ns = @as(u64, @intCast(start.untilNow(client.io, .awake).nanoseconds));

    const body = try response_body.toOwnedSlice();

    if (client.http_observer) |obs| {
        if (obs.onResponse) |cb| cb(obs.ctx, method, url, result.status, &.{}, body, elapsed_ns);
    }

    return .{
        .allocator = allocator,
        .status = result.status,
        .body = body,
    };
}

pub fn parseRawResponse(comptime T: type, raw: RawResponse) !ApiResult(T) {
    if (raw.status.class() != .success) return .{ .api_error = raw };
    const parsed = std.json.parseFromSlice(T, raw.allocator, raw.body, .{ .ignore_unknown_fields = true }) catch |err| {
        return .{ .parse_error = .{ .raw = raw, .error_name = @errorName(err) } };
    };
    return .{ .ok = .{ .allocator = raw.allocator, .body = raw.body, .parsed = parsed } };
}

/// User-Agent identifying this client and its version to providers.
pub const user_agent = version.user_agent;

/// Header OpenCode uses to group requests belonging to the same conversation.
pub const session_header_name = "x-opencode-session";

/// OpenCode's usage metrics only surface a short slice of the session id, so
/// requests carry the same 8-character prefix `--session` matches on.
pub const session_header_len = 8;

pub fn sessionHeaderValue(session_id: []const u8) []const u8 {
    return session_id[0..@min(session_id.len, session_header_len)];
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
    if (client.sessionHeader()) |session_header| {
        try headers.append(allocator, session_header);
    }
    return auth_header;
}

pub fn isAuthFailure(status: std.http.Status) bool {
    return status == .unauthorized or status == .forbidden;
}

pub fn emitDiagnostic(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(format, args);
}

pub fn printAuthHint(io: std.Io) void {
    if (builtin.is_test) return;
    var buf: [256]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stderr(), io, &buf);
    fw.interface.print("Authentication failed. Configure an API key with --api-key, PUNY_API_KEY, or --reconfigure.\n", .{}) catch {};
    fw.interface.flush() catch {};
}

///////////////////////////////////////////
// Cancellation
///////////////////////////////////////////

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool),

    pub fn init() CancellationToken {
        return .{ .cancelled = std.atomic.Value(bool).init(false) };
    }

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn isCancelled(self: *CancellationToken) bool {
        return self.cancelled.load(.seq_cst);
    }
};

pub const CancelWatcher = struct {
    connection: ?*std.http.Client.Connection,
    io: std.Io,
    pred: *const fn () bool,
    done: *std.atomic.Value(bool),
    replacement_handle: ?std.Io.net.Socket.Handle = null,
    interrupted: bool = false,

    const Windows = if (builtin.os.tag == .windows) struct {
        extern "kernel32" fn CreateEventW(event_attributes: ?*anyopaque, manual_reset: std.os.windows.BOOL, initial_state: std.os.windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
    } else struct {};

    pub fn run(self: *CancelWatcher) void {
        while (!self.done.load(.acquire)) {
            if (self.pred()) {
                if (self.connection) |conn| {
                    if (comptime builtin.os.tag == .windows) {
                        if (Windows.CreateEventW(null, .FALSE, .FALSE, null)) |replacement| {
                            self.replacement_handle = replacement;
                            self.interrupted = true;
                            conn.stream_reader.stream.close(self.io);
                        } else {
                            self.interrupted = true;
                            conn.stream_reader.stream.shutdown(self.io, .both) catch {};
                        }
                    } else {
                        self.interrupted = true;
                        conn.stream_reader.stream.shutdown(self.io, .both) catch {};
                    }
                }
                return;
            }
            self.io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
        }
    }

    pub fn restoreConnection(self: *CancelWatcher) void {
        if (!self.interrupted) return;
        const conn = self.connection.?;
        if (comptime builtin.os.tag == .windows) {
            if (self.replacement_handle) |handle| {
                conn.stream_reader.stream.socket.handle = handle;
                conn.stream_writer.stream.socket.handle = handle;
            }
        }
        conn.closing = true;
    }
};

fn checkCancellation(token: ?*CancellationToken) !void {
    if (token) |t| {
        if (t.isCancelled()) return error.Cancelled;
    }
}

///////////////////////////////////////////
// Server-sent events parsing
///////////////////////////////////////////

const max_sse_line_size = 256 * 1024;
const max_sse_event_size = 1024 * 1024;

pub fn parseSseBytes(allocator: std.mem.Allocator, bytes: []const u8, callback: anytype, cancellation_token: ?*CancellationToken) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    try parseSseReader(allocator, &reader, callback, cancellation_token);
}

pub fn parseSseReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, callback: anytype, cancellation_token: ?*CancellationToken) !void {
    var line_buf: std.Io.Writer.Allocating = .init(allocator);
    defer line_buf.deinit();

    var event_data: std.Io.Writer.Allocating = .init(allocator);
    defer event_data.deinit();

    while (true) {
        try checkCancellation(cancellation_token);
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

///////////////////////////////////////////
// Tests
///////////////////////////////////////////

fn findHeader(headers: []const std.http.Header, name: []const u8) ?std.http.Header {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, name)) return header;
    }
    return null;
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

test "lmstudio client compiles after regeneration" {
    const lmstudio = @import("lmstudio/client.zig");
    _ = lmstudio.Client;
    const contracts = @import("lmstudio/contracts.zig");
    _ = contracts.ListModelsResponse;
    _ = contracts.ModelInfo;
}

test "isValidUtf8 accepts ASCII and rejects invalid bytes" {
    try std.testing.expect(isValidUtf8("hello"));
    try std.testing.expect(isValidUtf8("Qwen2.5 7B Instruct"));
    try std.testing.expect(!isValidUtf8(&.{0xaa}));
    try std.testing.expect(!isValidUtf8(&.{ 0xc0, 0x80 }));
}

test "setConfig applies non-null fields and preserves null ones" {
    var client = Client{
        .allocator = undefined,
        .io = undefined,
        .http = undefined,
        .api_key = "old-key",
        .base_url = "http://old.url",
        .http_observer = null,
    };

    client.setConfig(.{ .base_url = "http://new.url" });
    try std.testing.expectEqualStrings("http://new.url", client.base_url);
    try std.testing.expectEqualStrings("old-key", client.api_key);

    client.setConfig(.{ .api_key = "new-key" });
    try std.testing.expectEqualStrings("new-key", client.api_key);
    try std.testing.expectEqualStrings("http://new.url", client.base_url);

    client.setConfig(.{});
    try std.testing.expectEqualStrings("http://new.url", client.base_url);
    try std.testing.expectEqualStrings("new-key", client.api_key);
}

test "appendClientHeaders omits Content-Type when null and adds org project and defaults" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .http = undefined,
        .api_key = "",
        .organization = "my-org",
        .project = "my-project",
        .default_headers = &.{.{ .name = "X-Default", .value = "1" }},
    };

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth_header = try appendClientHeaders(allocator, &headers, &client, null, "application/json");
    defer if (auth_header) |value| allocator.free(value);

    try std.testing.expect(findHeader(headers.items, "Content-Type") == null);
    try std.testing.expect(findHeader(headers.items, "Authorization") == null);
    try std.testing.expectEqualStrings("application/json", findHeader(headers.items, "Accept").?.value);
    try std.testing.expectEqualStrings("my-org", findHeader(headers.items, "OpenAI-Organization").?.value);
    try std.testing.expectEqualStrings("my-project", findHeader(headers.items, "OpenAI-Project").?.value);
    try std.testing.expectEqualStrings("1", findHeader(headers.items, "X-Default").?.value);
}

test "isAuthFailure recognizes unauthorized and forbidden" {
    try std.testing.expect(isAuthFailure(.unauthorized));
    try std.testing.expect(isAuthFailure(.forbidden));
    try std.testing.expect(!isAuthFailure(.ok));
    try std.testing.expect(!isAuthFailure(.not_found));
    try std.testing.expect(!isAuthFailure(.internal_server_error));
}

test "CancellationToken cancels and reports cancellation" {
    var token = CancellationToken.init();
    try std.testing.expect(!token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
}

// ── SSE parsing tests ────────────────────────────────────────────────

const SseRecorder = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList([]u8),

    pub fn event(self: *@This(), data: []const u8) !void {
        try self.events.append(self.allocator, try self.allocator.dupe(u8, data));
    }
};

test "parseSseBytes dispatches multiline data events and stops at DONE" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events };

    const bytes =
        ":keep-alive comment\n" ++
        "event: message\n" ++
        "data: first\n" ++
        "data: second line\n" ++
        "id: 42\n" ++
        "\n" ++
        "data: {\"a\":1}\n" ++
        "\n" ++
        "data: [DONE]\n" ++
        "\n" ++
        "data: after done\n" ++
        "\n";
    try parseSseBytes(allocator, bytes, &recorder, null);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("first\nsecond line", events.items[0]);
    try std.testing.expectEqualStrings("{\"a\":1}", events.items[1]);
}

test "parseSseBytes handles events without a trailing blank line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events };

    try parseSseBytes(allocator, "data: solo", &recorder, null);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("solo", events.items[0]);
}

test "parseSseBytes tolerates CRLF line endings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events };

    try parseSseBytes(allocator, "data: x\r\n\r\n", &recorder, null);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("x", events.items[0]);
}

test "parseSseBytes rejects oversized lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events };

    const line = try allocator.alloc(u8, 300 * 1024);
    @memset(line, 'a');

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll("data: ");
    try bytes.writer.writeAll(line);
    try bytes.writer.writeByte('\n');

    try std.testing.expectError(error.SseLineTooLong, parseSseBytes(allocator, bytes.written(), &recorder, null));
}

test "parseSseBytes rejects oversized events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events };

    const chunk = try allocator.alloc(u8, 250 * 1024);
    @memset(chunk, 'a');

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    for (0..5) |_| {
        try bytes.writer.writeAll("data: ");
        try bytes.writer.writeAll(chunk);
        try bytes.writer.writeByte('\n');
    }
    try bytes.writer.writeByte('\n');

    try std.testing.expectError(error.SseEventTooLong, parseSseBytes(allocator, bytes.written(), &recorder, null));
}

test "parseSseBytes respects the cancellation token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events };

    var token = CancellationToken.init();
    token.cancel();
    try std.testing.expectError(error.Cancelled, parseSseBytes(allocator, "data: x\n\n", &recorder, &token));
}

const FailingSseReader = struct {
    reader: std.Io.Reader,

    fn init() FailingSseReader {
        return .{
            .reader = .{
                .buffer = &.{},
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = stream,
                    .discard = discard,
                    .readVec = readVec,
                    .rebase = rebase,
                },
            },
        };
    }

    fn rebase(ctx: *std.Io.Reader, capacity: usize) std.Io.Reader.Error!void {
        _ = ctx;
        _ = capacity;
    }

    fn stream(ctx: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = ctx;
        _ = w;
        _ = limit;
        return error.ReadFailed;
    }

    fn discard(ctx: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        _ = ctx;
        _ = limit;
        return error.ReadFailed;
    }

    fn readVec(ctx: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = ctx;
        _ = data;
        return error.ReadFailed;
    }
};

test "parseSseReader propagates read failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events };

    var failing = FailingSseReader.init();
    try std.testing.expectError(error.ReadFailed, parseSseReader(allocator, &failing.reader, &recorder, null));
}

// ── parseRawResponse tests ───────────────────────────────────────────

const SimpleResponse = struct {
    value: []const u8,
};

fn rawResponse(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) !RawResponse {
    return .{
        .allocator = allocator,
        .status = status,
        .body = try allocator.dupe(u8, body),
    };
}

test "parseRawResponse maps ok api_error and parse_error states" {
    const allocator = std.testing.allocator;

    {
        var result = try parseRawResponse(SimpleResponse, try rawResponse(allocator, .ok, "{\"value\":\"x\"}"));
        try std.testing.expect(result == .ok);
        try std.testing.expectEqualStrings("x", result.ok.value().value);
        result.deinit();
    }

    {
        var result = try parseRawResponse(SimpleResponse, try rawResponse(allocator, .internal_server_error, "oops"));
        try std.testing.expect(result == .api_error);
        try std.testing.expectEqual(@as(i64, @intFromEnum(std.http.Status.internal_server_error)), @intFromEnum(result.api_error.status));
        result.deinit();
    }

    {
        var result = try parseRawResponse(SimpleResponse, try rawResponse(allocator, .ok, "not json"));
        try std.testing.expect(result == .parse_error);
        result.deinit();
    }
}

test "ApiResult deinit frees every state" {
    const allocator = std.testing.allocator;

    {
        const parsed = try std.json.parseFromSlice(SimpleResponse, allocator, "{\"value\":\"x\"}", .{ .ignore_unknown_fields = true });
        const owned = Owned(SimpleResponse){
            .allocator = allocator,
            .body = try allocator.dupe(u8, "{\"value\":\"x\"}"),
            .parsed = parsed,
        };
        var result = ApiResult(SimpleResponse){ .ok = owned };
        result.deinit();
    }

    {
        const raw = try rawResponse(allocator, .internal_server_error, "boom");
        var result = ApiResult(SimpleResponse){ .api_error = raw };
        result.deinit();
    }

    {
        const raw = try rawResponse(allocator, .ok, "boom");
        var result = ApiResult(SimpleResponse){ .parse_error = .{ .raw = raw, .error_name = "SyntaxError" } };
        result.deinit();
    }
}

// ── HTTP server tests ────────────────────────────────────────────────

const HttpTestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    status: std.http.Status,
    body: []const u8,
    thread: std.Thread = undefined,

    fn serve(self: *@This()) void {
        var stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);

        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch return;
        request.respond(self.body, .{ .status = self.status }) catch return;
    }
};

fn startHttpTestServer(status: std.http.Status, body: []const u8) !*HttpTestServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(HttpTestServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    errdefer ctx.server.deinit(std.testing.io);
    ctx.thread = try std.Thread.spawn(.{}, HttpTestServer.serve, .{ctx});
    return ctx;
}

fn stopHttpTestServer(ctx: *HttpTestServer) void {
    ctx.server.deinit(std.testing.io);
    ctx.thread.join();
    std.testing.allocator.destroy(ctx);
}

fn clientForTestServer(ctx: *HttpTestServer, arena: std.mem.Allocator, api_key: []const u8) !Client {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    var c = Client.init(std.testing.allocator, std.testing.io, api_key);
    c.withBaseUrl(url);
    return c;
}

test "requestRaw returns the response body and status" {
    const ctx = try startHttpTestServer(.ok, "{\"ok\":true}");
    defer stopHttpTestServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForTestServer(ctx, arena, "secret-key");
    defer c.deinit();

    var raw = try requestRaw(&c, .GET, c.base_url, null);
    defer raw.deinit();

    try std.testing.expectEqual(.ok, raw.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", raw.body);
}

test "requestRaw returns the raw body for a non-success status" {
    const ctx = try startHttpTestServer(.internal_server_error, "boom");
    defer stopHttpTestServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForTestServer(ctx, arena, "");
    defer c.deinit();

    var raw = try requestRaw(&c, .GET, c.base_url, null);
    defer raw.deinit();

    try std.testing.expectEqual(.internal_server_error, raw.status);
    try std.testing.expectEqualStrings("boom", raw.body);
}

test "requestRaw notifies the http observer" {
    const ctx = try startHttpTestServer(.ok, "pong");
    defer stopHttpTestServer(ctx);

    const ObserverCtx = struct {
        requests: usize = 0,
        responses: usize = 0,
        errors: usize = 0,

        fn onRequest(user_ctx: ?*anyopaque, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) void {
            _ = method;
            _ = url;
            _ = headers;
            _ = body;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.requests += 1;
        }

        fn onResponse(user_ctx: ?*anyopaque, method: std.http.Method, url: []const u8, status: std.http.Status, headers: []const std.http.Header, body: []const u8, duration_ns: u64) void {
            _ = method;
            _ = url;
            _ = status;
            _ = headers;
            _ = body;
            _ = duration_ns;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.responses += 1;
        }

        fn onError(user_ctx: ?*anyopaque, method: std.http.Method, url: []const u8, err_name: []const u8) void {
            _ = method;
            _ = url;
            _ = err_name;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.errors += 1;
        }
    };

    var observer_ctx = ObserverCtx{};
    const observer = HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = ObserverCtx.onRequest,
        .onResponse = ObserverCtx.onResponse,
        .onError = ObserverCtx.onError,
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForTestServer(ctx, arena, "");
    defer c.deinit();
    c.http_observer = observer;

    var raw = try requestRaw(&c, .GET, c.base_url, null);
    defer raw.deinit();

    try std.testing.expectEqual(@as(usize, 1), observer_ctx.requests);
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.responses);
    try std.testing.expectEqual(@as(usize, 0), observer_ctx.errors);
}

test "requestRaw reports connection errors to the http observer" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    server.deinit(std.testing.io);

    const ObserverCtx = struct {
        errors: usize = 0,
        fn onError(ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, err_name: []const u8) void {
            _ = method;
            _ = request_url;
            _ = err_name;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.errors += 1;
        }
    };

    var observer_ctx = ObserverCtx{};
    const observer = HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = Client.init(std.testing.allocator, std.testing.io, "");
    defer c.deinit();
    c.withBaseUrl(url);
    c.http_observer = observer;

    if (requestRaw(&c, .GET, url, null)) |_| {
        return error.ExpectedConnectionFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

test "requestRaw invokes every observer callback on connection errors" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    server.deinit(std.testing.io);

    const ObserverCtx = struct {
        requests: usize = 0,
        responses: usize = 0,
        errors: usize = 0,

        fn onRequest(user_ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, headers: []const std.http.Header, body: ?[]const u8) void {
            _ = method;
            _ = request_url;
            _ = headers;
            _ = body;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.requests += 1;
        }

        fn onResponse(user_ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, status: std.http.Status, headers: []const std.http.Header, body: []const u8, duration_ns: u64) void {
            _ = method;
            _ = request_url;
            _ = status;
            _ = headers;
            _ = body;
            _ = duration_ns;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.responses += 1;
        }

        fn onError(user_ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, err_name: []const u8) void {
            _ = method;
            _ = request_url;
            _ = err_name;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.errors += 1;
        }
    };

    var observer_ctx = ObserverCtx{};
    const observer = HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = ObserverCtx.onRequest,
        .onResponse = ObserverCtx.onResponse,
        .onError = ObserverCtx.onError,
    };

    var c = Client.init(std.testing.allocator, std.testing.io, "");
    defer c.deinit();
    c.withBaseUrl(url);
    c.http_observer = observer;

    if (requestRaw(&c, .GET, url, null)) |_| {
        return error.ExpectedConnectionFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.requests);
    try std.testing.expectEqual(@as(usize, 0), observer_ctx.responses);
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

test "isValidUtf8 accepts multibyte sequences and rejects truncation" {
    try std.testing.expect(isValidUtf8("héllo"));
    try std.testing.expect(isValidUtf8("日本語テキスト"));
    try std.testing.expect(isValidUtf8("emoji 🎉 ok"));
    try std.testing.expect(!isValidUtf8(&.{0xc3}));
    try std.testing.expect(!isValidUtf8(&.{0x80}));
    try std.testing.expect(!isValidUtf8(&.{ 0xf0, 0x9f, 0x8e }));
    try std.testing.expect(!isValidUtf8(&.{ 'a', 0xe2, 0x82 }));
}

test "FailingSseReader discard and readVec report read failures" {
    var failing = FailingSseReader.init();
    try std.testing.expectError(error.ReadFailed, failing.reader.discard(.limited(16)));
    var buf: [1]u8 = undefined;
    var vec = [_][]u8{&buf};
    try std.testing.expectError(error.ReadFailed, failing.reader.readVec(vec[0..]));
}

test "appendClientHeaders sends the OpenCode session header when a session id is set" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .http = undefined,
        .api_key = "",
        .session_id = "9f1c2b3a",
    };

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth_header = try appendClientHeaders(allocator, &headers, &client, "application/json", "application/json");
    defer if (auth_header) |value| allocator.free(value);

    try std.testing.expectEqualStrings("9f1c2b3a", findHeader(headers.items, "x-opencode-session").?.value);
}

test "appendClientHeaders omits the OpenCode session header without a session id" {
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

    try std.testing.expect(findHeader(headers.items, "x-opencode-session") == null);
}

const UserAgentServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    user_agent: [128]u8 = undefined,
    user_agent_len: usize = 0,
    thread: std.Thread = undefined,

    fn serve(self: *@This()) void {
        var stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);

        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch return;
        var it = request.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
                const len = @min(header.value.len, self.user_agent.len);
                @memcpy(self.user_agent[0..len], header.value[0..len]);
                self.user_agent_len = len;
            }
        }
        request.respond("{}", .{ .status = .ok }) catch return;
    }

    fn received(self: *const @This()) []const u8 {
        return self.user_agent[0..self.user_agent_len];
    }
};

fn startUserAgentServer() !*UserAgentServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = std.testing.allocator.create(UserAgentServer) catch |err| {
        server.deinit(std.testing.io);
        return err;
    };
    ctx.* = .{ .io = std.testing.io, .server = server };
    ctx.thread = try std.Thread.spawn(.{}, UserAgentServer.serve, .{ctx});
    return ctx;
}

fn stopUserAgentServer(ctx: *UserAgentServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

test "requestRaw identifies itself as puny with its version" {
    const ctx = try startUserAgentServer();
    defer stopUserAgentServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var client = Client.init(std.testing.allocator, std.testing.io, "");
    defer client.deinit();

    var raw = try requestRaw(&client, .GET, url, null);
    defer raw.deinit();

    const received = ctx.received();
    try std.testing.expect(std.mem.startsWith(u8, received, "puny/"));
    try std.testing.expectEqualStrings(version.version, received["puny/".len..]);
}

test "setConfig applies the session id and preserves it when unset" {
    var client = Client{
        .allocator = undefined,
        .io = undefined,
        .http = undefined,
        .api_key = "key",
    };

    client.setConfig(.{ .session_id = "9f1c2b3a" });
    try std.testing.expectEqualStrings("9f1c2b3a", client.session_id.?);

    client.setConfig(.{ .base_url = "http://new.url" });
    try std.testing.expectEqualStrings("9f1c2b3a", client.session_id.?);
}

test "sessionHeaderValue keeps the first eight characters of a session id" {
    try std.testing.expectEqualStrings("363313fc", sessionHeaderValue("363313fc-7071-4450-bcc2-bd3eaaf93886"));
    try std.testing.expectEqualStrings("9f1c2b3a", sessionHeaderValue("9f1c2b3a"));
    try std.testing.expectEqualStrings("short", sessionHeaderValue("short"));
    try std.testing.expectEqualStrings("", sessionHeaderValue(""));
}

test "appendClientHeaders sends only the session id prefix" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .http = undefined,
        .api_key = "",
        .session_id = "363313fc-7071-4450-bcc2-bd3eaaf93886",
    };

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth_header = try appendClientHeaders(allocator, &headers, &client, "application/json", "application/json");
    defer if (auth_header) |value| allocator.free(value);

    try std.testing.expectEqualStrings("363313fc", findHeader(headers.items, "x-opencode-session").?.value);
}

test "appendClientHeaders omits the OpenCode session header for an empty session id" {
    const allocator = std.testing.allocator;
    var client = Client{
        .allocator = allocator,
        .io = undefined,
        .http = undefined,
        .api_key = "",
        .session_id = "",
    };

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth_header = try appendClientHeaders(allocator, &headers, &client, "application/json", "application/json");
    defer if (auth_header) |value| allocator.free(value);

    try std.testing.expect(findHeader(headers.items, "x-opencode-session") == null);
}
