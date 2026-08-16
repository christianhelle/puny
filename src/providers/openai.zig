const std = @import("std");
const cancel = @import("../core/cancel.zig");
const client = @import("client.zig");

const message = @import("message.zig");

pub const ToolCall = message.ToolCall;
pub const AssistantContent = message.AssistantContent;
pub const ToolResult = message.ToolResult;
pub const Message = message.Message;

pub const TurnUsage = struct {
    input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: ?i64 = null,
    tokens_per_second: ?f64 = null,
    time_to_first_token_seconds: ?f64 = null,
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

const CompletionTokensDetails = struct {
    reasoning_tokens: ?i64 = null,
};

const UsageJson = struct {
    prompt_tokens: i64,
    completion_tokens: i64,
    reasoning_output_tokens: ?i64 = null,
    reasoning_tokens: ?i64 = null,
    completion_tokens_details: ?CompletionTokensDetails = null,
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
                .reasoning_output_tokens = usage.reasoning_output_tokens orelse usage.reasoning_tokens orelse (if (usage.completion_tokens_details) |d| d.reasoning_tokens else null),
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

test "usage event falls back to reasoning_tokens field" {
    var events: std.ArrayList(TurnUsage) = .empty;
    defer events.deinit(std.testing.allocator);

    const UsageListener = struct {
        events: *std.ArrayList(TurnUsage),

        pub fn event(self: *@This(), ev: StreamEvent) !void {
            if (ev == .usage) try self.events.append(std.testing.allocator, ev.usage);
        }
    };

    var listener = UsageListener{ .events = &events };
    const callback = StreamCallback{
        .context = &listener,
        .vtable = &.{
            .event = struct {
                pub fn event(ctx: *anyopaque, ev: StreamEvent) !void {
                    const state: *UsageListener = @ptrCast(@alignCast(ctx));
                    try state.event(ev);
                }
            }.event,
        },
    };

    var sse = SseCallback{ .allocator = std.testing.allocator, .callback = callback };

    try sse.event("{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"reasoning_tokens\":5}}");

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(@as(i64, 5), events.items[0].reasoning_output_tokens.?);
}

test "usage event parses nested completion_tokens_details reasoning_tokens" {
    var events: std.ArrayList(TurnUsage) = .empty;
    defer events.deinit(std.testing.allocator);

    const UsageListener = struct {
        events: *std.ArrayList(TurnUsage),

        pub fn event(self: *@This(), ev: StreamEvent) !void {
            if (ev == .usage) try self.events.append(std.testing.allocator, ev.usage);
        }
    };

    var listener = UsageListener{ .events = &events };
    const callback = StreamCallback{
        .context = &listener,
        .vtable = &.{
            .event = struct {
                pub fn event(ctx: *anyopaque, ev: StreamEvent) !void {
                    const state: *UsageListener = @ptrCast(@alignCast(ctx));
                    try state.event(ev);
                }
            }.event,
        },
    };

    var sse = SseCallback{ .allocator = std.testing.allocator, .callback = callback };

    try sse.event("{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"completion_tokens_details\":{\"reasoning_tokens\":5}}}");

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(@as(i64, 5), events.items[0].reasoning_output_tokens.?);
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

// ── SSE callback tests ───────────────────────────────────────────────

const SseTestEvent = union(enum) {
    content: []const u8,
    reasoning: []const u8,
    tool_call_start: struct { index: usize, id: []const u8, name: []const u8 },
    tool_call_delta: struct { index: usize, arguments: []const u8 },
    finish: ?[]const u8,
    usage: TurnUsage,
};

const SseRecorder = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList(SseTestEvent),
    chunks: *std.ArrayList([]u8),

    fn callback(self: *SseRecorder) StreamCallback {
        return .{
            .context = self,
            .vtable = &.{
                .event = event,
                .reset = null,
            },
        };
    }

    fn event(ctx: *anyopaque, ev: StreamEvent) !void {
        const self: *SseRecorder = @ptrCast(@alignCast(ctx));
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
            .finish => |v| try self.events.append(self.allocator, .{ .finish = if (v) |s| try self.allocator.dupe(u8, s) else null }),
            .usage => |v| try self.events.append(self.allocator, .{ .usage = v }),
        }
    }

    fn onChunk(ctx: ?*anyopaque, data: []const u8) void {
        const self: *SseRecorder = @ptrCast(@alignCast(ctx.?));
        self.chunks.append(self.allocator, self.allocator.dupe(u8, data) catch return) catch {};
    }
};

test "SseCallback emits content reasoning and tool call events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(SseTestEvent).empty;
    var chunks = std.ArrayList([]u8).empty;

    var recorder = SseRecorder{ .allocator = allocator, .events = &events, .chunks = &chunks };
    const observer = client.HttpObserver{
        .ctx = &recorder,
        .onRequest = null,
        .onResponse = null,
        .onError = null,
        .on_chunk = SseRecorder.onChunk,
    };

    var sse = SseCallback{ .allocator = allocator, .callback = recorder.callback(), .observer = observer };

    const data =
        \\{"choices":[{"delta":{"reasoning_content":"think","content":"hi","tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"p"}},{"index":2,"id":"","function":{"name":"search","arguments":"x}"}}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}
    ;
    try sse.event(data);

    try std.testing.expectEqual(@as(usize, 7), events.items.len);
    try std.testing.expectEqualStrings("think", events.items[0].reasoning);
    try std.testing.expectEqualStrings("hi", events.items[1].content);
    try std.testing.expectEqual(@as(usize, 0), events.items[2].tool_call_start.index);
    try std.testing.expectEqualStrings("c1", events.items[2].tool_call_start.id);
    try std.testing.expectEqualStrings("read_file", events.items[2].tool_call_start.name);
    try std.testing.expectEqualStrings("{\"p", events.items[3].tool_call_delta.arguments);
    try std.testing.expectEqual(@as(usize, 2), events.items[4].tool_call_delta.index);
    try std.testing.expectEqualStrings("x}", events.items[4].tool_call_delta.arguments);
    try std.testing.expectEqualStrings("stop", events.items[5].finish.?);
    try std.testing.expectEqual(@as(i64, 10), events.items[6].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 20), events.items[6].usage.output_tokens);
    try std.testing.expect(events.items[6].usage.reasoning_output_tokens == null);

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings(data, chunks.items[0]);
}

test "SseCallback emits a null finish for an empty finish reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(SseTestEvent).empty;
    var chunks = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events, .chunks = &chunks };
    var sse = SseCallback{ .allocator = allocator, .callback = recorder.callback() };

    try sse.event("{\"choices\":[{\"delta\":{},\"finish_reason\":\"\"}]}");
    try sse.event("{\"choices\":[{\"delta\":{\"content\":\"done\"}}]}");

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expect(events.items[0].finish == null);
    try std.testing.expectEqualStrings("done", events.items[1].content);
}

