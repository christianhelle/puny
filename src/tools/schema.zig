const std = @import("std");

fn comptimeJsonType(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "boolean",
        .int, .comptime_int => "integer",
        .float, .comptime_float => "number",
        .optional => |opt| comptimeJsonType(opt.child),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return "string";
            if (ptr.size == .slice) return "array";
            return "string";
        },
        else => "string",
    };
}

pub fn ToolDefinition(comptime name: []const u8, comptime description: []const u8, comptime Params: type) type {
    return struct {
        pub const tool_name = name;
        pub const tool_description = description;
        pub const ParamsType = Params;

        pub fn schema(allocator: std.mem.Allocator) std.mem.Allocator.Error!std.json.Value {
            const json = comptime build: {
                @setEvalBranchQuota(10000);
                var buf: [2048]u8 = undefined;
                var pos: usize = 0;

                const S = struct {
                    fn append(b: *[2048]u8, p: *usize, s: []const u8) void {
                        @memcpy(b.*[p.*..][0..s.len], s);
                        p.* += s.len;
                    }
                };

                S.append(&buf, &pos, "{\"name\":\"");
                S.append(&buf, &pos, name);
                S.append(&buf, &pos, "\",\"description\":\"");
                S.append(&buf, &pos, description);
                S.append(&buf, &pos, "\",\"parameters\":{\"type\":\"object\",\"properties\":{");

                for (std.meta.fields(Params), 0..) |field, i| {
                    if (i > 0) S.append(&buf, &pos, ",");
                    S.append(&buf, &pos, "\"");
                    S.append(&buf, &pos, field.name);
                    S.append(&buf, &pos, "\":{\"type\":\"");
                    S.append(&buf, &pos, comptimeJsonType(field.type));
                    S.append(&buf, &pos, "\",\"description\":\"");
                    S.append(&buf, &pos, field.name);
                    S.append(&buf, &pos, "\"}");
                }

                S.append(&buf, &pos, "}");

                var has_required = false;
                for (std.meta.fields(Params)) |field| {
                    if (@typeInfo(field.type) != .optional) has_required = true;
                }

                if (has_required) {
                    S.append(&buf, &pos, ",\"required\":[");
                    var first = true;
                    for (std.meta.fields(Params)) |field| {
                        if (@typeInfo(field.type) != .optional) {
                            if (!first) S.append(&buf, &pos, ",");
                            S.append(&buf, &pos, "\"");
                            S.append(&buf, &pos, field.name);
                            S.append(&buf, &pos, "\"");
                            first = false;
                        }
                    }
                    S.append(&buf, &pos, "]");
                }

                S.append(&buf, &pos, "}}");

                const len = pos;
                var result: [len]u8 = undefined;
                @memcpy(&result, buf[0..len]);
                break :build result;
            };
            return std.json.parseFromSliceLeaky(std.json.Value, allocator, &json, .{}) catch unreachable;
        }
    };
}

const TestParams = struct {
    path: []const u8,
    recursive: bool,
    count: i32,
    tags: []const []const u8,
    limit: ?i32 = null,
};

test "schema generation" {
    const Schema = ToolDefinition("test_tool", "A test tool.", TestParams);
    const schema_value = try Schema.schema(std.testing.allocator);

    try std.testing.expectEqualStrings("test_tool", schema_value.object.get("name").?.string);
    try std.testing.expectEqualStrings("A test tool.", schema_value.object.get("description").?.string);
    const params = schema_value.object.get("parameters").?.object;
    const props = params.get("properties").?.object;
    try std.testing.expectEqualStrings("string", props.get("path").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("boolean", props.get("recursive").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("integer", props.get("count").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("array", props.get("tags").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("integer", props.get("limit").?.object.get("type").?.string);

    const required = params.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 4), required.items.len);
}

const AllOptionalParams = struct {
    path: ?[]const u8 = null,
    staged: ?bool = null,
};

test "schema omits empty required array" {
    const Schema = ToolDefinition("all_optional", "All params optional.", AllOptionalParams);
    const schema_value = try Schema.schema(std.testing.allocator);
    // Leaky parse is fine for test — schema_json is embedded in binary, allocation is tiny

    const params = schema_value.object.get("parameters").?.object;
    try std.testing.expect(params.get("properties").?.object.count() == 2);
    // Gemini rejects "required": [] with 400 INVALID_ARGUMENT, so it must be absent.
    try std.testing.expect(params.get("required") == null);
}
