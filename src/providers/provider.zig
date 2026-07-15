const std = @import("std");
const lmstudio = @import("lmstudio.zig");
const openai = @import("openai.zig");
const mock = @import("mock.zig");
const opencode = @import("opencode.zig");

pub const Provider = union(enum) {
    lmstudio: lmstudio.Client,
    opencode: lmstudio.Client,
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
            .mock => |*c| c.listModels(),
        };
    }

    pub fn chatStreaming(self: *Provider, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
        return switch (self.*) {
            .lmstudio => |*c| openai.chatStreaming(c, request, callback),
            .opencode => |*c| openai.chatStreaming(c, request, callback),
            .mock => |*c| c.chatStreaming(request, callback),
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
            .mock => {},
        }
    }
};
