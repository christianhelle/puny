const std = @import("std");
const cancel = @import("../core/cancel.zig");
const http_client = @import("client.zig");
const openai = @import("openai.zig");

pub const default_base_url = "https://opencode.ai/zen";
pub const anthropic_version = "2023-06-01";
pub const default_max_tokens = 4096;

pub fn isSupportedModel(model_id: []const u8) bool {
    // Every OpenCode Zen model is reachable through one of the three
    // transports (OpenAI-compatible, Anthropic, or Google). Prefixes listed
    // here are filtered out of the model picker as unreachable.
    const excluded = [_][]const u8{};

    for (excluded) |prefix| {
        if (std.mem.startsWith(u8, model_id, prefix)) return false;
    }
    return true;
}

pub fn isAnthropicModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "claude-");
}

pub const ModelInfo = struct {
    id: []const u8,
    owned_by: []const u8,
};

pub const ModelsList = struct {
    data: []const ModelInfo,
};

pub fn parseModels(allocator: std.mem.Allocator, response_json: []const u8) !http_client.Owned(ModelsList) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    const items = data.array.items;

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);

    var models: std.ArrayList(ModelInfo) = .empty;

    for (items) |item| {
        const id = if (item.object.get("id")) |v| v.string else continue;
        if (!isSupportedModel(id)) continue;

        const owned_by = if (item.object.get("owned_by")) |v| v.string else "opencode";
        const arena_alloc = arena.allocator();

        try models.append(arena_alloc, .{
            .id = try arena_alloc.dupe(u8, id),
            .owned_by = try arena_alloc.dupe(u8, owned_by),
        });
    }

    const result = std.json.Parsed(ModelsList){
        .arena = arena,
        .value = .{ .data = try models.toOwnedSlice(arena.allocator()) },
    };

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, response_json),
        .parsed = result,
    };
}

/// Convert an OpenCode-specific model list into the app-wide shared model list.
/// The source `owned` is deinitialized; ownership of the returned value is transferred.
pub fn toSharedModels(owned: *http_client.Owned(ModelsList)) !http_client.Owned(http_client.ModelsList) {
    const allocator = owned.allocator;
    const source = owned.value();

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    var models = try arena_alloc.alloc(http_client.Model, source.data.len);
    for (source.data, 0..) |m, i| {
        models[i] = .{
            .id = try arena_alloc.dupe(u8, m.id),
            .display_name = try arena_alloc.dupe(u8, m.id),
            .provider = try arena_alloc.dupe(u8, m.owned_by),
            .context_length = 0,
        };
    }

    owned.deinit();

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, ""),
        .parsed = .{
            .arena = arena,
            .value = .{ .models = models },
        },
    };
}

pub fn listModelsRaw(client: *http_client.Client) !http_client.RawResponse {
    const allocator = client.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/v1/models", .{client.base_url});
    return http_client.requestRaw(client, std.http.Method.GET, uri_buf.written(), null);
}

fn listModelsResult(client: *http_client.Client) !http_client.ApiResult(ModelsList) {
    var raw = try listModelsRaw(client);
    if (raw.status.class() != .success) return .{ .api_error = raw };
    const result = parseModels(client.allocator, raw.body) catch |err| {
        return .{ .parse_error = .{ .raw = raw, .error_name = @errorName(err) } };
    };
    raw.deinit();
    return .{ .ok = result };
}

pub fn listModels(client: *http_client.Client) !http_client.Owned(ModelsList) {
    var result = try listModelsResult(client);
    switch (result) {
        .ok => |ok| return ok,
        .api_error => |*err| {
            if (http_client.isAuthFailure(err.status)) http_client.printAuthHint(client.io);
            err.deinit();
            return error.ResponseError;
        },
        .parse_error => |*err| {
            err.raw.deinit();
            return error.ResponseParseError;
        },
    }
}

fn writeAnthropicTextBlock(writer: anytype, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte('}');
}

fn writeAnthropicToolUseBlock(writer: anytype, id: []const u8, name: []const u8, arguments: []const u8) !void {
    try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"input\":");
    if (std.mem.trim(u8, arguments, " \t\r\n").len > 0) {
        try writer.writeAll(arguments);
    } else {
        try writer.writeAll("{}");
    }
    try writer.writeByte('}');
}

