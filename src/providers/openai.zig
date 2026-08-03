const std = @import("std");
const cancel = @import("../core/cancel.zig");
const client = @import("client.zig");

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

pub const AssistantContent = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
};

pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
};

pub const TurnUsage = struct {
    input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: ?i64 = null,
    tokens_per_second: ?f64 = null,
    time_to_first_token_seconds: ?f64 = null,
};

pub const Message = union(enum) {
    system: []const u8,
    user: []const u8,
    assistant: AssistantContent,
    tool: ToolResult,

    pub fn jsonStringify(self: Message, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        switch (self) {
            .system => |content| {
                try jw.objectField("role");
                try jw.write("system");
                try jw.objectField("content");
                try jw.write(content);
            },
            .user => |content| {
                try jw.objectField("role");
                try jw.write("user");
                try jw.objectField("content");
                try jw.write(content);
            },
            .assistant => |assistant| {
                try jw.objectField("role");
                try jw.write("assistant");
                try jw.objectField("content");
                if (assistant.content) |content| {
                    try jw.write(content);
                } else {
                    try jw.write(std.json.Value{ .null = {} });
                }
                if (assistant.tool_calls) |tool_calls| {
                    try jw.objectField("tool_calls");
                    try jw.beginArray();
                    for (tool_calls) |tc| {
                        try jw.beginObject();
                        try jw.objectField("id");
                        try jw.write(tc.id);
                        try jw.objectField("type");
                        try jw.write(tc.type);
                        try jw.objectField("function");
                        try jw.beginObject();
                        try jw.objectField("name");
                        try jw.write(tc.function.name);
                        try jw.objectField("arguments");
                        try jw.write(tc.function.arguments);
                        try jw.endObject();
                        try jw.endObject();
                    }
                    try jw.endArray();
                }
            },
            .tool => |tool| {
                try jw.objectField("role");
                try jw.write("tool");
                try jw.objectField("tool_call_id");
                try jw.write(tool.tool_call_id);
                try jw.objectField("content");
                try jw.write(tool.content);
            },
        }
        try jw.endObject();
    }

    pub fn fromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !Message {
        const obj = if (value == .object) value.object else return error.InvalidMessage;
        const role_val = obj.get("role") orelse return error.InvalidMessage;
        const role = if (role_val == .string) role_val.string else return error.InvalidMessage;

        if (std.mem.eql(u8, role, "system")) {
            const content_val = obj.get("content") orelse return error.InvalidMessage;
            if (content_val != .string) return error.InvalidMessage;
            return .{ .system = try allocator.dupe(u8, content_val.string) };
        }

        if (std.mem.eql(u8, role, "user")) {
            const content_val = obj.get("content") orelse return error.InvalidMessage;
            if (content_val != .string) return error.InvalidMessage;
            return .{ .user = try allocator.dupe(u8, content_val.string) };
        }

        if (std.mem.eql(u8, role, "assistant")) {
            const content = if (obj.get("content")) |c| switch (c) {
                .null => null,
                .string => |s| s,
                else => return error.InvalidMessage,
            } else null;

            var tool_calls: ?[]ToolCall = null;
            if (obj.get("tool_calls")) |tc_arr_val| {
                if (tc_arr_val != .array) return error.InvalidMessage;
                const arr = tc_arr_val.array;
                var list = try std.ArrayList(ToolCall).initCapacity(allocator, arr.items.len);
                for (arr.items) |tc_val| {
                    if (tc_val != .object) return error.InvalidMessage;
                    const tc_obj = tc_val.object;
                    const id_val = tc_obj.get("id") orelse return error.InvalidMessage;
                    if (id_val != .string) return error.InvalidMessage;
                    const func_val = tc_obj.get("function") orelse return error.InvalidMessage;
                    if (func_val != .object) return error.InvalidMessage;
                    const func_obj = func_val.object;
                    const name_val = func_obj.get("name") orelse return error.InvalidMessage;
                    if (name_val != .string) return error.InvalidMessage;
                    const args_val = func_obj.get("arguments") orelse return error.InvalidMessage;
                    if (args_val != .string) return error.InvalidMessage;
                    list.appendAssumeCapacity(.{
                        .id = try allocator.dupe(u8, id_val.string),
                        .type = try allocator.dupe(u8, "function"),
                        .function = .{
                            .name = try allocator.dupe(u8, name_val.string),
                            .arguments = try allocator.dupe(u8, args_val.string),
                        },
                    });
                }
                tool_calls = try list.toOwnedSlice(allocator);
            }

            return .{ .assistant = .{
                .content = if (content) |c| try allocator.dupe(u8, c) else null,
                .tool_calls = tool_calls,
            } };
        }

        if (std.mem.eql(u8, role, "tool")) {
            const tcid_val = obj.get("tool_call_id") orelse return error.InvalidMessage;
            if (tcid_val != .string) return error.InvalidMessage;
            const content_val = obj.get("content") orelse return error.InvalidMessage;
            if (content_val != .string) return error.InvalidMessage;
            return .{ .tool = .{
                .tool_call_id = try allocator.dupe(u8, tcid_val.string),
                .content = try allocator.dupe(u8, content_val.string),
            } };
        }

        return error.UnknownRole;
    }
};

