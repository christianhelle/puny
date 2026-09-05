const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const terminal = @import("../tui/terminal.zig");
const stats = @import("stats.zig");
const openai = @import("../providers/openai.zig");
const tools = @import("../tools/root.zig");
const cancel = @import("../core/cancel.zig");
const stream_markdown = @import("../tui/stream_markdown.zig");

fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

const PartialToolCall = struct {
    id: []const u8,
    name: []const u8,
    args: std.ArrayList(u8),
};

pub const OpenAiAccumulator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: ?*std.Io.Writer,
    session_stats: *stats.SessionStats,
    has_header: bool,
    lines_printed: usize,
    content_start_line: usize,
    content: std.ArrayList(u8),
    reasoning: std.ArrayList(u8),
    partial_calls: std.array_hash_map.Auto(usize, PartialToolCall),
    tool_calls: std.ArrayList(openai.ToolCall),
    usage: ?openai.TurnUsage,
    turn_start: std.Io.Clock.Timestamp,
    first_token_recorded: bool,
    has_streamed_output: bool,
    show_thinking: bool,
    reasoning_shown: bool,
    content_started: bool,
    stream: ?stream_markdown.StreamRenderer,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stdout: ?*std.Io.Writer, session_stats: *stats.SessionStats) OpenAiAccumulator {
        return .{
            .allocator = allocator,
            .io = io,
            .stdout = stdout,
            .session_stats = session_stats,
            .has_header = false,
            .lines_printed = 0,
            .content_start_line = 0,
            .content = .empty,
            .reasoning = .empty,
            .partial_calls = .{},
            .tool_calls = .empty,
            .usage = null,
            .turn_start = std.Io.Clock.Timestamp.now(io, .awake),
            .first_token_recorded = false,
            .has_streamed_output = false,
            .show_thinking = false,
            .reasoning_shown = false,
            .content_started = false,
            .stream = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.content.deinit(self.allocator);
        self.reasoning.deinit(self.allocator);
        if (self.stream) |*s| s.deinit();
        var it = self.partial_calls.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.name);
            entry.value_ptr.args.deinit(self.allocator);
        }
        self.partial_calls.deinit(self.allocator);
        for (self.tool_calls.items) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.function.name);
            self.allocator.free(tc.function.arguments);
        }
        self.tool_calls.deinit(self.allocator);
    }

    pub fn hasToolCalls(self: *const @This()) bool {
        return self.tool_calls.items.len > 0;
    }

    /// Output chars for providers that do not report usage: content plus
    /// tool-call arguments, matching what addStreamingOutput counts.
    pub fn estimatedOutputChars(self: *const @This()) usize {
        var chars: usize = self.content.items.len + self.reasoning.items.len;
        for (self.tool_calls.items) |tc| {
            chars += tc.function.arguments.len;
        }
        return chars;
    }

    pub fn cloneAssistantContent(self: *const @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!?openai.AssistantContent {
        if (self.content.items.len == 0 and !self.hasToolCalls()) return null;
        const content = if (self.content.items.len > 0)
            try tools.dupeString(allocator, self.content.items)
        else
            null;
        const tool_calls = if (self.tool_calls.items.len > 0) blk: {
            const arr = try allocator.alloc(openai.ToolCall, self.tool_calls.items.len);
            errdefer allocator.free(arr);
            for (self.tool_calls.items, 0..) |tc, i| {
                arr[i] = .{
                    .id = try tools.dupeString(allocator, tc.id),
                    .function = .{
                        .name = try tools.dupeString(allocator, tc.function.name),
                        .arguments = try tools.dupeString(allocator, tc.function.arguments),
                    },
                };
            }
            break :blk arr;
        } else null;
        return .{
            .content = content,
            .tool_calls = tool_calls,
        };
    }

    /// End an open streamed-reasoning block so whatever is printed next starts
    /// on its own line. Does nothing when no reasoning block is open.
    pub fn finishReasoning(self: *@This()) !void {
        if (!self.reasoning_shown) return;
        self.reasoning_shown = false;
        if (self.stdout) |stdout| {
            try stdout.print("\r\n", .{});
            try stdout.flush();
        }
        self.lines_printed += 1;
    }

    fn recordFirstToken(self: *@This()) void {
        if (self.first_token_recorded) return;
        self.first_token_recorded = true;
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed_ns = self.turn_start.raw.durationTo(now.raw).nanoseconds;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
        self.session_stats.addFirstTokenTiming(elapsed_s);
    }

    pub fn onEvent(self: *@This(), ev: openai.StreamEvent) !void {
        if (cancel.isCancelled()) {
            self.content.clearRetainingCapacity();
            self.tool_calls.clearRetainingCapacity();
            return error.Canceled;
        }
        switch (ev) {
            .content => |text| {
                // Providers may send `"content": ""` alongside every reasoning
                // delta. Such a delta carries no output, and treating it as
                // content would close the reasoning block, breaking streamed
                // thinking text onto a new line for every delta.
                if (text.len == 0) return;
                self.has_streamed_output = true;
                self.recordFirstToken();
                if (self.reasoning_shown) {
                    try self.finishReasoning();
                    self.content_start_line = self.lines_printed;
                    self.content_started = true;
                }
                self.session_stats.addStreamingOutput(@intCast(@divFloor(text.len, 4)), null);
                if (self.stdout) |stdout| {
                    if (!self.content_started) {
                        try stdout.print("\r\n", .{});
                        try stdout.flush();
                        self.lines_printed += 1;
                        self.content_start_line = self.lines_printed;
                        self.content_started = true;
                    }
                    if (self.stream == null) {
                        const width = terminal.terminalWidth() orelse 80;
                        self.stream = stream_markdown.StreamRenderer.init(self.allocator, stdout, width);
                    }
                    const streamer = &self.stream.?;
                    try streamer.push(text);
                    self.lines_printed = self.content_start_line + streamer.contentRows();
                }
                try self.content.appendSlice(self.allocator, text);
            },
            .reasoning => |text| {
                try self.reasoning.appendSlice(self.allocator, text);
                if (self.show_thinking) {
                    self.has_streamed_output = true;
                    self.reasoning_shown = true;
                    if (self.stdout) |stdout| {
                        if (!self.has_header) {
                            self.has_header = true;
                            try stdout.print("\r\n", .{});
                        }
                        try stdout.print("{s}", .{ansi.dim});
                        try terminal.writeWithCRLF(stdout, text);
                        try stdout.print("{s}", .{ansi.reset});
                        try stdout.flush();
                    }
                    self.lines_printed += countNewlines(text);
                }
            },
            .tool_call_start => |tc| {
                const gop = try self.partial_calls.getOrPut(self.allocator, tc.index);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .id = try self.allocator.dupe(u8, tc.id),
                        .name = try self.allocator.dupe(u8, tc.name),
                        .args = .empty,
                    };
                }
            },
            .tool_call_delta => |tc| {
                self.has_streamed_output = true;
                self.recordFirstToken();
                self.session_stats.addStreamingOutput(@intCast(@divFloor(tc.arguments.len, 4)), null);
                if (self.partial_calls.getPtr(tc.index)) |partial| {
                    try partial.args.appendSlice(self.allocator, tc.arguments);
                }
            },
            .finish => {
                try self.finalizeToolCalls();
            },
            .usage => |u| {
                self.usage = u;
            },
        }
    }

    fn finalizeToolCalls(self: *@This()) !void {
        var it = self.partial_calls.iterator();
        while (it.next()) |entry| {
            try self.tool_calls.append(self.allocator, .{
                .id = entry.value_ptr.id,
                .function = .{
                    .name = entry.value_ptr.name,
                    .arguments = try tools.ownedSliceOrEmpty(&entry.value_ptr.args, self.allocator),
                },
            });
        }
        self.partial_calls.clearRetainingCapacity();
    }

    /// Commit the streamed content and return the number of screen rows the
    /// content occupies (plus one for the leading newline before it).
    pub fn finishStream(self: *@This()) !usize {
        if (self.stream) |*s| {
            try s.finish();
            self.lines_printed = self.content_start_line + s.contentRows();
            return s.contentRows() + 1;
        }
        return 0;
    }

    /// Drop streamed content and usage from a failed attempt so a retry
    /// attempt starts from a clean slate. Display state is left untouched.
    pub fn resetForRetry(self: *@This()) void {
        self.content.clearRetainingCapacity();
        self.reasoning.clearRetainingCapacity();
        self.usage = null;
        self.first_token_recorded = false;
        self.has_streamed_output = false;
        for (self.tool_calls.items) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.function.name);
            self.allocator.free(tc.function.arguments);
        }
        self.tool_calls.clearRetainingCapacity();
        var it = self.partial_calls.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.name);
            entry.value_ptr.args.deinit(self.allocator);
        }
        self.partial_calls.clearRetainingCapacity();
    }

    pub fn streamCallback(self: *@This()) openai.StreamCallback {
        return .{
            .context = self,
            .vtable = &.{
                .event = struct {
                    pub fn event(ctx: *anyopaque, ev: openai.StreamEvent) !void {
                        const acc: *OpenAiAccumulator = @ptrCast(@alignCast(ctx));
                        try acc.onEvent(ev);
                    }
                }.event,
                .reset = struct {
                    pub fn reset(ctx: *anyopaque) void {
                        const acc: *OpenAiAccumulator = @ptrCast(@alignCast(ctx));
                        acc.resetForRetry();
                    }
                }.reset,
            },
        };
    }
};