fn writeAnthropicToolResultBlock(writer: anytype, tool_use_id: []const u8, content: []const u8) !void {
    try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try std.json.Stringify.value(tool_use_id, .{}, writer);
    try writer.writeAll(",\"content\":");
    try std.json.Stringify.value(content, .{}, writer);
    try writer.writeByte('}');
}

fn writeAnthropicTool(writer: anytype, tool: openai.ToolDefinition) !void {
    const function = tool.function.object;
    const name = if (function.get("name")) |v| v.string else return error.MissingToolName;
    const description = if (function.get("description")) |v| v.string else "";

    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"input_schema\":");
    if (function.get("parameters")) |params| {
        try std.json.Stringify.value(params, .{}, writer);
    } else {
        try writer.writeAll("{}");
    }
    try writer.writeByte('}');
}

fn writeAnthropicMessage(writer: anytype, msg: openai.Message) !void {
    switch (msg) {
        .system => unreachable, // handled separately
        .user => |content| {
            try writer.writeAll("{\"role\":\"user\",\"content\":[");
            try writeAnthropicTextBlock(writer, content);
            try writer.writeAll("]}");
        },
        .assistant => |assistant| {
            try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
            var first = true;
            if (assistant.content) |content| {
                try writeAnthropicTextBlock(writer, content);
                first = false;
            }
            if (assistant.tool_calls) |tool_calls| {
                for (tool_calls) |tc| {
                    if (!first) try writer.writeByte(',');
                    try writeAnthropicToolUseBlock(writer, tc.id, tc.function.name, tc.function.arguments);
                    first = false;
                }
            }
            try writer.writeAll("]}");
        },
        .tool => |tool| {
            try writer.writeAll("{\"role\":\"user\",\"content\":[");
            try writeAnthropicToolResultBlock(writer, tool.tool_call_id, tool.content);
            try writer.writeAll("]}");
        },
    }
}

const BlockType = enum {
    text,
    thinking,
    tool_use,
};

