const std = @import("std");
const cancel = @import("../core/cancel.zig");
const lmstudio = @import("lmstudio.zig");
const openai = @import("openai.zig");

fn newObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

fn appendTextContent(allocator: std.mem.Allocator, arr: *std.json.Array, text: []const u8) !void {
    if (text.len == 0) return;
    var block = try newObject(allocator);
    try block.put(allocator, "type", .{ .string = "text" });
    try block.put(allocator, "text", .{ .string = text });
    try arr.append(.{ .object = block });
}

pub fn chatStreaming(client: *lmstudio.Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    const allocator = client.allocator;
    const payload = try requestPayload(allocator, request);
    defer allocator.free(payload);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{client.base_url});
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Accept", .value = "text/event-stream" });
    try headers.append(allocator, .{ .name = "anthropic-version", .value = "2023-06-01" });

    if (client.api_key.len > 0) {
        try headers.append(allocator, .{ .name = "x-api-key", .value = client.api_key });
    }

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
    const reader = response.reader(&transfer_buffer);

    if (response.head.status.class() != .success) {
        var body_alloc: std.Io.Writer.Allocating = .init(allocator);
        defer body_alloc.deinit();
        _ = reader.streamRemaining(&body_alloc.writer) catch {};

        if (lmstudio.isAuthFailure(response.head.status)) {
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

    var sse = AnthropicSseCallback{
        .allocator = allocator,
        .callback = callback,
    };
    lmstudio.parseSseReader(allocator, reader, &sse) catch |err| switch (err) {
        error.ReadFailed => {
            if (cancel.isCancelled()) return error.Canceled;
            return err;
        },
        else => return err,
    };
}

const AnthropicSseCallback = struct {
    allocator: std.mem.Allocator,
    callback: openai.StreamCallback,

    pub fn event(self: *@This(), data: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const root = parsed.value.object;

        const type_value = root.get("type") orelse return;
        if (type_value != .string) return;
        const ev_type = type_value.string;

        if (std.mem.eql(u8, ev_type, "content_block_start")) {
            const index = getUsize(root.get("index")) orelse 0;
            const block_value = root.get("content_block") orelse return;
            if (block_value != .object) return;
            const block = block_value.object;
            const block_type = getString(block.get("type")) orelse return;
            if (std.mem.eql(u8, block_type, "tool_use")) {
                const id = getString(block.get("id")) orelse "";
                const name = getString(block.get("name")) orelse "";
                if (id.len > 0 and name.len > 0) {
                    try self.callback.emit(.{ .tool_call_start = .{
                        .index = index,
                        .id = id,
                        .name = name,
                    } });
                }
                if (block.get("input")) |input| {
                    const args_json = try stringifyJson(self.allocator, input);
                    defer self.allocator.free(args_json);
                    if (args_json.len > 0) {
                        try self.callback.emit(.{ .tool_call_delta = .{
                            .index = index,
                            .arguments = args_json,
                        } });
                    }
                }
            }
            return;
        }

        if (std.mem.eql(u8, ev_type, "content_block_delta")) {
            const index = getUsize(root.get("index")) orelse 0;
            const delta_value = root.get("delta") orelse return;
            if (delta_value != .object) return;
            const delta = delta_value.object;
            const delta_type = getString(delta.get("type")) orelse return;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                if (getString(delta.get("text"))) |text| {
                    try self.callback.emit(.{ .content = text });
                }
                return;
            }
            if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                if (getString(delta.get("partial_json"))) |partial_json| {
                    try self.callback.emit(.{ .tool_call_delta = .{
                        .index = index,
                        .arguments = partial_json,
                    } });
                }
                return;
            }
            return;
        }

        if (std.mem.eql(u8, ev_type, "message_start")) {
            const message_value = root.get("message") orelse return;
            if (message_value != .object) return;
            if (message_value.object.get("usage")) |usage| {
                try emitUsage(self.callback, usage);
            }
            return;
        }

        if (std.mem.eql(u8, ev_type, "message_delta")) {
            if (root.get("usage")) |usage| {
                try emitUsage(self.callback, usage);
            }
            return;
        }

        if (std.mem.eql(u8, ev_type, "message_stop")) {
            try self.callback.emit(.{ .finish = null });
            return;
        }
    }
};

fn emitUsage(callback: openai.StreamCallback, usage_value: std.json.Value) !void {
    if (usage_value != .object) return;
    const usage = usage_value.object;
    const input_tokens = getI64(usage.get("input_tokens")) orelse 0;
    const output_tokens = getI64(usage.get("output_tokens")) orelse 0;
    try callback.emit(.{ .usage = .{
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
    } });
}

fn getString(value: ?std.json.Value) ?[]const u8 {
    if (value == null or value.? != .string) return null;
    return value.?.string;
}

fn getI64(value: ?std.json.Value) ?i64 {
    if (value == null) return null;
    return switch (value.?) {
        .integer => |v| v,
        else => null,
    };
}

