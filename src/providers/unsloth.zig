const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");

// Unsloth Studio serves one loaded model and, unless "Switch model by request"
// is enabled in its settings, answers chat requests for anything else with
// "No model loaded". So load the requested model through its inference API
// before streaming, the same way Unsloth's own CLI does.

pub const Client = struct {
    inner: client.Client,
    /// Model this client last loaded, so chats with the same model skip the load.
    loaded_model: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8) Client {
        return .{ .inner = client.Client.init(allocator, io, api_key) };
    }

    pub fn deinit(self: *Client) void {
        self.forgetLoadedModel();
        self.inner.deinit();
    }

    pub fn withBaseUrl(self: *Client, base_url: []const u8) void {
        self.inner.withBaseUrl(base_url);
    }

    pub fn setConfig(self: *Client, config: client.ClientConfig) void {
        // A (possibly different) server has not loaded anything for this client yet.
        if (config.base_url != null) self.forgetLoadedModel();
        self.inner.setConfig(config);
    }

    fn forgetLoadedModel(self: *Client) void {
        if (self.loaded_model) |model| self.inner.allocator.free(model);
        self.loaded_model = null;
    }
};

pub fn chatStreaming(self: *Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    const was_loaded = if (self.loaded_model) |loaded| std.mem.eql(u8, loaded, request.model) else false;
    try ensureModelLoaded(self, request.model);
    if (!was_loaded) return openai.chatStreaming(&self.inner, request, callback);

    // Unsloth may have unloaded the model since (idle timeout, or the UI), so
    // watch for its "No model loaded" reply and load it again once.
    var capture = client.HttpFailureCapture.init(&self.inner);
    defer capture.deinit();
    const original_observer = self.inner.http_observer;
    self.inner.http_observer = capture.observer();
    defer self.inner.http_observer = original_observer;

    openai.chatStreaming(&self.inner, request, callback) catch |err| {
        if (err != error.ResponseError or !isNoModelLoaded(capture.failure)) return err;
        self.inner.http_observer = original_observer;
        self.forgetLoadedModel();
        try ensureModelLoaded(self, request.model);
        return openai.chatStreaming(&self.inner, request, callback);
    };
}

fn isNoModelLoaded(failure: ?client.HttpFailure) bool {
    const f = failure orelse return false;
    return f.status == .bad_request and std.mem.indexOf(u8, f.body, "No model loaded") != null;
}

fn ensureModelLoaded(self: *Client, model: []const u8) !void {
    if (self.loaded_model) |loaded| {
        if (std.mem.eql(u8, loaded, model)) return;
    }
    self.forgetLoadedModel();
    try loadModel(self, model);
    self.loaded_model = try self.inner.allocator.dupe(u8, model);
}

fn loadModel(self: *Client, model: []const u8) !void {
    const allocator = self.inner.allocator;
    // The inference API lives at the server root, beside the OpenAI-compatible /v1.
    var root = std.mem.trimEnd(u8, self.inner.base_url, "/");
    if (std.mem.endsWith(u8, root, "/v1")) root = root[0 .. root.len - "/v1".len];
    const url = try std.fmt.allocPrint(allocator, "{s}/api/inference/load", .{root});
    defer allocator.free(url);
    const payload = try std.json.Stringify.valueAlloc(allocator, .{ .model_path = model }, .{});
    defer allocator.free(payload);

    var raw = try client.requestRaw(&self.inner, .POST, url, payload);
    defer raw.deinit();
    if (raw.status.class() != .success) return error.ResponseError;
    try checkLoadBody(self, url, raw.body);
}

/// A slow load commits 200 early and pads the body until it finishes, so a late
/// failure arrives as `_deferred_error` in the JSON, and a body cut off mid-pad
/// means the load never reported completion.
fn checkLoadBody(self: *Client, url: []const u8, body: []const u8) !void {
    const allocator = self.inner.allocator;
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
        return error.UnslothModelLoadIncomplete;
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() == 0) return error.UnslothModelLoadIncomplete;

    const deferred = parsed.value.object.get("_deferred_error") orelse return;
    const status_code: u10 = blk: {
        if (deferred == .object) {
            if (deferred.object.get("status_code")) |code| {
                if (code == .integer and code.integer >= 400 and code.integer <= 599) break :blk @intCast(code.integer);
            }
        }
        break :blk 500;
    };
    const detail: []const u8 = blk: {
        if (deferred == .object) {
            if (deferred.object.get("detail")) |value| {
                if (value == .string and value.string.len > 0) break :blk value.string;
            }
        }
        break :blk "Model load failed";
    };

    // Report it like any failed response so the chat error shows the reason.
    if (self.inner.http_observer) |obs| {
        if (obs.onResponse) |on_response| {
            const failure_body = try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = .{ .message = detail } }, .{});
            defer allocator.free(failure_body);
            on_response(obs.ctx, .POST, url, @enumFromInt(status_code), &.{}, failure_body, 0);
        }
    }
    return error.ResponseError;
}