pub const ToolDefinition = struct {
    type: []const u8 = "function",
    function: std.json.Value,
};

pub const ReasoningEffort = enum {
    default,
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDefinition,
    stream: bool = true,
    temperature: ?f64 = null,
    reasoning_effort: ?ReasoningEffort = null,
};

pub const StreamEvent = union(enum) {
    content: []const u8,
    reasoning: []const u8,
    tool_call_start: struct {
        index: usize,
        id: []const u8,
        name: []const u8,
    },
    tool_call_delta: struct {
        index: usize,
        arguments: []const u8,
    },
    finish: ?[]const u8,
    usage: TurnUsage,
};

pub const StreamCallback = struct {
    context: *anyopaque,
    vtable: *const struct {
        event: *const fn (context: *anyopaque, ev: StreamEvent) anyerror!void,
        reset: ?*const fn (context: *anyopaque) void = null,
    },

    pub fn emit(self: StreamCallback, ev: StreamEvent) !void {
        try self.vtable.event(self.context, ev);
    }

    pub fn reset(self: StreamCallback) void {
        if (self.vtable.reset) |r| r(self.context);
    }
};

const DeltaFunction = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const DeltaToolCall = struct {
    index: ?usize = null,
    id: ?[]const u8 = null,
    function: ?DeltaFunction = null,
};

const DeltaChoice = struct {
    delta: struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        role: ?[]const u8 = null,
        tool_calls: ?[]const DeltaToolCall = null,
    },
    finish_reason: ?[]const u8 = null,
};

const UsageJson = struct {
    prompt_tokens: i64,
    completion_tokens: i64,
    reasoning_output_tokens: ?i64 = null,
    tokens_per_second: ?f64 = null,
    time_to_first_token_seconds: ?f64 = null,
};

const StreamChunk = struct {
    choices: []const DeltaChoice,
    usage: ?UsageJson = null,
};