test "SseCallback defaults missing tool call fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(SseTestEvent).empty;
    var chunks = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events, .chunks = &chunks };
    var sse = SseCallback{ .allocator = allocator, .callback = recorder.callback() };

    try sse.event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"{}\"}}]}}]}");
    try sse.event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"name\":\"\"}}]}}]}");

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(@as(usize, 0), events.items[0].tool_call_delta.index);
    try std.testing.expectEqualStrings("{}", events.items[0].tool_call_delta.arguments);
}

test "StreamCallback reset invokes the vtable reset when present" {
    const ResetCounter = struct {
        count: usize = 0,
        fn resetFn(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
    };

    var counter = ResetCounter{};
    var cb = StreamCallback{ .context = &counter, .vtable = &.{
        .event = undefined,
        .reset = ResetCounter.resetFn,
    } };
    cb.reset();
    try std.testing.expectEqual(@as(usize, 1), counter.count);

    var cb2 = StreamCallback{ .context = &counter, .vtable = &.{ .event = undefined } };
    cb2.reset();
    try std.testing.expectEqual(@as(usize, 1), counter.count);
}

test "CancelableReader passes through when not cancelled and fails when cancelled" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    cancel.reset();
    var fixed = std.Io.Reader.fixed("hello");
    var buffer: [1]u8 = undefined;
    var reader = CancelableReader.init(&fixed, &buffer);
    _ = try reader.reader.streamRemaining(&out.writer);
    try std.testing.expectEqualStrings("hello", out.written());

    cancel.setCancelled();
    defer cancel.reset();
    var fixed2 = std.Io.Reader.fixed("hello");
    var buffer2: [1]u8 = undefined;
    var reader2 = CancelableReader.init(&fixed2, &buffer2);
    try std.testing.expectError(error.ReadFailed, reader2.reader.streamRemaining(&out.writer));
}

test "requestPayload serializes temperature messages and tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"name\":\"read_file\",\"description\":\"Read a file\",\"parameters\":{\"type\":\"object\"}}",
        .{},
    );

    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{
            .{ .system = "You are helpful." },
            .{ .user = "Read src/main.zig" },
            .{ .assistant = .{
                .tool_calls = &.{
                    .{ .id = "call_1", .function = .{ .name = "read_file", .arguments = "{\"path\":\"src/main.zig\"}" } },
                },
            } },
            .{ .tool = .{ .tool_call_id = "call_1", .content = "file contents" } },
        },
        .tools = &.{
            .{ .function = schema },
        },
        .temperature = 0.7,
    };

    const payload = try requestPayload(std.testing.allocator, request);
    defer std.testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("test-model", root.get("model").?.string);
    try std.testing.expectEqual(@as(f64, 0.7), root.get("temperature").?.float);
    try std.testing.expectEqual(@as(usize, 4), root.get("messages").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), root.get("tools").?.array.items.len);
    const tool = root.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("function", tool.get("type").?.string);
    try std.testing.expectEqualStrings("read_file", tool.get("function").?.object.get("name").?.string);
}

