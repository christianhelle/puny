const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");
const mock = @import("mock.zig");
const opencode = @import("opencode_zen.zig");
const opencode_go = @import("opencode_go.zig");
const copilot = @import("copilot.zig");
const models = @import("models.zig");

pub const Provider = union(enum) {
    lmstudio: client.Client,
    opencode: client.Client,
    opencode_go: client.Client,
    copilot: copilot.Client,
    mock: mock.MockClient,

    pub fn deinit(self: *Provider) void {
        switch (self.*) {
            inline else => |*p| p.deinit(),
        }
    }

    pub fn listModels(self: *Provider) !client.Owned(client.ModelsList) {
        return switch (self.*) {
            .lmstudio => |*c| blk: {
                var owned = try models.listModels(c);
                break :blk try models.toSharedModels(&owned);
            },
            .opencode => |*c| blk: {
                var owned = try opencode.listModels(c);
                break :blk try opencode.toSharedModels(&owned);
            },
            .opencode_go => |*c| blk: {
                var owned = try opencode_go.listModels(c);
                break :blk try opencode_go.toSharedModels(&owned);
            },
            .copilot => |*c| blk: {
                var owned = try copilot.listModels(c);
                break :blk try copilot.toSharedModels(&owned);
            },
            .mock => |*c| blk: {
                var owned = try c.listModels();
                break :blk try mock.MockClient.toSharedModels(&owned);
            },
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
            .opencode_go => |*c| if (opencode_go.isAnthropicModel(request.model))
                opencode.chatStreamingAnthropic(c, request, callback)
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
            .opencode, .opencode_go => |*c| {
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

    pub fn setHttpObserver(self: *Provider, observer: client.HttpObserver) void {
        switch (self.*) {
            .lmstudio => |*c| c.http_observer = observer,
            .opencode, .opencode_go => |*c| c.http_observer = observer,
            .copilot => |*c| c.inner.http_observer = observer,
            .mock => {},
        }
    }
};
