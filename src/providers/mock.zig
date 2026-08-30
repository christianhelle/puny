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
    /// Generate a markdown table with realistic data.
    table,
    /// Generate complex markdown with headings, code blocks, lists, blockquotes, etc.
    markdown,
    /// Stream a large amount of reasoning output before the final content, to
    /// verify --show-thinking rendering.
    reasoning,
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

    pub fn setConfig(self: *MockClient, config: client.ClientConfig) void {
        _ = self;
        _ = config;
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

        // Check for reasoning mode
        if (isKeyword(last_content, .reasoning)) {
            return respondWithReasoning(callback, last_content, speed, self.io);
        }

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

        // Check for table mode first — explicit table requests take priority
        // over the broader markdown keyword.
        if (isKeyword(last_content, .table)) {
            return respondWithTable(callback, speed, self.io);
        }

        // Check for markdown mode (complex markdown with all features)
        if (isKeyword(last_content, .markdown)) {
            return respondWithMarkdown(callback, speed, self.io);
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
        .table => "table",
        .markdown => "markdown",
        .reasoning => "reasoning",
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

fn respondWithReasoning(callback: openai.StreamCallback, user_message: []const u8, speed: MockSpeed, io: std.Io) !void {
    // A verbose, multi-step internal monologue, streamed before the final
    // answer, so --show-thinking has substantial reasoning output to render.
    const reasoning_chunks = [_][]const u8{
        "Let me think through this step by step.\n",
        "First, I need to understand what the user is asking for.\n",
        "The request seems to be about testing the reasoning display.\n",
        "I should consider a few different approaches before answering.\n",
        "One option is to give a short, direct answer.\n",
        "Another option is to explain my reasoning in more detail first.\n",
        "I'll weigh the tradeoffs of each approach.\n",
        "A more detailed answer is probably more helpful here.\n",
        "Let me also double-check that I'm not missing any context.\n",
        "I don't see any missing context, so I can proceed.\n",
        "Now let me draft the final response.\n",
        "I think I have enough reasoning to produce a good answer now.\n",
    };

    for (reasoning_chunks) |chunk| {
        try callback.emit(.{ .reasoning = chunk });
        try emitDelay(speed, io);
    }

    const content_chunks = [_][]const u8{
        "This is a **mock response**.\n\n",
        "You said: ",
        user_message,
        "\n\nThe reasoning above was mock output for verifying --show-thinking rendering.",
    };
    for (content_chunks) |chunk| {
        try callback.emit(.{ .content = chunk });
        try emitDelay(speed, io);
    }
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

fn respondWithTable(callback: openai.StreamCallback, speed: MockSpeed, io: std.Io) !void {
    const header = "| ID | Name | Department | Position | Salary | Start Date |\n";
    const separator = "| --- | --- | --- | --- | --- | --- |\n";
    const rows = [_][]const u8{
        "| 101 | Alice Johnson | Engineering | Senior Developer | $120,000 | 2020-03-15 |\n",
        "| 102 | Bob Smith | Marketing | Marketing Manager | $95,000 | 2019-07-22 |\n",
        "| 103 | Carol Davis | Sales | Sales Representative | $82,000 | 2021-01-10 |\n",
        "| 104 | David Wilson | Engineering | DevOps Engineer | $110,000 | 2022-05-03 |\n",
        "| 105 | Emma Brown | HR | HR Coordinator | $65,000 | 2020-11-18 |\n",
        "| 106 | Frank Miller | Finance | Financial Analyst | $88,000 | 2018-09-01 |\n",
        "| 107 | Grace Taylor | Engineering | Frontend Developer | $105,000 | 2023-02-14 |\n",
        "| 108 | Henry Anderson | Marketing | Content Strategist | $72,000 | 2021-06-30 |\n",
    };

    try callback.emit(.{ .content = "Here is a markdown table with employee data:\n\n" });
    try emitDelay(speed, io);
    try callback.emit(.{ .content = header });
    try emitDelay(speed, io);
    try callback.emit(.{ .content = separator });
    try emitDelay(speed, io);
    for (rows) |row| {
        try callback.emit(.{ .content = row });
        try emitDelay(speed, io);
    }
    try callback.emit(.{ .finish = "stop" });
}

fn respondWithMarkdown(callback: openai.StreamCallback, speed: MockSpeed, io: std.Io) !void {
    const chunks = [_][]const u8{
        "# Complex Markdown Sample\n\n",
        "This paragraph demonstrates **bold**, *italic*, and ***bold+italic*** text styles. It also shows `inline code` with backticks and ~strikethrough~ for deleted text.\n\n",
        "## Headings\n\n",
        "### H3 Subheading\n",
        "#### H4 Subheading\n",
        "##### H5 Subheading\n",
        "###### H6 Subheading\n\n",
        "## Code Blocks\n\n",
        "```zig\nconst std = @import(\"std\");\n\npub fn main() !void {\n    std.debug.print(\"Hello, {s}!\\n\", .{\"World\"});\n}\n```\n\n",
        "```python\ndef fibonacci(n: int) -> int:\n    if n <= 1:\n        return n\n    return fibonacci(n - 1) + fibonacci(n - 2)\n\nprint(fibonacci(10))\n```\n\n",
        "```bash\n$ curl -s https://api.example.com/v1/health | jq '.status'\n\"ok\"\n```\n\n",
        "## Lists\n\n",
        "### Unordered\n\n",
        "- Item **one** with bold\n",
        "- Item *two* with italic\n",
        "  - Nested `code` item\n",
        "  - Nested ***bold+italic*** item\n",
        "- Item three\n\n",
        "### Ordered\n\n",
        "1. First numbered step\n",
        "2. Second numbered step\n",
        "   1. Nested sub-step A\n",
        "   2. Nested sub-step B\n",
        "3. Third numbered step\n\n",
        "### Task Lists\n\n",
        "- [x] Completed task item\n",
        "- [ ] Pending task item\n",
        "- [x] ~Strikethrough~ completed task\n\n",
        "## Blockquotes\n\n",
        "> Single-level blockquote with **bold** and `code`.\n",
        ">\n",
        "> > Nested blockquote with *italic* and `inline`.\n",
        ">\n",
        "> Back to outer blockquote level.\n\n",
        "## Horizontal Rule\n\n",
        "---\n\n",
        "## Links & Images\n\n",
        "[Puny Repository](https://github.com/christianhelle/puny)\n",
        "![Puny Banner](https://via.placeholder.com/200x40?text=Puny)\n\n",
        "## Table\n\n",
        "| Language | Typing | Compiled | Created |\n",
        "| --- | --- | --- | --- |\n",
        "| **Zig** | Static | Yes | 2016 |\n",
        "| *Python* | Dynamic | No | 1991 |\n",
        "| `Rust` | Static | Yes | 2010 |\n",
        "| Go | Static | Yes | 2009 |\n\n",
        "## Escaped Characters\n\n",
        "\\*literal asterisks\\*\n",
        "\\_literal underscores\\_\n",
        "\\`literal backticks\\`\n\n",
        "## Blockquote with Mixed Content\n\n",
        "> **Overview:** Nested formatting examples:\n",
        ">\n",
        "> 1. An ordered list item\n",
        "> 2. Another with `inline code`\n",
        ">    - Unordered sub-item\n",
        ">    - Another sub-item\n",
        ">\n",
        "> ```rust\n",
        "> let msg = \"embedded code block\";\n",
        "> println!(\"{msg}\");\n",
        "> ```\n",
        ">\n",
        "> End of blockquote section.\n",
    };

    for (chunks) |chunk| {
        try callback.emit(.{ .content = chunk });
        try emitDelay(speed, io);
    }
    try callback.emit(.{ .finish = "stop" });
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

// ── Test helpers ─────────────────────────────────────────────────────

const Recorder = struct {
    events: std.ArrayList(openai.StreamEvent),
    allocator: std.mem.Allocator,

    fn callback(self: *Recorder) openai.StreamCallback {
        return .{
            .context = self,
            .vtable = &.{
                .event = event,
                .reset = null,
            },
        };
    }

    fn event(context: *anyopaque, ev: openai.StreamEvent) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        try self.events.append(self.allocator, ev);
    }
};

fn recorder(allocator: std.mem.Allocator) Recorder {
    return .{ .events = .empty, .allocator = allocator };
}

fn joinedContent(arena: std.mem.Allocator, events: []const openai.StreamEvent) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(arena);
    for (events) |ev| {
        switch (ev) {
            .content => |content| try out.appendSlice(arena, content),
            else => {},
        }
    }
    return out.toOwnedSlice(arena);
}

fn joinedReasoning(arena: std.mem.Allocator, events: []const openai.StreamEvent) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(arena);
    for (events) |ev| {
        switch (ev) {
            .reasoning => |text| try out.appendSlice(arena, text),
            else => {},
        }
    }
    return out.toOwnedSlice(arena);
}

// ── Helper tests ────────────────────────────────────────────────────

test "containsWord matches case-insensitively at word boundaries" {
    try std.testing.expect(containsWord("read the file", "read"));
    try std.testing.expect(containsWord("READ THE FILE", "read"));
    try std.testing.expect(containsWord("a long text", "long"));
    try std.testing.expect(containsWord("error", "error"));
    try std.testing.expect(containsWord("ends with echo", "echo"));
    try std.testing.expect(containsWord("prefix error suffix", "error"));
    try std.testing.expect(containsWord("(error)", "error"));
}

test "containsWord rejects substring matches and words with letters on both sides" {
    try std.testing.expect(!containsWord("terror", "error"));
    try std.testing.expect(!containsWord("reader", "read"));
    try std.testing.expect(!containsWord("longest", "long"));
    try std.testing.expect(!containsWord("errored", "error"));
    try std.testing.expect(!containsWord("x", "long"));
}

test "containsWord handles empty and short text" {
    try std.testing.expect(!containsWord("", "read"));
    try std.testing.expect(!containsWord("abc", "abcdef"));
    try std.testing.expect(containsWord("a", "a"));
}

test "isKeyword maps each mock keyword" {
    try std.testing.expect(isKeyword("long response", .long));
    try std.testing.expect(isKeyword("fast mode", .fast));
    try std.testing.expect(isKeyword("slow mode", .slow));
    try std.testing.expect(isKeyword("echo this", .echo));
    try std.testing.expect(isKeyword("empty output", .empty));
    try std.testing.expect(isKeyword("partial response", .partial));
    try std.testing.expect(isKeyword("usage stats", .usage));
    try std.testing.expect(isKeyword("trigger error", .err));
    try std.testing.expect(isKeyword("timeout please", .timeout));
    try std.testing.expect(isKeyword("make it fail", .fail));
    try std.testing.expect(isKeyword("read that file", .read));
    try std.testing.expect(isKeyword("search for it", .search));
    try std.testing.expect(isKeyword("shell command", .shell));
    try std.testing.expect(isKeyword("table of data", .table));
    try std.testing.expect(isKeyword("markdown it", .markdown));
}

test "isKeyword rejects words embedded inside other words" {
    try std.testing.expect(!isKeyword("reader tool", .read));
    try std.testing.expect(!isKeyword("fastest mode", .fast));
    try std.testing.expect(!isKeyword("shellfish", .shell));
    try std.testing.expect(!isKeyword("searching", .search));
    try std.testing.expect(!isKeyword("markdowns", .markdown));
}

test "findLastUserMessage returns the most recent user content" {
    const messages = [_]openai.Message{
        .{ .system = "be concise" },
        .{ .user = "first question" },
        .{ .assistant = .{ .content = "first answer" } },
        .{ .user = "second question" },
    };
    try std.testing.expectEqualStrings("second question", findLastUserMessage(&messages));
}

test "findLastUserMessage returns empty string when no user message exists" {
    const messages = [_]openai.Message{
        .{ .system = "be concise" },
        .{ .assistant = .{ .content = "answer" } },
    };
    try std.testing.expectEqualStrings("", findLastUserMessage(&messages));
    try std.testing.expectEqualStrings("", findLastUserMessage(&.{}));
}

test "isToolResultMessage detects a trailing tool result" {
    const with_tool = [_]openai.Message{
        .{ .user = "read the file" },
        .{ .tool = .{ .tool_call_id = "call_1", .content = "file contents" } },
    };
    try std.testing.expect(isToolResultMessage(&with_tool));

    const without_tool = [_]openai.Message{
        .{ .user = "read the file" },
        .{ .assistant = .{ .content = "done" } },
    };
    try std.testing.expect(!isToolResultMessage(&without_tool));
    try std.testing.expect(!isToolResultMessage(&.{}));
}

// ── Model list tests ─────────────────────────────────────────────────

test "listModels returns the four mock models" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var owned = try mock_client.listModels();
    defer owned.deinit();
    const models = owned.value().models;
    try std.testing.expectEqual(@as(usize, 4), models.len);
    try std.testing.expectEqualStrings("mock-model", models[0].key);
    try std.testing.expectEqualStrings("Mock Model (GPT-4 level)", models[0].display_name);
    try std.testing.expectEqualStrings("mock", models[0].publisher);
    try std.testing.expectEqual(@as(i64, 128000), models[0].max_context_length);
    try std.testing.expectEqualStrings("mock-model-fast", models[1].key);
    try std.testing.expectEqualStrings("mock-model-slow", models[3].key);
}

