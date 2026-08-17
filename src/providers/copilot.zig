const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");
const client = @import("client.zig");
const openai = @import("openai.zig");

// GitHub Copilot is OpenAI-compatible on the wire but uses a two-token auth flow:
// a long-lived GitHub OAuth token is exchanged for a short-lived Copilot token that
// is then used as a Bearer credential against the Copilot API.

pub const default_base_url = "https://api.githubcopilot.com";
pub const github_api_base_url = "https://api.github.com";
pub const github_base_url = "https://github.com";

pub const client_id = "Iv1.b507a08c87ecfe98";
pub const app_scopes = "read:user";

const editor_version = "vscode/1.99.3";
const editor_plugin_version = "copilot-chat/0.26.7";
const user_agent = "GitHubCopilotChat/0.26.7";
const integration_id = "vscode-chat";
const api_version = "2025-04-01";
const openai_intent = "conversation-panel";
const max_token_file_size = 1024 * 1024;

// Refresh the Copilot token this many seconds before it actually expires.
const token_refresh_buffer_seconds = 120;

pub const Client = struct {
    inner: client.Client,
    /// Long-lived GitHub OAuth token (gho_...). Resolved from manual config,
    /// auto-discovery, or device-flow login before the first request.
    github_token: []const u8 = "",
    /// Short-lived Copilot token exchanged from the GitHub OAuth token.
    copilot_token: ?[]u8 = null,
    /// Unix seconds at which the cached Copilot token expires.
    copilot_token_expires_at: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, github_token: []const u8) Client {
        var inner = client.Client.init(allocator, io, "");
        inner.withBaseUrl(default_base_url);
        return .{
            .inner = inner,
            .github_token = github_token,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.copilot_token) |token| self.inner.allocator.free(token);
        self.copilot_token = null;
        self.inner.deinit();
    }

    pub fn withBaseUrl(self: *Client, base_url: []const u8) void {
        self.inner.withBaseUrl(base_url);
    }

    /// Replace the GitHub OAuth token and invalidate any cached Copilot token.
    pub fn setGithubToken(self: *Client, github_token: []const u8) void {
        self.github_token = github_token;
        if (self.copilot_token) |token| self.inner.allocator.free(token);
        self.copilot_token = null;
        self.copilot_token_expires_at = 0;
    }

    pub fn setConfig(self: *Client, config: client.ClientConfig) void {
        if (config.base_url) |url| self.withBaseUrl(url);
        if (config.api_key) |key| self.setGithubToken(key);
        if (config.http_observer) |obs| self.inner.http_observer = obs;
    }
};

fn httpRequest(
    self: *Client,
    method: std.http.Method,
    url: []const u8,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) !client.RawResponse {
    const allocator = self.inner.allocator;

    if (self.inner.http_observer) |obs| {
        if (obs.onRequest) |cb| cb(obs.ctx, method, url, extra_headers, payload);
    }

    const uri = try std.Uri.parse(url);
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const start = std.Io.Clock.awake.now(self.inner.io);
    const result = self.inner.http.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .extra_headers = extra_headers,
        .payload = payload,
        .response_writer = &response_body.writer,
    }) catch |err| {
        if (self.inner.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, method, url, @errorName(err));
        }
        return err;
    };
    const elapsed_ns = @as(u64, @intCast(start.untilNow(self.inner.io, .awake).nanoseconds));

    const body = try response_body.toOwnedSlice();
    if (self.inner.http_observer) |obs| {
        if (obs.onResponse) |cb| cb(obs.ctx, method, url, result.status, &.{}, body, elapsed_ns);
    }

    return .{
        .allocator = allocator,
        .status = result.status,
        .body = body,
    };
}

fn appendFormField(writer: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte('&');
    try writeFormComponent(writer, name);
    try writer.writeByte('=');
    try writeFormComponent(writer, value);
}

fn writeFormComponent(writer: anytype, value: []const u8) !void {
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(c),
        ' ' => try writer.writeByte('+'),
        else => try writer.print("%{X:0>2}", .{c}),
    };
}

const CopilotTokenResponse = struct {
    token: []const u8,
    expires_at: i64 = 0,
    refresh_in: i64 = 0,
};

fn tokenNeedsRefresh(expires_at: i64, now: i64) bool {
    return now >= expires_at - token_refresh_buffer_seconds;
}

/// Current wall-clock time in seconds since the Unix epoch. The Copilot API returns
/// token expiries as Unix timestamps, so refresh decisions compare against this.
fn nowUnixSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Exchange the GitHub OAuth token for a Copilot token, caching it until shortly
/// before it expires. Returns the currently valid Copilot token.
pub fn ensureCopilotToken(self: *Client) ![]const u8 {
    const now = nowUnixSeconds(self.inner.io);
    if (self.copilot_token) |token| {
        if (!tokenNeedsRefresh(self.copilot_token_expires_at, now)) return token;
    }
    if (self.github_token.len == 0) return error.MissingGithubToken;

    const allocator = self.inner.allocator;

    const auth_value = try std.fmt.allocPrint(allocator, "token {s}", .{self.github_token});
    defer allocator.free(auth_value);

    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_value },
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "editor-version", .value = editor_version },
        .{ .name = "editor-plugin-version", .value = editor_plugin_version },
        .{ .name = "user-agent", .value = user_agent },
        .{ .name = "x-github-api-version", .value = api_version },
    };

    var raw = try httpRequest(self, .GET, github_api_base_url ++ "/copilot_internal/v2/token", &headers, null);
    defer raw.deinit();

    if (raw.status.class() != .success) {
        if (client.isAuthFailure(raw.status)) client.printAuthHint(self.inner.io);
        return error.TokenExchangeFailed;
    }

    const token = try parseCopilotToken(allocator, raw.body);
    if (self.copilot_token) |old| allocator.free(old);
    self.copilot_token = token.value;
    self.copilot_token_expires_at = token.expires_at;
    return token.value;
}

