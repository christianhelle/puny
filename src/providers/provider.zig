const std = @import("std");
const lmstudio = @import("lmstudio.zig");
const openai = @import("openai.zig");
const mock = @import("mock.zig");
const opencode = @import("opencode.zig");
const copilot = @import("copilot.zig");

pub const Provider = union(enum) {
    lmstudio: lmstudio.Client,
    opencode: lmstudio.Client,
    copilot: copilot.Client,
    mock: mock.MockClient,

    pub fn deinit(self: *Provider) void {
        switch (self.*) {
            inline else => |*p| p.deinit(),
        }
    }

    pub fn listModels(self: *Provider) !lmstudio.Owned(lmstudio.ListModelsResponse) {
        return switch (self.*) {
            .lmstudio => |*c| lmstudio.listModels(c),
            .opencode => |*c| opencode.listModels(c),
            .copilot => |*c| copilot.listModels(c),
            .mock => |*c| c.listModels(),
        };
    }

    pub fn chatStreaming(self: *Provider, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
        return switch (self.*) {
            .lmstudio => |*c| openai.chatStreaming(c, request, callback),
            .opencode => |*c| if (opencode.isAnthropicModel(request.model))
                opencode.chatStreamingAnthropic(c, request, callback)
            else if (opencode.isGoogleModel(request.model))
                opencode.chatStreamingGoogle(c, request, callback)
            else
                openai.chatStreaming(c, request, callback),
            .copilot => |*c| copilot.chatStreaming(c, request, callback),
            .mock => |*c| c.chatStreaming(request, callback),
        };
    }

    /// Access the underlying Copilot client, when this provider is Copilot.
    pub fn asCopilot(self: *Provider) ?*copilot.Client {
        return switch (self.*) {
            .copilot => |*c| c,
            else => null,
        };
    }

    pub fn setUrlAndKey(self: *Provider, url: []const u8, key: []const u8) void {
        switch (self.*) {
            .lmstudio => |*c| {
                c.withBaseUrl(url);
                c.api_key = key;
            },
            .opencode => |*c| {
                c.withBaseUrl(url);
                c.api_key = key;
            },
            .copilot => |*c| {
                c.withBaseUrl(url);
                c.setGithubToken(key);
            },
            .mock => {},
        }
    }
};