test "toSharedModels copies mock models into the shared model list" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var owned = try mock_client.listModels();
    var shared = try MockClient.toSharedModels(&owned);
    defer shared.deinit();
    const models = shared.value().models;
    try std.testing.expectEqual(@as(usize, 4), models.len);
    try std.testing.expectEqualStrings("mock-model", models[0].id);
    try std.testing.expectEqualStrings("Mock Model (GPT-4 level)", models[0].display_name);
    try std.testing.expectEqualStrings("mock", models[0].provider);
    try std.testing.expectEqual(@as(i64, 128000), models[0].context_length);
}

// ── Streaming tests ──────────────────────────────────────────────────

fn countTag(events: []const openai.StreamEvent, comptime tag: std.meta.Tag(openai.StreamEvent)) usize {
    var n: usize = 0;
    for (events) |ev| {
        if (std.meta.activeTag(ev) == tag) n += 1;
    }
    return n;
}

fn expectFinish(events: []const openai.StreamEvent, expected: ?[]const u8) !void {
    var i: usize = events.len;
    while (i > 0) {
        i -= 1;
        switch (events[i]) {
            .finish => |f| {
                if (f) |reason| {
                    try std.testing.expectEqualStrings(expected.?, reason);
                } else {
                    try std.testing.expect(expected == null);
                }
                return;
            },
            else => {},
        }
    }
    return error.NoFinishEvent;
}