test "OpenAiAccumulator assembles content" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .content = " world" });
    try acc.onEvent(.{ .finish = null });

    try std.testing.expectEqualStrings("Hello world", acc.content.items);
    try std.testing.expect(!acc.hasToolCalls());
}

test "OpenAiAccumulator streams content through the markdown renderer" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, &output.writer, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "# Title\n" });
    try acc.onEvent(.{ .content = "Body" });
    try acc.onEvent(.{ .finish = null });

    try std.testing.expectEqualStrings("# Title\nBody", acc.content.items);
    const rows = try acc.finishStream();
    try std.testing.expectEqual(@as(usize, 3), rows);
    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Body") != null);
}

test "OpenAiAccumulator captures reasoning unconditionally" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .reasoning = "thinking step 1" });
    try acc.onEvent(.{ .reasoning = "thinking step 2" });
    try acc.onEvent(.{ .finish = null });

    try std.testing.expectEqualStrings("thinking step 1thinking step 2", acc.reasoning.items);
    try std.testing.expectEqual(@as(usize, 0), acc.content.items.len);
}

test "OpenAiAccumulator updates SessionStats while streaming" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 10);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .content = " world" });
    try acc.onEvent(.{ .finish = "stop" });

    const model_stats = &session_stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 10), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 2), model_stats.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), model_stats.ttft_count);
}