const AnthropicSseCallback = struct {
    allocator: std.mem.Allocator,
    callback: openai.StreamCallback,
    block_types: std.ArrayList(BlockType),
    input_tokens: i64 = 0,
    observer: ?http_client.HttpObserver = null,

    pub fn event(self: *@This(), data: []const u8) !void {
        if (self.observer) |obs| {
            if (obs.on_chunk) |cb| cb(obs.ctx, data);
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const event_type = if (parsed.value.object.get("type")) |v| v.string else return;

        if (std.mem.eql(u8, event_type, "message_start")) {
            if (parsed.value.object.get("message")) |message| {
                if (message.object.get("usage")) |usage| {
                    if (usage.object.get("input_tokens")) |v| self.input_tokens = v.integer;
                }
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const index = if (parsed.value.object.get("index")) |v| @as(usize, @intCast(v.integer)) else return;
            const content_block = parsed.value.object.get("content_block") orelse return;
            const block_type = if (content_block.object.get("type")) |v| v.string else return;

            while (self.block_types.items.len <= index) {
                try self.block_types.append(self.allocator, .text);
            }

            if (std.mem.eql(u8, block_type, "tool_use")) {
                self.block_types.items[index] = .tool_use;
                const id = if (content_block.object.get("id")) |v| v.string else "";
                const name = if (content_block.object.get("name")) |v| v.string else "";
                if (id.len > 0 and name.len > 0) {
                    try self.callback.emit(.{ .tool_call_start = .{ .index = index, .id = id, .name = name } });
                }
            } else if (std.mem.eql(u8, block_type, "thinking")) {
                self.block_types.items[index] = .thinking;
            } else {
                self.block_types.items[index] = .text;
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const index = if (parsed.value.object.get("index")) |v| @as(usize, @intCast(v.integer)) else return;
            const delta = parsed.value.object.get("delta") orelse return;
            const delta_type = if (delta.object.get("type")) |v| v.string else return;

            if (index >= self.block_types.items.len) return;
            const block_type = self.block_types.items[index];

            switch (block_type) {
                .text => {
                    if (std.mem.eql(u8, delta_type, "text_delta")) {
                        if (delta.object.get("text")) |text| {
                            try self.callback.emit(.{ .content = text.string });
                        }
                    }
                },
                .thinking => {
                    if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                        if (delta.object.get("thinking")) |thinking| {
                            try self.callback.emit(.{ .reasoning = thinking.string });
                        }
                    }
                },
                .tool_use => {
                    if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                        if (delta.object.get("partial_json")) |partial| {
                            try self.callback.emit(.{ .tool_call_delta = .{ .index = index, .arguments = partial.string } });
                        }
                    }
                },
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "message_delta")) {
            if (parsed.value.object.get("delta")) |delta| {
                if (delta.object.get("stop_reason")) |reason| {
                    const reason_str = reason.string;
                    try self.callback.emit(.{ .finish = if (reason_str.len == 0) null else reason_str });
                }
            }
            var output_tokens: i64 = 0;
            if (parsed.value.object.get("usage")) |usage| {
                if (usage.object.get("output_tokens")) |v| output_tokens = v.integer;
            }
            try self.callback.emit(.{ .usage = .{
                .input_tokens = self.input_tokens,
                .output_tokens = output_tokens,
            } });
        }
    }
};

pub fn chatStreamingAnthropic(client: *http_client.Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    const allocator = client.allocator;
    const payload = try anthropicRequestPayload(allocator, request);
    defer allocator.free(payload);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{client.base_url});
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "x-api-key", .value = client.api_key });
    try headers.append(allocator, .{ .name = "anthropic-version", .value = anthropic_version });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "accept", .value = "text/event-stream" });

    if (client.http_observer) |obs| {
        if (obs.onRequest) |cb| cb(obs.ctx, .POST, url, headers.items, payload);
    }

    const uri = try std.Uri.parse(url);

    const start = std.Io.Clock.awake.now(client.io);
    var req = client.http.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers.items,
    }) catch |err| {
        if (client.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
        }
        return err;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = req.receiveHead(&.{}) catch |err| {
        if (client.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
        }
        return err;
    };
    const elapsed_ns = @as(u64, @intCast(start.untilNow(client.io, .awake).nanoseconds));

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    var cancelable_reader_buffer: [1]u8 = undefined;
    var cancelable_reader = openai.CancelableReader.init(response_reader, &cancelable_reader_buffer);
    const reader = &cancelable_reader.reader;

    if (response.head.status.class() != .success) {
        var body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer body_alloc.deinit();
        _ = reader.streamRemaining(&body_alloc.writer) catch {};

        if (client.http_observer) |obs| {
            if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, body_alloc.written(), elapsed_ns);
        }

        if (response.head.status == .unauthorized or response.head.status == .forbidden) {
            http_client.printAuthHint(client.io);
        }

        std.debug.print("Anthropic chat request failed\n  URL: {s}\n  Status: {d}\n  Payload: {s}\n  Response: {s}\n", .{
            url,
            @intFromEnum(response.head.status),
            payload,
            body_alloc.written(),
        });
        return error.ResponseError;
    }

    if (client.http_observer) |obs| {
        if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, "", elapsed_ns);
    }

    const block_types: std.ArrayList(BlockType) = .empty;

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
        .block_types = block_types,
        .observer = client.http_observer,
    };

    defer sse.block_types.deinit(allocator);
    http_client.parseSseReader(allocator, reader, &sse, null) catch |err| switch (err) {
        error.ReadFailed => {
            if (cancel.isCancelled()) return error.Canceled;
            return err;
        },
        else => return err,
    };
}

