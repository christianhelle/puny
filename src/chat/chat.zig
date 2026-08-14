const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const terminal = @import("../tui/terminal.zig");
const chat_retry = @import("retry.zig");
const stats = @import("stats.zig");
const indicator = @import("../tui/indicator.zig");
const openai = @import("../providers/openai.zig");
const provider = @import("../providers/provider.zig");
const tools = @import("../tools/root.zig");
const tool_display = @import("display.zig");
const usage_estimator = @import("usage.zig");
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

    pub fn assistantContent(self: *const @This()) ?openai.AssistantContent {
        if (self.content.items.len == 0 and !self.hasToolCalls()) return null;
        return .{
            .content = if (self.content.items.len > 0) self.content.items else null,
            .tool_calls = if (self.tool_calls.items.len > 0) self.tool_calls.items else null,
        };
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
                self.has_streamed_output = true;
                self.recordFirstToken();
                if (self.reasoning_shown) {
                    self.reasoning_shown = false;
                    if (self.stdout) |stdout| {
                        try stdout.print("\r\n", .{});
                        try stdout.flush();
                    }
                    self.lines_printed += 1;
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

pub const TurnResult = struct {
    turn_complete: bool,
    usage: ?openai.TurnUsage,
    usage_estimated: bool = false,
    was_cancelled: bool = false,
    had_error: bool = false,
};

pub fn runTurn(
    prov: *provider.Provider,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    session_stats: *stats.SessionStats,
    show_thinking: bool,
    random: std.Random,
    model_key: []const u8,
    reasoning_effort: ?openai.ReasoningEffort,
    messages: *std.ArrayList(openai.Message),
    tool_definitions: []const openai.ToolDefinition,
    indicator_opt: ?*indicator.ThinkingIndicator,
    chat_log: ?*std.Io.Writer,
) !TurnResult {
    const effective_effort = if (reasoning_effort) |e| e else if (show_thinking or chat_log != null) openai.ReasoningEffort.high else null;
    const request = openai.ChatRequest{
        .model = model_key,
        .messages = messages.items,
        .tools = tool_definitions,
        .stream = true,
        .reasoning_effort = effective_effort,
    };

    const input_estimate = usage_estimator.estimateUsage(request.messages, 0).input_tokens;
    session_stats.beginTurn(model_key, input_estimate);

    var accumulator = OpenAiAccumulator.init(arena, io, stdout_writer, session_stats);
    accumulator.show_thinking = show_thinking;
    defer accumulator.deinit();
    // Record partial tokens even when an error interrupts the turn mid-stream.
    errdefer session_stats.finalizeTurn(accumulator.usage, false);
    const callback = accumulator.streamCallback();

    const outcome = try chat_retry.runChatWithRetry(prov, request, callback, io, random, stdout_writer);

    const provider_ttft = if (accumulator.usage) |u| u.time_to_first_token_seconds else null;
    const has_streamed_content = accumulator.has_streamed_output or accumulator.hasToolCalls();
    const indicator_offset = 0;

    switch (outcome) {
        .success => {},
        .cancelled => {
            _ = try accumulator.finishStream();
            if (indicator_opt) |i| try i.finish(io, stdout_writer, indicator_offset, false, has_streamed_content, .cancelled, provider_ttft);
            return .{ .turn_complete = true, .usage = accumulator.usage, .usage_estimated = accumulator.usage == null, .was_cancelled = true };
        },
        .failed => {
            _ = try accumulator.finishStream();
            if (indicator_opt) |i| try i.finish(io, stdout_writer, indicator_offset, false, has_streamed_content, .error_, provider_ttft);
            return .{ .turn_complete = true, .usage = accumulator.usage, .usage_estimated = accumulator.usage == null, .had_error = true };
        },
    }

    const turn_usage_estimated = accumulator.usage == null;
    const turn_usage = if (accumulator.usage) |u| u else usage_estimator.estimateUsage(messages.items, accumulator.estimatedOutputChars());

    const has_content = accumulator.content.items.len > 0;
    const has_streamed_content_after = accumulator.has_streamed_output or accumulator.hasToolCalls() or has_content;

    var content_cursor_offset: usize = 0;
    var content_ends_with_newline = false;
    var final_lines_printed: usize = 0;
    if (has_content) {
        final_lines_printed = try accumulator.finishStream();
        content_cursor_offset = final_lines_printed;
        content_ends_with_newline = true;
    }

    if (accumulator.hasToolCalls()) {
        const assistant_content = try accumulator.cloneAssistantContent(arena) orelse return .{ .turn_complete = true, .usage = turn_usage, .usage_estimated = turn_usage_estimated };
        try messages.append(arena, .{ .assistant = assistant_content });

        if (chat_log) |log| {
            if (accumulator.reasoning.items.len > 0) {
                log.print("[REASONING]\n{s}\n\n", .{accumulator.reasoning.items}) catch {};
            }
            if (assistant_content.content) |c| {
                log.print("[ASSISTANT]\n{s}\n\n", .{c}) catch {};
            }
        }

        var tool_output_lines: usize = 0;
        for (assistant_content.tool_calls.?) |tc| {
            try printToolCall(arena, stdout_writer, tc);
            try stdout_writer.flush();
            tool_output_lines += 1;
            const result = try executeTool(arena, io, tc);
            try messages.append(arena, .{ .tool = .{ .tool_call_id = tc.id, .content = result } });
            if (chat_log) |log| {
                log.print("[TOOL_CALL]\n{s}\n{s}\n\n", .{ tc.function.name, tc.function.arguments }) catch {};
                log.print("[TOOL_RESULT]\n{s}\n\n", .{result}) catch {};
            }
        }

        const cursor_offset = content_cursor_offset + tool_output_lines;
        if (indicator_opt) |i| try i.finish(io, stdout_writer, cursor_offset, false, has_streamed_content_after, .done, provider_ttft);
        return .{ .turn_complete = false, .usage = turn_usage, .usage_estimated = turn_usage_estimated };
    }

    if (indicator_opt) |i| try i.finish(io, stdout_writer, content_cursor_offset, content_ends_with_newline, has_streamed_content_after, .done, provider_ttft);

    if (chat_log) |log| {
        if (accumulator.reasoning.items.len > 0) {
            log.print("[REASONING]\n{s}\n\n", .{accumulator.reasoning.items}) catch {};
        }
    }
    if (has_content) {
        if (chat_log) |log| {
            log.print("[ASSISTANT]\n{s}\n\n", .{accumulator.content.items}) catch {};
        }
        const content = try tools.dupeString(arena, accumulator.content.items);
        try messages.append(arena, .{ .assistant = .{ .content = content } });
    }

    return .{ .turn_complete = true, .usage = turn_usage, .usage_estimated = turn_usage_estimated };
}

fn printToolCall(
    arena: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    tool_call: openai.ToolCall,
) !void {
    const rendered_tool_call = try tool_display.renderToolCall(arena, tool_call);
    try stdout_writer.print("\n{s}🔧 {s}{s}", .{ ansi.dim, rendered_tool_call, ansi.reset });
}

fn executeTool(arena: std.mem.Allocator, io: std.Io, tool_call: openai.ToolCall) ![]const u8 {
    const tool = tools.dispatch(tool_call.function.name) orelse {
        return std.fmt.allocPrint(arena, "Unknown tool: {s}", .{tool_call.function.name});
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, tool_call.function.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return tool.execute(arena, io, parsed.value) catch |err| {
        return std.fmt.allocPrint(arena, "Tool {s} failed: {}", .{ tool_call.function.name, err });
    };
}

test "prints human-friendly tool call output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try printToolCall(
        arena_state.allocator(),
        &output.writer,
        .{
            .id = "call_1",
            .function = .{
                .name = "read_file",
                .arguments = "{\"path\":\"src/main.zig\"}",
            },
        },
    );

    try std.testing.expectEqualStrings(
        "\n\x1b[2m🔧 Reading \"src/main.zig\"\x1b[0m",
        output.written(),
    );
}

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