test "OpenAiAccumulator keeps partial stats on cancellation" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 16);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Partial" });
    try acc.onEvent(.{ .content = " output" });

    cancel.reset();
    defer cancel.reset();
    cancel.setCancelled();
    const result = acc.onEvent(.{ .content = " ignored" });
    try std.testing.expectError(error.Canceled, result);

    const model_stats = &session_stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 16), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 2), model_stats.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), model_stats.ttft_count);
}

test "OpenAiAccumulator estimates output chars including tool call args" {
    cancel.reset();
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .tool_call_start = .{ .index = 0, .id = "call_1", .name = "read_file" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"path\": \"x\"}" } });
    try acc.onEvent(.{ .finish = "tool_calls" });

    try std.testing.expectEqual(@as(usize, 18), acc.estimatedOutputChars());
}

test "OpenAiAccumulator estimates output chars including streamed reasoning" {
    cancel.reset();
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .reasoning = "reasoning steps" });
    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .finish = "stop" });

    // 15 reasoning chars + 5 content chars.
    try std.testing.expectEqual(@as(usize, 20), acc.estimatedOutputChars());
}

test "OpenAiAccumulator assembles tool call" {
    cancel.reset();
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .tool_call_start = .{ .index = 0, .id = "call_1", .name = "read_file" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"path\": \"" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "src/main.zig\"}" } });
    try acc.onEvent(.{ .finish = "tool_calls" });

    try std.testing.expect(acc.hasToolCalls());
    try std.testing.expectEqual(@as(usize, 1), acc.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", acc.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read_file", acc.tool_calls.items[0].function.name);
    try std.testing.expectEqualStrings("{\"path\": \"src/main.zig\"}", acc.tool_calls.items[0].function.arguments);
}