fn parseCopilotToken(allocator: std.mem.Allocator, body: []const u8) !struct { value: []u8, expires_at: i64 } {
    const parsed = try std.json.parseFromSlice(CopilotTokenResponse, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .value = try allocator.dupe(u8, parsed.value.token),
        .expires_at = parsed.value.expires_at,
    };
}

test "tokenNeedsRefresh respects the refresh buffer" {
    try std.testing.expect(tokenNeedsRefresh(1000, 1000));
    try std.testing.expect(tokenNeedsRefresh(1000, 900));
    try std.testing.expect(tokenNeedsRefresh(1000, 880));
    try std.testing.expect(!tokenNeedsRefresh(1000, 879));
    try std.testing.expect(!tokenNeedsRefresh(1000, 500));
}

test "parseCopilotToken extracts token and expiry" {
    const allocator = std.testing.allocator;
    const body =
        \\{"token":"tid=abc;exp=123","expires_at":1750000000,"refresh_in":1500}
    ;
    const result = try parseCopilotToken(allocator, body);
    defer allocator.free(result.value);
    try std.testing.expectEqualStrings("tid=abc;exp=123", result.value);
    try std.testing.expectEqual(@as(i64, 1750000000), result.expires_at);
}

/// Write a random v4 UUID (36 chars) into `out`, used for the per-request
/// `x-request-id` header the Copilot API expects.
fn writeRequestId(io: std.Io, out: *[36]u8) void {
    var source: std.Random.IoSource = .{ .io = io };
    const random = source.interface();
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (bytes, 0..) |b, idx| {
        if (idx == 4 or idx == 6 or idx == 8 or idx == 10) {
            out[pos] = '-';
            pos += 1;
        }
        out[pos] = hex[b >> 4];
        out[pos + 1] = hex[b & 0x0f];
        pos += 2;
    }
}

/// Append the standard Copilot API headers and return the allocated
/// `Authorization` value, which the caller must free after the request.
fn appendCopilotHeaders(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(std.http.Header),
    bearer_token: []const u8,
    accept: []const u8,
    request_id: []const u8,
    initiator: ?[]const u8,
) ![]u8 {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{bearer_token});
    try headers.append(allocator, .{ .name = "authorization", .value = auth });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "accept", .value = accept });
    try headers.append(allocator, .{ .name = "copilot-integration-id", .value = integration_id });
    try headers.append(allocator, .{ .name = "editor-version", .value = editor_version });
    try headers.append(allocator, .{ .name = "editor-plugin-version", .value = editor_plugin_version });
    try headers.append(allocator, .{ .name = "user-agent", .value = user_agent });
    try headers.append(allocator, .{ .name = "openai-intent", .value = openai_intent });
    try headers.append(allocator, .{ .name = "x-github-api-version", .value = api_version });
    try headers.append(allocator, .{ .name = "x-request-id", .value = request_id });
    if (initiator) |value| try headers.append(allocator, .{ .name = "X-Initiator", .value = value });
    return auth;
}

pub const ModelInfo = struct {
    id: []const u8,
    name: []const u8,
    vendor: []const u8,
    context_length: i64,
};

pub const ModelsList = struct {
    data: []const ModelInfo,
};

pub fn listModels(self: *Client) !client.Owned(ModelsList) {
    const token = try ensureCopilotToken(self);
    const allocator = self.inner.allocator;

    var request_id: [36]u8 = undefined;
    writeRequestId(self.inner.io, &request_id);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth = try appendCopilotHeaders(allocator, &headers, token, "application/json", &request_id, null);
    defer allocator.free(auth);

    const url = try std.fmt.allocPrint(allocator, "{s}/models", .{self.inner.base_url});
    defer allocator.free(url);

    var raw = try httpRequest(self, .GET, url, headers.items, null);
    defer raw.deinit();

    if (raw.status.class() != .success) {
        if (client.isAuthFailure(raw.status)) client.printAuthHint(self.inner.io);
        return error.ResponseError;
    }

    return parseModels(allocator, raw.body);
}

/// Convert a Copilot-specific model list into the app-wide shared model list.
/// The source `owned` is deinitialized; ownership of the returned value is transferred.
pub fn toSharedModels(owned: *client.Owned(ModelsList)) !client.Owned(client.ModelsList) {
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
            .display_name = try arena_alloc.dupe(u8, m.name),
            .provider = try arena_alloc.dupe(u8, m.vendor),
            .context_length = m.context_length,
        };
    }

    owned.deinit();

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{
            .arena = arena,
            .value = .{ .models = models },
        },
    };
}

/// Parse a Copilot `/models` response, keeping only chat-capable models.
pub fn parseModels(allocator: std.mem.Allocator, response_json: []const u8) !client.Owned(ModelsList) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    var models: std.ArrayList(ModelInfo) = .empty;

    for (data.array.items) |item| {
        if (item != .object) continue;
        const id = if (item.object.get("id")) |v| v.string else continue;
        if (!isChatModel(item)) continue;
        if (!isModelPickerEnabled(item)) continue;
        if (!supportsChatCompletions(item)) continue;

        const name = if (item.object.get("name")) |v| v.string else id;
        const vendor = if (item.object.get("vendor")) |v| v.string else "github-copilot";

        try models.append(arena_alloc, .{
            .id = try arena_alloc.dupe(u8, id),
            .name = try arena_alloc.dupe(u8, name),
            .vendor = try arena_alloc.dupe(u8, vendor),
            .context_length = modelContextLength(item),
        });
    }

    const result = std.json.Parsed(ModelsList){
        .arena = arena,
        .value = .{ .data = try models.toOwnedSlice(arena_alloc) },
    };

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, response_json),
        .parsed = result,
    };
}

fn isChatModel(item: std.json.Value) bool {
    const caps = item.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const kind = caps.object.get("type") orelse return false;
    if (kind != .string) return false;
    return std.mem.eql(u8, kind.string, "chat");
}

