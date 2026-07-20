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

    pub fn toJson(self: Message, allocator: std.mem.Allocator) !std.json.Value {
        return switch (self) {
            .system => |content| blk: {
                var obj = try newObject(allocator);
                errdefer obj.deinit(allocator);
                try obj.put(allocator, "role", .{ .string = "system" });
                try obj.put(allocator, "content", .{ .string = content });
                break :blk .{ .object = obj };
            },
            .user => |content| blk: {
                var obj = try newObject(allocator);
                errdefer obj.deinit(allocator);
                try obj.put(allocator, "role", .{ .string = "user" });
                try obj.put(allocator, "content", .{ .string = content });
                break :blk .{ .object = obj };
            },
            .assistant => |assistant| blk: {
                var obj = try newObject(allocator);
                errdefer obj.deinit(allocator);
                try obj.put(allocator, "role", .{ .string = "assistant" });
                if (assistant.content) |content| {
                    try obj.put(allocator, "content", .{ .string = content });
                } else {
                    try obj.put(allocator, "content", .{ .null = {} });
                }
                if (assistant.tool_calls) |tool_calls| {
                    var arr = try std.json.Array.initCapacity(allocator, tool_calls.len);
                    errdefer {
                        for (arr.items) |item| item.object.deinit(allocator);
                        arr.deinit(allocator);
                    }
                    for (tool_calls) |tc| {
                        var func = try newObject(allocator);
                        errdefer func.deinit(allocator);
                        try func.put(allocator, "name", .{ .string = tc.function.name });
                        try func.put(allocator, "arguments", .{ .string = tc.function.arguments });

                        var tc_obj = try newObject(allocator);
                        errdefer tc_obj.deinit(allocator);
                        try tc_obj.put(allocator, "id", .{ .string = tc.id });
                        try tc_obj.put(allocator, "type", .{ .string = tc.type });
                        try tc_obj.put(allocator, "function", .{ .object = func });
                        try arr.append(.{ .object = tc_obj });
                    }
                    try obj.put(allocator, "tool_calls", .{ .array = arr });
                }
                break :blk .{ .object = obj };
            },
            .tool => |tool| blk: {
                var obj = try newObject(allocator);
                errdefer obj.deinit(allocator);
                try obj.put(allocator, "role", .{ .string = "tool" });
                try obj.put(allocator, "tool_call_id", .{ .string = tool.tool_call_id });
                try obj.put(allocator, "content", .{ .string = tool.content });
                break :blk .{ .object = obj };
            },
        };
    }
};

fn newObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

pub const ToolDefinition = struct {
    type: []const u8 = "function",
    function: std.json.Value,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDefinition,
    stream: bool = true,
    temperature: ?f64 = null,
};

pub const StreamEvent = union(enum) {
    content: []const u8,
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
    },

    pub fn emit(self: StreamCallback, ev: StreamEvent) !void {
        try self.vtable.event(self.context, ev);
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
    var json_buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer json_buffer.deinit();

    var stringifier = std.json.Stringify{
        .writer = &json_buffer.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try stringifier.beginObject();
    try stringifier.objectField("model");
    try stringifier.write(request.model);
    try stringifier.objectField("messages");
    try stringifier.beginArray();
    for (request.messages) |msg| {
        try writeMessage(&stringifier, msg);
    }
    try stringifier.endArray();
    try stringifier.objectField("tools");
    try stringifier.beginArray();
    for (request.tools) |tool| {
        try stringifier.beginObject();
        try stringifier.objectField("type");
        try stringifier.write(tool.type);
        try stringifier.objectField("function");
        try stringifier.write(tool.function);
        try stringifier.endObject();
    }
    try stringifier.endArray();
    try stringifier.objectField("stream");
    try stringifier.write(request.stream);
    if (request.temperature) |temperature| {
        try stringifier.objectField("temperature");
        try stringifier.write(temperature);
    }
    try stringifier.endObject();

    return json_buffer.toOwnedSlice();
}

fn writeMessage(stringifier: *std.json.Stringify, msg: Message) !void {
    try stringifier.beginObject();
    switch (msg) {
        .system => |content| {
            try stringifier.objectField("role");
            try stringifier.write("system");
            try stringifier.objectField("content");
            try stringifier.write(content);
        },
        .user => |content| {
            try stringifier.objectField("role");
            try stringifier.write("user");
            try stringifier.objectField("content");
            try stringifier.write(content);
        },
        .assistant => |assistant| {
            try stringifier.objectField("role");
            try stringifier.write("assistant");
            try stringifier.objectField("content");
            if (assistant.content) |content| {
                try stringifier.write(content);
            } else {
                try stringifier.write(null);
            }
            if (assistant.tool_calls) |tool_calls| {
                try stringifier.objectField("tool_calls");
                try stringifier.beginArray();
                for (tool_calls) |tc| {
                    try stringifier.beginObject();
                    try stringifier.objectField("id");
                    try stringifier.write(tc.id);
                    try stringifier.objectField("type");
                    try stringifier.write(tc.type);
                    try stringifier.objectField("function");
                    try stringifier.beginObject();
                    try stringifier.objectField("name");
                    try stringifier.write(tc.function.name);
                    try stringifier.objectField("arguments");
                    try stringifier.write(tc.function.arguments);
                    try stringifier.endObject();
                    try stringifier.endObject();
                }
                try stringifier.endArray();
            }
        },
        .tool => |tool| {
            try stringifier.objectField("role");
            try stringifier.write("tool");
            try stringifier.objectField("tool_call_id");
            try stringifier.write(tool.tool_call_id);
            try stringifier.objectField("content");
            try stringifier.write(tool.content);
        },
    }
    try stringifier.endObject();
}

test "message JSON conversion" {
    const allocator = std.testing.allocator;

    var system_msg = try (Message{ .system = "You are a helpful assistant." }).toJson(allocator);
    try std.testing.expectEqualStrings("system", system_msg.object.get("role").?.string);
    try std.testing.expectEqualStrings("You are a helpful assistant.", system_msg.object.get("content").?.string);
    system_msg.object.deinit(allocator);

    var tool_msg = try (Message{ .tool = .{ .tool_call_id = "call_1", .content = "result" } }).toJson(allocator);
    try std.testing.expectEqualStrings("tool", tool_msg.object.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", tool_msg.object.get("tool_call_id").?.string);
    tool_msg.object.deinit(allocator);
}