test "countNewlines counts line breaks" {
    try std.testing.expectEqual(@as(usize, 0), countNewlines(""));
    try std.testing.expectEqual(@as(usize, 0), countNewlines("no breaks"));
    try std.testing.expectEqual(@as(usize, 1), countNewlines("a\nb"));
    try std.testing.expectEqual(@as(usize, 3), countNewlines("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 2), countNewlines("\n\n"));
}

test "OpenAiAccumulator ignores tool deltas for unknown indexes" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .tool_call_delta = .{ .index = 7, .arguments = "{}" } });
    try acc.onEvent(.{ .finish = "tool_calls" });

    try std.testing.expect(!acc.hasToolCalls());
}

test "OpenAiAccumulator keeps the first tool call start for a repeated index" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .tool_call_start = .{ .index = 0, .id = "first", .name = "read_file" } });
    try acc.onEvent(.{ .tool_call_start = .{ .index = 0, .id = "second", .name = "grep_search" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "{}" } });
    try acc.onEvent(.{ .finish = "tool_calls" });

    try std.testing.expectEqual(@as(usize, 1), acc.tool_calls.items.len);
    try std.testing.expectEqualStrings("first", acc.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read_file", acc.tool_calls.items[0].function.name);
}

test "OpenAiAccumulator assembles interleaved tool call deltas" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .tool_call_start = .{ .index = 0, .id = "call_0", .name = "read_file" } });
    try acc.onEvent(.{ .tool_call_start = .{ .index = 1, .id = "call_1", .name = "list_directory" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"path\":" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 1, .arguments = "{\"path\":" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "\"x\"}" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 1, .arguments = "\"y\"}" } });
    try acc.onEvent(.{ .finish = "tool_calls" });

    try std.testing.expectEqual(@as(usize, 2), acc.tool_calls.items.len);
    try std.testing.expectEqualStrings("read_file", acc.tool_calls.items[0].function.name);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", acc.tool_calls.items[0].function.arguments);
    try std.testing.expectEqualStrings("list_directory", acc.tool_calls.items[1].function.name);
    try std.testing.expectEqualStrings("{\"path\":\"y\"}", acc.tool_calls.items[1].function.arguments);
}

test "OpenAiAccumulator records usage events" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try std.testing.expect(acc.usage == null);
    try acc.onEvent(.{ .usage = .{ .input_tokens = 10, .output_tokens = 5 } });

    try std.testing.expect(acc.usage != null);
    try std.testing.expectEqual(@as(i64, 10), acc.usage.?.input_tokens);
    try std.testing.expectEqual(@as(i64, 5), acc.usage.?.output_tokens);
}

test "OpenAiAccumulator cloneAssistantContent deep-copies" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .tool_call_start = .{ .index = 0, .id = "call_1", .name = "read_file" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "{}" } });
    try acc.onEvent(.{ .finish = "tool_calls" });

    const cloned = (try acc.cloneAssistantContent(std.testing.allocator)).?;
    defer {
        std.testing.allocator.free(cloned.content.?);
        for (cloned.tool_calls.?) |tc| {
            std.testing.allocator.free(tc.id);
            std.testing.allocator.free(tc.function.name);
            std.testing.allocator.free(tc.function.arguments);
        }
        std.testing.allocator.free(cloned.tool_calls.?);
    }

    try std.testing.expectEqualStrings("Hello", cloned.content.?);
    try std.testing.expect(cloned.content.?.ptr != acc.content.items.ptr);
    try std.testing.expectEqualStrings("call_1", cloned.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("read_file", cloned.tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{}", cloned.tool_calls.?[0].function.arguments);
}

test "OpenAiAccumulator cloneAssistantContent returns null when empty" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try std.testing.expect((try acc.cloneAssistantContent(std.testing.allocator)) == null);
}

