const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");
const mock = @import("mock.zig");
const opencode_zen = @import("opencode_zen.zig");
const anthropic = @import("anthropic.zig");
const google = @import("google.zig");
const opencode_go = @import("opencode_go.zig");
const copilot = @import("copilot.zig");
const lmstudio_shim = @import("lmstudio_shim.zig");
const openai_shim = @import("openai_shim.zig");
const anthropic_shim = @import("anthropic_shim.zig");
const lmstudio = @import("lmstudio/client.zig");
const openai_client = @import("openai/client.zig");
const anthropic_client = @import("anthropic/client.zig");

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
                var owned = try lmstudio_shim.listModels(c);
                break :blk try lmstudio_shim.toSharedModels(&owned);
            },
            .opencode => |*c| blk: {
                var owned = try openai_shim.listModels(c);
                break :blk try openai_shim.toSharedModels(&owned);
            },
            .opencode_go => |*c| blk: {
                var owned = try openai_shim.listModels(c);
                break :blk try openai_shim.toSharedModels(&owned);
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
            .lmstudio => |*c| openai_shim.chatStreaming(c, request, callback),
            .opencode => |*c| if (opencode_zen.isAnthropicModel(request.model))
                anthropic_shim.chatStreaming(c, request, callback)
            else if (google.isGoogleModel(request.model))
                google.chatStreamingGoogle(c, request, callback)
            else
                openai_shim.chatStreaming(c, request, callback),
            .opencode_go => |*c| if (opencode_go.isAnthropicModel(request.model))
                anthropic_shim.chatStreaming(c, request, callback)
            else
                openai_shim.chatStreaming(c, request, callback),
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
        const a = self.allocator;
        const owned: openai.StreamEvent = switch (ev) {
            .content => |content| .{ .content = try a.dupe(u8, content) },
            .reasoning => |reasoning| .{ .reasoning = try a.dupe(u8, reasoning) },
            .tool_call_start => |tc| .{ .tool_call_start = .{
                .index = tc.index,
                .id = try a.dupe(u8, tc.id),
                .name = try a.dupe(u8, tc.name),
            } },
            .tool_call_delta => |tc| .{ .tool_call_delta = .{
                .index = tc.index,
                .arguments = try a.dupe(u8, tc.arguments),
            } },
            .finish => |reason| .{ .finish = if (reason) |r| try a.dupe(u8, r) else null },
            .usage => |usage| .{ .usage = usage },
        };
        try self.events.append(self.allocator, owned);
    }
};

test "Provider.chatStreaming dispatches to the mock provider" {
    var prov = Provider{ .mock = mock.MockClient.init(std.testing.allocator, std.testing.io) };
    defer prov.deinit();
    var rec_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rec_state.deinit();
    var rec = TestRecorder{ .events = .empty, .allocator = rec_state.allocator() };

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

const ProviderTestServer = struct {
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

fn startProviderTestServer(status: std.http.Status, body: []const u8) !*ProviderTestServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(ProviderTestServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    ctx.thread = try std.Thread.spawn(.{}, ProviderTestServer.serve, .{ctx});
    return ctx;
}

fn stopProviderTestServer(ctx: *ProviderTestServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn providerTestUrl(ctx: *ProviderTestServer) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
}

fn expectModelIds(owned: *client.Owned(client.ModelsList), expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, owned.value().models.len);
    for (expected, 0..) |id, i| {
        try std.testing.expectEqualStrings(id, owned.value().models[i].id);
    }
}

test "Provider.listModels dispatches to the lmstudio provider" {
    const body =
        \\{"models":[{"type":"llm","publisher":"lmstudio","key":"qwen2.5-7b","display_name":"Qwen2.5 7B","size_bytes":1,"max_context_length":32768,"loaded_instances":[],"format":"gguf"}]}
    ;
    const ctx = try startProviderTestServer(.ok, body);
    defer stopProviderTestServer(ctx);
    const url = try providerTestUrl(ctx);
    defer std.testing.allocator.free(url);

    var prov = Provider{ .lmstudio = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = url });

    var owned = try prov.listModels();
    defer owned.deinit();
    try expectModelIds(&owned, &.{"qwen2.5-7b"});
}

