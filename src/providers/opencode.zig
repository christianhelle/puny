const std = @import("std");
const cancel = @import("../core/cancel.zig");
const lmstudio = @import("lmstudio.zig");
const openai = @import("openai.zig");

pub const default_base_url = "https://opencode.ai/zen";
pub const anthropic_version = "2023-06-01";
pub const default_max_tokens = 4096;

/// OpenCode Zen serves models over several transports. Puny supports
/// OpenAI-compatible `/v1/chat/completions` and Anthropic `/v1/messages`.
/// This heuristic returns false for model families known to use unsupported
/// transports (/responses, /models/<id>) and true for everything else, so
/// newly-added chat/completions or messages models are accepted automatically.
pub fn isSupportedModel(model_id: []const u8) bool {
    const excluded = [_][]const u8{
        "gpt-",
        "gemini-",
        "qwen",
    };

    for (excluded) |prefix| {
        if (std.mem.startsWith(u8, model_id, prefix)) return false;
    }
    return true;
}

/// Returns true for models served over Anthropic's `/v1/messages` transport.
pub fn isAnthropicModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "claude-");
}

/// Parses the OpenAI-standard `/v1/models` response from OpenCode Zen and
/// converts it into the `ListModelsResponse` shape consumed by the rest of
/// Puny. Models that are not served over `/v1/chat/completions` are filtered
/// out so the picker only shows usable models.
pub fn parseModels(allocator: std.mem.Allocator, response_json: []const u8) !lmstudio.Owned(lmstudio.ListModelsResponse) {
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

    var models = std.array_list.Managed(lmstudio.ModelInfo).init(arena.allocator());

    for (items) |item| {
        const id = if (item.object.get("id")) |v| v.string else continue;
        if (!isSupportedModel(id)) continue;

        const owned_by = if (item.object.get("owned_by")) |v| v.string else "opencode";
        const arena_alloc = arena.allocator();

        try models.append(.{
            .key = try arena_alloc.dupe(u8, id),
            .display_name = try arena_alloc.dupe(u8, id),
            .publisher = try arena_alloc.dupe(u8, owned_by),
            .format = "api",
            .size_bytes = 0,
            .max_context_length = 0,
            .loaded_instances = &.{},
            .type = "llm",
        });
    }

    const result = std.json.Parsed(lmstudio.ListModelsResponse){
        .arena = arena,
        .value = .{ .models = try models.toOwnedSlice() },
    };

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, response_json),
        .parsed = result,
    };
}

pub fn listModelsRaw(client: *lmstudio.Client) !lmstudio.RawResponse {
    const allocator = client.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/v1/models", .{client.base_url});
    return lmstudio.requestRaw(client, std.http.Method.GET, uri_buf.written(), null);
}

fn listModelsResult(client: *lmstudio.Client) !lmstudio.ApiResult(lmstudio.ListModelsResponse) {
    var raw = try listModelsRaw(client);
    if (raw.status.class() != .success) return .{ .api_error = raw };
    const result = parseModels(client.allocator, raw.body) catch |err| {
        return .{ .parse_error = .{ .raw = raw, .error_name = @errorName(err) } };
    };
    raw.deinit();
    return .{ .ok = result };
}

pub fn listModels(client: *lmstudio.Client) !lmstudio.Owned(lmstudio.ListModelsResponse) {
    var result = try listModelsResult(client);
    switch (result) {
        .ok => |ok| return ok,
        .api_error => |*err| {
            if (lmstudio.isAuthFailure(err.status)) lmstudio.printAuthHint(client.io);
            err.deinit();
            return error.ResponseError;
        },
        .parse_error => |*err| {
            err.raw.deinit();
            return error.ResponseParseError;
        },
    }
}

fn newObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

fn newTextBlock(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var obj = try newObject(allocator);
    try obj.put(allocator, "type", .{ .string = "text" });
    try obj.put(allocator, "text", .{ .string = text });
    return .{ .object = obj };
}

fn newToolUseBlock(allocator: std.mem.Allocator, id: []const u8, name: []const u8, input: std.json.Value) !std.json.Value {
    var obj = try newObject(allocator);
    try obj.put(allocator, "type", .{ .string = "tool_use" });
    try obj.put(allocator, "id", .{ .string = id });
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "input", input);
    return .{ .object = obj };
}