pub fn anthropicRequestPayload(allocator: std.mem.Allocator, request: openai.ChatRequest) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, w);

    var system: ?[]const u8 = null;

    try w.writeAll(",\"messages\":[");
    var first_msg = true;
    for (request.messages) |msg| {
        switch (msg) {
            .system => |content| {
                if (system == null) system = content;
            },
            else => {
                if (!first_msg) try w.writeByte(',');
                try writeAnthropicMessage(w, msg);
                first_msg = false;
            },
        }
    }
    try w.writeByte(']');

    try w.writeAll(",\"max_tokens\":");
    try std.json.Stringify.value(default_max_tokens, .{}, w);

    try w.writeAll(",\"stream\":");
    try std.json.Stringify.value(request.stream, .{}, w);

    if (system) |value| {
        try w.writeAll(",\"system\":");
        try std.json.Stringify.value(value, .{}, w);
    }

    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, i| {
            if (i > 0) try w.writeByte(',');
            try writeAnthropicTool(w, tool);
        }
        try w.writeByte(']');
    }

    if (request.temperature) |temp| {
        try w.writeAll(",\"temperature\":");
        try std.json.Stringify.value(temp, .{}, w);
    }

    if (request.reasoning_effort) |effort| {
        if (effort != .default) {
            const effort_str = switch (effort) {
                .xhigh => "max",
                else => @tagName(effort),
            };
            try w.writeAll(",\"thinking\":{\"type\":\"enabled\"},\"output_config\":{\"effort\":\"");
            try w.writeAll(effort_str);
            try w.writeAll("\"}");
        }
    }

    try w.writeByte('}');

    return buf.toOwnedSlice();
}

test "isSupportedModel accepts supported model families" {
    try std.testing.expect(isSupportedModel("deepseek-v4-pro"));
    try std.testing.expect(isSupportedModel("deepseek-v4-flash-free"));
    try std.testing.expect(isSupportedModel("kimi-k2.7-code"));
    try std.testing.expect(isSupportedModel("kimi-k2.5"));
    try std.testing.expect(isSupportedModel("glm-5.2"));
    try std.testing.expect(isSupportedModel("minimax-m3"));
    try std.testing.expect(isSupportedModel("grok-4.5"));
    try std.testing.expect(isSupportedModel("grok-build-0.1"));
    try std.testing.expect(isSupportedModel("big-pickle"));
    try std.testing.expect(isSupportedModel("mimo-v2.5-free"));
    try std.testing.expect(isSupportedModel("north-mini-code-free"));
    try std.testing.expect(isSupportedModel("nemotron-3-ultra-free"));
    try std.testing.expect(isSupportedModel("claude-opus-4-8"));
    try std.testing.expect(isSupportedModel("claude-sonnet-4.6"));
    try std.testing.expect(isSupportedModel("claude-haiku-4.5"));
    try std.testing.expect(isSupportedModel("gpt-5.5"));
    try std.testing.expect(isSupportedModel("gpt-5.3-codex"));
    try std.testing.expect(isSupportedModel("gemini-3.5-flash"));
    try std.testing.expect(isSupportedModel("gemini-3.1-pro"));
}

test "isAnthropicModel detects claude families" {
    try std.testing.expect(isAnthropicModel("claude-opus-4-8"));
    try std.testing.expect(isAnthropicModel("claude-sonnet-4.6"));
    try std.testing.expect(isAnthropicModel("claude-haiku-4.5"));
    try std.testing.expect(!isAnthropicModel("deepseek-v4-pro"));
    try std.testing.expect(!isAnthropicModel("kimi-k2.7-code"));
}

test "parseModels maps OpenAI model list" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"deepseek-v4-pro","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"gemini-3.5-flash","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"kimi-k2.7-code","object":"model","created":1784147408,"owned_by":"opencode"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.value().data.len);
    try std.testing.expectEqualStrings("deepseek-v4-pro", result.value().data[0].id);
    try std.testing.expectEqualStrings("opencode", result.value().data[0].owned_by);
    try std.testing.expectEqualStrings("gemini-3.5-flash", result.value().data[1].id);
    try std.testing.expectEqualStrings("kimi-k2.7-code", result.value().data[2].id);
}

test "parseModels ignores unknown fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","extra":true,"data":[
        \\  {"id":"big-pickle","object":"model","created":1784147408,"owned_by":"opencode","unknown_field":123}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.value().data.len);
    try std.testing.expectEqualStrings("big-pickle", result.value().data[0].id);
}

fn sampleToolSchema(allocator: std.mem.Allocator) !std.json.Value {
    const schema =
        \\{"name":"read_file","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}
    ;
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, schema, .{ .ignore_unknown_fields = true });
}