test "chatStreaming echoes the user message in echo mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "echo hello world" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const content = try joinedContent(arena_state.allocator(), rec.events.items);
    try std.testing.expect(std.mem.indexOf(u8, content, "Echo: echo hello world") != null);
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming emits verbose reasoning before content in reasoning mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "respond with reasoning" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const reasoning = try joinedReasoning(arena_state.allocator(), rec.events.items);
    const content = try joinedContent(arena_state.allocator(), rec.events.items);
    try std.testing.expect(std.mem.indexOf(u8, reasoning, "step by step") != null);
    try std.testing.expect(reasoning.len > 200);
    try std.testing.expect(std.mem.indexOf(u8, content, "mock response") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "You said: respond with reasoning") != null);
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming emits only a finish event in empty mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "empty response" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try std.testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming returns an error in error mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "trigger error please" }},
        .tools = &.{},
    };
    try std.testing.expectError(error.ResponseError, mock_client.chatStreaming(request, rec.callback()));
}

test "chatStreaming emits tool call events in read mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "read the file" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try std.testing.expectEqual(@as(usize, toolCallCount), countTag(rec.events.items, .tool_call_start));
    try std.testing.expectEqual(@as(usize, toolCallCount * 3), countTag(rec.events.items, .tool_call_delta));
    switch (rec.events.items[0]) {
        .tool_call_start => |tc| try std.testing.expectEqualStrings("read_file", tc.name),
        else => return error.ExpectedToolCallStart,
    }
    try expectFinish(rec.events.items, "tool_calls");
}