fn newToolResultBlock(allocator: std.mem.Allocator, tool_use_id: []const u8, content: []const u8) !std.json.Value {
    var obj = try newObject(allocator);
    try obj.put(allocator, "type", .{ .string = "tool_result" });
    try obj.put(allocator, "tool_use_id", .{ .string = tool_use_id });
    try obj.put(allocator, "content", .{ .string = content });
    return .{ .object = obj };
}

fn parseToolArguments(allocator: std.mem.Allocator, arguments: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return try parsed.value.clone(allocator);
}

fn anthropicTool(allocator: std.mem.Allocator, tool: openai.ToolDefinition) !std.json.Value {
    var obj = try newObject(allocator);

    const function = tool.function.object;
    const name = if (function.get("name")) |v| v.string else return error.MissingToolName;
    const description = if (function.get("description")) |v| v.string else "";
    const parameters = function.get("parameters") orelse .{ .object = try newObject(allocator) };

    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "description", .{ .string = description });
    try obj.put(allocator, "input_schema", parameters);
    return .{ .object = obj };
}

fn anthropicMessage(allocator: std.mem.Allocator, msg: openai.Message) !std.json.Value {
    var obj = try newObject(allocator);

    switch (msg) {
        .system => unreachable, // handled separately
        .user => |content| {
            try obj.put(allocator, "role", .{ .string = "user" });
            var arr = try std.json.Array.initCapacity(allocator, 1);
            try arr.append(try newTextBlock(allocator, content));
            try obj.put(allocator, "content", .{ .array = arr });
        },
        .assistant => |assistant| {
            try obj.put(allocator, "role", .{ .string = "assistant" });
            var content_blocks = try std.json.Array.initCapacity(allocator, 2);
            if (assistant.content) |content| {
                try content_blocks.append(try newTextBlock(allocator, content));
            }
            if (assistant.tool_calls) |tool_calls| {
                for (tool_calls) |tc| {
                    const input = try parseToolArguments(allocator, tc.function.arguments);
                    try content_blocks.append(try newToolUseBlock(allocator, tc.id, tc.function.name, input));
                }
            }
            try obj.put(allocator, "content", .{ .array = content_blocks });
        },
        .tool => |tool| {
            try obj.put(allocator, "role", .{ .string = "user" });
            var arr = try std.json.Array.initCapacity(allocator, 1);
            try arr.append(try newToolResultBlock(allocator, tool.tool_call_id, tool.content));
            try obj.put(allocator, "content", .{ .array = arr });
        },
    }

    return .{ .object = obj };
}

const BlockType = enum {
    text,
    tool_use,
};

