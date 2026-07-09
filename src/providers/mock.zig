const std = @import("std");
const lmstudio = @import("lmstudio.zig");
const openai = @import("openai.zig");

const MockModel = struct {
    key: []const u8,
    display_name: []const u8,
};

const mock_models = [_]MockModel{
    .{ .key = "mock-model", .display_name = "Mock Model (GPT-4 level)" },
    .{ .key = "mock-model-fast", .display_name = "Mock Model Fast" },
};

pub const MockClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MockClient {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *MockClient) void {
        _ = self;
    }

    pub fn listModels(self: *MockClient) !lmstudio.Owned(lmstudio.ListModelsResponse) {
        const fake_models = [_]lmstudio.ModelInfo{
            .{
                .publisher = "mock",
                .key = mock_models[0].key,
                .format = "gguf",
                .display_name = mock_models[0].display_name,
                .size_bytes = 0,
                .max_context_length = 128000,
                .loaded_instances = &.{},
                .@"type" = "llm",
            },
            .{
                .publisher = "mock",
                .key = mock_models[1].key,
                .format = "gguf",
                .display_name = mock_models[1].display_name,
                .size_bytes = 0,
                .max_context_length = 32000,
                .loaded_instances = &.{},
                .@"type" = "llm",
            },
        };
        const response = lmstudio.ListModelsResponse{ .models = &fake_models };
        const json_bytes = try std.json.stringifyAlloc(self.allocator, response, .{});
        errdefer self.allocator.free(json_bytes);
        const parsed = try std.json.parseFromSlice(
            lmstudio.ListModelsResponse,
            self.allocator,
            json_bytes,
            .{ .ignore_unknown_fields = true },
        );
        return .{
            .allocator = self.allocator,
            .body = json_bytes,
            .parsed = parsed,
        };
    }

    pub fn chatStreaming(self: *MockClient, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
        _ = self;
        const last_content = findLastUserMessage(request.messages);

        if (isToolResultMessage(request.messages)) {
            return respondWithCompletion(callback, last_content);
        }

        if (containsWord(last_content, "error") or containsWord(last_content, "timeout") or containsWord(last_content, "fail")) {
            return error.ResponseError;
        }

        if (containsWord(last_content, "read") or containsWord(last_content, "file") or containsWord(last_content, "code")) {
            try callback.emit(.{ .tool_call_start = .{ .index = 0, .id = "mock_call_1", .name = "read_file" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"path\": \"" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "." } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "\"}" } });
            try callback.emit(.{ .finish = "tool_calls" });
            return;
        }

        if (containsWord(last_content, "search") or containsWord(last_content, "grep") or containsWord(last_content, "find")) {
            try callback.emit(.{ .tool_call_start = .{ .index = 0, .id = "mock_call_1", .name = "grep_search" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"pattern\": \"" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "mock" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "\"}" } });
            try callback.emit(.{ .finish = "tool_calls" });
            return;
        }

        if (containsWord(last_content, "shell") or containsWord(last_content, "run") or containsWord(last_content, "execute")) {
            try callback.emit(.{ .tool_call_start = .{ .index = 0, .id = "mock_call_1", .name = "execute_shell" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"command\": \"" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "echo mock" } });
            try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "\"}" } });
            try callback.emit(.{ .finish = "tool_calls" });
            return;
        }

        return respondWithContent(callback, last_content);
    }
};

fn findLastUserMessage(messages: []const openai.Message) []const u8 {
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        switch (messages[i]) {
            .user => |content| return content,
            else => {},
        }
    }
    return "";
}

fn isToolResultMessage(messages: []const openai.Message) bool {
    if (messages.len == 0) return false;
    return switch (messages[messages.len - 1]) {
        .tool => true,
        else => false,
    };
}

fn containsWord(text: []const u8, word: []const u8) bool {
    if (text.len < word.len) return false;
    var i: usize = 0;
    while (i <= text.len - word.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) {
            const before_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
            const after_ok = i + word.len >= text.len or !std.ascii.isAlphanumeric(text[i + word.len]);
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

fn respondWithContent(callback: openai.StreamCallback, user_message: []const u8) !void {
    try callback.emit(.{ .content = "This is a **mock response**.\n\n" });
    try callback.emit(.{ .content = "You said: " });
    try callback.emit(.{ .content = user_message });
    try callback.emit(.{ .content = "\n\nI'm running in mock mode, so this is a canned response. The UI, rendering, and tool-calling infrastructure all work without a real AI backend." });
    try callback.emit(.{ .finish = "stop" });
}

fn respondWithCompletion(callback: openai.StreamCallback, user_message: []const u8) !void {
    _ = user_message;
    try callback.emit(.{ .content = "Tool executed successfully. Here's the result:\n\n" });
    try callback.emit(.{ .content = "The operation completed. I'm running in mock mode, so the result is simulated.\n" });
    try callback.emit(.{ .finish = "stop" });
}
