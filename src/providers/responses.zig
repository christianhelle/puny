const std = @import("std");
const cancel = @import("../core/cancel.zig");
const client = @import("client.zig");
const openai = @import("openai.zig");
const message = @import("message.zig");

pub const ChatRequest = openai.ChatRequest;
pub const StreamEvent = openai.StreamEvent;
pub const StreamCallback = openai.StreamCallback;
pub const ReasoningEffort = openai.ReasoningEffort;

// Reuse openai's CancelableReader but we need it for responses streaming
pub const CancelableReader = openai.CancelableReader;

pub const ResponsesSseCallback = struct {
    allocator: std.mem.Allocator,
    callback: StreamCallback,
    observer: ?client.HttpObserver = null,
    // Track function call name by output_index for delta correlation
    // Simple fixed map for up to 32 simultaneous tool calls
    tool_names: [32][]const u8 = [_][]const u8{""} ** 32,
    tool_ids: [32][]const u8 = [_][]const u8{""} ** 32,

    pub fn event(self: *@This(), data: []const u8) !void {
        if (self.observer) |obs| {
            if (obs.on_chunk) |cb| cb(obs.ctx, data);
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        const typ_val = obj.get("type") orelse return;
        if (typ_val != .string) return;
        const typ = typ_val.string;

        // Text delta -> content
        if (std.mem.eql(u8, typ, "response.output_text.delta")) {
            if (obj.get("delta")) |d| {
                if (d == .string) {
                    try self.callback.emit(.{ .content = d.string });
                }
            }
            return;
        }

        // Reasoning deltas
        if (std.mem.eql(u8, typ, "response.reasoning_text.delta") or std.mem.eql(u8, typ, "response.reasoning_summary_text.delta")) {
            if (obj.get("delta")) |d| {
                if (d == .string) {
                    try self.callback.emit(.{ .reasoning = d.string });
                }
            }
            return;
        }

        // Refusal delta - treat as content
        if (std.mem.eql(u8, typ, "response.refusal.delta")) {
            if (obj.get("delta")) |d| {
                if (d == .string) {
                    try self.callback.emit(.{ .content = d.string });
                }
            }
            return;
        }

        // Output item added - detect function_call
        if (std.mem.eql(u8, typ, "response.output_item.added")) {
            const item_val = obj.get("item") orelse return;
            if (item_val != .object) return;
            const item = item_val.object;
            const item_type_val = item.get("type") orelse return;
            if (item_type_val != .string) return;
            if (!std.mem.eql(u8, item_type_val.string, "function_call")) return;

            const output_index: usize = if (obj.get("output_index")) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => 0,
            } else 0;

            const call_id: []const u8 = if (item.get("call_id")) |v| switch (v) {
                .string => |s| s,
                else => "",
            } else if (item.get("id")) |v| switch (v) {
                .string => |s| s,
                else => "",
            } else "";

            const name: []const u8 = if (item.get("name")) |v| switch (v) {
                .string => |s| s,
                else => "",
            } else "";

            // Store for later deltas
            if (output_index < self.tool_names.len) {
                // We need to dupe to keep alive beyond this callback - but callback expects slice valid only during emit
                // We'll store duped slices in allocator and leak for duration? Simpler: keep reference to parsed string which is owned by parsed arena - not safe after defer.
                // Instead we store by duplicating into allocator and managing lifecycle - for test simplicity, we emit directly without long storage
                // For now, store empty; but emit.
            }

            if (call_id.len > 0 or name.len > 0) {
                try self.callback.emit(.{ .tool_call_start = .{ .index = output_index, .id = call_id, .name = name } });
                // Check if arguments already present in added event
                if (item.get("arguments")) |args_val| {
                    if (args_val == .string and args_val.string.len > 0) {
                        try self.callback.emit(.{ .tool_call_delta = .{ .index = output_index, .arguments = args_val.string } });
                    }
                }
            }
            return;
        }

        // Function call arguments delta
        if (std.mem.eql(u8, typ, "response.function_call_arguments.delta")) {
            const output_index: usize = if (obj.get("output_index")) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => 0,
            } else 0;
            if (obj.get("delta")) |d| {
                if (d == .string and d.string.len > 0) {
                    try self.callback.emit(.{ .tool_call_delta = .{ .index = output_index, .arguments = d.string } });
                }
            }
            return;
        }

        // Also handle custom tool call input delta
        if (std.mem.eql(u8, typ, "response.custom_tool_call_input.delta")) {
            const output_index: usize = if (obj.get("output_index")) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => 0,
            } else 0;
            if (obj.get("delta")) |d| {
                if (d == .string and d.string.len > 0) {
                    try self.callback.emit(.{ .tool_call_delta = .{ .index = output_index, .arguments = d.string } });
                }
            }
            return;
        }

        // For completed / failed etc - emit finish and usage
        if (std.mem.eql(u8, typ, "response.completed") or std.mem.eql(u8, typ, "response.incomplete") or std.mem.eql(u8, typ, "response.failed")) {
            // Try to extract usage from response object
            if (obj.get("response")) |resp_val| {
                if (resp_val == .object) {
                    const resp_obj = resp_val.object;
                    if (resp_obj.get("usage")) |usage_val| {
                        if (usage_val == .object) {
                            const usage_obj = usage_val.object;
                            const input_tokens: i64 = if (usage_obj.get("input_tokens")) |v| switch (v) {
                                .integer => |i| i,
                                else => 0,
                            } else 0;
                            const output_tokens: i64 = if (usage_obj.get("output_tokens")) |v| switch (v) {
                                .integer => |i| i,
                                else => 0,
                            } else 0;
                            // Try nested reasoning tokens
                            var reasoning_output_tokens: ?i64 = null;
                            if (usage_obj.get("output_tokens_details")) |details| {
                                if (details == .object) {
                                    if (details.object.get("reasoning_tokens")) |rt| {
                                        if (rt == .integer) reasoning_output_tokens = rt.integer;
                                    }
                                }
                            }
                            try self.callback.emit(.{ .usage = .{
                                .input_tokens = input_tokens,
                                .output_tokens = output_tokens,
                                .reasoning_output_tokens = reasoning_output_tokens,
                                .tokens_per_second = null,
                                .time_to_first_token_seconds = null,
                            } });
                        }
                    }
                }
            }
            // Also emit finish
            const finish: ?[]const u8 = if (std.mem.eql(u8, typ, "response.completed")) "stop" else typ;
            try self.callback.emit(.{ .finish = finish });
            return;
        }

        // response.output_item.done for function_call with final args - already handled as delta? Emit if needed
        if (std.mem.eql(u8, typ, "response.output_item.done")) {
            const item_val = obj.get("item") orelse return;
            if (item_val != .object) return;
            const item = item_val.object;
            const item_type_val = item.get("type") orelse return;
            if (item_type_val != .string) return;
            if (!std.mem.eql(u8, item_type_val.string, "function_call")) return;
            const output_index: usize = if (obj.get("output_index")) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => 0,
            } else 0;
            // If arguments present and we haven't emitted, emit as delta
            // This handles case where incremental deltas were not sent but final done contains full args
            // To avoid duplicate, we could check but simpler: if delta not already sent via previous deltas, the streaming may have already covered.
            // We'll not emit here to avoid duplication; but if you rely on done for completeness, uncomment.
            _ = output_index;
            return;
        }

        // Ignore other types: response.created, response.in_progress, response.queued, response.content_part.*, etc.
    }
};