/// The Copilot `/models` catalog marks user-selectable models with
/// `model_picker_enabled`. This is the curated set the GitHub Copilot CLI and editors
/// surface in their model pickers, so filtering on it drops the legacy and internal
/// models (e.g. gpt-3.5-turbo, gpt-4o, exec-agent-*, trajectory-compaction) that the
/// raw catalog also lists.
fn isModelPickerEnabled(item: std.json.Value) bool {
    const value = item.object.get("model_picker_enabled") orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

/// Puny drives Copilot over the OpenAI-compatible `/chat/completions` endpoint, so
/// picker-enabled models that are only served over `/responses` (e.g. gpt-5.5,
/// gpt-5.3-codex, mai-code-1-flash-picker) can't be used here and are excluded. A
/// missing `supported_endpoints` field means the model uses the default
/// `/chat/completions` transport.
fn supportsChatCompletions(item: std.json.Value) bool {
    const endpoints = item.object.get("supported_endpoints") orelse return true;
    if (endpoints != .array) return true;
    for (endpoints.array.items) |ep| {
        if (ep == .string and std.mem.eql(u8, ep.string, "/chat/completions")) return true;
    }
    return false;
}

fn modelContextLength(item: std.json.Value) i64 {
    const caps = item.object.get("capabilities") orelse return 0;
    if (caps != .object) return 0;
    const limits = caps.object.get("limits") orelse return 0;
    if (limits != .object) return 0;
    const value = limits.object.get("max_context_window_tokens") orelse return 0;
    return switch (value) {
        .integer => |i| i,
        else => 0,
    };
}

test "parseModels keeps only picker-enabled chat models on /chat/completions" {
    const allocator = std.testing.allocator;
    const body =
        \\{"data":[
        \\{"id":"claude-sonnet-4.5","name":"Claude Sonnet 4.5","vendor":"Anthropic","model_picker_enabled":true,"capabilities":{"type":"chat","limits":{"max_context_window_tokens":200000}},"supported_endpoints":["/chat/completions","/v1/messages"]},
        \\{"id":"gpt-4o","name":"GPT-4o","vendor":"Azure OpenAI","model_picker_enabled":false,"capabilities":{"type":"chat","limits":{"max_context_window_tokens":128000}}},
        \\{"id":"text-embedding-3-small","name":"Embedding","vendor":"openai","model_picker_enabled":true,"capabilities":{"type":"embeddings"}},
        \\{"id":"gpt-5.5","name":"GPT-5.5","vendor":"OpenAI","model_picker_enabled":true,"capabilities":{"type":"chat"},"supported_endpoints":["/responses","ws:/responses"]},
        \\{"id":"gemini-2.5-pro","name":"Gemini 2.5 Pro","vendor":"Google","model_picker_enabled":true,"capabilities":{"type":"chat"}}
        \\],"object":"list"}
    ;
    var owned = try parseModels(allocator, body);
    defer owned.deinit();

    const models = owned.value().data;
    // Kept: claude-sonnet-4.5 (picker + /chat/completions) and gemini-2.5-pro
    // (picker + no supported_endpoints => default /chat/completions).
    // Dropped: gpt-4o (picker disabled), text-embedding-3-small (not chat),
    // gpt-5.5 (picker enabled but /responses-only).
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("claude-sonnet-4.5", models[0].id);
    try std.testing.expectEqualStrings("Claude Sonnet 4.5", models[0].name);
    try std.testing.expectEqualStrings("Anthropic", models[0].vendor);
    try std.testing.expectEqual(@as(i64, 200000), models[0].context_length);
    try std.testing.expectEqualStrings("gemini-2.5-pro", models[1].id);
}

/// The Copilot API expects `X-Initiator: agent` once the conversation contains
/// assistant or tool turns, and `user` for the very first user request.
fn requestInitiator(messages: []const openai.Message) []const u8 {
    for (messages) |msg| {
        switch (msg) {
            .assistant, .tool => return "agent",
            else => {},
        }
    }
    return "user";
}

pub fn chatStreaming(self: *Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    const token = try ensureCopilotToken(self);
    const allocator = self.inner.allocator;

    const payload = try openai.requestPayload(allocator, request);
    defer allocator.free(payload);

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.inner.base_url});
    defer allocator.free(url);

    var request_id: [36]u8 = undefined;
    writeRequestId(self.inner.io, &request_id);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth = try appendCopilotHeaders(
        allocator,
        &headers,
        token,
        "text/event-stream",
        &request_id,
        requestInitiator(request.messages),
    );
    defer allocator.free(auth);

    if (self.inner.http_observer) |obs| {
        if (obs.onRequest) |cb| cb(obs.ctx, .POST, url, headers.items, payload);
    }

    const uri = try std.Uri.parse(url);

    const start = std.Io.Clock.awake.now(self.inner.io);
    var req = self.inner.http.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers.items,
    }) catch |err| {
        if (self.inner.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
        }
        return err;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = req.receiveHead(&.{}) catch |err| {
        if (self.inner.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
        }
        return err;
    };
    const elapsed_ns = @as(u64, @intCast(start.untilNow(self.inner.io, .awake).nanoseconds));

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    var cancelable_reader_buffer: [1]u8 = undefined;
    var cancelable_reader = openai.CancelableReader.init(response_reader, &cancelable_reader_buffer);
    const reader = &cancelable_reader.reader;

    if (response.head.status.class() != .success) {
        var body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer body_alloc.deinit();
        _ = reader.streamRemaining(&body_alloc.writer) catch {};

        if (self.inner.http_observer) |obs| {
            if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, body_alloc.written(), elapsed_ns);
        }

        if (response.head.status == .unauthorized or response.head.status == .forbidden) {
            client.printAuthHint(self.inner.io);
        }

        if (builtin.mode == .Debug) {
            std.debug.print("Copilot chat request failed\n  URL: {s}\n  Status: {d}\n  Response: {s}\n", .{
                url,
                @intFromEnum(response.head.status),
                body_alloc.written(),
            });
        } else {
            std.debug.print("Copilot chat request failed\n  URL: {s}\n  Status: {d}\n", .{
                url,
                @intFromEnum(response.head.status),
            });
        }
        return error.ResponseError;
    }

    if (self.inner.http_observer) |obs| {
        if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, "", elapsed_ns);
    }

    var sse = openai.SseCallback{
        .allocator = allocator,
        .callback = callback,
        .observer = self.inner.http_observer,
    };

    client.parseSseReader(allocator, reader, &sse, null) catch |err| switch (err) {
        error.ReadFailed => {
            if (cancel.isCancelled()) return error.Canceled;
            return err;
        },
        else => return err,
    };
}

