const std = @import("std");
const lmstudio = @import("lmstudio.zig");

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

pub const Message = union(enum) {
    system: []const u8,
    user: []const u8,
    assistant: AssistantContent,
    tool: ToolResult,

    pub fn toJson(self: Message, allocator: std.mem.Allocator) !std.json.Value {
        return switch (self) {
            .system => |content| .{
                .object = try std.json.ObjectMap.init(allocator, &.{
                    .{ "role", .{ .string = "system" } },
                    .{ "content", .{ .string = content } },
                }, &.{}),
            },
            .user => |content| .{
                .object = try std.json.ObjectMap.init(allocator, &.{
                    .{ "role", .{ .string = "user" } },
                    .{ "content", .{ .string = content } },
                }, &.{}),
            },
            .assistant => |assistant| blk: {
                var obj = try std.json.ObjectMap.init(allocator, &.{
                    .{ "role", .{ .string = "assistant" } },
                }, &.{});
                if (assistant.content) |content| {
                    try obj.put(allocator, "content", .{ .string = content });
                } else {
                    try obj.put(allocator, "content", .{ .null = {} });
                }
                if (assistant.tool_calls) |tool_calls| {
                    var arr = try std.json.Array.initCapacity(allocator, tool_calls.len);
                    for (tool_calls) |tc| {
                        const tc_obj = try std.json.ObjectMap.init(allocator, &.{
                            .{ "id", .{ .string = tc.id } },
                            .{ "type", .{ .string = tc.type } },
                            .{
                                "function",
                                .{
                                    .object = try std.json.ObjectMap.init(allocator, &.{
                                        .{ "name", .{ .string = tc.function.name } },
                                        .{ "arguments", .{ .string = tc.function.arguments } },
                                    }, &.{}),
                                },
                            },
                        }, &.{});
                        try arr.append(.{ .object = tc_obj });
                    }
                    try obj.put(allocator, "tool_calls", .{ .array = arr });
                }
                break :blk .{ .object = obj };
            },
            .tool => |tool| .{
                .object = try std.json.ObjectMap.init(allocator, &.{
                    .{ "role", .{ .string = "tool" } },
                    .{ "tool_call_id", .{ .string = tool.tool_call_id } },
                    .{ "content", .{ .string = tool.content } },
                }, &.{}),
            },
        };
    }
};

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

const StreamChunk = struct {
    choices: []const DeltaChoice,
};

const SseCallback = struct {
    allocator: std.mem.Allocator,
    callback: StreamCallback,

    pub fn event(self: *@This(), data: []const u8) !void {
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
    }
};

pub fn chatStreaming(client: *lmstudio.Client, request: ChatRequest, callback: StreamCallback) !void {
    const allocator = client.allocator;
    const payload = try requestPayload(allocator, request);
    defer allocator.free(payload);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{client.base_url});
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try lmstudio.appendClientHeaders(allocator, &headers, client, "application/json", "text/event-stream");
    defer if (auth_header) |value| allocator.free(value);

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
    if (response.head.status.class() != .success) return error.ResponseError;

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var sse = SseCallback{
        .allocator = allocator,
        .callback = callback,
    };

    try lmstudio.parseSseReader(allocator, reader, &sse);
}

test "message JSON conversion" {
    const allocator = std.testing.allocator;

    const system_msg = try (Message{ .system = "You are a helpful assistant." }).toJson(allocator);
    try std.testing.expectEqualStrings("system", system_msg.object.get("role").?.string);
    try std.testing.expectEqualStrings("You are a helpful assistant.", system_msg.object.get("content").?.string);
    system_msg.object.deinit(allocator);

    const tool_msg = try (Message{ .tool = .{ .tool_call_id = "call_1", .content = "result" } }).toJson(allocator);
    try std.testing.expectEqualStrings("tool", tool_msg.object.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", tool_msg.object.get("tool_call_id").?.string);
    tool_msg.object.deinit(allocator);
}

fn requestPayload(allocator: std.mem.Allocator, request: ChatRequest) ![]u8 {
    var messages = try std.json.Array.initCapacity(allocator, request.messages.len);
    for (request.messages) |msg| {
        try messages.append(try msg.toJson(allocator));
    }

    var tools = try std.json.Array.initCapacity(allocator, request.tools.len);
    for (request.tools) |tool| {
        try tools.append(.{
            .object = try std.json.ObjectMap.init(allocator, &.{
                .{ "type", .{ .string = tool.type } },
                .{ "function", tool.function },
            }, &.{}),
        });
    }

    var body_obj = try std.json.ObjectMap.init(allocator, &.{
        .{ "model", .{ .string = request.model } },
        .{ "messages", .{ .array = messages } },
        .{ "tools", .{ .array = tools } },
        .{ "stream", .{ .bool = request.stream } },
    }, &.{});

    if (request.temperature) |temperature| {
        try body_obj.put(allocator, "temperature", .{ .float = temperature });
    }

    var str: std.Io.Writer.Allocating = .init(allocator);
    defer str.deinit();
    try std.json.Stringify.value(.{ .object = body_obj }, .{ .emit_null_optional_fields = false }, &str.writer);
    return str.toOwnedSlice();
}
