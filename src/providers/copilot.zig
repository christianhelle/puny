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
