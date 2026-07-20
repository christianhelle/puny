const std = @import("std");
const openai = @import("../providers/openai.zig");

const max_value_length = 120;
const max_json_render_depth = 3;

pub fn renderToolCall(allocator: std.mem.Allocator, tool_call: openai.ToolCall) ![]const u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, tool_call.function.arguments, .{}) catch {
        try output.appendSlice("Calling ");
        try appendJsonString(&output, tool_call.function.name);
        try output.appendSlice(" (invalid arguments: ");
        try appendJsonString(&output, tool_call.function.arguments);
        try output.append(')');
        return output.toOwnedSlice();
    };
    defer parsed.deinit();

    if (!try renderKnown(&output, tool_call.function.name, parsed.value)) {
        try appendGeneric(&output, tool_call.function.name, parsed.value);
    }
    return output.toOwnedSlice();
}

fn renderKnown(
    output: *std.array_list.Managed(u8),
    name: []const u8,
    args: std.json.Value,
) !bool {
    if (std.mem.eql(u8, name, "read_file")) {
        const path = getString(args, "path") orelse return false;
        try output.appendSlice("Reading ");
        try appendJsonString(output, path);
        return true;
    }

    if (std.mem.eql(u8, name, "write_file")) {
        const path = getString(args, "path") orelse return false;
        const content = getString(args, "content") orelse return false;
        try output.appendSlice("Writing ");
        if (content.len == 0) {
            try output.appendSlice("an empty file to ");
        } else {
            try appendCount(output, lineCount(content), "line", "lines");
            try output.appendSlice(" (");
            try appendCount(output, content.len, "byte", "bytes");
            try output.appendSlice(") to ");
        }
        try appendJsonString(output, path);
        return true;
    }

    if (std.mem.eql(u8, name, "list_directory")) {
        const path = getString(args, "path") orelse return false;
        try output.appendSlice("Listing ");
        try appendJsonString(output, path);
        return true;
    }

    if (std.mem.eql(u8, name, "execute_shell")) {
        const command = getString(args, "command") orelse return false;
        try output.appendSlice("Running ");
        try appendJsonString(output, command);
        if (getString(args, "working_directory")) |working_directory| {
            try output.appendSlice(" in ");
            try appendJsonString(output, working_directory);
        }
        return true;
    }

    if (std.mem.eql(u8, name, "grep_search")) {
        const query = getString(args, "query") orelse return false;
        try output.appendSlice("Searching for ");
        try appendJsonString(output, query);
        try output.appendSlice(" in ");
        if (getString(args, "path")) |path| {
            try appendJsonString(output, path);
        } else {
            try output.appendSlice("current directory");
        }
        if (getBool(args, "case_sensitive") == true) {
            try output.appendSlice(" (case-sensitive)");
        }
        return true;
    }

    if (std.mem.eql(u8, name, "git_status")) {
        try output.appendSlice("Checking git status");
        if (getString(args, "path")) |path| {
            try output.appendSlice(" for ");
            try appendJsonString(output, path);
        }
        return true;
    }

    if (std.mem.eql(u8, name, "git_diff")) {
        try output.appendSlice("Showing ");
        if (getBool(args, "staged") == true) {
            try output.appendSlice("staged ");
        }
        try output.appendSlice("git diff");
        if (getString(args, "path")) |path| {
            try output.appendSlice(" for ");
            try appendJsonString(output, path);
        }
        return true;
    }

    if (std.mem.eql(u8, name, "web_fetch")) {
        const url = getString(args, "url") orelse return false;
        try output.appendSlice("Fetching ");
        try appendJsonString(output, url);
        return true;
    }

    return false;
}

fn appendGeneric(
    output: *std.array_list.Managed(u8),
    name: []const u8,
    args: std.json.Value,
) !void {
    try output.appendSlice("Calling ");
    try appendJsonString(output, name);

    if (args == .object) {
        var iterator = args.object.iterator();
        if (iterator.next() == null) {
            try output.appendSlice(" with no arguments");
            return;
        }

        try output.appendSlice(" with ");
        var first = true;
        iterator = args.object.iterator();
        while (iterator.next()) |entry| {
            if (!first) try output.appendSlice(", ");
            first = false;
            try output.appendSlice(entry.key_ptr.*);
            try output.append('=');
            try appendJsonValue(output, entry.value_ptr.*);
        }
        return;
    }

    try output.appendSlice(" with ");
    try appendJsonValue(output, args);
}

fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getBool(args: std.json.Value, key: []const u8) ?bool {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn appendJsonString(output: *std.array_list.Managed(u8), value: []const u8) !void {
    try output.append('"');

    var index: usize = 0;
    var display_length: usize = 1;
    while (index < value.len) {
        const byte = value[index];
        var escaped_buffer: [6]u8 = undefined;
        var escaped: []const u8 = undefined;
        var next_index = index + 1;
        var escaped_display_length: usize = 1;

        switch (byte) {
            '"' => escaped = "\\\"",
            '\\' => escaped = "\\\\",
            '\n' => escaped = "\\n",
            '\r' => escaped = "\\r",
            '\t' => escaped = "\\t",
            else => {
                if (byte < 0x20) {
                    escaped = std.fmt.bufPrint(&escaped_buffer, "\\u{x:0>4}", .{byte}) catch unreachable;
                    escaped_display_length = escaped.len;
                } else {
                    const width = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                    next_index = @min(value.len, index + width);
                    escaped = value[index..next_index];
                    escaped_display_length = if (next_index - index > 1) 1 else escaped.len;
                }
            },
        }

        if (display_length + escaped_display_length + 1 > max_value_length) {
            try output.appendSlice("...");
            try output.append('"');
            return;
        }

        try output.appendSlice(escaped);
        display_length += escaped_display_length;
        index = next_index;
    }

    try output.append('"');
}

fn appendJsonValue(
    output: *std.array_list.Managed(u8),
    value: std.json.Value,
) !void {
    try appendJsonValueDepth(output, value, 0);
}

fn appendJsonValueDepth(
    output: *std.array_list.Managed(u8),
    value: std.json.Value,
    depth: usize,
) !void {
    if (depth >= max_json_render_depth) {
        try output.appendSlice("...");
        return;
    }
    switch (value) {
        .string => |s| try appendJsonString(output, s),
        .bool => |b| try output.appendSlice(if (b) "true" else "false"),
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{d}", .{i});
            try output.appendSlice(text);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{d}", .{f});
            try output.appendSlice(text);
        },
        .null => try output.appendSlice("null"),
        .array => |arr| {
            if (arr.items.len == 0) {
                try output.appendSlice("[]");
                return;
            }
            try output.appendSlice("[");
            var first = true;
            for (arr.items) |item| {
                if (!first) try output.appendSlice(", ");
                first = false;
                try appendJsonValueDepth(output, item, depth + 1);
            }
            try output.appendSlice("]");
        },
        .object => |obj| {
            if (obj.count() == 0) {
                try output.appendSlice("{}");
                return;
            }
            try output.appendSlice("{");
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try output.appendSlice(", ");
                first = false;
                try output.appendSlice(entry.key_ptr.*);
                try output.appendSlice(": ");
                try appendJsonValueDepth(output, entry.value_ptr.*, depth + 1);
            }
            try output.appendSlice("}");
        },
    }
}

fn appendCount(
    output: *std.array_list.Managed(u8),
    value: usize,
    singular: []const u8,
    plural: []const u8,
) !void {
    var buffer: [32]u8 = undefined;
    const number = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try output.appendSlice(number);
    try output.append(' ');
    try output.appendSlice(if (value == 1) singular else plural);
}

fn lineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = 0;
    for (content) |byte| {
        if (byte == '\n') count += 1;
    }
    if (content[content.len - 1] != '\n') count += 1;
    return count;
}

fn makeToolCall(name: []const u8, arguments: []const u8) openai.ToolCall {
    return .{
        .id = "test_call",
        .function = .{
            .name = name,
            .arguments = arguments,
        },
    };
}

fn expectRendered(name: []const u8, arguments: []const u8, expected: []const u8) !void {
    const rendered = try renderToolCall(std.testing.allocator, makeToolCall(name, arguments));
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(expected, rendered);
}

test "renders current tool calls as actions" {
    try expectRendered("read_file", "{\"path\":\"src/main.zig\"}", "Reading \"src/main.zig\"");
    try expectRendered("write_file", "{\"path\":\"src/main.zig\",\"content\":\"abc\\nxyz\"}", "Writing 2 lines (7 bytes) to \"src/main.zig\"");
    try expectRendered("write_file", "{\"path\":\"empty.txt\",\"content\":\"\"}", "Writing an empty file to \"empty.txt\"");
    try expectRendered("list_directory", "{\"path\":\".\"}", "Listing \".\"");
    try expectRendered("execute_shell", "{\"command\":\"zig test\",\"working_directory\":\"src\"}", "Running \"zig test\" in \"src\"");
    try expectRendered("grep_search", "{\"query\":\"TODO\"}", "Searching for \"TODO\" in current directory");
    try expectRendered("grep_search", "{\"query\":\"TODO\",\"path\":\"src\",\"case_sensitive\":true}", "Searching for \"TODO\" in \"src\" (case-sensitive)");
    try expectRendered("git_status", "{}", "Checking git status");
    try expectRendered("git_status", "{\"path\":\"src\"}", "Checking git status for \"src\"");
    try expectRendered("git_diff", "{\"staged\":true,\"path\":\"src\"}", "Showing staged git diff for \"src\"");
    try expectRendered("web_fetch", "{\"url\":\"https://example.com\"}", "Fetching \"https://example.com\"");
}

test "summarizes unknown and invalid tool calls" {
    try expectRendered("custom_tool", "{\"count\":3,\"enabled\":true}", "Calling \"custom_tool\" with count=3, enabled=true");
    try expectRendered("read_file", "{", "Calling \"read_file\" (invalid arguments: \"{\")");
}

test "truncates long string values" {
    var command: [200]u8 = undefined;
    @memset(&command, 'x');
    const arguments = try std.fmt.allocPrint(std.testing.allocator, "{{\"command\":\"{s}\"}}", .{command[0..]});
    defer std.testing.allocator.free(arguments);

    const rendered = try renderToolCall(
        std.testing.allocator,
        makeToolCall("execute_shell", arguments),
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "Running \""));
    try std.testing.expect(std.mem.endsWith(u8, rendered, "...\""));
    try std.testing.expect(rendered.len < 130);
}

test "does not expose write content in summaries" {
    const rendered = try renderToolCall(
        std.testing.allocator,
        makeToolCall("write_file", "{\"path\":\"secret.txt\",\"content\":\"secret value\"}"),
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Writing 1 line (12 bytes) to \"secret.txt\"", rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "secret value") == null);
}