test "anthropicRequestPayload converts OpenAI request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const schema = try sampleToolSchema(allocator);

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{
            .{ .system = "You are helpful." },
            .{ .user = "Hello" },
            .{ .assistant = .{ .content = "Hi" } },
            .{ .assistant = .{
                .tool_calls = &.{
                    .{
                        .id = "call_1",
                        .function = .{ .name = "read_file", .arguments = "{\"path\":\"src/main.zig\"}" },
                    },
                },
            } },
            .{ .tool = .{ .tool_call_id = "call_1", .content = "file contents" } },
        },
        .tools = &.{
            .{ .function = schema },
        },
        .stream = true,
        .temperature = 0.5,
    };

    const payload = try anthropicRequestPayload(allocator, request);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("claude-sonnet-4.6", obj.get("model").?.string);
    try std.testing.expectEqualStrings("You are helpful.", obj.get("system").?.string);
    try std.testing.expectEqual(@as(i64, 4096), obj.get("max_tokens").?.integer);
    try std.testing.expectEqual(@as(f64, 0.5), obj.get("temperature").?.float);

    const messages = obj.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), messages.len);

    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("Hello", messages[0].object.get("content").?.array.items[0].object.get("text").?.string);

    try std.testing.expectEqualStrings("assistant", messages[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("Hi", messages[1].object.get("content").?.array.items[0].object.get("text").?.string);

    try std.testing.expectEqualStrings("assistant", messages[2].object.get("role").?.string);
    const tool_use = messages[2].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_use", tool_use.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", tool_use.get("id").?.string);
    try std.testing.expectEqualStrings("read_file", tool_use.get("name").?.string);
    try std.testing.expectEqualStrings("src/main.zig", tool_use.get("input").?.object.get("path").?.string);

    try std.testing.expectEqualStrings("user", messages[3].object.get("role").?.string);
    const tool_result = messages[3].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_result", tool_result.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", tool_result.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings("file contents", tool_result.get("content").?.string);

    const tools = obj.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("read_file", tools[0].object.get("name").?.string);
    try std.testing.expect(tools[0].object.get("input_schema") != null);
}

const TestEvent = union(enum) {
    content: []const u8,
    reasoning: []const u8,
    tool_call_start: struct { index: usize, id: []const u8, name: []const u8 },
    tool_call_delta: struct { index: usize, arguments: []const u8 },
    finish: ?[]const u8,
    usage: openai.TurnUsage,
};

const TestSseCallback = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList(TestEvent),

    pub fn event(ctx: *anyopaque, ev: openai.StreamEvent) !void {
        const self: *TestSseCallback = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .content => |v| try self.events.append(self.allocator, .{ .content = try self.allocator.dupe(u8, v) }),
            .reasoning => |v| try self.events.append(self.allocator, .{ .reasoning = try self.allocator.dupe(u8, v) }),
            .tool_call_start => |v| try self.events.append(self.allocator, .{ .tool_call_start = .{
                .index = v.index,
                .id = try self.allocator.dupe(u8, v.id),
                .name = try self.allocator.dupe(u8, v.name),
            } }),
            .tool_call_delta => |v| try self.events.append(self.allocator, .{ .tool_call_delta = .{
                .index = v.index,
                .arguments = try self.allocator.dupe(u8, v.arguments),
            } }),
            .finish => |v| try self.events.append(self.allocator, .{ .finish = if (v) |reason| try self.allocator.dupe(u8, reason) else null }),
            .usage => |v| try self.events.append(self.allocator, .{ .usage = v }),
        }
    }
};

test "AnthropicSseCallback emits content and usage events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const block_types = std.ArrayList(BlockType).empty;

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
        .block_types = block_types,
    };

    try sse.event("{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-4.6\",\"content\":[],\"usage\":{\"input_tokens\":10}}}");
    try sse.event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}");
    try sse.event("{\"type\":\"content_block_stop\",\"index\":0}");
    try sse.event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":20}}");

    try std.testing.expectEqual(@as(usize, 4), events.items.len);
    try std.testing.expectEqualStrings("Hello", events.items[0].content);
    try std.testing.expectEqualStrings(" world", events.items[1].content);
    try std.testing.expectEqualStrings("end_turn", events.items[2].finish.?);
    try std.testing.expectEqual(@as(i64, 10), events.items[3].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 20), events.items[3].usage.output_tokens);
}