test "requestInitiator distinguishes user and agent turns" {
    const user_only = [_]openai.Message{
        .{ .system = "sys" },
        .{ .user = "hello" },
    };
    try std.testing.expectEqualStrings("user", requestInitiator(&user_only));

    const with_assistant = [_]openai.Message{
        .{ .user = "hello" },
        .{ .assistant = .{ .content = "hi" } },
        .{ .user = "again" },
    };
    try std.testing.expectEqualStrings("agent", requestInitiator(&with_assistant));

    const with_tool = [_]openai.Message{
        .{ .user = "hello" },
        .{ .tool = .{ .tool_call_id = "call_1", .content = "result" } },
    };
    try std.testing.expectEqualStrings("agent", requestInitiator(&with_tool));
}

// --- OAuth token discovery -------------------------------------------------
// Reuse a GitHub OAuth token already stored by editor Copilot plugins or by
// OpenCode, so users who are logged in elsewhere don't have to log in again.

/// Env var holding a ready-to-use GitHub OAuth token for Copilot.
const oauth_token_env = "GITHUB_COPILOT_OAUTH_TOKEN";

/// Discover a GitHub OAuth token from the environment or from known config
/// files. Returns an allocated token (caller owns) or null if none is found.
pub fn discoverGithubToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) !?[]const u8 {
    if (environ_map.get(oauth_token_env)) |value| {
        if (value.len > 0) return try allocator.dupe(u8, value);
    }

    var candidates = std.ArrayList([]const u8).empty;
    defer {
        for (candidates.items) |path| allocator.free(path);
        candidates.deinit(allocator);
    }
    try collectTokenFilePaths(allocator, environ_map, &candidates);

    for (candidates.items) |path| {
        const data = readFileOpt(allocator, io, path) orelse continue;
        defer allocator.free(data);
        if (try oauthTokenFromFile(allocator, path, data)) |token| return token;
    }

    return null;
}

fn readFileOpt(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_token_file_size)) catch null;
}

fn homeDir(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    return environ_map.get("HOME") orelse environ_map.get("USERPROFILE");
}

fn collectTokenFilePaths(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    candidates: *std.ArrayList([]const u8),
) !void {
    // Editor Copilot plugins: apps.json (current) and hosts.json (legacy).
    for ([_][]const u8{ "apps.json", "hosts.json" }) |name| {
        if (builtin.os.tag == .windows) {
            if (environ_map.get("LOCALAPPDATA")) |base| {
                try candidates.append(allocator, try std.fs.path.join(allocator, &.{ base, "github-copilot", name }));
            }
        } else if (environ_map.get("XDG_CONFIG_HOME")) |base| {
            try candidates.append(allocator, try std.fs.path.join(allocator, &.{ base, "github-copilot", name }));
        }
        if (homeDir(environ_map)) |home| {
            if (builtin.os.tag == .windows) {
                try candidates.append(allocator, try std.fs.path.join(allocator, &.{ home, "AppData", "Local", "github-copilot", name }));
            }
            try candidates.append(allocator, try std.fs.path.join(allocator, &.{ home, ".config", "github-copilot", name }));
        }
    }

    // OpenCode credential store.
    if (environ_map.get("XDG_DATA_HOME")) |base| {
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ base, "opencode", "auth.json" }));
    }
    if (homeDir(environ_map)) |home| {
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ home, ".local", "share", "opencode", "auth.json" }));
    }
}

fn oauthTokenFromFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !?[]const u8 {
    if (std.mem.endsWith(u8, path, "auth.json")) {
        return oauthTokenFromOpencode(allocator, data);
    }
    return oauthTokenFromApps(allocator, data);
}

/// Parse an editor Copilot `apps.json`/`hosts.json`: an object whose keys start
/// with `github.com`, each holding an `oauth_token` string.
fn oauthTokenFromApps(allocator: std.mem.Allocator, json: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, "github.com")) continue;
        const value = entry.value_ptr.*;
        if (value != .object) continue;
        const token = value.object.get("oauth_token") orelse continue;
        if (token != .string or token.string.len == 0) continue;
        return try allocator.dupe(u8, token.string);
    }
    return null;
}

/// Parse OpenCode's `auth.json`: `{ "github-copilot": { "refresh": "gho_..." } }`.
fn oauthTokenFromOpencode(allocator: std.mem.Allocator, json: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const entry = parsed.value.object.get("github-copilot") orelse return null;
    if (entry != .object) return null;
    const refresh = entry.object.get("refresh") orelse return null;
    if (refresh != .string or refresh.string.len == 0) return null;
    return try allocator.dupe(u8, refresh.string);
}

test "oauthTokenFromApps reads token from app-id keyed entry" {
    const allocator = std.testing.allocator;
    const json =
        \\{"github.com:Iv1.b507a08c87ecfe98":{"user":"octocat","oauth_token":"gho_apps"}}
    ;
    const token = (try oauthTokenFromApps(allocator, json)).?;
    defer allocator.free(token);
    try std.testing.expectEqualStrings("gho_apps", token);
}

