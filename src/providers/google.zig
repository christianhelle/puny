const std = @import("std");
const cancel = @import("../core/cancel.zig");
const http_client = @import("client.zig");
const openai = @import("openai.zig");
const opencode_zen = @import("opencode_zen.zig");

pub fn isGoogleModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "gemini-");
}

fn newObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

fn writeGoogleTextPart(writer: anytype, text: []const u8) !void {
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte('}');
}

fn writeGoogleFunctionCallPart(writer: anytype, name: []const u8, arguments: []const u8) !void {
    try writer.writeAll("{\"functionCall\":{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"args\":");
    if (std.mem.trim(u8, arguments, " \t\r\n").len > 0) {
        try writer.writeAll(arguments);
    } else {
        try writer.writeAll("{}");
    }
    try writer.writeAll("}}");
}

fn writeGoogleFunctionDeclaration(writer: anytype, tool: openai.ToolDefinition) !void {
    const function = tool.function.object;
    const name = if (function.get("name")) |v| v.string else return error.MissingToolName;
    const description = if (function.get("description")) |v| v.string else "";

    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"parameters\":");
    if (function.get("parameters")) |params| {
        try std.json.Stringify.value(params, .{}, writer);
    } else {
        try writer.writeAll("{}");
    }
    try writer.writeByte('}');
}

fn googleToolNameForId(messages: []const openai.Message, tool_call_id: []const u8, before_index: usize) []const u8 {
    var idx = @min(before_index, messages.len);
    while (idx > 0) : (idx -= 1) {
        const msg = messages[idx - 1];
        switch (msg) {
            .assistant => |assistant| {
                if (assistant.tool_calls) |tool_calls| {
                    for (tool_calls) |tc| {
                        if (std.mem.eql(u8, tc.id, tool_call_id)) return tc.function.name;
                    }
                }
            },
            else => {},
        }
    }
    return tool_call_id;
}

pub fn googleRequestPayload(allocator: std.mem.Allocator, request: openai.ChatRequest) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    var system: ?[]const u8 = null;

    try w.writeAll("{\"contents\":[");

    var i: usize = 0;
    var first_content = true;
    while (i < request.messages.len) {
        switch (request.messages[i]) {
            .system => |content| {
                if (system == null) system = content;
                i += 1;
            },
            .user => |content| {
                if (!first_content) try w.writeByte(',');
                try w.writeAll("{\"role\":\"user\",\"parts\":[");
                try writeGoogleTextPart(w, content);
                try w.writeAll("]}");
                first_content = false;
                i += 1;
            },
            .assistant => |assistant| {
                if (!first_content) try w.writeByte(',');
                try w.writeAll("{\"role\":\"model\",\"parts\":[");
                var first_part = true;
                if (assistant.content) |content| {
                    try writeGoogleTextPart(w, content);
                    first_part = false;
                }
                if (assistant.tool_calls) |tool_calls| {
                    for (tool_calls) |tc| {
                        if (!first_part) try w.writeByte(',');
                        try writeGoogleFunctionCallPart(w, tc.function.name, tc.function.arguments);
                        first_part = false;
                    }
                }
                try w.writeAll("]}");
                first_content = false;
                i += 1;
            },
            .tool => {
                if (!first_content) try w.writeByte(',');
                try w.writeAll("{\"role\":\"user\",\"parts\":[");
                var first_part = true;
                while (i < request.messages.len and std.meta.activeTag(request.messages[i]) == .tool) {
                    const tool = request.messages[i].tool;
                    const name = googleToolNameForId(request.messages, tool.tool_call_id, i);
                    if (!first_part) try w.writeByte(',');
                    var prefix_buf: [256]u8 = undefined;
                    const prefix = try std.fmt.bufPrint(&prefix_buf, "Tool {s} result:", .{name});
                    try writeGoogleTextPart(w, prefix);
                    try w.writeByte(',');
                    try writeGoogleTextPart(w, tool.content);
                    first_part = false;
                    i += 1;
                }
                try w.writeAll("]}");
                first_content = false;
            },
        }
    }
    try w.writeByte(']');

    if (system) |value| {
        try w.writeAll(",\"systemInstruction\":{\"parts\":[");
        try writeGoogleTextPart(w, value);
        try w.writeAll("]}");
    }

    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[{\"functionDeclarations\":[");
        for (request.tools, 0..) |tool, j| {
            if (j > 0) try w.writeByte(',');
            try writeGoogleFunctionDeclaration(w, tool);
        }
        try w.writeAll("]}]");
    }

    try w.writeAll(",\"generationConfig\":{\"maxOutputTokens\":");
    try std.json.Stringify.value(opencode_zen.default_max_tokens, .{}, w);
    if (request.temperature) |temp| {
        try w.writeAll(",\"temperature\":");
        try std.json.Stringify.value(temp, .{}, w);
    }
    if (request.reasoning_effort) |effort| {
        if (effort != .default) {
            try w.writeAll(",\"thinkingConfig\":{\"includeThoughts\":true}");
        }
    }
    try w.writeByte('}');

    try w.writeByte('}');

    return buf.toOwnedSlice();
}