test "OpenAiAccumulator finishStream returns zero without a stream" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "x" });
    try std.testing.expectEqual(@as(usize, 0), try acc.finishStream());
}

test "OpenAiAccumulator streamCallback reset clears partial state" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &session_stats);
    defer acc.deinit();

    const callback = acc.streamCallback();
    try callback.emit(.{ .content = "Hello" });
    try callback.emit(.{ .reasoning = "thinking" });
    try callback.emit(.{ .usage = .{ .input_tokens = 1, .output_tokens = 2 } });
    try callback.emit(.{ .tool_call_start = .{ .index = 0, .id = "call_1", .name = "read_file" } });
    try callback.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "{}" } });
    try callback.emit(.{ .finish = "tool_calls" });

    callback.reset();

    try std.testing.expectEqual(@as(usize, 0), acc.content.items.len);
    try std.testing.expectEqual(@as(usize, 0), acc.reasoning.items.len);
    try std.testing.expect(acc.usage == null);
    try std.testing.expect(!acc.hasToolCalls());
    try std.testing.expect(!acc.has_streamed_output);
}

test "OpenAiAccumulator prints dimmed reasoning when show thinking is enabled" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, &output.writer, &session_stats);
    defer acc.deinit();
    acc.show_thinking = true;

    try acc.onEvent(.{ .reasoning = "thinking\n" });
    try acc.onEvent(.{ .reasoning = " more\n" });
    try acc.onEvent(.{ .content = "answer" });
    try acc.onEvent(.{ .finish = "stop" });

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, ansi.dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, " more") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\r\n") != null);
    try std.testing.expectEqualStrings("answer", acc.content.items);
}

test "OpenAiAccumulator keeps reasoning on one line when empty content deltas interleave" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, &output.writer, &session_stats);
    defer acc.deinit();
    acc.show_thinking = true;

    // Some providers send `"content": ""` alongside every reasoning delta.
    try acc.onEvent(.{ .content = "" });
    try acc.onEvent(.{ .reasoning = "Windows environment." });
    try acc.onEvent(.{ .content = "" });
    try acc.onEvent(.{ .reasoning = " Let me use different commands." });
    try acc.onEvent(.{ .content = "" });

    const written = output.written();
    var breaks: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, written, i, "\r\n")) |pos| {
        breaks += 1;
        i = pos + 2;
    }
    // Only the newline that opens the reasoning block; none between deltas.
    try std.testing.expectEqual(@as(usize, 1), breaks);
    try std.testing.expectEqual(@as(usize, 0), acc.content.items.len);
}

test "OpenAiAccumulator finishReasoning closes the block once" {
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, &output.writer, &session_stats);
    defer acc.deinit();
    acc.show_thinking = true;

    try acc.onEvent(.{ .reasoning = "planning" });
    const before = output.written().len;
    try acc.finishReasoning();
    try std.testing.expectEqualStrings("\r\n", output.written()[before..]);

    const after_first = output.written().len;
    try acc.finishReasoning();
    try std.testing.expectEqual(after_first, output.written().len);
}
test "OpenAiAccumulator cancellation clears content and tool calls" {
    cancel.reset();
    defer cancel.reset();
    var session_stats = stats.SessionStats.init(std.testing.allocator, std.testing.io);
    defer session_stats.deinit();
    session_stats.beginTurn("model-a", 0);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var acc = OpenAiAccumulator.init(arena_state.allocator(), std.testing.io, null, &session_stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Partial" });
    try acc.onEvent(.{ .tool_call_start = .{ .index = 0, .id = "call_1", .name = "read_file" } });
    try acc.onEvent(.{ .tool_call_delta = .{ .index = 0, .arguments = "{}" } });
    try acc.onEvent(.{ .finish = "tool_calls" });
    try std.testing.expect(acc.hasToolCalls());

    cancel.setCancelled();
    try std.testing.expectError(error.Canceled, acc.onEvent(.{ .content = "ignored" }));

    try std.testing.expectEqual(@as(usize, 0), acc.content.items.len);
    try std.testing.expect(!acc.hasToolCalls());
}
