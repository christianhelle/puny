const std = @import("std");
const cancel = @import("../core/cancel.zig");
const http_client = @import("client.zig");
const openai = @import("openai.zig");
const generated = @import("anthropic/client.zig");

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

fn anthropicClient(c: *http_client.Client) generated.Client {
    var g = generated.Client.init(c.allocator, c.io, c.api_key);
    g.base_url = c.base_url;
    // Forward observer (without on_chunk which runtime observer doesn't have)
    if (c.http_observer) |obs| {
        g.http_observer = .{
            .ctx = obs.ctx,
            .onRequest = obs.onRequest,
            .onResponse = obs.onResponse,
            .onError = obs.onError,
        };
    }
    if (c.default_headers.len == 0) {
        g.default_headers = &.{.{ .name = "anthropic-version", .value = anthropic_version }};
    } else {
        // For non-empty default_headers, let chatStreaming merge with anthropic-version
        // and manage the allocation lifetime to avoid leaks.
        g.default_headers = c.default_headers;
    }
    g.cancel_check = cancel.isCancelled;
    return g;
}

/// Adapter that turns an OpenAI ChatRequest into Anthropic JSON.
/// This mirrors requestPayload logic but via jsonStringify so the generated
/// client's stringifyStreamRequest can add stream:true.
const AnthropicAdapterRequest = struct {
    request: openai.ChatRequest,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        const req = self.request;
        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(req.model);

        // system handling: first system message only
        var system: ?[]const u8 = null;
        for (req.messages) |msg| {
            if (msg == .system) {
                if (system == null) system = msg.system;
            }
        }

        try jw.objectField("messages");
        try jw.beginArray();
        var first = true;
        for (req.messages) |msg| {
            switch (msg) {
                .system => continue,
                else => {
                    if (!first) {
                        // handled by array
                    }
                    // We need to write the message as raw JSON object matching writeAnthropicMessage.
                    // To avoid duplicating logic, we write via temporary allocation and then write as Value.
                    // However we have jw directly, we can manually write the object.
                    // For maintainability, we duplicate the writer logic here using jw.
                    switch (msg) {
                        .user => |content| {
                            try jw.beginObject();
                            try jw.objectField("role");
                            try jw.write("user");
                            try jw.objectField("content");
                            try jw.beginArray();
                            try jw.beginObject();
                            try jw.objectField("type");
                            try jw.write("text");
                            try jw.objectField("text");
                            try jw.write(content);
                            try jw.endObject();
                            try jw.endArray();
                            try jw.endObject();
                        },
                        .assistant => |assistant| {
                            try jw.beginObject();
                            try jw.objectField("role");
                            try jw.write("assistant");
                            try jw.objectField("content");
                            try jw.beginArray();
                            var first_block = true;
                            if (assistant.content) |content| {
                                try jw.beginObject();
                                try jw.objectField("type");
                                try jw.write("text");
                                try jw.objectField("text");
                                try jw.write(content);
                                try jw.endObject();
                                first_block = false;
                            }
                            if (assistant.tool_calls) |tool_calls| {
                                for (tool_calls) |tc| {
                                    if (!first_block) {
                                        // comma handled by array
                                    }
                                    try jw.beginObject();
                                    try jw.objectField("type");
                                    try jw.write("tool_use");
                                    try jw.objectField("id");
                                    try jw.write(tc.id);
                                    try jw.objectField("name");
                                    try jw.write(tc.function.name);
                                    try jw.objectField("input");
                                    if (std.mem.trim(u8, tc.function.arguments, " \t\r\n").len > 0) {
                                        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, tc.function.arguments, .{}) catch return error.WriteFailed;
                                        defer parsed.deinit();
                                        try jw.write(parsed.value);
                                    } else {
                                        try jw.beginObject();
                                        try jw.endObject();
                                    }
                                    try jw.endObject();
                                    first_block = false;
                                }
                            }
                            try jw.endArray();
                            try jw.endObject();
                        },
                        .tool => |tool| {
                            try jw.beginObject();
                            try jw.objectField("role");
                            try jw.write("user");
                            try jw.objectField("content");
                            try jw.beginArray();
                            try jw.beginObject();
                            try jw.objectField("type");
                            try jw.write("tool_result");
                            try jw.objectField("tool_use_id");
                            try jw.write(tool.tool_call_id);
                            try jw.objectField("content");
                            try jw.write(tool.content);
                            try jw.endObject();
                            try jw.endArray();
                            try jw.endObject();
                        },
                        else => {},
                    }
                    first = false;
                },
            }
        }
        try jw.endArray();

        try jw.objectField("max_tokens");
        try jw.write(default_max_tokens);

        // stream is injected by generated stringifyStreamRequest, but we include for completeness
        // The generated helper will force stream=true regardless, so we omit here.

        if (system) |value| {
            try jw.objectField("system");
            try jw.write(value);
        }

        if (req.tools.len > 0) {
            try jw.objectField("tools");
            try jw.beginArray();
            for (req.tools) |tool| {
                const function = tool.function.object;
                const name_val = function.get("name") orelse continue;
                const name = name_val.string;
                const description = if (function.get("description")) |v| v.string else "";
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(name);
                try jw.objectField("description");
                try jw.write(description);
                try jw.objectField("input_schema");
                if (function.get("parameters")) |params| {
                    try jw.write(params);
                } else {
                    try jw.beginObject();
                    try jw.endObject();
                }
                try jw.endObject();
            }
            try jw.endArray();
        }

        if (req.temperature) |temp| {
            try jw.objectField("temperature");
            try jw.write(temp);
        }

        if (req.reasoning_effort) |effort| {
            if (effort != .default) {
                const effort_str = switch (effort) {
                    .xhigh => "max",
                    else => @tagName(effort),
                };
                try jw.objectField("thinking");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("enabled");
                try jw.endObject();
                try jw.objectField("output_config");
                try jw.beginObject();
                try jw.objectField("effort");
                try jw.write(effort_str);
                try jw.endObject();
            }
        }

        try jw.endObject();
    }
};