const GoogleSseCallback = struct {
    allocator: std.mem.Allocator,
    callback: openai.StreamCallback,
    tool_call_index: usize = 0,
    input_tokens: i64 = 0,
    observer: ?http_client.HttpObserver = null,

    pub fn event(self: *@This(), data: []const u8) !void {
        if (self.observer) |obs| {
            if (obs.on_chunk) |cb| cb(obs.ctx, data);
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const root = parsed.value.object;

        if (root.get("candidates")) |candidates| {
            if (candidates == .array) {
                for (candidates.array.items) |candidate| {
                    if (candidate != .object) continue;
                    try self.handleCandidate(candidate.object);
                }
            }
        }

        if (root.get("usageMetadata")) |usage| {
            if (usage == .object) {
                if (usage.object.get("promptTokenCount")) |v| {
                    if (v == .integer) self.input_tokens = v.integer;
                }
                var output_tokens: i64 = 0;
                if (usage.object.get("candidatesTokenCount")) |v| {
                    if (v == .integer) output_tokens = v.integer;
                }
                try self.callback.emit(.{ .usage = .{
                    .input_tokens = self.input_tokens,
                    .output_tokens = output_tokens,
                } });
            }
        }
    }

    fn handleCandidate(self: *@This(), candidate: std.json.ObjectMap) !void {
        if (candidate.get("content")) |content| {
            if (content == .object) {
                if (content.object.get("parts")) |parts| {
                    if (parts == .array) {
                        for (parts.array.items) |part| {
                            if (part != .object) continue;
                            try self.handlePart(part.object);
                        }
                    }
                }
            }
        }

        if (candidate.get("finishReason")) |reason| {
            if (reason == .string) {
                try self.callback.emit(.{ .finish = if (reason.string.len == 0) null else reason.string });
            }
        }
    }

    fn handlePart(self: *@This(), part: std.json.ObjectMap) !void {
        if (part.get("thought")) |thought| {
            if (thought == .bool and thought.bool) {
                if (part.get("text")) |text| {
                    if (text == .string) {
                        try self.callback.emit(.{ .reasoning = text.string });
                    }
                }
                return;
            }
        }

        if (part.get("text")) |text| {
            if (text == .string) {
                try self.callback.emit(.{ .content = text.string });
            }
            return;
        }

        if (part.get("functionCall")) |function_call| {
            if (function_call != .object) return;
            const name = if (function_call.object.get("name")) |v|
                (if (v == .string) v.string else return)
            else
                return;

            const index = self.tool_call_index;
            self.tool_call_index += 1;

            var id_buf: [32]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buf, "call_{d}", .{index}) catch return;
            try self.callback.emit(.{ .tool_call_start = .{ .index = index, .id = id, .name = name } });

            const args = function_call.object.get("args") orelse std.json.Value{ .object = try newObject(self.allocator) };
            var args_str: std.Io.Writer.Allocating = .init(self.allocator);
            defer args_str.deinit();
            try std.json.Stringify.value(args, .{ .emit_null_optional_fields = false }, &args_str.writer);
            try self.callback.emit(.{ .tool_call_delta = .{ .index = index, .arguments = args_str.written() } });
        }
    }
};