test "AnthropicSseCallback emits tool call events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const block_types = std.ArrayList(BlockType).empty;

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
        .block_types = block_types,
    };

    try sse.event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"read_file\",\"input\":{}}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"src\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"/main.zig\\\"}\"}}");
    try sse.event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":15}}");

    try std.testing.expectEqual(@as(usize, 5), events.items.len);
    try std.testing.expectEqualStrings("call_1", events.items[0].tool_call_start.id);
    try std.testing.expectEqualStrings("read_file", events.items[0].tool_call_start.name);
    try std.testing.expectEqualStrings("{\"path\":\"src", events.items[1].tool_call_delta.arguments);
    try std.testing.expectEqualStrings("/main.zig\"}", events.items[2].tool_call_delta.arguments);
    try std.testing.expectEqualStrings("tool_use", events.items[3].finish.?);
    try std.testing.expectEqual(@as(i64, 15), events.items[4].usage.output_tokens);
}

test "AnthropicSseCallback emits thinking delta as reasoning events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const block_types = std.ArrayList(BlockType).empty;

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
        .block_types = block_types,
    };

    try sse.event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"text\":\"\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Let me think\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\" about this...\"}}");
    try sse.event("{\"type\":\"content_block_stop\",\"index\":0}");
    try sse.event("{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Here is the answer\"}}");
    try sse.event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":10}}");

    try std.testing.expectEqual(@as(usize, 5), events.items.len);
    try std.testing.expectEqualStrings("Let me think", events.items[0].reasoning);
    try std.testing.expectEqualStrings(" about this...", events.items[1].reasoning);
    try std.testing.expectEqualStrings("Here is the answer", events.items[2].content);
    try std.testing.expectEqualStrings("end_turn", events.items[3].finish.?);
    try std.testing.expectEqual(@as(i64, 10), events.items[4].usage.output_tokens);
}

test "anthropicRequestPayload includes thinking and output_config when reasoning_effort high" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .high,
    };

    const payload = try anthropicRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("enabled", root.get("thinking").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("high", root.get("output_config").?.object.get("effort").?.string);
}

test "anthropicRequestPayload omits thinking when reasoning_effort default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .default,
    };

    const payload = try anthropicRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("thinking") == null);
    try std.testing.expect(parsed.value.object.get("output_config") == null);
}

test "anthropicRequestPayload maps xhigh to max effort" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .xhigh,
    };

    const payload = try anthropicRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("max", root.get("output_config").?.object.get("effort").?.string);
}

test "parseModels errors when the data field is missing" {
    try std.testing.expectError(error.MissingData, parseModels(std.testing.allocator, "{\"object\":\"list\"}"));
}

test "parseModels skips entries without id and defaults owned_by" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data":[
        \\  {"object":"model","owned_by":"vendor-a"},
        \\  {"id":"alpha","object":"model"},
        \\  {"id":"beta","object":"model","owned_by":"vendor-b"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.value().data.len);
    try std.testing.expectEqualStrings("alpha", result.value().data[0].id);
    try std.testing.expectEqualStrings("opencode", result.value().data[0].owned_by);
    try std.testing.expectEqualStrings("beta", result.value().data[1].id);
    try std.testing.expectEqualStrings("vendor-b", result.value().data[1].owned_by);
}

test "toSharedModels copies zen models into the shared model list" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data":[
        \\  {"id":"alpha","owned_by":"opencode"},
        \\  {"id":"beta","owned_by":"acme"}
        \\]}
    ;

    const parsed = try std.json.parseFromSlice(ModelsList, allocator, json, .{ .ignore_unknown_fields = true });
    var owned = http_client.Owned(ModelsList){
        .allocator = allocator,
        .body = try allocator.dupe(u8, json),
        .parsed = parsed,
    };

    var shared = try toSharedModels(&owned);
    defer shared.deinit();

    try std.testing.expectEqual(@as(usize, 2), shared.value().models.len);
    try std.testing.expectEqualStrings("alpha", shared.value().models[0].id);
    try std.testing.expectEqualStrings("alpha", shared.value().models[0].display_name);
    try std.testing.expectEqualStrings("opencode", shared.value().models[0].provider);
    try std.testing.expectEqual(@as(i64, 0), shared.value().models[0].context_length);
    try std.testing.expectEqualStrings("beta", shared.value().models[1].id);
    try std.testing.expectEqualStrings("acme", shared.value().models[1].provider);
}

// ── listModels server tests ──────────────────────────────────────────

