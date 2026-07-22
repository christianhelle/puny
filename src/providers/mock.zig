const std = @import("std");
const client = @import("client.zig");
const openai = @import("openai.zig");

const toolCallCount = 10; // Number of tool calls to simulate in mock mode.

/// Mock mode controls the delay between token emissions.
pub const MockSpeed = enum {
    /// No delay between tokens (instant).
    instant,
    /// Normal speed: ~100 tokens/second.
    normal,
    /// Slow speed: ~10 tokens/second.
    slow,
};

/// Keywords that the mock provider recognizes in the last user message.
pub const MockKeyword = enum {
    /// Produce a long text response (~1000 words) at ~100 tokens/second.
    long,
    /// Produce text instantly with no delay.
    fast,
    /// Produce text slowly at ~10 tokens/second.
    slow,
    /// Echo the user's message back as the response.
    echo,
    /// Produce an empty response (no content, just finish).
    empty,
    /// Produce partial content (simulates a truncated response with no finish event).
    partial,
    /// Include mock usage statistics in the response.
    usage,
    /// Trigger an error response.
    err,
    /// Trigger a timeout response.
    timeout,
    /// Trigger a failure response.
    fail,
    /// Trigger a tool call for reading a file.
    read,
    /// Trigger a tool call for searching.
    search,
    /// Trigger a tool call for shell execution.
    shell,
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

    pub fn listModels(self: *MockClient) !client.Owned(ModelsList) {
        const json =
            \\{"models":[
            \\  {"key":"mock-model","display_name":"Mock Model (GPT-4 level)","publisher":"mock","max_context_length":128000},
            \\  {"key":"mock-model-fast","display_name":"Mock Model Fast","publisher":"mock","max_context_length":32000},
            \\  {"key":"mock-model-long","display_name":"Mock Model Long Output","publisher":"mock","max_context_length":64000},
            \\  {"key":"mock-model-slow","display_name":"Mock Model Slow Output","publisher":"mock","max_context_length":64000}
            \\]}
        ;
        const json_bytes = try self.allocator.dupe(u8, json);
        errdefer self.allocator.free(json_bytes);
        const parsed = try std.json.parseFromSlice(
            ModelsList,
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

    pub const ModelInfo = struct {
        key: []const u8,
        display_name: []const u8,
        publisher: []const u8,
        max_context_length: i64,
    };

    pub const ModelsList = struct {
        models: []const ModelInfo,
    };

    /// Convert a mock-specific model list into the app-wide shared model list.
    /// The source `owned` is deinitialized; ownership of the returned value is transferred.
    pub fn toSharedModels(owned: *client.Owned(ModelsList)) !client.Owned(client.ModelsList) {
        const allocator = owned.allocator;
        const source = owned.value();

        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        var models = try arena_alloc.alloc(client.Model, source.models.len);
        for (source.models, 0..) |m, i| {
            models[i] = .{
                .id = try arena_alloc.dupe(u8, m.key),
                .display_name = try arena_alloc.dupe(u8, m.display_name),
                .provider = try arena_alloc.dupe(u8, m.publisher),
                .context_length = m.max_context_length,
            };
        }

        owned.deinit();

        return .{
            .allocator = allocator,
            .body = try allocator.dupe(u8, ""),
            .parsed = .{
                .arena = arena,
                .value = .{ .models = models },
            },
        };
    }

    pub fn chatStreaming(self: *MockClient, request: openai.ChatRequest, callback: openai.StreamCallback) !void {
        const last_content = findLastUserMessage(request.messages);

        // If the last message is a tool result, respond with a plain completion
        // to avoid re-triggering tool call keywords from the original user message.
        if (isToolResultMessage(request.messages)) {
            return respondWithCompletion(callback);
        }

        // Check for error/timeout/fail first (highest priority)
        if (isKeyword(last_content, .err) or isKeyword(last_content, .timeout) or isKeyword(last_content, .fail)) {
            return error.ResponseError;
        }

        // Check for tool call keywords
        if (isKeyword(last_content, .read)) {
            for (0..toolCallCount) |i| {
                try callback.emit(.{ .tool_call_start = .{ .index = i, .id = "mock_call_1", .name = "read_file" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "{\"path\": \"" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "." } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "\"}" } });
            }
            try callback.emit(.{ .finish = "tool_calls" });
            return;
        }

        if (isKeyword(last_content, .search)) {
            for (0..toolCallCount) |i| {
                try callback.emit(.{ .tool_call_start = .{ .index = i, .id = "mock_call_1", .name = "grep_search" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "{\"query\": \"" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "mock" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "\"}" } });
            }
            try callback.emit(.{ .finish = "tool_calls" });
            return;
        }

        if (isKeyword(last_content, .shell)) {
            for (0..toolCallCount) |i| {
                try callback.emit(.{ .tool_call_start = .{ .index = i, .id = "mock_call_1", .name = "execute_shell" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "{\"command\": \"" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "echo mock" } });
                try callback.emit(.{ .tool_call_delta = .{ .index = i, .arguments = "\"}" } });
            }
            try callback.emit(.{ .finish = "tool_calls" });
            return;
        }

        // Determine speed from keywords (fast overrides slow)
        var speed: MockSpeed = .normal;
        if (isKeyword(last_content, .fast)) speed = .instant;
        if (isKeyword(last_content, .slow)) speed = .slow;

        // Check for echo mode
        if (isKeyword(last_content, .echo)) {
            return respondWithEcho(callback, last_content, speed, self.io);
        }

        // Check for empty mode
        if (isKeyword(last_content, .empty)) {
            return respondWithEmpty(callback);
        }

        // Check for partial mode
        if (isKeyword(last_content, .partial)) {
            return respondWithPartial(callback, speed, self.io);
        }

        // Check for usage mode
        if (isKeyword(last_content, .usage)) {
            return respondWithUsage(callback, last_content, speed, self.io);
        }

        // Check for long mode
        if (isKeyword(last_content, .long)) {
            return respondWithLong(callback, speed, self.io);
        }

        // Default: normal content response
        return respondWithContent(callback, last_content, speed, self.io);
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

/// Check if the given keyword appears as a whole word in the text.
fn isKeyword(text: []const u8, comptime kw: MockKeyword) bool {
    const keyword_str = keywordToString(kw);
    return containsWord(text, keyword_str);
}

fn keywordToString(kw: MockKeyword) []const u8 {
    return switch (kw) {
        .long => "long",
        .fast => "fast",
        .slow => "slow",
        .echo => "echo",
        .empty => "empty",
        .partial => "partial",
        .usage => "usage",
        .err => "error",
        .timeout => "timeout",
        .fail => "fail",
        .read => "read",
        .search => "search",
        .shell => "shell",
    };
}

fn respondWithContent(callback: openai.StreamCallback, user_message: []const u8, speed: MockSpeed, io: std.Io) !void {
    const chunks = [_][]const u8{
        "This is a **mock response**.\n\n",
        "You said: ",
        user_message,
        "\n\nI'm running in mock mode, so this is a canned response. The UI, rendering, and tool-calling infrastructure all work without a real AI backend.",
    };

    for (chunks) |chunk| {
        try callback.emit(.{ .content = chunk });
        try emitDelay(speed, io);
    }
    try callback.emit(.{ .finish = "stop" });
}

fn respondWithEcho(callback: openai.StreamCallback, user_message: []const u8, speed: MockSpeed, io: std.Io) !void {
    const chunks = [_][]const u8{
        "Echo: ",
        user_message,
        "\n\nThis is your input echoed back in mock mode.",
    };

    for (chunks) |chunk| {
        try callback.emit(.{ .content = chunk });
        try emitDelay(speed, io);
    }
    try callback.emit(.{ .finish = "stop" });
}

fn respondWithEmpty(callback: openai.StreamCallback) !void {
    try callback.emit(.{ .finish = "stop" });
}

fn respondWithLong(callback: openai.StreamCallback, speed: MockSpeed, io: std.Io) !void {
    // Generate a long text of ~1000 words, emitted at the given speed.
    // At 100 tokens/sec (normal), this takes ~10 seconds.
    const word_pool = [_][]const u8{
        "the",        "quick",    "brown",     "fox",     "jumps",       "over",    "lazy",       "dog",
        "mock",       "provider", "generates", "long",    "text",        "for",     "testing",    "purposes",
        "streaming",  "works",    "correctly", "with",    "this",        "output",  "mode",       "you",
        "can",        "see",      "tokens",    "flowing", "in",          "real",    "time",       "the",
        "interface",  "handles",  "partial",   "results", "beautifully", "and",     "renders",    "markdown",
        "formatting", "as",       "expected",  "this",    "is",          "a",       "useful",     "feature",
        "for",        "testing",  "the",       "ui",      "under",       "various", "conditions",
    };

    var word_idx: usize = 0;
    var sentence_len: usize = 0;
    var sentence_count: usize = 0;
    var total_words: usize = 0;

    while (total_words < 1000) : (total_words += 1) {
        const word = word_pool[word_idx % word_pool.len];
        if (sentence_len == 0 and total_words > 0) {
            // Start of a new sentence
            if (sentence_count > 0) {
                try callback.emit(.{ .content = ". " });
                sentence_count += 1;
            }
            // Capitalize first letter: emit the first char separately to avoid
            // slice concatenation (Zig 0.16 requires comptime-known slices)
            if (total_words == 0) {
                try callback.emit(.{ .content = &.{std.ascii.toUpper(word[0])} });
            } else {
                try callback.emit(.{ .content = word });
            }
        } else {
            try callback.emit(.{ .content = " " });
            try callback.emit(.{ .content = word });
        }
        sentence_len += 1;
        word_idx += 1;

        // End sentence every 12-18 words
        if (sentence_len >= 12 + (total_words % 7)) {
            sentence_len = 0;
        }

        try emitDelay(speed, io);
    }
    try callback.emit(.{ .finish = "stop" });
}

fn respondWithPartial(callback: openai.StreamCallback, speed: MockSpeed, io: std.Io) !void {
    // Simulate partial/truncated streaming
    const chunks = [_][]const u8{
        "This is a partial response.\n\n",
        "The mock provider is simulating a truncated stream.\n\n",
        "This content may appear incomplete in the UI.\n\n",
        "Use this mode to test how the app handles partial data.",
    };

    for (chunks) |chunk| {
        try callback.emit(.{ .content = chunk });
        try emitDelay(speed, io);
    }
    // null finish_reason = no finish event (simulates a hanging stream)
    try callback.emit(.{ .finish = null });
}

fn respondWithUsage(callback: openai.StreamCallback, user_message: []const u8, speed: MockSpeed, io: std.Io) !void {
    _ = speed;
    _ = io;
    try callback.emit(.{ .content = "This is a mock response with usage statistics.\n\n" });
    try callback.emit(.{ .content = "You said: " });
    try callback.emit(.{ .content = user_message });
    try callback.emit(.{ .content = "\n\n" });
    try callback.emit(.{ .finish = "stop" });

    // Emit usage info after finishing content
    try callback.emit(.{ .usage = .{
        .input_tokens = 24,
        .output_tokens = 156,
        .reasoning_output_tokens = null,
        .tokens_per_second = 100.0,
        .time_to_first_token_seconds = 0.0,
    } });
}

fn respondWithCompletion(callback: openai.StreamCallback) !void {
    try callback.emit(.{ .content = "Tool executed successfully. Here's the result:\n\n" });
    try callback.emit(.{ .content = "The operation completed. I'm running in mock mode, so the result is simulated.\n" });
    try callback.emit(.{ .finish = "stop" });
}

/// Emit a delay based on mock speed.
fn emitDelay(speed: MockSpeed, io: std.Io) !void {
    switch (speed) {
        .instant => {},
        .normal => {
            // ~2ms per token = ~1000  tokens/sec
            try io.sleep(.{ .nanoseconds = @as(i96, @intCast(std.time.ns_per_ms * 2)) }, .awake);
        },
        .slow => {
            // ~100ms per token = ~10 tokens/sec
            try io.sleep(.{ .nanoseconds = @as(i96, @intCast(std.time.ns_per_ms * 100)) }, .awake);
        },
    }
}