pub fn chatStreamingGoogle(client: *http_client.Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    const allocator = client.allocator;
    const payload = try googleRequestPayload(allocator, request);
    defer allocator.free(payload);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/models/{s}:streamGenerateContent?alt=sse", .{ client.base_url, request.model });
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "x-goog-api-key", .value = client.api_key });
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

        std.debug.print("Google chat request failed\n  URL: {s}\n  Status: {d}\n  Payload: {s}\n  Response: {s}\n", .{
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

    var sse = GoogleSseCallback{
        .allocator = allocator,
        .callback = callback,
        .observer = client.http_observer,
    };

    http_client.parseSseReader(allocator, reader, &sse, null) catch |err| switch (err) {
        error.ReadFailed => {
            if (cancel.isCancelled()) return error.Canceled;
            return err;
        },
        else => return err,
    };
}

test "isGoogleModel detects gemini families" {
    try std.testing.expect(isGoogleModel("gemini-3.5-flash"));
    try std.testing.expect(isGoogleModel("gemini-3.1-pro"));
    try std.testing.expect(isGoogleModel("gemini-3-flash"));
    try std.testing.expect(!isGoogleModel("claude-opus-4-8"));
    try std.testing.expect(!isGoogleModel("deepseek-v4-pro"));
    try std.testing.expect(!isGoogleModel("gpt-5.5"));
}

fn sampleToolSchema(allocator: std.mem.Allocator) !std.json.Value {
    const schema =
        \\{"name":"read_file","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}
    ;
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, schema, .{ .ignore_unknown_fields = true });
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

test "googleRequestPayload converts OpenAI request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const schema = try sampleToolSchema(allocator);

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{
            .{ .system = "You are helpful." },
            .{ .user = "Hello" },
            .{ .assistant = .{ .content = "Hi" } },
            .{ .assistant = .{
                .tool_calls = &.{
                    .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\":\"src/main.zig\"}" } },
                    .{ .id = "call_2", .function = .{ .name = "grep_search", .arguments = "{\"pattern\":\"foo\"}" } },
                },
            } },
            .{ .tool = .{ .tool_call_id = "call_1", .content = "file contents" } },
            .{ .tool = .{ .tool_call_id = "call_2", .content = "match found" } },
        },
        .tools = &.{
            .{ .function = schema },
        },
        .stream = true,
        .temperature = 0.5,
    };

    const payload = try googleRequestPayload(allocator, request);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const obj = parsed.value.object;

    // The model is carried in the URL, not the request body.
    try std.testing.expect(obj.get("model") == null);

    const system_parts = obj.get("systemInstruction").?.object.get("parts").?.array.items;
    try std.testing.expectEqualStrings("You are helpful.", system_parts[0].object.get("text").?.string);

    const generation_config = obj.get("generationConfig").?.object;
    try std.testing.expectEqual(@as(i64, 4096), generation_config.get("maxOutputTokens").?.integer);
    try std.testing.expectEqual(@as(f64, 0.5), generation_config.get("temperature").?.float);

    const contents = obj.get("contents").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), contents.len);

    try std.testing.expectEqualStrings("user", contents[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("Hello", contents[0].object.get("parts").?.array.items[0].object.get("text").?.string);

    try std.testing.expectEqualStrings("model", contents[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("Hi", contents[1].object.get("parts").?.array.items[0].object.get("text").?.string);

    try std.testing.expectEqualStrings("model", contents[2].object.get("role").?.string);
    const call_parts = contents[2].object.get("parts").?.array.items;
    const function_call_0 = call_parts[0].object.get("functionCall").?.object;
    try std.testing.expectEqualStrings("read_file", function_call_0.get("name").?.string);
    try std.testing.expectEqualStrings("src/main.zig", function_call_0.get("args").?.object.get("path").?.string);
    const function_call_1 = call_parts[1].object.get("functionCall").?.object;
    try std.testing.expectEqualStrings("grep_search", function_call_1.get("name").?.string);

    // Consecutive tool results are coalesced into a single user turn as text
    // parts labeled with the matched tool name.
    try std.testing.expectEqualStrings("user", contents[3].object.get("role").?.string);
    const response_parts = contents[3].object.get("parts").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), response_parts.len);
    try std.testing.expectEqualStrings("Tool read_file result:", response_parts[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("file contents", response_parts[1].object.get("text").?.string);
    try std.testing.expectEqualStrings("Tool grep_search result:", response_parts[2].object.get("text").?.string);
    try std.testing.expectEqualStrings("match found", response_parts[3].object.get("text").?.string);

    const tools = obj.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    const declarations = tools[0].object.get("functionDeclarations").?.array.items;
    try std.testing.expectEqualStrings("read_file", declarations[0].object.get("name").?.string);
    try std.testing.expect(declarations[0].object.get("parameters") != null);
    try std.testing.expect(generation_config.get("thinkingConfig") == null);
}

test "googleRequestPayload includes thinkingConfig when reasoning is enabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .high,
    };

    const payload = try googleRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const generation_config = parsed.value.object.get("generationConfig").?.object;
    const thinking_config = generation_config.get("thinkingConfig").?.object;
    try std.testing.expectEqual(true, thinking_config.get("includeThoughts").?.bool);
}

test "googleRequestPayload omits thinkingConfig when reasoning_effort default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .default,
    };

    const payload = try googleRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("generationConfig").?.object.get("thinkingConfig") == null);
}