test "oauthTokenFromApps reads token from legacy hosts entry" {
    const allocator = std.testing.allocator;
    const json =
        \\{"github.com":{"user":"octocat","oauth_token":"gho_hosts"}}
    ;
    const token = (try oauthTokenFromApps(allocator, json)).?;
    defer allocator.free(token);
    try std.testing.expectEqualStrings("gho_hosts", token);
}

test "oauthTokenFromApps returns null without a github.com entry" {
    const allocator = std.testing.allocator;
    const json =
        \\{"example.com":{"oauth_token":"nope"}}
    ;
    try std.testing.expect((try oauthTokenFromApps(allocator, json)) == null);
}

test "oauthTokenFromOpencode reads the refresh token" {
    const allocator = std.testing.allocator;
    const json =
        \\{"github-copilot":{"type":"oauth","refresh":"gho_opencode","access":"tid=x","expires":123}}
    ;
    const token = (try oauthTokenFromOpencode(allocator, json)).?;
    defer allocator.free(token);
    try std.testing.expectEqualStrings("gho_opencode", token);
}

test "oauthTokenFromOpencode returns null when copilot entry is absent" {
    const allocator = std.testing.allocator;
    const json =
        \\{"anthropic":{"type":"api","key":"sk-x"}}
    ;
    try std.testing.expect((try oauthTokenFromOpencode(allocator, json)) == null);
}

test "appendFormField percent-encodes form values" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try appendFormField(&output.writer, "scope", "read:user email", true);
    try appendFormField(&output.writer, "device_code", "abc:/+=", false);

    try std.testing.expectEqualStrings("scope=read%3Auser+email&device_code=abc%3A%2F%2B%3D", output.written());
}

// --- Device-flow login -----------------------------------------------------
// Interactive OAuth device flow, used when no token can be discovered.

const DeviceCodeResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: i64 = 900,
    interval: i64 = 5,
};

const AccessTokenResponse = struct {
    access_token: ?[]const u8 = null,
    token_type: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

const PollOutcome = union(enum) {
    token: []const u8,
    pending,
    slow_down,
    failed: []const u8,
};

fn sleepSeconds(io: std.Io, seconds: i64) void {
    if (seconds <= 0) return;
    const ns: i96 = @as(i96, @intCast(seconds)) * std.time.ns_per_s;
    io.sleep(.{ .nanoseconds = ns }, .awake) catch {};
}

/// Run the GitHub device-authorization flow. Prints the verification URL and
/// user code, polls until authorized, and returns the OAuth token (caller owns)
/// or null if the flow was denied or timed out.
pub fn deviceLogin(self: *Client, stdout_writer: *std.Io.Writer) !?[]const u8 {
    const allocator = self.inner.allocator;

    const form_headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "accept", .value = "application/json" },
    };

    var device_body_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer device_body_alloc.deinit();
    try appendFormField(&device_body_alloc.writer, "client_id", client_id, true);
    try appendFormField(&device_body_alloc.writer, "scope", app_scopes, false);
    const device_body = device_body_alloc.written();

    var device_raw = try httpRequest(self, .POST, github_base_url ++ "/login/device/code", &form_headers, device_body);
    defer device_raw.deinit();
    if (device_raw.status.class() != .success) return error.DeviceCodeRequestFailed;

    const device_parsed = std.json.parseFromSlice(DeviceCodeResponse, allocator, device_raw.body, .{ .ignore_unknown_fields = true }) catch
        return error.DeviceCodeRequestFailed;
    defer device_parsed.deinit();
    const device = device_parsed.value;

    try stdout_writer.print(
        "\nTo sign in to GitHub Copilot, open {s} and enter code: {s}\n",
        .{ device.verification_uri, device.user_code },
    );
    try stdout_writer.print("Waiting for authorization...\n", .{});
    try stdout_writer.flush();

    var interval_s: i64 = if (device.interval > 0) device.interval else 5;
    const deadline = nowUnixSeconds(self.inner.io) + (if (device.expires_in > 0) device.expires_in else 900);

    while (nowUnixSeconds(self.inner.io) < deadline) {
        sleepSeconds(self.inner.io, interval_s + 1);

        var poll_body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer poll_body_alloc.deinit();
        try appendFormField(&poll_body_alloc.writer, "client_id", client_id, true);
        try appendFormField(&poll_body_alloc.writer, "device_code", device.device_code, false);
        try appendFormField(&poll_body_alloc.writer, "grant_type", "urn:ietf:params:oauth:grant-type:device_code", false);
        const poll_body = poll_body_alloc.written();

        var poll_raw = try httpRequest(self, .POST, github_base_url ++ "/login/oauth/access_token", &form_headers, poll_body);
        defer poll_raw.deinit();

        switch (parseAccessToken(allocator, poll_raw.body) catch PollOutcome.pending) {
            .token => |token| return token,
            .pending => {},
            .slow_down => interval_s += 5,
            .failed => |reason| {
                try stdout_writer.print("GitHub Copilot sign-in failed: {s}\n", .{reason});
                try stdout_writer.flush();
                return null;
            },
        }
    }

    try stdout_writer.print("GitHub Copilot sign-in timed out.\n", .{});
    try stdout_writer.flush();
    return null;
}

fn parseAccessToken(allocator: std.mem.Allocator, body: []const u8) !PollOutcome {
    const parsed = std.json.parseFromSlice(AccessTokenResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return PollOutcome.pending;
    defer parsed.deinit();

    if (parsed.value.access_token) |token| {
        if (token.len > 0) return .{ .token = try allocator.dupe(u8, token) };
    }
    if (parsed.value.@"error") |err| {
        if (std.mem.eql(u8, err, "authorization_pending")) return PollOutcome.pending;
        if (std.mem.eql(u8, err, "slow_down")) return PollOutcome.slow_down;
        if (std.mem.eql(u8, err, "expired_token")) return .{ .failed = "the device code expired" };
        if (std.mem.eql(u8, err, "access_denied")) return .{ .failed = "access was denied" };
    }
    return PollOutcome.pending;
}

test "parseAccessToken returns the access token when present" {
    const allocator = std.testing.allocator;
    const body =
        \\{"access_token":"gho_flow","token_type":"bearer","scope":"read:user"}
    ;
    switch (try parseAccessToken(allocator, body)) {
        .token => |token| {
            defer allocator.free(token);
            try std.testing.expectEqualStrings("gho_flow", token);
        },
        else => try std.testing.expect(false),
    }
}

test "parseAccessToken maps pending and slow_down errors" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try parseAccessToken(allocator,
        \\{"error":"authorization_pending"}
    )) == .pending);
    try std.testing.expect((try parseAccessToken(allocator,
        \\{"error":"slow_down"}
    )) == .slow_down);
    try std.testing.expect((try parseAccessToken(allocator,
        \\{"error":"expired_token"}
    )) == .failed);
}

