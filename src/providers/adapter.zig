const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");
const generated_openai = @import("openai/client.zig");

pub const ToolDefinition = openai.ToolDefinition;

/// Creates a generated OpenAI Client with its own HTTP client but sharing
/// allocator, io, and config from the hand-written client. The caller must
/// call `generated.deinit()` when done to free HTTP client resources.
pub fn openAiClient(c: *client.Client) generated_openai.Client {
    return generated_openai.Client.init(c.allocator, c.io, c.api_key);
}

/// Adapter struct that wraps ChatRequest and provides jsonStringify for use with
/// generated OpenAI client's streamJson(). Produces the same JSON format as the
/// hand-written requestPayload().
pub const OpenAiStreamingRequest = struct {
    request: openai.ChatRequest,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        const r = self.request;
        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(r.model);

        try jw.objectField("messages");
        try jw.write(r.messages);

        try jw.objectField("tools");
        try jw.beginArray();
        for (r.tools) |tool| {
            try jw.write(tool);
        }
        try jw.endArray();

        if (r.temperature) |temp| {
            try jw.objectField("temperature");
            try jw.write(temp);
        }

        if (r.reasoning_effort) |effort| {
            if (effort != .default) {
                try jw.objectField("reasoning_effort");
                try jw.write(@tagName(effort));
                try jw.objectField("thinking");
                try jw.write(.{ .type = "enabled" });
            }
        }

        // Stream options are always included for usage tracking
        try jw.objectField("stream_options");
        try jw.write(.{ .include_usage = true });

        try jw.endObject();
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn jsonValue(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, payload, .{ .ignore_unknown_fields = true });
}

test "simple json write" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value("hello", .{}, &buf.writer);
    const written = buf.written();
    try testing.expect(written.len > 0);
}

test "OpenAiStreamingRequest includes stream_options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = OpenAiStreamingRequest{
        .request = .{
            .model = "gpt-4o",
            .messages = &.{},
            .tools = &.{},
        },
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(request, .{}, &buf.writer);
    const payload = buf.written();

    const parsed = try jsonValue(testing.allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    const stream_options = root.get("stream_options").?.object;
    try testing.expectEqual(true, stream_options.get("include_usage").?.bool);
}

test "OpenAiStreamingRequest includes temperature when set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = OpenAiStreamingRequest{
        .request = .{
            .model = "gpt-4o",
            .messages = &.{},
            .tools = &.{},
            .temperature = 0.7,
        },
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(request, .{}, &buf.writer);
    const payload = buf.written();

    const parsed = try jsonValue(testing.allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqual(@as(f64, 0.7), root.get("temperature").?.float);
}

test "OpenAiStreamingRequest omits temperature when null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = OpenAiStreamingRequest{
        .request = .{
            .model = "gpt-4o",
            .messages = &.{},
            .tools = &.{},
        },
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(request, .{}, &buf.writer);
    const payload = buf.written();

    const parsed = try jsonValue(testing.allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.get("temperature") == null);
}

test "OpenAiStreamingRequest includes reasoning_effort and thinking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = OpenAiStreamingRequest{
        .request = .{
            .model = "o3",
            .messages = &.{},
            .tools = &.{},
            .reasoning_effort = .high,
        },
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(request, .{}, &buf.writer);
    const payload = buf.written();

    const parsed = try jsonValue(testing.allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("high", root.get("reasoning_effort").?.string);
    try testing.expectEqualStrings("enabled", root.get("thinking").?.object.get("type").?.string);
}

test "OpenAiStreamingRequest omits reasoning_effort when default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const request = OpenAiStreamingRequest{
        .request = .{
            .model = "o3",
            .messages = &.{},
            .tools = &.{},
            .reasoning_effort = .default,
        },
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(request, .{}, &buf.writer);
    const payload = buf.written();

    const parsed = try jsonValue(testing.allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.get("reasoning_effort") == null);
    try testing.expect(root.get("thinking") == null);
}

test "OpenAiStreamingRequest serializes tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"name\":\"read_file\",\"description\":\"Read a file\",\"parameters\":{\"type\":\"object\"}}",
        .{},
    );

    const request = OpenAiStreamingRequest{
        .request = .{
            .model = "gpt-4o",
            .messages = &.{},
            .tools = &.{
                .{ .function = schema },
            },
        },
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(request, .{}, &buf.writer);
    const payload = buf.written();

    const parsed = try jsonValue(testing.allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    const tools = root.get("tools").?.array;
    try testing.expectEqual(@as(usize, 1), tools.items.len);
    const tool = tools.items[0].object;
    try testing.expectEqualStrings("function", tool.get("type").?.string);
    try testing.expectEqualStrings("read_file", tool.get("function").?.object.get("name").?.string);
}

