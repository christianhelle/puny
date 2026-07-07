const std = @import("std");

fn newObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

pub fn schemaForType(allocator: std.mem.Allocator, comptime T: type, comptime field_name: []const u8) !std.json.Value {
    switch (@typeInfo(T)) {
        .bool => return propertyObject(allocator, "boolean", field_name),
        .int, .comptime_int => return propertyObject(allocator, "integer", field_name),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return propertyObject(allocator, "string", field_name);
            }
            if (ptr.size == .slice) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .pointer and child_info.pointer.size == .slice and child_info.pointer.child == u8) {
                    var obj = try newObject(allocator);
                    try obj.put(allocator, "type", .{ .string = "array" });
                    try obj.put(allocator, "description", .{ .string = field_name });
                    const items = try newObject(allocator);
                    try items.put(allocator, "type", .{ .string = "string" });
                    try obj.put(allocator, "items", .{ .object = items });
                    return .{ .object = obj };
                }
            }
        },
        else => {},
    }
    return .{ .object = try newObject(allocator) };
}

fn propertyObject(allocator: std.mem.Allocator, type_name: []const u8, description: []const u8) !std.json.Value {
    var obj = try newObject(allocator);
    try obj.put(allocator, "type", .{ .string = type_name });
    try obj.put(allocator, "description", .{ .string = description });
    return .{ .object = obj };
}

pub fn fromStruct(allocator: std.mem.Allocator, comptime T: type) !std.json.Value {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        return .{ .object = try newObject(allocator) };
    }

    var properties = try newObject(allocator);
    var required = try std.json.Array.initCapacity(allocator, info.@"struct".fields.len);

    inline for (info.@"struct".fields) |field| {
        const field_schema = try schemaForType(allocator, field.type, field.name);
        try properties.put(allocator, field.name, field_schema);
        try required.append(.{ .string = field.name });
    }

    var obj = try newObject(allocator);
    try obj.put(allocator, "type", .{ .string = "object" });
    try obj.put(allocator, "properties", .{ .object = properties });
    try obj.put(allocator, "required", .{ .array = required });
    return .{ .object = obj };
}

pub fn ToolDefinition(comptime name: []const u8, comptime description: []const u8, comptime Params: type) type {
    return struct {
        pub const tool_name = name;
        pub const tool_description = description;
        pub const ParamsType = Params;

        pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
            const parameters = try fromStruct(allocator, Params);

            var func = try newObject(allocator);
            try func.put(allocator, "name", .{ .string = name });
            try func.put(allocator, "description", .{ .string = description });
            try func.put(allocator, "parameters", parameters);

            var obj = try newObject(allocator);
            try obj.put(allocator, "type", .{ .string = "function" });
            try obj.put(allocator, "function", .{ .object = func });
            return .{ .object = obj };
        }
    };
}

const TestParams = struct {
    path: []const u8,
    recursive: bool,
    count: i32,
    tags: []const []const u8,
};

test "schema generation" {
    const Schema = ToolDefinition("test_tool", "A test tool.", TestParams);
    const schema_value = try Schema.schema(std.testing.allocator);
    defer freeSchema(std.testing.allocator, schema_value);

    try std.testing.expectEqualStrings("function", schema_value.object.get("type").?.string);
    const func = schema_value.object.get("function").?.object;
    try std.testing.expectEqualStrings("test_tool", func.get("name").?.string);
    const params = func.get("parameters").?.object;
    const props = params.get("properties").?.object;
    try std.testing.expectEqualStrings("string", props.get("path").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("boolean", props.get("recursive").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("integer", props.get("count").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("array", props.get("tags").?.object.get("type").?.string);
}

fn freeSchema(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                freeSchema(allocator, entry.value);
            }
            obj.deinit(allocator);
        },
        .array => |arr| {
            for (arr.items) |item| {
                freeSchema(allocator, item);
            }
            arr.deinit(allocator);
        },
        else => {},
    }
}
