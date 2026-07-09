const std = @import("std");
const lmstudio = @import("lmstudio.zig");
const openai = @import("openai.zig");
const mock = @import("mock.zig");

pub const Provider = union(enum) {
    lmstudio: lmstudio.Client,
    mock: mock.MockClient,

    pub fn deinit(self: *Provider) void {
        switch (self.*) {
            inline else => |*p| p.deinit(),
        }
    }

    pub fn listModels(self: *Provider) !lmstudio.Owned(lmstudio.ListModelsResponse) {
        return switch (self.*) {
            .lmstudio => |*c| lmstudio.listModels(c),
            .mock => |*c| c.listModels(),
        };
    }

    pub fn chatStreaming(self: *Provider, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
        return switch (self.*) {
            .lmstudio => |*c| openai.chatStreaming(c, request, callback),
            .mock => |*c| c.chatStreaming(request, callback),
        };
    }
};