test "chatStreaming responds with a completion after a tool result" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{
            .{ .user = "read the file" },
            .{ .tool = .{ .tool_call_id = "call_1", .content = "file contents" } },
        },
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const content = try joinedContent(arena_state.allocator(), rec.events.items);
    try std.testing.expect(std.mem.indexOf(u8, content, "Tool executed successfully") != null);
    try std.testing.expectEqual(@as(usize, 0), countTag(rec.events.items, .tool_call_start));
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming emits usage events in usage mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "usage stats" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try std.testing.expectEqual(@as(usize, 1), countTag(rec.events.items, .usage));
    for (rec.events.items) |ev| {
        switch (ev) {
            .usage => |u| {
                try std.testing.expectEqual(@as(i64, 24), u.input_tokens);
                try std.testing.expectEqual(@as(i64, 156), u.output_tokens);
            },
            else => {},
        }
    }
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming renders a markdown table in table mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "table please" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const content = try joinedContent(arena_state.allocator(), rec.events.items);
    try std.testing.expect(std.mem.indexOf(u8, content, "| 101 | Alice Johnson |") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "| --- |") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "| 108 | Henry Anderson |") != null);
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming produces default content without keywords" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "plain question" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const content = try joinedContent(arena_state.allocator(), rec.events.items);
    try std.testing.expect(std.mem.indexOf(u8, content, "mock response") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "You said: plain question") != null);
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming emits a null finish reason in partial mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "partial response" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try expectFinish(rec.events.items, null);
}