const AnthropicSseCallback = struct {
    allocator: std.mem.Allocator,
    callback: openai.StreamCallback,
    block_types: std.ArrayList(BlockType),
    input_tokens: i64 = 0,

    pub fn event(self: *@This(), data: []const u8) !void {
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
                try self.block_types.append(.text);
            }

            if (std.mem.eql(u8, block_type, "tool_use")) {
                self.block_types.items[index] = .tool_use;
                const id = if (content_block.object.get("id")) |v| v.string else "";
                const name = if (content_block.object.get("name")) |v| v.string else "";
                if (id.len > 0 and name.len > 0) {
                    try self.callback.emit(.{ .tool_call_start = .{ .index = index, .id = id, .name = name } });
                }
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

/// Streams a chat completion from Anthropic's `/v1/messages` endpoint and
/// emits the same `openai.StreamEvent` shapes consumed by the rest of Puny.
pub fn chatStreamingAnthropic(client: *lmstudio.Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
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

    const uri = try std.Uri.parse(url);
    var req = try client.http.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers.items,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    var cancelable_reader_buffer: [1]u8 = undefined;
    var cancelable_reader = openai.CancelableReader.init(response_reader, &cancelable_reader_buffer);
    const reader = &cancelable_reader.reader;

    if (response.head.status.class() != .success) {
        var body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer body_alloc.deinit();
        _ = reader.streamRemaining(&body_alloc.writer) catch {};

        if (response.head.status == .unauthorized or response.head.status == .forbidden) {
            lmstudio.printAuthHint(client.io);
        }

        std.debug.print("Anthropic chat request failed\n  URL: {s}\n  Status: {d}\n  Payload: {s}\n  Response: {s}\n", .{
            url,
            @intFromEnum(response.head.status),
            payload,
            body_alloc.written(),
        });
        return error.ResponseError;
    }

    var block_types = std.ArrayList(BlockType).init(allocator);
    defer block_types.deinit();

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
        .block_types = block_types,
    };

    lmstudio.parseSseReader(allocator, reader, &sse) catch |err| switch (err) {
        error.ReadFailed => {
            if (cancel.isCancelled()) return error.Canceled;
            return err;
        },
        else => return err,
    };
}

/// Builds an Anthropic `/v1/messages` request payload from an OpenAI-style
/// chat request. The first system message is extracted to the top-level
/// `system` field; any additional system messages are ignored.
pub fn anthropicRequestPayload(allocator: std.mem.Allocator, request: openai.ChatRequest) ![]u8 {
    var messages = try std.json.Array.initCapacity(allocator, request.messages.len);
    var system: ?[]const u8 = null;
    for (request.messages) |msg| {
        switch (msg) {
            .system => |content| {
                if (system == null) system = content;
            },
            else => try messages.append(try anthropicMessage(allocator, msg)),
        }
    }

    var tools: ?std.json.Array = null;
    if (request.tools.len > 0) {
        tools = try std.json.Array.initCapacity(allocator, request.tools.len);
        for (request.tools) |tool| {
            try tools.?.append(try anthropicTool(allocator, tool));
        }
    }

    var body_obj = try newObject(allocator);
    try body_obj.put(allocator, "model", .{ .string = request.model });
    try body_obj.put(allocator, "messages", .{ .array = messages });
    try body_obj.put(allocator, "max_tokens", .{ .integer = default_max_tokens });
    try body_obj.put(allocator, "stream", .{ .bool = request.stream });

    if (system) |value| {
        try body_obj.put(allocator, "system", .{ .string = value });
    }
    if (tools) |value| {
        try body_obj.put(allocator, "tools", .{ .array = value });
    }
    if (request.temperature) |temperature| {
        try body_obj.put(allocator, "temperature", .{ .float = temperature });
    }

    var str: std.Io.Writer.Allocating = .init(allocator);
    defer str.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = body_obj }, .{ .emit_null_optional_fields = false }, &str.writer);
    return str.toOwnedSlice();
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
}

test "isSupportedModel rejects unsupported model families" {
    try std.testing.expect(!isSupportedModel("gpt-5.5"));
    try std.testing.expect(!isSupportedModel("gpt-5.3-codex"));
    try std.testing.expect(!isSupportedModel("gemini-3.5-flash"));
    try std.testing.expect(!isSupportedModel("gemini-3.1-pro"));
    try std.testing.expect(!isSupportedModel("qwen3.7-max"));
    try std.testing.expect(!isSupportedModel("qwen3.5-plus"));
}

test "isAnthropicModel detects claude families" {
    try std.testing.expect(isAnthropicModel("claude-opus-4-8"));
    try std.testing.expect(isAnthropicModel("claude-sonnet-4.6"));
    try std.testing.expect(isAnthropicModel("claude-haiku-4.5"));
    try std.testing.expect(!isAnthropicModel("deepseek-v4-pro"));
    try std.testing.expect(!isAnthropicModel("kimi-k2.7-code"));
}

test "parseModels maps and filters OpenAI model list" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"deepseek-v4-pro","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"gpt-5.5","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"kimi-k2.7-code","object":"model","created":1784147408,"owned_by":"opencode"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.value().models.len);
    try std.testing.expectEqualStrings("deepseek-v4-pro", result.value().models[0].key);
    try std.testing.expectEqualStrings("deepseek-v4-pro", result.value().models[0].display_name);
    try std.testing.expectEqualStrings("opencode", result.value().models[0].publisher);
    try std.testing.expectEqualStrings("kimi-k2.7-code", result.value().models[1].key);
}

test "parseModels returns empty list when no compatible models" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"gpt-5.5","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"gemini-3.5-flash","object":"model","created":1784147408,"owned_by":"opencode"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.value().models.len);
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

    try std.testing.expectEqual(@as(usize, 1), result.value().models.len);
    try std.testing.expectEqualStrings("big-pickle", result.value().models[0].key);
}