test "googleToolNameForId prefers the nearest prior assistant tool call" {
    const messages: []const openai.Message = &.{
        .{ .assistant = .{
            .tool_calls = &.{
                .{ .id = "call_0", .function = .{ .name = "read_file", .arguments = "{}" } },
            },
        } },
        .{ .tool = .{ .tool_call_id = "call_0", .content = "old result" } },
        .{ .assistant = .{
            .tool_calls = &.{
                .{ .id = "call_0", .function = .{ .name = "grep_search", .arguments = "{}" } },
            },
        } },
        .{ .tool = .{ .tool_call_id = "call_0", .content = "new result" } },
    };

    try std.testing.expectEqualStrings("read_file", googleToolNameForId(messages, "call_0", 1));
    try std.testing.expectEqualStrings("grep_search", googleToolNameForId(messages, "call_0", 3));
    try std.testing.expectEqualStrings("call_404", googleToolNameForId(messages, "call_404", messages.len));
}

test "GoogleSseCallback emits content and usage events" {
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

    var sse = GoogleSseCallback{ .allocator = allocator, .callback = callback };

    try sse.event("{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello\"}]},\"index\":0}]}");
    try sse.event("{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\" world\"}]},\"index\":0}]}");
    try sse.event("{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[]},\"finishReason\":\"STOP\",\"index\":0}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":20,\"totalTokenCount\":30}}");

    try std.testing.expectEqual(@as(usize, 4), events.items.len);
    try std.testing.expectEqualStrings("Hello", events.items[0].content);
    try std.testing.expectEqualStrings(" world", events.items[1].content);
    try std.testing.expectEqualStrings("STOP", events.items[2].finish.?);
    try std.testing.expectEqual(@as(i64, 10), events.items[3].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 20), events.items[3].usage.output_tokens);
}

test "GoogleSseCallback emits tool call events" {
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

    var sse = GoogleSseCallback{ .allocator = allocator, .callback = callback };

    try sse.event("{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"read_file\",\"args\":{\"path\":\"src/main.zig\"}}}]},\"finishReason\":\"STOP\",\"index\":0}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":15}}");

    try std.testing.expectEqual(@as(usize, 4), events.items.len);
    try std.testing.expectEqual(@as(usize, 0), events.items[0].tool_call_start.index);
    try std.testing.expectEqualStrings("call_0", events.items[0].tool_call_start.id);
    try std.testing.expectEqualStrings("read_file", events.items[0].tool_call_start.name);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", events.items[1].tool_call_delta.arguments);
    try std.testing.expectEqualStrings("STOP", events.items[2].finish.?);
    try std.testing.expectEqual(@as(i64, 5), events.items[3].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 15), events.items[3].usage.output_tokens);
}