pub fn responsesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        return std.fmt.allocPrint(allocator, "{s}/responses", .{trimmed});
    }
    return std.fmt.allocPrint(allocator, "{s}/v1/responses", .{trimmed});
}

pub fn responsesRequestPayload(allocator: std.mem.Allocator, request: ChatRequest) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, w);

    try w.writeAll(",\"input\":[");
    // Build input items with proper comma handling
    {
        var first = true;
        for (request.messages) |msg| {
            switch (msg) {
                .system => |content| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeAll("{\"type\":\"message\",\"role\":\"system\",\"content\":");
                    try std.json.Stringify.value(content, .{}, w);
                    try w.writeByte('}');
                },
                .user => |content| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(content, .{}, w);
                    try w.writeByte('}');
                },
                .assistant => |assistant| {
                    if (assistant.content) |content| {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":");
                        try std.json.Stringify.value(content, .{}, w);
                        try w.writeByte('}');
                    }
                    if (assistant.tool_calls) |tool_calls| {
                        for (tool_calls) |tc| {
                            if (!first) try w.writeByte(',');
                            first = false;
                            try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
                            try std.json.Stringify.value(tc.id, .{}, w);
                            try w.writeAll(",\"name\":");
                            try std.json.Stringify.value(tc.function.name, .{}, w);
                            try w.writeAll(",\"arguments\":");
                            try std.json.Stringify.value(tc.function.arguments, .{}, w);
                            try w.writeByte('}');
                        }
                    }
                    // If assistant has neither content nor tool_calls, still emit empty message to preserve turn?
                    if (assistant.content == null and assistant.tool_calls == null) {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":null}");
                    }
                },
                .tool => |tool| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                    try std.json.Stringify.value(tool.tool_call_id, .{}, w);
                    try w.writeAll(",\"output\":");
                    try std.json.Stringify.value(tool.content, .{}, w);
                    try w.writeByte('}');
                },
            }
        }
    }
    try w.writeByte(']');

    // Tools array for Responses: flatten Chat's ToolDefinition.function object
    try w.writeAll(",\"tools\":[");
    for (request.tools, 0..) |tool, idx| {
        if (idx > 0) try w.writeByte(',');
        // tool.function is a std.json.Value containing name, description, parameters, maybe strict
        // Extract fields
        var name: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        var parameters: ?std.json.Value = null;
        var strict: ?bool = null;
        if (tool.function == .object) {
            const obj = tool.function.object;
            if (obj.get("name")) |v| {
                if (v == .string) name = v.string;
            }
            if (obj.get("description")) |v| {
                if (v == .string) description = v.string;
            }
            if (obj.get("parameters")) |v| parameters = v;
            if (obj.get("strict")) |v| {
                if (v == .bool) strict = v.bool;
            }
        }
        try w.writeAll("{\"type\":\"function\"");
        if (name) |n| {
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(n, .{}, w);
        }
        if (description) |d| {
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(d, .{}, w);
        }
        if (parameters) |p| {
            // Ensure strict mode compliance: 'required' must include every property key and 'additionalProperties' false
            if (p == .object) {
                if (p.object.get("properties")) |props_val| {
                    if (props_val == .object) {
                        const props = props_val.object;
                        try w.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":");
                        try std.json.Stringify.value(std.json.Value{ .object = props }, .{}, w);
                        try w.writeAll(",\"required\":[");
                        var first_req = true;
                        var prop_it = props.iterator();
                        while (prop_it.next()) |entry| {
                            if (!first_req) try w.writeByte(',');
                            first_req = false;
                            try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
                        }
                        try w.writeAll("],\"additionalProperties\":false}");
                    } else {
                        // properties not an object, fallback to ensure additionalProperties
                        if (p.object.get("additionalProperties") == null) {
                            try w.writeAll(",\"parameters\":{");
                            var first = true;
                            var it = p.object.iterator();
                            while (it.next()) |entry| {
                                if (!first) try w.writeByte(',');
                                first = false;
                                try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
                                try w.writeByte(':');
                                try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
                            }
                            if (!first) try w.writeByte(',');
                            try w.writeAll("\"additionalProperties\":false}");
                        } else {
                            try w.writeAll(",\"parameters\":");
                            try std.json.Stringify.value(p, .{}, w);
                        }
                    }
                } else {
                    // no properties, ensure additionalProperties
                    if (p.object.get("additionalProperties") == null) {
                        try w.writeAll(",\"parameters\":{");
                        var first = true;
                        var it = p.object.iterator();
                        while (it.next()) |entry| {
                            if (!first) try w.writeByte(',');
                            first = false;
                            try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
                            try w.writeByte(':');
                            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
                        }
                        if (!first) try w.writeByte(',');
                        try w.writeAll("\"additionalProperties\":false}");
                    } else {
                        try w.writeAll(",\"parameters\":");
                        try std.json.Stringify.value(p, .{}, w);
                    }
                }
            } else {
                try w.writeAll(",\"parameters\":");
                try std.json.Stringify.value(p, .{}, w);
            }
        } else {
            try w.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}");
        }
        // strict defaults to true if not specified
        try w.writeAll(",\"strict\":");
        try std.json.Stringify.value(strict orelse true, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    try w.writeAll(",\"stream\":true");

    if (request.temperature) |temp| {
        try w.writeAll(",\"temperature\":");
        try std.json.Stringify.value(temp, .{}, w);
    }

    if (request.reasoning_effort) |effort| {
        if (effort != .default) {
            try w.writeAll(",\"reasoning\":{\"effort\":\"");
            try w.writeAll(@tagName(effort));
            try w.writeAll("\"}");
        }
    }

    try w.writeByte('}');

    return buf.toOwnedSlice();
}

