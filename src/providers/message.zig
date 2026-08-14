const std = @import("std");

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
