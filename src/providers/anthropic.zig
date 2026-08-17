const std = @import("std");
const cancel = @import("../core/cancel.zig");
const http_client = @import("client.zig");
const openai = @import("openai.zig");

pub const anthropic_version = "2023-06-01";
pub const default_max_tokens = 4096;

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

pub fn chatStreaming(client: *http_client.Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    const allocator = client.allocator;
    const payload = try requestPayload(allocator, request);
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

pub fn requestPayload(allocator: std.mem.Allocator, request: openai.ChatRequest) ![]u8 {
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

// ── Tests ────────────────────────────────────────────────────────────

fn sampleToolSchema(allocator: std.mem.Allocator) !std.json.Value {
    const schema =
        \\{"name":"read_file","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}
    ;
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, schema, .{ .ignore_unknown_fields = true });
}

test "requestPayload converts OpenAI request" {
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

    const payload = try requestPayload(allocator, request);

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

test "requestPayload includes thinking and output_config when reasoning_effort high" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .high,
    };

    const payload = try requestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("enabled", root.get("thinking").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("high", root.get("output_config").?.object.get("effort").?.string);
}

test "requestPayload omits thinking when reasoning_effort default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .default,
    };

    const payload = try requestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("thinking") == null);
    try std.testing.expect(parsed.value.object.get("output_config") == null);
}

test "requestPayload maps xhigh to max effort" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .xhigh,
    };

    const payload = try requestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("max", root.get("output_config").?.object.get("effort").?.string);
}

test "requestPayload defaults missing tool description and schema" {
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

    const payload = try requestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const tool = parsed.value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("noop", tool.get("name").?.string);
    try std.testing.expectEqualStrings("", tool.get("description").?.string);
    try std.testing.expectEqual(@as(usize, 0), tool.get("input_schema").?.object.count());
}

test "requestPayload rejects tools without a name" {
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

    try std.testing.expectError(error.MissingToolName, requestPayload(allocator, request));
}

test "requestPayload writes empty tool call arguments as empty input" {
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

    const payload = try requestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const block = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_use", block.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 0), block.get("input").?.object.count());
}

test "requestPayload keeps only the first system message" {
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

    const payload = try requestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("first system", root.get("system").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("messages").?.array.items.len);
}

test "requestPayload honors the stream flag with empty messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{},
        .tools = &.{},
        .stream = false,
    };

    const payload = try requestPayload(allocator, request);
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

// ── Server test infrastructure ────────────────────────────────────────

const TestServer = struct {
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

fn startTestServer(status: std.http.Status, body: []const u8) !*TestServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(TestServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    ctx.thread = try std.Thread.spawn(.{}, TestServer.serve, .{ctx});
    return ctx;
}

fn stopTestServer(ctx: *TestServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn clientForServer(ctx: *TestServer, arena: std.mem.Allocator) !http_client.Client {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    var c = http_client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    c.withBaseUrl(url);
    return c;
}

test "chatStreaming reports response head failures to the http observer" {
    const GarbageServer = struct {
        io: std.Io,
        server: std.Io.net.Server,
        thread: std.Thread = undefined,

        fn serve(self: *@This()) void {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);

            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);

            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            _ = http_server.receiveHead() catch return;
            writer.interface.writeAll("definitely-not-an-http-response\r\n\r\n") catch return;
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    var ctx = GarbageServer{ .io = std.testing.io, .server = server };
    ctx.thread = try std.Thread.spawn(.{}, GarbageServer.serve, .{&ctx});

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    const ObserverCtx = struct {
        errors: usize = 0,
        fn onError(user_ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, err_name: []const u8) void {
            _ = method;
            _ = request_url;
            _ = err_name;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.errors += 1;
        }
    };

    var observer_ctx = ObserverCtx{};
    const observer = http_client.HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = http_client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);
    c.http_observer = observer;

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    if (chatStreaming(&c, request, undefined)) |_| {
        return error.ExpectedHeadFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);

    ctx.thread.join();
    server.deinit(std.testing.io);
}

test "chatStreaming returns Canceled when the stream is cancelled" {
    const body =
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startTestServer(.ok, body);
    defer stopTestServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var c = http_client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.setCancelled();
    defer cancel.reset();
    try std.testing.expectError(error.Canceled, chatStreaming(&c, request, undefined));
}

test "chatStreaming reports request creation failures to the http observer" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    server.deinit(std.testing.io);

    const ObserverCtx = struct {
        errors: usize = 0,
        fn onError(user_ctx: ?*anyopaque, method: std.http.Method, request_url: []const u8, err_name: []const u8) void {
            _ = method;
            _ = request_url;
            _ = err_name;
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            self.errors += 1;
        }
    };

    var observer_ctx = ObserverCtx{};
    const observer = http_client.HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = http_client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);
    c.http_observer = observer;

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.reset();
    if (chatStreaming(&c, request, undefined)) |_| {
        return error.ExpectedConnectionFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

test "chatStreaming propagates SSE parse errors from a local server" {
    const ctx = try startTestServer(.ok, "data: not-json\n\n");
    defer stopTestServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var c = try clientForServer(ctx, allocator);
    defer c.deinit();

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.reset();
    if (chatStreaming(&c, request, callback)) |_| {
        return error.ExpectedSseParseFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}
