const std = @import("std");
const lmstudio = @import("lmstudio.zig");

pub const default_base_url = "https://opencode.ai/zen";

/// OpenCode Zen serves models over several transports. Puny currently only
/// supports OpenAI-compatible `/v1/chat/completions`. This heuristic returns
/// false for model families known to use other transports (/responses,
/// /messages, /models/<id>) and true for everything else, so newly-added
/// chat/completions models are accepted automatically.
pub fn isChatCompletionsCompatible(model_id: []const u8) bool {
    const excluded = [_][]const u8{
        "gpt-",
        "claude-",
        "gemini-",
        "qwen",
    };

    for (excluded) |prefix| {
        if (std.mem.startsWith(u8, model_id, prefix)) return false;
    }
    return true;
}

/// Parses the OpenAI-standard `/v1/models` response from OpenCode Zen and
/// converts it into the `ListModelsResponse` shape consumed by the rest of
/// Puny. Models that are not served over `/v1/chat/completions` are filtered
/// out so the picker only shows usable models.
pub fn parseModels(allocator: std.mem.Allocator, response_json: []const u8) !lmstudio.Owned(lmstudio.ListModelsResponse) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    const items = data.array.items;

    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    arena.* = std.heap.ArenaAllocator.init(allocator);

    var models = std.array_list.Managed(lmstudio.ModelInfo).init(arena.allocator());

    for (items) |item| {
        const id = if (item.object.get("id")) |v| v.string else continue;
        if (!isChatCompletionsCompatible(id)) continue;

        const owned_by = if (item.object.get("owned_by")) |v| v.string else "opencode";
        const arena_alloc = arena.allocator();

        try models.append(.{
            .key = try arena_alloc.dupe(u8, id),
            .display_name = try arena_alloc.dupe(u8, id),
            .publisher = try arena_alloc.dupe(u8, owned_by),
            .format = "api",
            .size_bytes = 0,
            .max_context_length = 0,
            .loaded_instances = &.{},
            .type = "llm",
        });
    }

    const result = std.json.Parsed(lmstudio.ListModelsResponse){
        .arena = arena,
        .value = .{ .models = try models.toOwnedSlice() },
    };

    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, response_json),
        .parsed = result,
    };
}

pub fn listModelsRaw(client: *lmstudio.Client) !lmstudio.RawResponse {
    const allocator = client.allocator;
    var uri_buf: std.Io.Writer.Allocating = .init(allocator);
    defer uri_buf.deinit();
    try uri_buf.writer.print("{s}/v1/models", .{client.base_url});
    return lmstudio.requestRaw(client, std.http.Method.GET, uri_buf.written(), null);
}

fn listModelsResult(client: *lmstudio.Client) !lmstudio.ApiResult(lmstudio.ListModelsResponse) {
    var raw = try listModelsRaw(client);
    if (raw.status.class() != .success) return .{ .api_error = raw };
    const result = parseModels(client.allocator, raw.body) catch |err| {
        return .{ .parse_error = .{ .raw = raw, .error_name = @errorName(err) } };
    };
    raw.deinit();
    return .{ .ok = result };
}

pub fn listModels(client: *lmstudio.Client) !lmstudio.Owned(lmstudio.ListModelsResponse) {
    var result = try listModelsResult(client);
    switch (result) {
        .ok => |ok| return ok,
        .api_error => |*err| {
            if (lmstudio.isAuthFailure(err.status)) lmstudio.printAuthHint(client.io);
            err.deinit();
            return error.ResponseError;
        },
        .parse_error => |*err| {
            err.raw.deinit();
            return error.ResponseParseError;
        },
    }
}

test "isChatCompletionsCompatible accepts chat/completions families" {
    try std.testing.expect(isChatCompletionsCompatible("deepseek-v4-pro"));
    try std.testing.expect(isChatCompletionsCompatible("deepseek-v4-flash-free"));
    try std.testing.expect(isChatCompletionsCompatible("kimi-k2.7-code"));
    try std.testing.expect(isChatCompletionsCompatible("kimi-k2.5"));
    try std.testing.expect(isChatCompletionsCompatible("glm-5.2"));
    try std.testing.expect(isChatCompletionsCompatible("minimax-m3"));
    try std.testing.expect(isChatCompletionsCompatible("grok-4.5"));
    try std.testing.expect(isChatCompletionsCompatible("grok-build-0.1"));
    try std.testing.expect(isChatCompletionsCompatible("big-pickle"));
    try std.testing.expect(isChatCompletionsCompatible("mimo-v2.5-free"));
    try std.testing.expect(isChatCompletionsCompatible("north-mini-code-free"));
    try std.testing.expect(isChatCompletionsCompatible("nemotron-3-ultra-free"));
}

test "isChatCompletionsCompatible rejects non-chat families" {
    try std.testing.expect(!isChatCompletionsCompatible("gpt-5.5"));
    try std.testing.expect(!isChatCompletionsCompatible("gpt-5.3-codex"));
    try std.testing.expect(!isChatCompletionsCompatible("claude-opus-4-8"));
    try std.testing.expect(!isChatCompletionsCompatible("claude-sonnet-4.6"));
    try std.testing.expect(!isChatCompletionsCompatible("claude-haiku-4.5"));
    try std.testing.expect(!isChatCompletionsCompatible("gemini-3.5-flash"));
    try std.testing.expect(!isChatCompletionsCompatible("gemini-3.1-pro"));
    try std.testing.expect(!isChatCompletionsCompatible("qwen3.7-max"));
    try std.testing.expect(!isChatCompletionsCompatible("qwen3.5-plus"));
}

test "parseModels maps and filters OpenAI model list" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"deepseek-v4-pro","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"gpt-5.5","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"kimi-k2.7-code","object":"model","created":1784147408,"owned_by":"opencode"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.value().models.len);
    try std.testing.expectEqualStrings("deepseek-v4-pro", result.value().models[0].key);
    try std.testing.expectEqualStrings("deepseek-v4-pro", result.value().models[0].display_name);
    try std.testing.expectEqualStrings("opencode", result.value().models[0].publisher);
    try std.testing.expectEqualStrings("kimi-k2.7-code", result.value().models[1].key);
}

test "parseModels returns empty list when no compatible models" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"gpt-5.5","object":"model","created":1784147408,"owned_by":"opencode"},
        \\  {"id":"claude-opus-4-8","object":"model","created":1784147408,"owned_by":"opencode"}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.value().models.len);
}

test "parseModels ignores unknown fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"object":"list","extra":true,"data":[
        \\  {"id":"big-pickle","object":"model","created":1784147408,"owned_by":"opencode","unknown_field":123}
        \\]}
    ;

    var result = try parseModels(allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.value().models.len);
    try std.testing.expectEqualStrings("big-pickle", result.value().models[0].key);
}
