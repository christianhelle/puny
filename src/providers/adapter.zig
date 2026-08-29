const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");
const message = @import("message.zig");
const generated_openai = @import("openai/client.zig");

pub const Message = message.Message;
pub const ToolDefinition = openai.ToolDefinition;

/// Creates a generated OpenAI Client with its own HTTP client but sharing
/// allocator, io, base URL, organization, project, default headers, and
/// observer from the hand-written client. The caller must call
/// `generated.deinit()` when done to free HTTP resources.
pub fn openAiClient(c: *client.Client) generated_openai.Client {
    var generated = generated_openai.Client.init(c.allocator, c.io, c.api_key);
    generated.base_url = c.base_url;
    generated.organization = c.organization;
    generated.project = c.project;
    generated.default_headers = c.default_headers;
    generated.http_observer = if (c.http_observer) |obs| .{
        .ctx = obs.ctx,
        .onRequest = obs.onRequest,
        .onResponse = obs.onResponse,
        .onError = obs.onError,
    } else null;
    return generated;
}

/// Adapter struct that wraps ChatRequest and provides jsonStringify for use with
/// generated OpenAI client's streamJson(). Produces the same JSON format as the
/// hand-written requestPayload().
/// Maps an OpenAI ReasoningEffort to the LM Studio native `reasoning` enum
/// (off/low/medium/high/on in openapi/lmstudio.json). Used when streaming
/// via the native LM Studio endpoint; the OpenAI-compatible path forwards
/// `reasoning_effort` verbatim and does not use this mapping.
pub fn lmStudioReasoningFromEffort(effort: openai.ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .default => null,
        .none => "off",
        .minimal => "low",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "on",
    };
}

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

        try jw.objectField("stream");
        try jw.write(true);

        // Stream options are always included for usage tracking
        try jw.objectField("stream_options");
        try jw.write(.{ .include_usage = true });

        try jw.endObject();
    }
};

// ── Tests ────────────────────────────────────────────────────────────

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
    try testing.expectEqual(true, root.get("stream").?.bool);
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

test "openAiClient propagates organization project and default_headers" {
    var c = client.Client.init(testing.allocator, std.testing.io, "test-key");
    defer c.deinit();
    c.base_url = "https://api.example.com";
    c.organization = "my-org";
    c.project = "my-proj";
    const hdrs = [_]std.http.Header{.{ .name = "X-Custom", .value = "1" }};
    c.default_headers = &hdrs;

    var generated = openAiClient(&c);
    defer generated.deinit();

    try testing.expectEqualStrings("https://api.example.com", generated.base_url);
    try testing.expectEqualStrings("my-org", generated.organization.?);
    try testing.expectEqualStrings("my-proj", generated.project.?);
    try testing.expectEqual(@as(usize, 1), generated.default_headers.len);
    try testing.expectEqualStrings("X-Custom", generated.default_headers[0].name);
    try testing.expectEqualStrings("my-org", generated.organization.?);
}

test "lmStudioReasoningFromEffort maps OpenAI effort to LM Studio enum" {
    try testing.expect(lmStudioReasoningFromEffort(.default) == null);
    try testing.expectEqualStrings("off", lmStudioReasoningFromEffort(.none).?);
    try testing.expectEqualStrings("low", lmStudioReasoningFromEffort(.minimal).?);
    try testing.expectEqualStrings("low", lmStudioReasoningFromEffort(.low).?);
    try testing.expectEqualStrings("medium", lmStudioReasoningFromEffort(.medium).?);
    try testing.expectEqualStrings("high", lmStudioReasoningFromEffort(.high).?);
    try testing.expectEqualStrings("on", lmStudioReasoningFromEffort(.xhigh).?);
}