test "parseAccessToken maps access_denied and unknown errors" {
    const allocator = std.testing.allocator;
    switch (try parseAccessToken(allocator, "{\"error\":\"access_denied\"}")) {
        .failed => |reason| try std.testing.expectEqualStrings("access was denied", reason),
        else => try std.testing.expect(false),
    }
    try std.testing.expect((try parseAccessToken(allocator, "{\"error\":\"something_else\"}")) == .pending);
    try std.testing.expect((try parseAccessToken(allocator, "not json at all")) == .pending);
    try std.testing.expect((try parseAccessToken(allocator, "{\"access_token\":\"\"}")) == .pending);
}

fn findHeader(headers: []const std.http.Header, name: []const u8) ?std.http.Header {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, name)) return header;
    }
    return null;
}

test "writeRequestId produces a valid v4 UUID" {
    var id: [36]u8 = undefined;
    writeRequestId(std.testing.io, &id);

    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    try std.testing.expectEqual(@as(u8, '4'), id[14]);
    try std.testing.expect(id[19] == '8' or id[19] == '9' or id[19] == 'a' or id[19] == 'b');
    for (id) |c| {
        if (c == '-') continue;
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "appendCopilotHeaders sets the standard Copilot headers" {
    const allocator = std.testing.allocator;
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth = try appendCopilotHeaders(allocator, &headers, "tok-123", "text/event-stream", "req-id-1", "agent");
    defer allocator.free(auth);

    try std.testing.expectEqualStrings("Bearer tok-123", auth);
    try std.testing.expectEqualStrings("Bearer tok-123", findHeader(headers.items, "authorization").?.value);
    try std.testing.expectEqualStrings("application/json", findHeader(headers.items, "content-type").?.value);
    try std.testing.expectEqualStrings("text/event-stream", findHeader(headers.items, "accept").?.value);
    try std.testing.expectEqualStrings("vscode-chat", findHeader(headers.items, "copilot-integration-id").?.value);
    try std.testing.expectEqualStrings("req-id-1", findHeader(headers.items, "x-request-id").?.value);
    try std.testing.expectEqualStrings("agent", findHeader(headers.items, "X-Initiator").?.value);
    try std.testing.expectEqualStrings("2025-04-01", findHeader(headers.items, "x-github-api-version").?.value);
}

test "appendCopilotHeaders omits X-Initiator when null" {
    const allocator = std.testing.allocator;
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth = try appendCopilotHeaders(allocator, &headers, "tok-123", "application/json", "req-id-1", null);
    defer allocator.free(auth);

    try std.testing.expect(findHeader(headers.items, "X-Initiator") == null);
}

test "setGithubToken invalidates the cached copilot token" {
    var c = Client.init(std.testing.allocator, std.testing.io, "gho_old");
    defer c.deinit();

    const seeded = try std.testing.allocator.dupe(u8, "tid=seeded");
    c.copilot_token = seeded;
    c.copilot_token_expires_at = 12345;

    c.setGithubToken("gho_new");
    try std.testing.expectEqualStrings("gho_new", c.github_token);
    try std.testing.expect(c.copilot_token == null);
    try std.testing.expectEqual(@as(i64, 0), c.copilot_token_expires_at);
}

test "setConfig applies base url key and observer" {
    var c = Client.init(std.testing.allocator, std.testing.io, "gho_old");
    defer c.deinit();

    const observer = client.HttpObserver{
        .ctx = null,
        .onRequest = null,
        .onResponse = null,
        .onError = null,
    };
    c.setConfig(.{ .base_url = "http://copilot.example", .api_key = "gho_new", .http_observer = observer });

    try std.testing.expectEqualStrings("http://copilot.example", c.inner.base_url);
    try std.testing.expectEqualStrings("gho_new", c.github_token);
    try std.testing.expect(c.inner.http_observer != null);
}

test "parseModels returns MissingData without a data field" {
    try std.testing.expectError(error.MissingData, parseModels(std.testing.allocator, "{\"object\":\"list\"}"));
}

test "parseModels skips malformed entries and defaults display fields" {
    const allocator = std.testing.allocator;
    const body =
        \\{"data":[
        \\42,
        \\{"id":"plain","model_picker_enabled":true,"capabilities":{"type":"chat"}},
        \\{"id":"no-caps","model_picker_enabled":true},
        \\{"id":"non-bool-picker","model_picker_enabled":"yes","capabilities":{"type":"chat"}},
        \\{"id":"non-chat","model_picker_enabled":true,"capabilities":{"type":"embeddings"}},
        \\{"id":"bad-caps","model_picker_enabled":true,"capabilities":"chat"},
        \\{"id":"non-array-endpoints","model_picker_enabled":true,"capabilities":{"type":"chat"},"supported_endpoints":"x"}
        \\],"object":"list"}
    ;
    var owned = try parseModels(allocator, body);
    defer owned.deinit();

    const models = owned.value().data;
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("plain", models[0].id);
    try std.testing.expectEqualStrings("plain", models[0].name);
    try std.testing.expectEqualStrings("github-copilot", models[0].vendor);
    try std.testing.expectEqual(@as(i64, 0), models[0].context_length);
    try std.testing.expectEqualStrings("non-array-endpoints", models[1].id);
}

test "toSharedModels copies copilot models into the shared model list" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data":[
        \\{"id":"claude-sonnet-4.5","name":"Claude Sonnet 4.5","vendor":"Anthropic","context_length":200000}
        \\]}
    ;

    const parsed = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    var owned = client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = parsed,
    };

    var shared = try toSharedModels(&owned);
    defer shared.deinit();

    try std.testing.expectEqual(@as(usize, 1), shared.value().models.len);
    try std.testing.expectEqualStrings("claude-sonnet-4.5", shared.value().models[0].id);
    try std.testing.expectEqualStrings("Claude Sonnet 4.5", shared.value().models[0].display_name);
    try std.testing.expectEqualStrings("Anthropic", shared.value().models[0].provider);
    try std.testing.expectEqual(@as(i64, 200000), shared.value().models[0].context_length);
}