const ModelsServer = struct {
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

fn startModelsServer(status: std.http.Status, body: []const u8) !*ModelsServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(ModelsServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    ctx.thread = try std.Thread.spawn(.{}, ModelsServer.serve, .{ctx});
    return ctx;
}

fn stopModelsServer(ctx: *ModelsServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn clientForServer(ctx: *ModelsServer, arena: std.mem.Allocator) !http_client.Client {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    var c = http_client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    c.withBaseUrl(url);
    return c;
}

test "listModels fetches and parses the model list" {
    const body =
        \\{"data":[{"id":"big-pickle","object":"model","owned_by":"opencode"}]}
    ;
    const ctx = try startModelsServer(.ok, body);
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    var owned = try listModels(&c);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 1), owned.value().data.len);
    try std.testing.expectEqualStrings("big-pickle", owned.value().data[0].id);
}

test "listModels returns ResponseError on API failure" {
    const ctx = try startModelsServer(.internal_server_error, "nope");
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    try std.testing.expectError(error.ResponseError, listModels(&c));
}

test "listModels returns ResponseParseError on invalid body" {
    const ctx = try startModelsServer(.ok, "not json at all");
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    try std.testing.expectError(error.ResponseParseError, listModels(&c));
}

test "listModels returns ResponseError on unauthorized" {
    const ctx = try startModelsServer(.unauthorized, "{}");
    defer stopModelsServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try clientForServer(ctx, arena);
    defer c.deinit();

    try std.testing.expectError(error.ResponseError, listModels(&c));
}

test "anthropicRequestPayload defaults missing tool description and schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const function = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"name\":\"noop\"}",
        .{},
    );

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{.{ .function = function }},
    };

    const payload = try anthropicRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const tool = parsed.value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("noop", tool.get("name").?.string);
    try std.testing.expectEqualStrings("", tool.get("description").?.string);
    try std.testing.expectEqual(@as(usize, 0), tool.get("input_schema").?.object.count());
}

test "anthropicRequestPayload rejects tools without a name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const function = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"description\":\"no name\"}",
        .{},
    );

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{.{ .function = function }},
    };

    try std.testing.expectError(error.MissingToolName, anthropicRequestPayload(allocator, request));
}

test "anthropicRequestPayload writes empty tool call arguments as empty input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{
            .{ .assistant = .{
                .tool_calls = &.{
                    .{ .id = "call_1", .function = .{ .name = "noop", .arguments = "   " } },
                },
            } },
        },
        .tools = &.{},
    };

    const payload = try anthropicRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const block = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_use", block.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 0), block.get("input").?.object.count());
}

test "anthropicRequestPayload keeps only the first system message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{
            .{ .system = "first system" },
            .{ .system = "second system" },
            .{ .user = "hello" },
        },
        .tools = &.{},
    };

    const payload = try anthropicRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("first system", root.get("system").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("messages").?.array.items.len);
}

test "anthropicRequestPayload honors the stream flag with empty messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .stream = false,
    };

    const payload = try anthropicRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(false, root.get("stream").?.bool);
    try std.testing.expectEqual(@as(usize, 0), root.get("messages").?.array.items.len);
    try std.testing.expect(root.get("system") == null);
    try std.testing.expect(root.get("tools") == null);
}

test "AnthropicSseCallback ignores unknown events and missing fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const block_types = std.ArrayList(BlockType).empty;

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
        .block_types = block_types,
    };

    try sse.event("{\"type\":\"ping\"}");
    try sse.event("{\"type\":\"message_start\"}");
    try sse.event("{\"type\":\"content_block_start\",\"index\":0}");
    try sse.event("{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":5,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{}}");
    try sse.event("{\"type\":\"content_block_delta\",\"index\":0}");
    try sse.event("{\"type\":\"message_delta\"}");

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(@as(i64, 0), events.items[0].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), events.items[0].usage.output_tokens);
}

test "AnthropicSseCallback maps an empty stop reason and missing usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const block_types = std.ArrayList(BlockType).empty;

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
        .block_types = block_types,
    };

    try sse.event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\"}}");

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expect(events.items[0].finish == null);
    try std.testing.expectEqual(@as(i64, 0), events.items[1].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), events.items[1].usage.output_tokens);
}
