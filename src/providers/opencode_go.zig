const std = @import("std");
const http_client = @import("client.zig");
const openai = @import("openai.zig");
const opencode = @import("opencode_zen.zig");

pub const default_base_url = "https://opencode.ai/zen/go";

pub fn isSupportedModel(_: []const u8) bool {
    return true;
}

pub fn isAnthropicModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "minimax-") or
        std.mem.startsWith(u8, model_id, "qwen");
}

pub const ModelInfo = opencode.ModelInfo;
pub const ModelsList = opencode.ModelsList;
pub const parseModels = opencode.parseModels;
pub const toSharedModels = opencode.toSharedModels;
pub const listModelsRaw = opencode.listModelsRaw;

fn listModelsResult(client: *http_client.Client) !http_client.ApiResult(ModelsList) {
    var raw = try listModelsRaw(client);
    if (raw.status.class() != .success) return .{ .api_error = raw };
    const result = parseModels(client.allocator, raw.body) catch |err| {
        return .{ .parse_error = .{ .raw = raw, .error_name = @errorName(err) } };
    };
    raw.deinit();
    return .{ .ok = result };
}

pub fn listModels(client: *http_client.Client) !http_client.Owned(ModelsList) {
    var result = try listModelsResult(client);
    switch (result) {
        .ok => |ok| return ok,
        .api_error => |*err| {
            if (http_client.isAuthFailure(err.status)) http_client.printAuthHint(client.io);
            err.deinit();
            return error.ResponseError;
        },
        .parse_error => |*err| {
            err.raw.deinit();
            return error.ResponseParseError;
        },
    }
}

test "isAnthropicModel detects minimax and qwen families" {
    try std.testing.expect(isAnthropicModel("minimax-m3"));
    try std.testing.expect(isAnthropicModel("minimax-m2.7"));
    try std.testing.expect(isAnthropicModel("minimax-m2.5"));
    try std.testing.expect(isAnthropicModel("qwen3.7-max"));
    try std.testing.expect(isAnthropicModel("qwen3.7-plus"));
    try std.testing.expect(isAnthropicModel("qwen3.6-plus"));
    try std.testing.expect(!isAnthropicModel("deepseek-v4-flash"));
    try std.testing.expect(!isAnthropicModel("grok-4.5"));
    try std.testing.expect(!isAnthropicModel("kimi-k2.7-code"));
}