test "chatStreaming loads the requested model before streaming" {
    const ctx = try SequenceServer.start(&.{
        .{ .body = "{\"status\":\"loaded\",\"model\":\"unsloth/Qwen3-8B-GGUF\"}" },
        .{ .body = stop_stream },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();

    var events: EventCounter = .{};
    try chatStreaming(&c, chatRequest("unsloth/Qwen3-8B-GGUF"), events.callback());

    try std.testing.expectEqual(@as(usize, 2), ctx.request_count);
    try std.testing.expectEqualStrings("/api/inference/load", ctx.path(0));
    try std.testing.expectEqualStrings("{\"model_path\":\"unsloth/Qwen3-8B-GGUF\"}", ctx.body(0));
    try std.testing.expectEqualStrings("/v1/chat/completions", ctx.path(1));
    try std.testing.expect(events.count > 0);
}

test "chatStreaming loads a model once and again only when the model changes" {
    const ctx = try SequenceServer.start(&.{
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
        .{ .body = stop_stream },
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();

    var events: EventCounter = .{};
    try chatStreaming(&c, chatRequest("model-a"), events.callback());
    try chatStreaming(&c, chatRequest("model-a"), events.callback());
    try chatStreaming(&c, chatRequest("model-b"), events.callback());

    try std.testing.expectEqual(@as(usize, 5), ctx.request_count);
    try std.testing.expectEqualStrings("/v1/chat/completions", ctx.path(2));
    try std.testing.expectEqualStrings("/api/inference/load", ctx.path(3));
    try std.testing.expectEqualStrings("{\"model_path\":\"model-b\"}", ctx.body(3));
}

test "chatStreaming stops and retries the load after a failed load" {
    const ctx = try SequenceServer.start(&.{
        .{ .status = .not_found, .body = "{\"detail\":\"Model not found\"}" },
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();

    var events: EventCounter = .{};
    try std.testing.expectError(error.ResponseError, chatStreaming(&c, chatRequest("missing"), events.callback()));
    try std.testing.expectEqual(@as(usize, 1), ctx.request_count);

    try chatStreaming(&c, chatRequest("missing"), events.callback());
    try std.testing.expectEqualStrings("/api/inference/load", ctx.path(1));
    try std.testing.expectEqualStrings("/v1/chat/completions", ctx.path(2));
}

test "chatStreaming reports a load failure that arrives inside a 200 response" {
    // Slow loads commit 200 early and pad the body, so a late failure is
    // carried in the JSON instead of the status line.
    const ctx = try SequenceServer.start(&.{
        .{ .body = "   \n{\"_deferred_error\":{\"status_code\":507,\"detail\":\"Not enough GPU memory\"}}" },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();
    var capture = client.HttpFailureCapture.init(&c.inner);
    defer capture.deinit();
    c.inner.http_observer = capture.observer();

    var events: EventCounter = .{};
    try std.testing.expectError(error.ResponseError, chatStreaming(&c, chatRequest("too-big"), events.callback()));
    try capture.commit(&c.inner);

    const failure = c.inner.lastHttpFailure() orelse return error.ExpectedHttpFailure;
    try std.testing.expectEqual(@as(u10, 507), @intFromEnum(failure.status));
    try std.testing.expect(std.mem.indexOf(u8, failure.body, "Not enough GPU memory") != null);
    try std.testing.expectEqual(@as(usize, 1), ctx.request_count);
}

test "chatStreaming rejects a load response that ends before completion" {
    const ctx = try SequenceServer.start(&.{
        .{ .body = "    " },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();

    var events: EventCounter = .{};
    try std.testing.expectError(error.UnslothModelLoadIncomplete, chatStreaming(&c, chatRequest("model-a"), events.callback()));
    try std.testing.expectEqual(@as(usize, 1), ctx.request_count);
}

test "chatStreaming loads from the server root when the base url ends in /v1" {
    const ctx = try SequenceServer.start(&.{
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
    });
    defer ctx.stop();
    var c = Client.init(std.testing.allocator, std.testing.io, "");
    defer c.deinit();
    c.withBaseUrl(try std.fmt.bufPrint(&ctx.url_buf, "http://127.0.0.1:{d}/v1/", .{ctx.server.socket.address.getPort()}));

    var events: EventCounter = .{};
    try chatStreaming(&c, chatRequest("model-a"), events.callback());

    try std.testing.expectEqualStrings("/api/inference/load", ctx.path(0));
    try std.testing.expectEqualStrings("/v1/chat/completions", ctx.path(1));
}

test "setConfig with a base url loads the model again on the next chat" {
    const ctx = try SequenceServer.start(&.{
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();

    var events: EventCounter = .{};
    try chatStreaming(&c, chatRequest("model-a"), events.callback());
    c.setConfig(.{ .base_url = c.inner.base_url });
    try chatStreaming(&c, chatRequest("model-a"), events.callback());

    try std.testing.expectEqual(@as(usize, 4), ctx.request_count);
    try std.testing.expectEqualStrings("/api/inference/load", ctx.path(2));
}

test "chatStreaming reloads and retries once when Unsloth unloaded the model" {
    const no_model = "{\"error\":{\"message\":\"No model loaded. Call POST /inference/load first\"}}";
    const ctx = try SequenceServer.start(&.{
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
        // Unsloth unloaded the model (idle timeout or the UI) between turns.
        .{ .status = .bad_request, .body = no_model },
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .body = stop_stream },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();

    var events: EventCounter = .{};
    try chatStreaming(&c, chatRequest("model-a"), events.callback());
    try chatStreaming(&c, chatRequest("model-a"), events.callback());

    try std.testing.expectEqual(@as(usize, 5), ctx.request_count);
    try std.testing.expectEqualStrings("/api/inference/load", ctx.path(3));
    try std.testing.expectEqualStrings("/v1/chat/completions", ctx.path(4));
}

test "chatStreaming does not retry a no-model error right after loading" {
    const no_model = "{\"error\":{\"message\":\"No model loaded. Call POST /inference/load first\"}}";
    const ctx = try SequenceServer.start(&.{
        .{ .body = "{\"status\":\"loaded\"}" },
        .{ .status = .bad_request, .body = no_model },
    });
    defer ctx.stop();
    var c = try testClient(ctx);
    defer c.deinit();

    var events: EventCounter = .{};
    try std.testing.expectError(error.ResponseError, chatStreaming(&c, chatRequest("model-a"), events.callback()));
    try std.testing.expectEqual(@as(usize, 2), ctx.request_count);
}

// Test helpers

const stop_stream =
    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

fn chatRequest(model: []const u8) openai.ChatRequest {
    return .{ .model = model, .messages = &.{.{ .user = "hi" }}, .tools = &.{} };
}

fn testClient(ctx: *SequenceServer) !Client {
    var c = Client.init(std.testing.allocator, std.testing.io, "");
    const url = try std.fmt.bufPrint(&ctx.url_buf, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    c.withBaseUrl(url);
    return c;
}

const EventCounter = struct {
    count: usize = 0,

    fn callback(self: *EventCounter) openai.StreamCallback {
        return .{ .context = self, .vtable = &.{ .event = event, .reset = null } };
    }

    fn event(context: *anyopaque, _: openai.StreamEvent) anyerror!void {
        const self: *EventCounter = @ptrCast(@alignCast(context));
        self.count += 1;
    }
};

/// Answers requests in order with canned responses, recording each request's
/// path and body. Handles several requests on one kept-alive connection.
const SequenceServer = struct {
    const Response = struct {
        status: std.http.Status = .ok,
        body: []const u8,
    };
    const max_requests = 8;

    io: std.Io,
    server: std.Io.net.Server,
    responses: []const Response,
    thread: std.Thread = undefined,
    request_count: usize = 0,
    paths: [max_requests]std.ArrayList(u8) = @splat(.empty),
    bodies: [max_requests]std.ArrayList(u8) = @splat(.empty),
    url_buf: [64]u8 = undefined,

    fn start(responses: []const Response) !*SequenceServer {
        const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        const server = try std.Io.net.IpAddress.listen(&address, std.testing.io, .{});
        const ctx = try std.testing.allocator.create(SequenceServer);
        errdefer std.testing.allocator.destroy(ctx);
        ctx.* = .{ .io = std.testing.io, .server = server, .responses = responses };
        errdefer ctx.server.deinit(std.testing.io);
        ctx.thread = try std.Thread.spawn(.{}, serve, .{ctx});
        return ctx;
    }

    fn stop(ctx: *SequenceServer) void {
        ctx.server.deinit(std.testing.io);
        ctx.thread.join();
        for (&ctx.paths, &ctx.bodies) |*p, *b| {
            p.deinit(std.testing.allocator);
            b.deinit(std.testing.allocator);
        }
        std.testing.allocator.destroy(ctx);
    }

    fn path(ctx: *SequenceServer, index: usize) []const u8 {
        return ctx.paths[index].items;
    }

    fn body(ctx: *SequenceServer, index: usize) []const u8 {
        return ctx.bodies[index].items;
    }

    fn serve(ctx: *SequenceServer) void {
        while (ctx.request_count < ctx.responses.len) {
            var stream = ctx.server.accept(ctx.io) catch return;
            defer stream.close(ctx.io);
            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var reader = stream.reader(ctx.io, &in_buf);
            var writer = stream.writer(ctx.io, &out_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            while (ctx.request_count < ctx.responses.len) {
                var request = http_server.receiveHead() catch break;
                const index = ctx.request_count;
                ctx.paths[index].appendSlice(std.testing.allocator, request.head.target) catch return;
                var body_buf: [4096]u8 = undefined;
                const body_reader = request.readerExpectNone(&body_buf);
                const request_body = body_reader.allocRemaining(std.testing.allocator, .limited(1 << 16)) catch return;
                defer std.testing.allocator.free(request_body);
                ctx.bodies[index].appendSlice(std.testing.allocator, request_body) catch return;
                ctx.request_count += 1;
                const response = ctx.responses[index];
                request.respond(response.body, .{ .status = response.status }) catch return;
            }
        }
    }
};