test "Provider.listModels dispatches to the opencode provider" {
    const body =
        \\{"data":[{"id":"deepseek-v4-pro","object":"model","owned_by":"opencode"}]}
    ;
    const ctx = try startProviderTestServer(.ok, body);
    defer stopProviderTestServer(ctx);
    const url = try providerTestUrl(ctx);
    defer std.testing.allocator.free(url);

    var prov = Provider{ .opencode = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = url });

    var owned = try prov.listModels();
    defer owned.deinit();
    try expectModelIds(&owned, &.{"deepseek-v4-pro"});
}

test "Provider.listModels dispatches to the opencode-go provider" {
    const body =
        \\{"data":[{"id":"minimax-m3","object":"model","owned_by":"opencode"}]}
    ;
    const ctx = try startProviderTestServer(.ok, body);
    defer stopProviderTestServer(ctx);
    const url = try providerTestUrl(ctx);
    defer std.testing.allocator.free(url);

    var prov = Provider{ .opencode_go = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = url });

    var owned = try prov.listModels();
    defer owned.deinit();
    try expectModelIds(&owned, &.{"minimax-m3"});
}

test "Provider.listModels dispatches to the copilot provider" {
    const body =
        \\{"data":[{"id":"claude-sonnet-4.5","name":"Claude Sonnet 4.5","vendor":"Anthropic","model_picker_enabled":true,"capabilities":{"type":"chat"}}]}
    ;
    const ctx = try startProviderTestServer(.ok, body);
    defer stopProviderTestServer(ctx);
    const url = try providerTestUrl(ctx);
    defer std.testing.allocator.free(url);

    var prov = Provider{ .copilot = copilot.Client.init(std.testing.allocator, std.testing.io, "gho_test") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = url });

    const token = try std.testing.allocator.dupe(u8, "tid=test");
    prov.copilot.copilot_token = token;
    prov.copilot.copilot_token_expires_at = std.Io.Timestamp.now(std.testing.io, .real).toSeconds() + 3600;

    var owned = try prov.listModels();
    defer owned.deinit();
    try expectModelIds(&owned, &.{"claude-sonnet-4.5"});
}

test "Provider.chatStreaming dispatches to the lmstudio provider" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hi from LM\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startProviderTestServer(.ok, body);
    defer stopProviderTestServer(ctx);
    const url = try providerTestUrl(ctx);
    defer std.testing.allocator.free(url);

    var prov = Provider{ .lmstudio = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = url });

    var rec_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rec_state.deinit();
    var rec = TestRecorder{ .events = .empty, .allocator = rec_state.allocator() };

    const request = openai.ChatRequest{
        .model = "qwen2.5-7b",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    try prov.chatStreaming(request, rec.callback());

    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
    switch (rec.events.items[0]) {
        .content => |content| try std.testing.expectEqualStrings("Hi from LM", content),
        else => return error.ExpectedContentEvent,
    }
}

test "Provider.chatStreaming dispatches to the google transport for gemini models" {
    const body =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello Gemini\"}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[]},\"finishReason\":\"STOP\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startProviderTestServer(.ok, body);
    defer stopProviderTestServer(ctx);
    const url = try providerTestUrl(ctx);
    defer std.testing.allocator.free(url);

    var prov = Provider{ .opencode = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = url });

    var rec_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rec_state.deinit();
    var rec = TestRecorder{ .events = .empty, .allocator = rec_state.allocator() };

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    try prov.chatStreaming(request, rec.callback());

    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
    switch (rec.events.items[0]) {
        .content => |content| try std.testing.expectEqualStrings("Hello Gemini", content),
        else => return error.ExpectedContentEvent,
    }
}

test "Provider.chatStreaming dispatches to the anthropic transport for claude models" {
    const body =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello Claude\"}}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startProviderTestServer(.ok, body);
    defer stopProviderTestServer(ctx);
    const url = try providerTestUrl(ctx);
    defer std.testing.allocator.free(url);

    var prov = Provider{ .opencode_go = client.Client.init(std.testing.allocator, std.testing.io, "") };
    defer prov.deinit();
    prov.setConfig(.{ .base_url = url });

    var rec_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rec_state.deinit();
    var rec = TestRecorder{ .events = .empty, .allocator = rec_state.allocator() };

    const request = openai.ChatRequest{
        .model = "minimax-m3",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    try prov.chatStreaming(request, rec.callback());

    try std.testing.expectEqual(@as(usize, 3), rec.events.items.len);
    switch (rec.events.items[0]) {
        .content => |content| try std.testing.expectEqualStrings("Hello Claude", content),
        else => return error.ExpectedContentEvent,
    }
}