pub fn chatStreamingResponses(chat_client: *client.Client, request: ChatRequest, callback: StreamCallback) !void {
    const allocator = chat_client.allocator;
    const payload = try responsesRequestPayload(allocator, request);
    defer allocator.free(payload);

    const url = try responsesUrl(allocator, chat_client.base_url);
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

    var done = std.atomic.Value(bool).init(false);
    var watcher_ctx = client.CancelWatcher{ .connection = req.connection, .io = chat_client.io, .pred = cancel.isCancelled, .done = &done };
    const watcher_thread: ?std.Thread = std.Thread.spawn(.{}, client.CancelWatcher.run, .{&watcher_ctx}) catch null;
    defer if (watcher_thread) |t| {
        done.store(true, .release);
        t.join();
        watcher_ctx.restoreConnection();
    };

    var cancelable_reader_buffer: [1]u8 = undefined;
    var cancelable_reader = CancelableReader.init(response_reader, &cancelable_reader_buffer);
    const reader = &cancelable_reader.reader;

    if (response.head.status.class() != .success) {
        var body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer body_alloc.deinit();
        _ = reader.streamRemaining(&body_alloc.writer) catch |err| {
            if (chat_client.http_observer) |obs| {
                if (obs.onError) |cb| cb(obs.ctx, .POST, url, @errorName(err));
            }
            if (cancel.isCancelled()) return error.Canceled;
            return response.bodyErr() orelse err;
        };

        if (chat_client.http_observer) |obs| {
            if (obs.onResponse) |cb| cb(obs.ctx, .POST, url, response.head.status, &.{}, body_alloc.written(), elapsed_ns);
        }

        if (response.head.status == .unauthorized or response.head.status == .forbidden) {
            client.printAuthHint(chat_client.io);
        }

        client.emitDiagnostic("OpenAI responses request failed\n  URL: {s}\n  Status: {d}\n  Payload: {s}\n  Response: {s}\n", .{
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

    var sse = ResponsesSseCallback{
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

// --- Tests ---

test "responsesUrl normalizes trailing slash" {
    const cases = [_]struct { base: []const u8, expected: []const u8 }{
        .{ .base = "http://127.0.0.1:1234", .expected = "http://127.0.0.1:1234/v1/responses" },
        .{ .base = "http://127.0.0.1:1234/", .expected = "http://127.0.0.1:1234/v1/responses" },
        .{ .base = "http://127.0.0.1:1234/v1", .expected = "http://127.0.0.1:1234/v1/responses" },
        .{ .base = "http://127.0.0.1:1234/v1/", .expected = "http://127.0.0.1:1234/v1/responses" },
        .{ .base = "https://opencode.ai/zen/go", .expected = "https://opencode.ai/zen/go/v1/responses" },
    };
    for (cases) |c| {
        const url = try responsesUrl(std.testing.allocator, c.base);
        defer std.testing.allocator.free(url);
        try std.testing.expectEqualStrings(c.expected, url);
    }
}

test "responsesRequestPayload maps system user assistant and tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"name\":\"read_file\",\"description\":\"Read a file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}",
        .{},
    );

    const request = ChatRequest{
        .model = "muse-spark-1.2-contributor",
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
        .reasoning_effort = .low,
    };

    const payload = try responsesRequestPayload(std.testing.allocator, request);
    defer std.testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("muse-spark-1.2-contributor", root.get("model").?.string);
    try std.testing.expectEqual(true, root.get("stream").?.bool);
    try std.testing.expectEqual(@as(f64, 0.7), root.get("temperature").?.float);

    const input = root.get("input").?.array;
    try std.testing.expectEqual(@as(usize, 4), input.items.len);
    try std.testing.expectEqualStrings("system", input.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", input.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("function_call", input.items[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input.items[2].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("function_call_output", input.items[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input.items[3].object.get("call_id").?.string);

    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    const tool_obj = tools.items[0].object;
    try std.testing.expectEqualStrings("function", tool_obj.get("type").?.string);
    try std.testing.expectEqualStrings("read_file", tool_obj.get("name").?.string);
    try std.testing.expect(tool_obj.get("strict").?.bool == true);

    const reasoning = root.get("reasoning").?.object;
    try std.testing.expectEqualStrings("low", reasoning.get("effort").?.string);
}

test "responsesRequestPayload omits reasoning when default" {
    const request = ChatRequest{
        .model = "muse-spark-1.2-contributor",
        .messages = &.{},
        .tools = &.{},
        .reasoning_effort = .default,
    };
    const payload = try responsesRequestPayload(std.testing.allocator, request);
    defer std.testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("reasoning") == null);
}

test "responsesRequestPayload handles minimal and xhigh reasoning" {
    for ([_]ReasoningEffort{ .minimal, .high, .xhigh }) |effort| {
        const request = ChatRequest{
            .model = "muse-spark-1.2-contributor",
            .messages = &.{},
            .tools = &.{},
            .reasoning_effort = effort,
        };
        const payload = try responsesRequestPayload(std.testing.allocator, request);
        defer std.testing.allocator.free(payload);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings(@tagName(effort), parsed.value.object.get("reasoning").?.object.get("effort").?.string);
    }
}

test "ResponsesSseCallback emits content and tool events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const SseTestEvent = union(enum) {
        content: []const u8,
        reasoning: []const u8,
        tool_call_start: struct { index: usize, id: []const u8, name: []const u8 },
        tool_call_delta: struct { index: usize, arguments: []const u8 },
        finish: ?[]const u8,
        usage: openai.TurnUsage,
    };

    var events = std.ArrayList(SseTestEvent).empty;

    const Recorder = struct {
        allocator: std.mem.Allocator,
        events: *std.ArrayList(SseTestEvent),
        fn callback(self: *@This()) StreamCallback {
            return .{
                .context = self,
                .vtable = &.{
                    .event = event,
                    .reset = null,
                },
            };
        }
        fn event(ctx: *anyopaque, ev: StreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .content => |v| try self.events.append(self.allocator, .{ .content = try self.allocator.dupe(u8, v) }),
                .reasoning => |v| try self.events.append(self.allocator, .{ .reasoning = try self.allocator.dupe(u8, v) }),
                .tool_call_start => |v| try self.events.append(self.allocator, .{ .tool_call_start = .{ .index = v.index, .id = try self.allocator.dupe(u8, v.id), .name = try self.allocator.dupe(u8, v.name) } }),
                .tool_call_delta => |v| try self.events.append(self.allocator, .{ .tool_call_delta = .{ .index = v.index, .arguments = try self.allocator.dupe(u8, v.arguments) } }),
                .finish => |v| try self.events.append(self.allocator, .{ .finish = if (v) |s| try self.allocator.dupe(u8, s) else null }),
                .usage => |v| try self.events.append(self.allocator, .{ .usage = v }),
            }
        }
    };

    var recorder = Recorder{ .allocator = allocator, .events = &events };
    var sse = ResponsesSseCallback{ .allocator = allocator, .callback = recorder.callback() };

    try sse.event("{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\",\"sequence_number\":1,\"logprobs\":[]}");
    try sse.event("{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\" world\",\"sequence_number\":2,\"logprobs\":[]}");
    try sse.event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"sequence_number\":3,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_123\",\"name\":\"read_file\",\"arguments\":\"\",\"status\":\"in_progress\"}}");
    try sse.event("{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"{\\\"path\\\":\",\"sequence_number\":4}");
    try sse.event("{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"\\\"src/main.zig\\\"}\",\"sequence_number\":5}");
    try sse.event("{\"type\":\"response.reasoning_text.delta\",\"item_id\":\"rs_1\",\"output_index\":1,\"content_index\":0,\"delta\":\"think\",\"sequence_number\":6}");
    try sse.event("{\"type\":\"response.completed\",\"sequence_number\":7,\"response\":{\"id\":\"resp_123\",\"object\":\"response\",\"created_at\":123,\"status\":\"completed\",\"model\":\"muse-spark-1.2-contributor\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"total_tokens\":30}}}");

    try std.testing.expectEqual(@as(usize, 8), events.items.len);
    try std.testing.expectEqualStrings("Hello", events.items[0].content);
    try std.testing.expectEqualStrings(" world", events.items[1].content);
    try std.testing.expectEqualStrings("call_123", events.items[2].tool_call_start.id);
    try std.testing.expectEqualStrings("read_file", events.items[2].tool_call_start.name);
    try std.testing.expectEqualStrings("{\"path\":", events.items[3].tool_call_delta.arguments);
    try std.testing.expectEqualStrings("\"src/main.zig\"}", events.items[4].tool_call_delta.arguments);
    try std.testing.expectEqualStrings("think", events.items[5].reasoning);
    try std.testing.expectEqual(@as(i64, 10), events.items[6].usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 20), events.items[6].usage.output_tokens);
    try std.testing.expectEqualStrings("stop", events.items[7].finish.?);
}

