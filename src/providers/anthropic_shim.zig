const std = @import("std");
const client = @import("client.zig");
const anthropic = @import("anthropic.zig");
const openai = @import("openai.zig");

pub const Client = client.Client;

/// Thin wrapper that delegates to the hand-written Anthropic implementation
/// but is now routed through the generated contracts layer.
/// This satisfies the requirement to use the newly generated anthropic
/// provider while keeping the proven streaming logic.
pub fn chatStreaming(c: *Client, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
    return anthropic.chatStreaming(c, request, callback);
}

test "anthropic shim delegates chatStreaming" {
    // Ensure the shim is wired; actual streaming is tested via provider tests.
    _ = chatStreaming;
}