test "chatStreaming emits search tool calls" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "search for it" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try std.testing.expectEqual(@as(usize, toolCallCount), countTag(rec.events.items, .tool_call_start));
    switch (rec.events.items[0]) {
        .tool_call_start => |tc| try std.testing.expectEqualStrings("grep_search", tc.name),
        else => return error.ExpectedToolCallStart,
    }
    try expectFinish(rec.events.items, "tool_calls");
}

test "chatStreaming emits shell tool calls" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "run a shell command" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try std.testing.expectEqual(@as(usize, toolCallCount), countTag(rec.events.items, .tool_call_start));
    switch (rec.events.items[0]) {
        .tool_call_start => |tc| try std.testing.expectEqualStrings("execute_shell", tc.name),
        else => return error.ExpectedToolCallStart,
    }
    try expectFinish(rec.events.items, "tool_calls");
}

test "chatStreaming fails on timeout and fail keywords" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();

    {
        var rec = recorder(std.testing.allocator);
        defer rec.events.deinit(std.testing.allocator);
        const request = openai.ChatRequest{
            .model = "mock-model",
            .messages = &.{.{ .user = "please timeout" }},
            .tools = &.{},
        };
        try std.testing.expectError(error.ResponseError, mock_client.chatStreaming(request, rec.callback()));
    }

    {
        var rec = recorder(std.testing.allocator);
        defer rec.events.deinit(std.testing.allocator);
        const request = openai.ChatRequest{
            .model = "mock-model",
            .messages = &.{.{ .user = "make it fail" }},
            .tools = &.{},
        };
        try std.testing.expectError(error.ResponseError, mock_client.chatStreaming(request, rec.callback()));
    }
}

test "chatStreaming long mode streams instantly with the fast keyword" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "long fast response" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try std.testing.expect(rec.events.items.len > 500);
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming renders complex markdown in markdown mode" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "markdown it" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const content = try joinedContent(arena_state.allocator(), rec.events.items);
    try std.testing.expect(std.mem.indexOf(u8, content, "# Complex Markdown Sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "```zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Blockquotes") != null);
    try expectFinish(rec.events.items, "stop");
}

test "chatStreaming slow keyword with empty mode skips delays" {
    var mock_client = MockClient.init(std.testing.allocator, std.testing.io);
    defer mock_client.deinit();
    var rec = recorder(std.testing.allocator);
    defer rec.events.deinit(std.testing.allocator);

    const request = openai.ChatRequest{
        .model = "mock-model",
        .messages = &.{.{ .user = "slow empty output" }},
        .tools = &.{},
    };
    try mock_client.chatStreaming(request, rec.callback());
    try std.testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try expectFinish(rec.events.items, "stop");
}
