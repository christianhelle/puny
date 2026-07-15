const std = @import("std");
const lmstudio = @import("lmstudio.zig");

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