// ── chatStreaming server tests ───────────────────────────────────────

const ChatServer = struct {
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

fn startChatServer(status: std.http.Status, body: []const u8) !*ChatServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(ChatServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server, .status = status, .body = body };
    ctx.thread = try std.Thread.spawn(.{}, ChatServer.serve, .{ctx});
    return ctx;
}

fn stopChatServer(ctx: *ChatServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

fn chatServerUrl(ctx: *ChatServer) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{ctx.server.socket.address.getPort()});
}

test "chatStreaming delivers SSE events from a local server" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startChatServer(.ok, body);
    defer stopChatServer(ctx);

    const url = try chatServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(SseTestEvent).empty;
    var chunks = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events, .chunks = &chunks };
    c.http_observer = client.HttpObserver{
        .ctx = &recorder,
        .onRequest = null,
        .onResponse = null,
        .onError = null,
        .on_chunk = SseRecorder.onChunk,
    };

    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.reset();
    try chatStreaming(&c, request, recorder.callback());

    try std.testing.expectEqual(@as(usize, 4), events.items.len);
    try std.testing.expectEqualStrings("Hello", events.items[0].content);
    try std.testing.expectEqualStrings(" world", events.items[1].content);
    try std.testing.expectEqualStrings("stop", events.items[2].finish.?);
    try std.testing.expectEqual(@as(i64, 7), events.items[3].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 3), events.items[3].usage.output_tokens);
    try std.testing.expectEqual(@as(usize, 3), chunks.items.len);
}

test "chatStreaming returns ResponseError on a non-success status" {
    const ctx = try startChatServer(.internal_server_error, "server exploded");
    defer stopChatServer(ctx);

    const url = try chatServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(SseTestEvent).empty;
    var chunks = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events, .chunks = &chunks };

    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    try std.testing.expectError(error.ResponseError, chatStreaming(&c, request, recorder.callback()));
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

const GarbageResponseServer = struct {
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

fn startGarbageResponseServer() !*GarbageResponseServer {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    const server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch return error.ListenFailed;
    const ctx = try std.testing.allocator.create(GarbageResponseServer);
    errdefer std.testing.allocator.destroy(ctx);
    ctx.* = .{ .io = std.testing.io, .server = server };
    ctx.thread = try std.Thread.spawn(.{}, GarbageResponseServer.serve, .{ctx});
    return ctx;
}

fn stopGarbageResponseServer(ctx: *GarbageResponseServer) void {
    ctx.thread.join();
    ctx.server.deinit(std.testing.io);
    std.testing.allocator.destroy(ctx);
}

test "chatStreaming reports response head failures to the http observer" {
    const ctx = try startGarbageResponseServer();
    defer stopGarbageResponseServer(ctx);

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
    const observer = client.HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);
    c.http_observer = observer;

    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    if (chatStreaming(&c, request, undefined)) |_| {
        return error.ExpectedHeadFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.errors);
}

test "chatStreaming returns Canceled when the stream is cancelled" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" ++
        "data: [DONE]\n\n";
    const ctx = try startChatServer(.ok, body);
    defer stopChatServer(ctx);

    const url = try chatServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);

    const request = ChatRequest{
        .model = "test-model",
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
    const observer = client.HttpObserver{
        .ctx = &observer_ctx,
        .onRequest = null,
        .onResponse = null,
        .onError = ObserverCtx.onError,
    };

    var c = client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);
    c.http_observer = observer;

    const request = ChatRequest{
        .model = "test-model",
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
    const ctx = try startChatServer(.ok, "data: not-json\n\n");
    defer stopChatServer(ctx);

    const url = try chatServerUrl(ctx);
    defer std.testing.allocator.free(url);

    var c = client.Client.init(std.testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.withBaseUrl(url);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var events = std.ArrayList(SseTestEvent).empty;
    var chunks = std.ArrayList([]u8).empty;
    var recorder = SseRecorder{ .allocator = allocator, .events = &events, .chunks = &chunks };

    const request = ChatRequest{
        .model = "test-model",
        .messages = &.{.{ .user = "hi" }},
        .tools = &.{},
    };
    cancel.reset();
    if (chatStreaming(&c, request, recorder.callback())) |_| {
        return error.ExpectedSseParseFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}
