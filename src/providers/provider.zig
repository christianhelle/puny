const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");
const mock = @import("mock.zig");
const opencode_zen = @import("opencode_zen.zig");
const google = @import("google.zig");
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

pub const ClientConfig = client.ClientConfig;

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
            else if (google.isGoogleModel(request.model))
                google.chatStreamingGoogle(c, request, callback)
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

    pub fn setConfig(self: *Provider, config: ClientConfig) void {
        switch (self.*) {
            .lmstudio, .opencode, .opencode_go => |*c| c.setConfig(config),
            .copilot => |*c| c.setConfig(config),
            .mock => |*c| c.setConfig(config),
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

test "asCopilot returns null for non-copilot providers" {
    var mock_provider = Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer mock_provider.deinit();
    try std.testing.expect(mock_provider.asCopilot() == null);
}

test "asCopilot returns the copilot client" {
    var prov = Provider{ .copilot = copilot.Client.init(std.testing.allocator, std.testing.io, "gho_test_token") };
    defer prov.deinit();

    const as_copilot = prov.asCopilot();
    try std.testing.expect(as_copilot != null);
    try std.testing.expectEqualStrings("gho_test_token", as_copilot.?.github_token);
}

test "Provider.listModels dispatches to the mock provider" {
    var prov = Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    var owned = try prov.listModels();
    defer owned.deinit();
    const model_list = owned.value().models;
    try std.testing.expectEqual(@as(usize, 4), model_list.len);
    try std.testing.expectEqualStrings("mock-model", model_list[0].id);
    try std.testing.expectEqualStrings("mock-model-fast", model_list[1].id);
    try std.testing.expectEqualStrings("mock", model_list[0].provider);
    try std.testing.expectEqual(@as(i64, 128000), model_list[0].context_length);
}

test "Provider.setConfig applies config to the copilot client" {
    var prov = Provider{ .copilot = copilot.Client.init(std.testing.allocator, std.testing.io, "old-token") };
    defer prov.deinit();

    prov.setConfig(.{ .base_url = "https://test.example.com", .api_key = "new-token" });

    const c = prov.asCopilot().?;
    try std.testing.expectEqualStrings("new-token", c.github_token);
    try std.testing.expectEqualStrings("https://test.example.com", c.inner.base_url);
}

test "Provider.setConfig applies config to the mock client" {
    var prov = Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();

    prov.setConfig(.{ .base_url = "https://ignored.example.com", .api_key = "ignored" });
}

test "Provider.setConfig applies config to the lmstudio client" {
    var prov = Provider{ .lmstudio = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();

    prov.setConfig(.{ .base_url = "http://localhost:1234", .api_key = "lm-key" });

    switch (prov) {
        .lmstudio => |c| {
            try std.testing.expectEqualStrings("http://localhost:1234", c.base_url);
            try std.testing.expectEqualStrings("lm-key", c.api_key);
        },
        else => unreachable,
    }
}

const TestRecorder = struct {
    events: std.ArrayList(openai.StreamEvent),
    allocator: std.mem.Allocator,

    fn callback(self: *TestRecorder) openai.StreamCallback {
        return .{
            .context = self,
            .vtable = &.{
                .event = event,
                .reset = null,
            },
        };
    }

    fn event(context: *anyopaque, ev: openai.StreamEvent) anyerror!void {
        const self: *TestRecorder = @ptrCast(@alignCast(context));
        try self.events.append(self.allocator, ev);
    }
};

test "Provider.chatStreaming dispatches to the mock provider" {
    var prov = Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();
    var rec = TestRecorder{ .events = .empty, .allocator = std.testing.allocator };
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "echo dispatch" }},
        .tools = &.{},
    };
    try prov.chatStreaming(request, rec.callback());

    try std.testing.expect(rec.events.items.len > 0);
    var found_finish = false;
    for (rec.events.items) |ev| {
        switch (ev) {
            .finish => |finish| {
                try std.testing.expectEqualStrings("stop", finish.?);
                found_finish = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_finish);
}