pub const SseCallback = struct {
    allocator: std.mem.Allocator,
    callback: StreamCallback,
    observer: ?client.HttpObserver = null,

    pub fn event(self: *@This(), data: []const u8) !void {
        if (self.observer) |obs| {
            if (obs.on_chunk) |cb| cb(obs.ctx, data);
        }

        const parsed = try std.json.parseFromSlice(StreamChunk, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        for (parsed.value.choices) |choice| {
            if (choice.delta.reasoning_content) |rc| {
                try self.callback.emit(.{ .reasoning = rc });
            }

            if (choice.delta.content) |content| {
                try self.callback.emit(.{ .content = content });
            }

            if (choice.delta.tool_calls) |tool_calls| {
                for (tool_calls) |tc| {
                    const index = tc.index orelse 0;
                    const id = tc.id orelse "";
                    const name = if (tc.function) |f| f.name orelse "" else "";
                    const args = if (tc.function) |f| f.arguments orelse "" else "";

                    if (id.len > 0 and name.len > 0) {
                        try self.callback.emit(.{ .tool_call_start = .{ .index = index, .id = id, .name = name } });
                    }
                    if (args.len > 0) {
                        try self.callback.emit(.{ .tool_call_delta = .{ .index = index, .arguments = args } });
                    }
                }
            }

            if (choice.finish_reason) |reason| {
                try self.callback.emit(.{ .finish = if (reason.len == 0) null else reason });
            }
        }

        if (parsed.value.usage) |usage| {
            try self.callback.emit(.{ .usage = .{
                .input_tokens = usage.prompt_tokens,
                .output_tokens = usage.completion_tokens,
                .reasoning_output_tokens = usage.reasoning_output_tokens,
                .tokens_per_second = usage.tokens_per_second,
                .time_to_first_token_seconds = usage.time_to_first_token_seconds,
            } });
        }
    }
};

pub const CancelableReader = struct {
    inner: *std.Io.Reader,
    reader: std.Io.Reader,

    pub fn init(inner: *std.Io.Reader, buffer: []u8) CancelableReader {
        return .{
            .inner = inner,
            .reader = .{
                .buffer = buffer,
                .seek = 0,
                .end = 0,
                .vtable = &vtable,
            },
        };
    }

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
        .discard = std.Io.Reader.defaultDiscard,
        .readVec = std.Io.Reader.defaultReadVec,
        .rebase = std.Io.Reader.defaultRebase,
    };

    fn stream(ctx: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CancelableReader = @fieldParentPtr("reader", ctx);
        if (cancel.isCancelled()) return error.ReadFailed;
        return self.inner.stream(w, limit);
    }
};

pub fn chatStreaming(chat_client: *client.Client, request: ChatRequest, callback: StreamCallback) !void {
    const allocator = chat_client.allocator;
    const payload = try requestPayload(allocator, request);
    defer allocator.free(payload);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{chat_client.base_url});
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try client.appendClientHeaders(allocator, &headers, chat_client, "application/json", "text/event-stream");
    defer if (auth_header) |value| allocator.free(value);

    const uri = try std.Uri.parse(url);

    if (chat_client.http_observer) |obs| {
        if (obs.onRequest) |cb| cb(obs.ctx, .POST, url, headers.items, payload);
    }

    const start = std.Io.Clock.awake.now(chat_client.io);
    var req = chat_client.http.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers.items,
    }) catch |err| {
        if (chat_client.http_observer) |obs| {
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
        if (chat_client.http_observer) |obs| {
            if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
        }
        return err;
    };
    const elapsed_ns = @as(u64, @intCast(start.untilNow(chat_client.io, .awake).nanoseconds));

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    var cancelable_reader_buffer: [1]u8 = undefined;
    var cancelable_reader = CancelableReader.init(response_reader, &cancelable_reader_buffer);
    const reader = &cancelable_reader.reader;

    if (response.head.status.class() != .success) {
        var body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer body_alloc.deinit();
        _ = reader.streamRemaining(&body_alloc.writer) catch {};

        if (chat_client.http_observer) |obs| {
            if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, body_alloc.written(), elapsed_ns);
        }

        if (response.head.status == .unauthorized or response.head.status == .forbidden) {
            client.printAuthHint(chat_client.io);
        }

        std.debug.print("OpenAI chat request failed\n  URL: {s}\n  Status: {d}\n  Payload: {s}\n  Response: {s}\n", .{
            url,
            @intFromEnum(response.head.status),
            payload,
            body_alloc.written(),
        });
        return error.ResponseError;
    }

    if (chat_client.http_observer) |obs| {
        if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, "", elapsed_ns);
    }

    var sse = SseCallback{
        .allocator = allocator,
        .callback = callback,
        .observer = chat_client.http_observer,
    };

    client.parseSseReader(allocator, reader, &sse, null) catch |err| switch (err) {
        error.ReadFailed => {
            if (cancel.isCancelled()) return error.Canceled;
            return err;
        },
        else => return err,
    };
}

