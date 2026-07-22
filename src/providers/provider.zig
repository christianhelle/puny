const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");
const mock = @import("mock.zig");
const opencode_zen = @import("opencode_zen.zig");
const opencode_go = @import("opencode_go.zig");
const copilot = @import("copilot.zig");
const models = @import("models.zig");

pub const ModelProvider = enum {
    lmstudio,
    opencode_zen,
    opencode_go,
    copilot,
    mock,
};

pub fn getProviderDisplayName(selected_provider: ModelProvider) []const u8 {
    return switch (selected_provider) {
        .lmstudio => "LM Studio",
        .opencode_zen => "OpenCode Zen",
        .opencode_go => "OpenCode Go",
        .copilot => "GitHub Copilot",
        .mock => "Mock",
    };
}

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
                var owned = try opencode_zen.listModels(c);
                break :blk try opencode_zen.toSharedModels(&owned);
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
            .opencode => |*c| if (opencode_zen.isAnthropicModel(request.model))
                opencode_zen.chatStreamingAnthropic(c, request, callback)
            else if (opencode_zen.isGoogleModel(request.model))
                opencode_zen.chatStreamingGoogle(c, request, callback)
            else
                openai.chatStreaming(c, request, callback),
            .opencode_go => |*c| if (opencode_go.isAnthropicModel(request.model))
                opencode_zen.chatStreamingAnthropic(c, request, callback)
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

test "getProviderDisplayName maps known providers" {
    try std.testing.expectEqualStrings("LM Studio", getProviderDisplayName(.lmstudio));
    try std.testing.expectEqualStrings("OpenCode Zen", getProviderDisplayName(.opencode_zen));
    try std.testing.expectEqualStrings("OpenCode Go", getProviderDisplayName(.opencode_go));
    try std.testing.expectEqualStrings("GitHub Copilot", getProviderDisplayName(.copilot));
    try std.testing.expectEqualStrings("Mock", getProviderDisplayName(.mock));
}