fn seedCopilotToken(c: *Client) !void {
    const token = try c.inner.allocator.dupe(u8, "tid=test-token");
    c.copilot_token = token;
    c.copilot_token_expires_at = nowUnixSeconds(c.inner.io) + 3600;
}

test "ensureCopilotToken returns the cached token while it is still valid" {
    var c = Client.init(std.testing.allocator, std.testing.io, "");
    defer c.deinit();
    try seedCopilotToken(&c);

    const token = try ensureCopilotToken(&c);
    try std.testing.expectEqualStrings("tid=test-token", token);
    try std.testing.expect(c.copilot_token != null);
}

test "ensureCopilotToken requires a github token after expiry" {
    var c = Client.init(std.testing.allocator, std.testing.io, "");
    defer c.deinit();

    const seeded = try std.testing.allocator.dupe(u8, "tid=expired");
    c.copilot_token = seeded;
    c.copilot_token_expires_at = 1;

    try std.testing.expectError(error.MissingGithubToken, ensureCopilotToken(&c));

    var fresh = Client.init(std.testing.allocator, std.testing.io, "");
    defer fresh.deinit();
    try std.testing.expectError(error.MissingGithubToken, ensureCopilotToken(&fresh));
}

test "discoverGithubToken reads the environment variable" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(oauth_token_env, "gho_env");

    const token = (try discoverGithubToken(std.testing.allocator, std.testing.io, &env)).?;
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("gho_env", token);
}

test "discoverGithubToken returns null with an empty environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(oauth_token_env, "");

    try std.testing.expect((try discoverGithubToken(std.testing.allocator, std.testing.io, &env)) == null);
}

test "discoverGithubToken reads apps.json from XDG_CONFIG_HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "github-copilot");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "github-copilot/apps.json",
        .data = "{\"github.com:Iv1.b507a08c87ecfe98\":{\"oauth_token\":\"gho_file\"}}",
    });

    const base = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", base);

    const token = (try discoverGithubToken(std.testing.allocator, std.testing.io, &env)).?;
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("gho_file", token);
}

test "discoverGithubToken reads opencode auth.json from XDG_DATA_HOME" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "opencode");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "opencode/auth.json",
        .data = "{\"github-copilot\":{\"type\":\"oauth\",\"refresh\":\"gho_opencode\"}}",
    });

    const base = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);

    const token = (try discoverGithubToken(std.testing.allocator, std.testing.io, &env)).?;
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("gho_opencode", token);
}

test "oauthTokenFromApps skips entries without a usable token" {
    const allocator = std.testing.allocator;

    try std.testing.expect((try oauthTokenFromApps(allocator,
        \\{"github.com":{"user":"octocat","oauth_token":""}}
    )) == null);
    try std.testing.expect((try oauthTokenFromApps(allocator,
        \\{"github.com":{"user":"octocat"}}
    )) == null);
    try std.testing.expect((try oauthTokenFromApps(allocator,
        \\{"github.com":"not an object"}
    )) == null);
    try std.testing.expect((try oauthTokenFromApps(allocator, "not json")) == null);
}

test "oauthTokenFromOpencode rejects missing or empty refresh tokens" {
    const allocator = std.testing.allocator;

    try std.testing.expect((try oauthTokenFromOpencode(allocator,
        \\{"github-copilot":{"type":"oauth","refresh":""}}
    )) == null);
    try std.testing.expect((try oauthTokenFromOpencode(allocator,
        \\{"github-copilot":{"type":"oauth"}}
    )) == null);
    try std.testing.expect((try oauthTokenFromOpencode(allocator, "not json")) == null);
}

test "sleepSeconds skips non-positive durations" {
    sleepSeconds(std.testing.io, 0);
    sleepSeconds(std.testing.io, -1);
}

// ── Copilot server tests ─────────────────────────────────────────────

const CopilotServer = struct {
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

fn startCopilotServer(status: std.http.Status, body: []const u8) !*CopilotServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(CopilotServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    ctx.thread = try std.Thread.spawn(.{}, CopilotServer.serve, .{ctx});
    return ctx;
}

fn stopCopilotServer(ctx: *CopilotServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn copilotClientForServer(ctx: *CopilotServer, arena: std.mem.Allocator) !Client {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    var c = Client.init(std.testing.allocator, std.testing.io, "gho_test");
    c.withBaseUrl(url);
    return c;
}

test "listModels fetches models from a local server with a cached token" {
    const body =
        \\{"data":[{"id":"claude-sonnet-4.5","name":"Claude Sonnet 4.5","vendor":"Anthropic","model_picker_enabled":true,"capabilities":{"type":"chat","limits":{"max_context_window_tokens":200000}}}]}
    ;
    const ctx = try startCopilotServer(.ok, body);
    defer stopCopilotServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try copilotClientForServer(ctx, arena);
    defer c.deinit();
    try seedCopilotToken(&c);

    var owned = try listModels(&c);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 1), owned.value().data.len);
    try std.testing.expectEqualStrings("claude-sonnet-4.5", owned.value().data[0].id);
    try std.testing.expectEqualStrings("Anthropic", owned.value().data[0].vendor);
}

