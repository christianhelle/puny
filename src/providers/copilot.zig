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