test "ResponsesSseCallback handles output at streaming server" {
    // Integration-like: ensure parsing multiple events via client.parseSseReader works
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const SseTestEvent = union(enum) {
        content: []const u8,
        usage: openai.TurnUsage,
        finish: ?[]const u8,
    };
    var events = std.ArrayList(SseTestEvent).empty;
    const Recorder = struct {
        allocator: std.mem.Allocator,
        events: *std.ArrayList(SseTestEvent),
        fn callback(self: *@This()) StreamCallback {
            return .{ .context = self, .vtable = &.{ .event = event } };
        }
        fn event(ctx: *anyopaque, ev: StreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .content => |v| try self.events.append(self.allocator, .{ .content = try self.allocator.dupe(u8, v) }),
                .usage => |v| try self.events.append(self.allocator, .{ .usage = v }),
                .finish => |v| try self.events.append(self.allocator, .{ .finish = if (v) |s| try self.allocator.dupe(u8, s) else null }),
                else => {},
            }
        }
    };
    var recorder = Recorder{ .allocator = allocator, .events = &events };
    var sse = ResponsesSseCallback{ .allocator = allocator, .callback = recorder.callback() };
    const data =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hi\",\"sequence_number\":1,\"logprobs\":[]}\n\n" ++
        "data: {\"type\":\"response.completed\",\"sequence_number\":2,\"response\":{\"id\":\"resp_123\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"x\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}}\n\n" ++
        "data: [DONE]\n\n";
    try client.parseSseBytes(allocator, data, &sse, null);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
}