test "GoogleSseCallback emits thought parts as reasoning events" {
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

    var sse = GoogleSseCallback{ .allocator = allocator, .callback = callback };

    try sse.event("{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Let me reason\",\"thought\":true},{\"text\":\"Here is the answer\"}]},\"finishReason\":\"STOP\",\"index\":0}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":20}}");

    try std.testing.expectEqual(@as(usize, 4), events.items.len);
    try std.testing.expectEqualStrings("Let me reason", events.items[0].reasoning);
    try std.testing.expectEqualStrings("Here is the answer", events.items[1].content);
    try std.testing.expectEqualStrings("STOP", events.items[2].finish.?);
    try std.testing.expectEqual(@as(i64, 10), events.items[3].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 20), events.items[3].usage.output_tokens);
}

test "googleRequestPayload labels unknown tool results with the call id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{
            .{ .tool = .{ .tool_call_id = "call_404", .content = "result" } },
        },
        .tools = &.{},
    };

    const payload = try googleRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const contents = parsed.value.object.get("contents").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), contents.len);
    const parts = contents[0].object.get("parts").?.array.items;
    try std.testing.expectEqualStrings("Tool call_404 result:", parts[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("result", parts[1].object.get("text").?.string);
}

test "googleRequestPayload keeps only the first system message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{
            .{ .system = "first system" },
            .{ .system = "second system" },
            .{ .user = "hello" },
        },
        .tools = &.{},
    };

    const payload = try googleRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    const system_parts = root.get("systemInstruction").?.object.get("parts").?.array.items;
    try std.testing.expectEqualStrings("first system", system_parts[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("contents").?.array.items.len);
}

test "googleRequestPayload omits system and tools for an empty request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{},
        .tools = &.{},
    };

    const payload = try googleRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 0), root.get("contents").?.array.items.len);
    try std.testing.expect(root.get("systemInstruction") == null);
    try std.testing.expect(root.get("tools") == null);
}

test "googleRequestPayload defaults a missing tool schema" {
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
        .model = "gemini-3.5-flash",
        .messages = &.{},
        .tools = &.{.{ .function = function }},
    };

    const payload = try googleRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const declaration = parsed.value.object.get("tools").?.array.items[0].object.get("functionDeclarations").?.array.items[0].object;
    try std.testing.expectEqualStrings("noop", declaration.get("name").?.string);
    try std.testing.expectEqualStrings("", declaration.get("description").?.string);
    try std.testing.expectEqual(@as(usize, 0), declaration.get("parameters").?.object.count());
}

test "googleRequestPayload rejects tools without a name" {
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
        .model = "gemini-3.5-flash",
        .messages = &.{},
        .tools = &.{.{ .function = function }},
    };

    try std.testing.expectError(error.MissingToolName, googleRequestPayload(allocator, request));
}

test "googleRequestPayload writes empty tool call arguments as empty args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{
            .{ .assistant = .{
                .tool_calls = &.{
                    .{ .id = "call_1", .function = .{ .name = "noop", .arguments = "   " } },
                },
            } },
        },
        .tools = &.{},
    };

    const payload = try googleRequestPayload(allocator, request);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const part = parsed.value.object.get("contents").?.array.items[0].object.get("parts").?.array.items[0].object;
    const function_call = part.get("functionCall").?.object;
    try std.testing.expectEqualStrings("noop", function_call.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 0), function_call.get("args").?.object.count());
}