fn getUsize(value: ?std.json.Value) ?usize {
    if (value == null) return null;
    return switch (value.?) {
        .integer => |v| if (v < 0) null else @as(usize, @intCast(v)),
        else => null,
    };
}

fn stringifyJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var str: std.Io.Writer.Allocating = .init(allocator);
    defer str.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &str.writer);
    return str.toOwnedSlice();
}

fn requestPayload(allocator: std.mem.Allocator, request: openai.ChatRequest) ![]u8 {
    var system_text = std.array_list.Managed(u8).init(allocator);
    defer system_text.deinit();

    var parsed_tool_inputs = std.array_list.Managed(std.json.Parsed(std.json.Value)).init(allocator);
    defer {
        for (parsed_tool_inputs.items) |*parsed| parsed.deinit();
        parsed_tool_inputs.deinit();
    }

    var messages = try std.json.Array.initCapacity(allocator, request.messages.len);
    for (request.messages) |msg| {
        switch (msg) {
            .system => |text| {
                if (system_text.items.len > 0) {
                    try system_text.appendSlice("\n\n");
                }
                try system_text.appendSlice(text);
            },
            .user => |text| {
                var content = try std.json.Array.initCapacity(allocator, 1);
                try appendTextContent(allocator, &content, text);

                var entry = try newObject(allocator);
                try entry.put(allocator, "role", .{ .string = "user" });
                try entry.put(allocator, "content", .{ .array = content });
                try messages.append(.{ .object = entry });
            },
            .assistant => |assistant| {
                var content = try std.json.Array.initCapacity(allocator, 0);
                if (assistant.content) |text| {
                    try appendTextContent(allocator, &content, text);
                }

                if (assistant.tool_calls) |tool_calls| {
                    for (tool_calls) |tc| {
                        const args_json = if (tc.function.arguments.len == 0) "{}" else tc.function.arguments;
                        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{ .ignore_unknown_fields = true });
                        try parsed_tool_inputs.append(parsed);
                        const parsed_input = parsed_tool_inputs.items[parsed_tool_inputs.items.len - 1].value;
                        const input: std.json.Value = switch (parsed_input) {
                            .object => parsed_input,
                            else => .{ .object = try newObject(allocator) },
                        };

                        var block = try newObject(allocator);
                        try block.put(allocator, "type", .{ .string = "tool_use" });
                        try block.put(allocator, "id", .{ .string = tc.id });
                        try block.put(allocator, "name", .{ .string = tc.function.name });
                        try block.put(allocator, "input", input);
                        try content.append(.{ .object = block });
                    }
                }

                var entry = try newObject(allocator);
                try entry.put(allocator, "role", .{ .string = "assistant" });
                try entry.put(allocator, "content", .{ .array = content });
                try messages.append(.{ .object = entry });
            },
            .tool => |tool| {
                var content = try std.json.Array.initCapacity(allocator, 1);
                var block = try newObject(allocator);
                try block.put(allocator, "type", .{ .string = "tool_result" });
                try block.put(allocator, "tool_use_id", .{ .string = tool.tool_call_id });
                try block.put(allocator, "content", .{ .string = tool.content });
                try content.append(.{ .object = block });

                var entry = try newObject(allocator);
                try entry.put(allocator, "role", .{ .string = "user" });
                try entry.put(allocator, "content", .{ .array = content });
                try messages.append(.{ .object = entry });
            },
        }
    }

    var tools = try std.json.Array.initCapacity(allocator, request.tools.len);
    for (request.tools) |tool| {
        const func = tool.function.object;
        const name = getString(func.get("name")) orelse continue;
        const description = getString(func.get("description")) orelse "";
        const parameters = func.get("parameters") orelse .{ .object = try newObject(allocator) };

        var tool_obj = try newObject(allocator);
        try tool_obj.put(allocator, "name", .{ .string = name });
        try tool_obj.put(allocator, "description", .{ .string = description });
        try tool_obj.put(allocator, "input_schema", parameters);
        try tools.append(.{ .object = tool_obj });
    }

    var body = try newObject(allocator);
    try body.put(allocator, "model", .{ .string = request.model });
    try body.put(allocator, "messages", .{ .array = messages });
    try body.put(allocator, "stream", .{ .bool = request.stream });
    try body.put(allocator, "max_tokens", .{ .integer = 8192 });

    if (system_text.items.len > 0) {
        try body.put(allocator, "system", .{ .string = system_text.items });
    }
    if (tools.items.len > 0) {
        try body.put(allocator, "tools", .{ .array = tools });
    }
    if (request.temperature) |temperature| {
        try body.put(allocator, "temperature", .{ .float = temperature });
    }

    var str: std.Io.Writer.Allocating = .init(allocator);
    defer str.deinit();
    try std.json.Stringify.value(.{ .object = body }, .{ .emit_null_optional_fields = false }, &str.writer);
    return str.toOwnedSlice();
}