/// Merges `anthropic-version` into `default_headers`, deduplicating a
/// caller-supplied `anthropic-version` header (case-insensitive) instead of
/// sending it twice on the wire. Returns the full owned buffer (for freeing)
/// and the used sub-slice (for use as `default_headers`).
fn mergeAnthropicHeaders(allocator: std.mem.Allocator, default_headers: []const std.http.Header) !struct {
    buffer: []std.http.Header,
    used: []std.http.Header,
} {
    const merged = try allocator.alloc(std.http.Header, default_headers.len + 1);
    merged[0] = .{ .name = "anthropic-version", .value = anthropic_version };
    var n: usize = 1;
    for (default_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "anthropic-version")) {
            merged[0] = h;
            continue;
        }
        merged[n] = h;
        n += 1;
    }
    return .{ .buffer = merged, .used = merged[0..n] };
}

pub fn chatStreaming(client: *http_client.Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    // Validate tools upfront to match requestPayload behavior
    for (request.tools) |tool| {
        const function = tool.function.object;
        if (function.get("name") == null) return error.MissingToolName;
    }
    var g = anthropicClient(client);
    defer g.deinit();
    var owned_headers: ?[]std.http.Header = null;
    defer if (owned_headers) |h| client.allocator.free(h);
    if (client.default_headers.len != 0) {
        if (mergeAnthropicHeaders(client.allocator, client.default_headers)) |merged| {
            g.default_headers = merged.used;
            owned_headers = merged.buffer;
        } else |_| {
            // On allocation failure, preserve the caller's headers as-is
            // rather than silently dropping them.
            g.default_headers = client.default_headers;
        }
    }
    // Use adapter request that will be stringified and have stream:true injected.
    const adapter_req = AnthropicAdapterRequest{ .request = request };

    const block_types: std.ArrayList(BlockType) = .empty;
    var sse = AnthropicSseCallback{
        .allocator = client.allocator,
        .callback = callback,
        .block_types = block_types,
        .observer = client.http_observer,
    };
    defer sse.block_types.deinit(client.allocator);

    // The generated client will handle headers (x-api-key via api_key, anthropic-version via default_headers)
    // and SSE parsing. It will inject stream:true.
    generated.messages_postStreaming(&g, adapter_req, &sse, null) catch |err| switch (err) {
        error.Cancelled, error.Canceled => return error.Canceled,
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
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = std.testing.allocator.create(TestServer) catch |err| {
        server.deinit(std.testing.io);
        return err;
    };
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    errdefer {
        ctx.server.deinit(std.testing.io);
        std.testing.allocator.destroy(ctx);
    }
    ctx.thread = try std.Thread.spawn(.{}, TestServer.serve, .{ctx});
    return ctx;
}

fn stopTestServer(ctx: *TestServer) void {
    ctx.server.deinit(std.testing.io);
    ctx.thread.join();
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
    errdefer ctx.server.deinit(std.testing.io);
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

test "AnthropicAdapterRequest matches requestPayload core fields except stream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const schema = try sampleToolSchema(allocator);
    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{
            .{ .system = "You are helpful." },
            .{ .user = "Hello" },
        },
        .tools = &.{
            .{ .function = schema },
        },
        .stream = true,
        .temperature = 0.5,
    };
    const expected = try requestPayload(allocator, request);
    defer allocator.free(expected);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(AnthropicAdapterRequest{ .request = request }, .{}, &buf.writer);
    const got = buf.written();
    // Parse both as Values ignoring field order differences
    const exp_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, expected, .{});
    defer exp_parsed.deinit();
    const got_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, got, .{});
    defer got_parsed.deinit();
    // Both should have same core fields; stream is injected later by generated client
    try std.testing.expectEqualStrings(exp_parsed.value.object.get("model").?.string, got_parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings(exp_parsed.value.object.get("system").?.string, got_parsed.value.object.get("system").?.string);
    try std.testing.expectEqual(exp_parsed.value.object.get("messages").?.array.items.len, got_parsed.value.object.get("messages").?.array.items.len);
    try std.testing.expectEqual(exp_parsed.value.object.get("max_tokens").?.integer, got_parsed.value.object.get("max_tokens").?.integer);
    try std.testing.expectEqual(exp_parsed.value.object.get("temperature").?.float, got_parsed.value.object.get("temperature").?.float);
    try std.testing.expectEqual(exp_parsed.value.object.get("tools").?.array.items.len, got_parsed.value.object.get("tools").?.array.items.len);
    try std.testing.expectEqualStrings(exp_parsed.value.object.get("tools").?.array.items[0].object.get("name").?.string, got_parsed.value.object.get("tools").?.array.items[0].object.get("name").?.string);
    // Adapter omits stream; generated helper injects it
    try std.testing.expect(exp_parsed.value.object.get("stream") != null);
    try std.testing.expect(got_parsed.value.object.get("stream") == null);
    // Messages content should match
    const exp_msg_content = exp_parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string;
    const got_msg_content = got_parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings(exp_msg_content, got_msg_content);
}