pub fn requestPayload(allocator: std.mem.Allocator, request: ChatRequest) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, w);

    try w.writeAll(",\"messages\":[");
    for (request.messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(msg, .{}, w);
    }
    try w.writeByte(']');

    try w.writeAll(",\"tools\":[");
    for (request.tools, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":");
        try std.json.Stringify.value(tool.type, .{}, w);
        try w.writeAll(",\"function\":");
        try std.json.Stringify.value(tool.function, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    try w.writeAll(",\"stream\":true");
    try w.writeAll(",\"stream_options\":{\"include_usage\":true}");

    if (request.temperature) |temp| {
        try w.writeAll(",\"temperature\":");
        try std.json.Stringify.value(temp, .{}, w);
    }

    if (request.reasoning_effort) |effort| {
        if (effort != .default) {
            try w.writeAll(",\"reasoning_effort\":\"");
            try w.writeAll(@tagName(effort));
            try w.writeAll("\",\"thinking\":{\"type\":\"enabled\"}");
        }
    }

    try w.writeByte('}');

    return buf.toOwnedSlice();
}

test "message JSON round-trip all variants" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const messages = [_]Message{
        .{ .system = "You are a helpful assistant." },
        .{ .user = "Hello!" },
        .{ .assistant = .{ .content = "Hi there!" } },
        .{ .assistant = .{ .content = null, .tool_calls = &[_]ToolCall{
            .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{}" } },
        } } },
        .{ .tool = .{ .tool_call_id = "call_1", .content = "file contents" } },
        .{ .assistant = .{ .content = "Done reading." } },
    };

    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try std.json.Stringify.value(&messages, .{}, &buf.writer);

    const parsed_val = try std.json.parseFromSlice(std.json.Value, a, buf.written(), .{});
    defer parsed_val.deinit();

    const arr = parsed_val.value.array;
    try std.testing.expectEqual(@as(usize, messages.len), arr.items.len);

    for (messages, arr.items, 0..) |expected, item, i| {
        const parsed = try Message.fromJsonValue(a, item);
        try std.testing.expectEqualDeep(expected, parsed);
        _ = i;
    }
}

test "message JSON conversion" {
    const allocator = std.testing.allocator;

    {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        try std.json.Stringify.value(Message{ .system = "You are a helpful assistant." }, .{}, &buf.writer);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("system", parsed.value.object.get("role").?.string);
        try std.testing.expectEqualStrings("You are a helpful assistant.", parsed.value.object.get("content").?.string);
    }

    {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        try std.json.Stringify.value(Message{ .tool = .{ .tool_call_id = "call_1", .content = "result" } }, .{}, &buf.writer);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("tool", parsed.value.object.get("role").?.string);
        try std.testing.expectEqualStrings("call_1", parsed.value.object.get("tool_call_id").?.string);
    }
}

test "requestPayload includes reasoning_effort and thinking for each level" {
    const levels = [_]ReasoningEffort{ .none, .minimal, .low, .medium, .high, .xhigh };
    for (levels) |effort| {
        const request = ChatRequest{
            .model = "test-model",
            .messages = &.{},
            .tools = &.{},
            .reasoning_effort = effort,
        };

        const payload = try requestPayload(std.testing.allocator, request);
        defer std.testing.allocator.free(payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const root = parsed.value.object;
        try std.testing.expectEqualStrings(@tagName(effort), root.get("reasoning_effort").?.string);
        try std.testing.expectEqualStrings("enabled", root.get("thinking").?.object.get("type").?.string);
    }
}

test "requestPayload requests usage in stream" {
    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{},
        .tools = &.{},
    };

    const payload = try requestPayload(std.testing.allocator, request);
    defer std.testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(true, root.get("stream").?.bool);
    const stream_options = root.get("stream_options").?.object;
    try std.testing.expectEqual(true, stream_options.get("include_usage").?.bool);
}

test "requestPayload omits reasoning_effort when default" {
    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .default,
    };

    const payload = try requestPayload(std.testing.allocator, request);
    defer std.testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("reasoning_effort") == null);
    try std.testing.expect(parsed.value.object.get("thinking") == null);
}

test "requestPayload omits reasoning_effort when null" {
    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{},
        .tools = &.{},
    };

    const payload = try requestPayload(std.testing.allocator, request);
    defer std.testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("reasoning_effort") == null);
    try std.testing.expect(parsed.value.object.get("thinking") == null);
}

test "ReasoningEffort JSON serialization" {
    const efforts = [_]ReasoningEffort{ .default, .none, .minimal, .low, .medium, .high, .xhigh };

    for (efforts) |effort| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();
        try std.json.Stringify.value(effort, .{}, &buf.writer);

        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(@tagName(effort), parsed.value.string);
    }
}