test "GoogleSseCallback ignores non-object payloads and malformed candidates" {
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

    var sse = GoogleSseCallback{ .allocator = allocator, .callback = callback };

    try sse.event("[1,2,3]");
    try sse.event("{\"candidates\":\"nope\"}");
    try sse.event("{\"candidates\":[42,{\"content\":{\"parts\":[{\"text\":\"hi\"}]}}]}");
    try sse.event("{\"candidates\":[{\"content\":\"not an object\"}]}");
    try sse.event("{\"candidates\":[{\"finishReason\":\"\"}]}");
    try sse.event("{\"usageMetadata\":{\"candidatesTokenCount\":5}}");

    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expectEqualStrings("hi", events.items[0].content);
    try std.testing.expect(events.items[1].finish == null);
    try std.testing.expectEqual(@as(i64, 0), events.items[2].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 5), events.items[2].usage.output_tokens);
}

test "GoogleSseCallback ignores malformed function calls" {
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

    var sse = GoogleSseCallback{ .allocator = allocator, .callback = callback };

    try sse.event("{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":\"not an object\"}]}}]}");
    try sse.event("{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"args\":{}}}]}}]}");
    try sse.event("{\"candidates\":[{\"content\":{\"parts\":[{\"unknown\":true}]}}]}");

    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

// ── chatStreamingGoogle server tests ─────────────────────────────────

const GoogleServer = struct {
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

fn startGoogleServer(status: std.http.Status, body: []const u8) !*GoogleServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(GoogleServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    ctx.thread = try std.Thread.spawn(.{}, GoogleServer.serve, .{ctx});
    return ctx;
}

fn stopGoogleServer(ctx: *GoogleServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn googleClientForServer(ctx: *GoogleServer, arena: std.mem.Allocator) !http_client.Client {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
    var c = http_client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    c.withBaseUrl(url);
    return c;
}

test "chatStreamingGoogle delivers SSE events from a local server" {
    const body =
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello\"}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":4,\"candidatesTokenCount\":2}}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startGoogleServer(.ok, body);
    defer stopGoogleServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try googleClientForServer(ctx, arena);
    defer c.deinit();
    const allocator = arena;

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.reset();
    try chatStreamingGoogle(&c, request, callback);

    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expectEqualStrings("Hello", events.items[0].content);
    try std.testing.expectEqualStrings("STOP", events.items[1].finish.?);
    try std.testing.expectEqual(@as(i64, 4), events.items[2].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 2), events.items[2].usage.output_tokens);
}

test "chatStreamingGoogle returns ResponseError on a non-success status" {
    const ctx = try startGoogleServer(.internal_server_error, "exploded");
    defer stopGoogleServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try googleClientForServer(ctx, arena);
    defer c.deinit();
    const allocator = arena;

    var events = std.ArrayList(TestEvent).empty;

    var sse_callback = TestSseCallback{ .allocator = allocator, .events = &events };
    const callback = openai.StreamCallback{
        .context = &sse_callback,
        .vtable = &.{
            .event = TestSseCallback.event,
        },
    };

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    try std.testing.expectError(error.ResponseError, chatStreamingGoogle(&c, request, callback));
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

const GoogleGarbageServer = struct {
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

fn startGoogleGarbageServer() !*GoogleGarbageServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(GoogleGarbageServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server };
    ctx.thread = try std.Thread.spawn(.{}, GoogleGarbageServer.serve, .{ctx});
    return ctx;
}

fn stopGoogleGarbageServer(ctx: *GoogleGarbageServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

test "chatStreamingGoogle reports response head failures to the http observer" {
    const ctx = try startGoogleGarbageServer();
    defer stopGoogleGarbageServer(ctx);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
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
        .model = "gemini-3.5-flash",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    if (chatStreamingGoogle(&c, request, undefined)) |_| {
        return error.ExpectedHeadFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

test "chatStreamingGoogle returns Canceled when the stream is cancelled" {
    const body =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello\"}]}}]}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startGoogleServer(.ok, body);
    defer stopGoogleServer(ctx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var c = try googleClientForServer(ctx, arena);
    defer c.deinit();

    const request = openai.ChatRequest{
        .model = "gemini-3.5-flash",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.setCancelled();
    defer cancel.reset();
    try std.testing.expectError(error.Canceled, chatStreamingGoogle(&c, request, undefined));
}