test "listModels returns ResponseError on a non-success status" {
    const ctx = try startCopilotServer(.internal_server_error, "nope");
    defer stopCopilotServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try copilotClientForServer(ctx, arena);
    defer c.deinit();
    try seedCopilotToken(&c);

    try std.testing.expectError(error.ResponseError, listModels(&c));
}

const CopilotSseEvent = union(enum) {
    content: []const u8,
    finish: ?[]const u8,
};

const CopilotSseRecorder = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList(CopilotSseEvent),

    fn callback(self: *CopilotSseRecorder) openai.StreamCallback {
        return .{
            .context = self,
            .vtable = &.{
                .event = event,
                .reset = null,
            },
        };
    }

    fn event(ctx: *anyopaque, ev: openai.StreamEvent) !void {
        const self: *CopilotSseRecorder = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .content => |v| try self.events.append(self.allocator, .{ .content = try self.allocator.dupe(u8, v) }),
            .finish => |v| try self.events.append(self.allocator, .{ .finish = if (v) |s| try self.allocator.dupe(u8, s) else null }),
            else => {},
        }
    }
};

test "chatStreaming streams SSE from a local server with a cached token" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" copilot\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startCopilotServer(.ok, body);
    defer stopCopilotServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try copilotClientForServer(ctx, arena);
    defer c.deinit();
    try seedCopilotToken(&c);
    const allocator = arena;

    var events = std.ArrayList(CopilotSseEvent).empty;
    var recorder = CopilotSseRecorder{ .allocator = allocator, .events = &events };

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.5",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.reset();
    try chatStreaming(&c, request, recorder.callback());

    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expectEqualStrings("Hello", events.items[0].content);
    try std.testing.expectEqualStrings(" copilot", events.items[1].content);
    try std.testing.expectEqualStrings("stop", events.items[2].finish.?);
}

test "chatStreaming returns ResponseError on a non-success status" {
    const ctx = try startCopilotServer(.internal_server_error, "nope");
    defer stopCopilotServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try copilotClientForServer(ctx, arena);
    defer c.deinit();
    try seedCopilotToken(&c);
    const allocator = arena;

    var events = std.ArrayList(CopilotSseEvent).empty;
    var recorder = CopilotSseRecorder{ .allocator = allocator, .events = &events };

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.5",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    try std.testing.expectError(error.ResponseError, chatStreaming(&c, request, recorder.callback()));
}

test "chatStreaming returns Canceled when the stream is cancelled" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startCopilotServer(.ok, body);
    defer stopCopilotServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try copilotClientForServer(ctx, arena);
    defer c.deinit();
    try seedCopilotToken(&c);

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.5",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.setCancelled();
    defer cancel.reset();
    try std.testing.expectError(error.Canceled, chatStreaming(&c, request, undefined));
}

test "listModels reports connection errors to the http observer" {
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
    const observer = client.HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = Client.init(std.testing.allocator, std.testing.io, "gho_test");
    defer c.deinit();
    c.withBaseUrl(url);
    c.inner.http_observer = observer;
    try seedCopilotToken(&c);

    if (listModels(&c)) |_| {
        return error.ExpectedConnectionFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

const CopilotGarbageServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    thread: std.Thread = undefined,

    fn serve(self: *@This()) void {
        var stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);

        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        _ = http_server.receiveHead() catch return;
        writer.interface.writeAll("definitely-not-an-http-response\r\n\r\n") catch return;
    }
};

fn startCopilotGarbageServer() !*CopilotGarbageServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(CopilotGarbageServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server };
    ctx.thread = try std.Thread.spawn(.{}, CopilotGarbageServer.serve, .{ctx});
    return ctx;
}

fn stopCopilotGarbageServer(ctx: *CopilotGarbageServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

test "chatStreaming reports response head failures to the http observer" {
    const ctx = try startCopilotGarbageServer();
    defer stopCopilotGarbageServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    const ObserverCtx = struct {
        errors: usize = 0,
        fn onError(user_ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, err_name: []const u8) void {
            _ = method;
            _ = request_url;
            _ = err_name;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.errors += 1;
        }
    };

    var observer_ctx = ObserverCtx{};
    const observer = client.HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = Client.init(std.testing.allocator, std.testing.io, "gho_test");
    defer c.deinit();
    c.withBaseUrl(url);
    c.inner.http_observer = observer;
    try seedCopilotToken(&c);

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.5",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    if (chatStreaming(&c, request, undefined)) |_| {
        return error.ExpectedHeadFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

test "chatStreaming reports request creation failures to the http observer" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    server.deinit(std.testing.io);

    const ObserverCtx = struct {
        errors: usize = 0,
        fn onError(user_ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, err_name: []const u8) void {
            _ = method;
            _ = request_url;
            _ = err_name;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.errors += 1;
        }
    };

    var observer_ctx = ObserverCtx{};
    const observer = client.HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = Client.init(std.testing.allocator, std.testing.io, "gho_test");
    defer c.deinit();
    c.withBaseUrl(url);
    c.inner.http_observer = observer;
    try seedCopilotToken(&c);

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.5",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    if (chatStreaming(&c, request, undefined)) |_| {
        return error.ExpectedConnectionFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

test "chatStreaming propagates SSE parse errors from a local server" {
    const ctx = try startCopilotServer(.ok, "data: not-json\n\n");
    defer stopCopilotServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try copilotClientForServer(ctx, arena);
    defer c.deinit();
    try seedCopilotToken(&c);
    const allocator = arena;

    var events = std.ArrayList(CopilotSseEvent).empty;
    var recorder = CopilotSseRecorder{ .allocator = allocator, .events = &events };

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.5",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.reset();
    if (chatStreaming(&c, request, recorder.callback())) |_| {
        return error.ExpectedSseParseFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}
