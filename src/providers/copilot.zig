const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");
const lmstudio = @import("lmstudio.zig");
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

// Refresh the Copilot token this many seconds before it actually expires.
const token_refresh_buffer_seconds = 120;

pub const Client = struct {
    inner: lmstudio.Client,
    /// Long-lived GitHub OAuth token (gho_...). Resolved from manual config,
    /// auto-discovery, or device-flow login before the first request.
    github_token: []const u8 = "",
    /// Short-lived Copilot token exchanged from the GitHub OAuth token.
    copilot_token: ?[]u8 = null,
    /// Unix seconds at which the cached Copilot token expires.
    copilot_token_expires_at: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, github_token: []const u8) Client {
        var inner = lmstudio.Client.init(allocator, io, "");
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
};

fn httpRequest(
    self: *Client,
    method: std.http.Method,
    url: []const u8,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) !lmstudio.RawResponse {
    const allocator = self.inner.allocator;
    const uri = try std.Uri.parse(url);
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try self.inner.http.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .extra_headers = extra_headers,
        .payload = payload,
        .response_writer = &response_body.writer,
    });

    return .{
        .allocator = allocator,
        .status = result.status,
        .body = try response_body.toOwnedSlice(),
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

/// Exchange the GitHub OAuth token for a Copilot token, caching it until shortly
/// before it expires. Returns the currently valid Copilot token.
pub fn ensureCopilotToken(self: *Client) ![]const u8 {
    const now = std.time.timestamp();
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
        if (lmstudio.isAuthFailure(raw.status)) lmstudio.printAuthHint(self.inner.io);
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
    try headers.append(allocator, .{ .name = "Authorization", .value = auth });
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

pub fn listModels(self: *Client) !lmstudio.Owned(lmstudio.ListModelsResponse) {
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
        if (lmstudio.isAuthFailure(raw.status)) lmstudio.printAuthHint(self.inner.io);
        return error.ResponseError;
    }

    return parseModels(allocator, raw.body);
}

/// Parse a Copilot `/models` response, keeping only chat-capable models.
pub fn parseModels(allocator: std.mem.Allocator, response_json: []const u8) !lmstudio.Owned(lmstudio.ListModelsResponse) {
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

    var models = std.array_list.Managed(lmstudio.ModelInfo).init(arena_alloc);

    for (data.array.items) |item| {
        if (item != .object) continue;
        const id = if (item.object.get("id")) |v| v.string else continue;
        if (!isChatModel(item)) continue;

        const name = if (item.object.get("name")) |v| v.string else id;
        const vendor = if (item.object.get("vendor")) |v| v.string else "github-copilot";

        try models.append(.{
            .key = try arena_alloc.dupe(u8, id),
            .display_name = try arena_alloc.dupe(u8, name),
            .publisher = try arena_alloc.dupe(u8, vendor),
            .format = "api",
            .size_bytes = 0,
            .max_context_length = modelContextLength(item),
            .loaded_instances = &.{},
            .type = "llm",
        });
    }

    const result = std.json.Parsed(lmstudio.ListModelsResponse){
        .arena = arena,
        .value = .{ .models = try models.toOwnedSlice() },
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

test "parseModels keeps only chat-capable models" {
    const allocator = std.testing.allocator;
    const body =
        \\{"data":[
        \\{"id":"gpt-4o","name":"GPT-4o","vendor":"openai","capabilities":{"type":"chat","limits":{"max_context_window_tokens":128000}}},
        \\{"id":"text-embedding-3-small","name":"Embedding","vendor":"openai","capabilities":{"type":"embeddings"}},
        \\{"id":"claude-sonnet-4","name":"Claude Sonnet 4","vendor":"anthropic","capabilities":{"type":"chat"}}
        \\],"object":"list"}
    ;
    var owned = try parseModels(allocator, body);
    defer owned.deinit();

    const models = owned.value().models;
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-4o", models[0].key);
    try std.testing.expectEqualStrings("GPT-4o", models[0].display_name);
    try std.testing.expectEqualStrings("openai", models[0].publisher);
    try std.testing.expectEqual(@as(i64, 128000), models[0].max_context_length);
    try std.testing.expectEqualStrings("claude-sonnet-4", models[1].key);
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

    const uri = try std.Uri.parse(url);
    var req = try self.inner.http.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers.items,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    var cancelable_reader_buffer: [1]u8 = undefined;
    var cancelable_reader = openai.CancelableReader.init(response_reader, &cancelable_reader_buffer);
    const reader = &cancelable_reader.reader;

    if (response.head.status.class() != .success) {
        var body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer body_alloc.deinit();
        _ = reader.streamRemaining(&body_alloc.writer) catch {};

        if (response.head.status == .unauthorized or response.head.status == .forbidden) {
            lmstudio.printAuthHint(self.inner.io);
        }

        std.debug.print("Copilot chat request failed\n  URL: {s}\n  Status: {d}\n  Payload: {s}\n  Response: {s}\n", .{
            url,
            @intFromEnum(response.head.status),
            payload,
            body_alloc.written(),
        });
        return error.ResponseError;
    }

    var sse = openai.SseCallback{
        .allocator = allocator,
        .callback = callback,
    };

    lmstudio.parseSseReader(allocator, reader, &sse) catch |err| switch (err) {
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
    return cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch null;
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

    const json_headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
    };

    const device_body = try std.fmt.allocPrint(
        allocator,
        "{{\"client_id\":\"{s}\",\"scope\":\"{s}\"}}",
        .{ client_id, app_scopes },
    );
    defer allocator.free(device_body);

    var device_raw = try httpRequest(self, .POST, github_base_url ++ "/login/device/code", &json_headers, device_body);
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
    const deadline = std.time.timestamp() + (if (device.expires_in > 0) device.expires_in else 900);

    while (std.time.timestamp() < deadline) {
        sleepSeconds(self.inner.io, interval_s + 1);

        const poll_body = try std.fmt.allocPrint(
            allocator,
            "{{\"client_id\":\"{s}\",\"device_code\":\"{s}\",\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\"}}",
            .{ client_id, device.device_code },
        );
        defer allocator.free(poll_body);

        var poll_raw = try httpRequest(self, .POST, github_base_url ++ "/login/oauth/access_token", &json_headers, poll_body);
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