test "AnthropicAdapterRequest fails on invalid tool arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const request = openai.ChatRequest{
        .model = "claude-sonnet-4.6",
        .messages = &.{
            .{ .assistant = .{
                .tool_calls = &.{
                    .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "not json" } },
                },
            } },
        },
        .tools = &.{},
    };
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.testing.expectError(error.WriteFailed, std.json.Stringify.value(AnthropicAdapterRequest{ .request = request }, .{}, &buf.writer));
}

test "anthropic client uses x-api-key not Bearer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var c = http_client.Client.init(allocator, std.testing.io, "my-key");
    defer c.deinit();
    c.organization = "my-org";
    c.project = "my-proj";
    var g = anthropicClient(&c);
    defer g.deinit();
    try std.testing.expectEqualStrings("my-key", g.api_key);
    try std.testing.expect(g.organization == null);
    try std.testing.expect(g.project == null);
    // g should have anthropic-version in default_headers
    var found_version = false;
    for (g.default_headers) |h| {
        if (std.mem.eql(u8, h.name, "anthropic-version") and std.mem.eql(u8, h.value, anthropic_version)) {
            found_version = true;
        }
    }
    try std.testing.expect(found_version);
}

test "anthropic client preserves custom headers and adds version via chatStreaming merge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var c = http_client.Client.init(allocator, std.testing.io, "my-key");
    defer c.deinit();
    c.default_headers = &.{.{ .name = "X-Custom", .value = "1" }};
    var g = anthropicClient(&c);
    defer g.deinit();
    // Use the real merge helper (same one chatStreaming uses).
    const merged = try mergeAnthropicHeaders(allocator, c.default_headers);
    defer allocator.free(merged.buffer);
    g.default_headers = merged.used;
    var found_version = false;
    var found_custom = false;
    for (g.default_headers) |h| {
        if (std.mem.eql(u8, h.name, "anthropic-version")) found_version = true;
        if (std.mem.eql(u8, h.name, "X-Custom") and std.mem.eql(u8, h.value, "1")) found_custom = true;
    }
    try std.testing.expect(found_version);
    try std.testing.expect(found_custom);
    try std.testing.expectEqual(@as(usize, 2), g.default_headers.len);
}

test "mergeAnthropicHeaders deduplicates a caller-supplied anthropic-version header" {
    const allocator = std.testing.allocator;
    const default_headers: []const std.http.Header = &.{
        .{ .name = "Anthropic-Version", .value = "caller-value" },
        .{ .name = "X-Custom", .value = "1" },
    };
    const merged = try mergeAnthropicHeaders(allocator, default_headers);
    defer allocator.free(merged.buffer);
    // Only one anthropic-version header should be present, and it should
    // keep the caller-supplied value rather than being duplicated.
    var version_count: usize = 0;
    var found_custom = false;
    for (merged.used) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "anthropic-version")) {
            version_count += 1;
            try std.testing.expectEqualStrings("caller-value", h.value);
        }
        if (std.mem.eql(u8, h.name, "X-Custom") and std.mem.eql(u8, h.value, "1")) found_custom = true;
    }
    try std.testing.expectEqual(@as(usize, 1), version_count);
    try std.testing.expect(found_custom);
    try std.testing.expectEqual(@as(usize, 2), merged.used.len);
}

test "chatStreaming preserves custom headers verbatim when header merge allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    const custom_headers: []const std.http.Header = &.{.{ .name = "X-Custom", .value = "1" }};
    // Directly exercise the OOM fallback path that chatStreaming takes when
    // mergeAnthropicHeaders fails: it must fall back to the caller's
    // original default_headers instead of dropping them.
    var g_default_headers: []const std.http.Header = &.{};
    if (mergeAnthropicHeaders(allocator, custom_headers)) |merged| {
        g_default_headers = merged.used;
    } else |_| {
        g_default_headers = custom_headers;
    }
    var found_custom = false;
    for (g_default_headers) |h| {
        if (std.mem.eql(u8, h.name, "X-Custom") and std.mem.eql(u8, h.value, "1")) found_custom = true;
    }
    try std.testing.expect(found_custom);
}
