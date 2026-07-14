const std = @import("std");
const ansi = @import("ansi.zig");
const indicator = @import("indicator.zig");
const openai = @import("providers/openai.zig");
const provider = @import("providers/provider.zig");
const retry = @import("retry.zig");
const tools = @import("tools");
const tool_display = @import("tool_display.zig");
const usage_estimator = @import("usage.zig");
const cancel = @import("cancel.zig");

fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

pub const PerModelStats = struct {
    turn_count: usize = 0,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    ttft_sum: f64 = 0,
    ttft_count: usize = 0,
    tps_sum: f64 = 0,
    tps_count: usize = 0,
};

pub const ModelEntry = struct {
    model_key: []const u8,
    stats: PerModelStats,
};

pub const SessionStats = struct {
    allocator: std.mem.Allocator,
    models: std.array_list.Managed(ModelEntry),
    active_model_index: ?usize = null,
    start_time: std.Io.Clock.Timestamp,

    // Per-turn streaming state used to reconcile estimates with final usage.
    current_turn_input: i64 = 0,
    current_turn_output: i64 = 0,
    current_turn_reasoning: i64 = 0,
    current_turn_ttft: ?f64 = null,
    current_turn_tps: ?f64 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SessionStats {
        return .{
            .allocator = allocator,
            .models = std.array_list.Managed(ModelEntry).init(allocator),
            .start_time = std.Io.Clock.Timestamp.now(io, .awake),
        };
    }

    pub fn deinit(self: *SessionStats) void {
        self.models.deinit();
    }

    fn activeModelStats(self: *@This()) *PerModelStats {
        return &self.models.items[self.active_model_index.?].stats;
    }

    /// Begin tracking a new model call. Input tokens are known up front and are
    /// added to the running total immediately so cancellation still records them.
    pub fn beginTurn(self: *@This(), model_key: []const u8, input_tokens: i64) void {
        for (self.models.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.model_key, model_key)) {
                self.active_model_index = i;
                break;
            }
        } else {
            self.models.append(.{ .model_key = model_key, .stats = .{} }) catch unreachable;
            self.active_model_index = self.models.items.len - 1;
        }

        self.current_turn_input = input_tokens;
        self.current_turn_output = 0;
        self.current_turn_reasoning = 0;
        self.current_turn_ttft = null;
        self.current_turn_tps = null;
        self.activeModelStats().input_tokens += input_tokens;
    }

    /// Add output tokens as they stream in. The caller is responsible for
    /// estimating from content deltas; finalizeTurn reconciles with provider
    /// usage when the turn ends.
    pub fn addStreamingOutput(self: *@This(), output_tokens: i64, reasoning_output_tokens: ?i64) void {
        const stats = self.activeModelStats();
        stats.output_tokens += output_tokens;
        self.current_turn_output += output_tokens;
        if (reasoning_output_tokens) |r| {
            stats.reasoning_output_tokens += r;
            self.current_turn_reasoning += r;
        }
    }

    /// Record time-to-first-token for the current turn. Safe to call multiple
    /// times; only the first value is kept.
    pub fn addFirstTokenTiming(self: *@This(), ttft_seconds: f64) void {
        if (self.current_turn_ttft != null) return;
        const stats = self.activeModelStats();
        stats.ttft_sum += ttft_seconds;
        stats.ttft_count += 1;
        self.current_turn_ttft = ttft_seconds;
    }

    /// Reconcile the streamed estimates with authoritative provider usage and,
    /// if the turn loop iteration is complete, increment the turn counter.
    pub fn finalizeTurn(self: *@This(), usage: ?openai.TurnUsage, turn_complete: bool) void {
        const stats = self.activeModelStats();
        if (usage) |u| {
            stats.input_tokens += u.input_tokens - self.current_turn_input;
            stats.output_tokens += u.output_tokens - self.current_turn_output;

            if (u.reasoning_output_tokens) |r| {
                stats.reasoning_output_tokens += r - self.current_turn_reasoning;
                self.current_turn_reasoning = r;
            }

            if (u.tokens_per_second) |t| {
                if (self.current_turn_tps) |prev| {
                    stats.tps_sum += t - prev;
                } else {
                    stats.tps_sum += t;
                    stats.tps_count += 1;
                }
                self.current_turn_tps = t;
            }

            if (u.time_to_first_token_seconds) |t| {
                if (self.current_turn_ttft == null) {
                    stats.ttft_sum += t;
                    stats.ttft_count += 1;
                    self.current_turn_ttft = t;
                }
            }
        }

        if (turn_complete) stats.turn_count += 1;
    }

    fn totalTurns(self: *const @This()) usize {
        var total: usize = 0;
        for (self.models.items) |entry| {
            total += entry.stats.turn_count;
        }
        return total;
    }

    pub fn print(self: *const @This(), io: std.Io, writer: *std.Io.Writer) !void {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed_ns = self.start_time.raw.durationTo(now.raw).nanoseconds;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;

        try writer.print("\n\n{s}─── Session Stats ───{s}\n", .{ ansi.dim, ansi.reset });
        try writer.print("  Turns:               {d}\n", .{self.totalTurns()});
        for (self.models.items) |entry| {
            const stats = entry.stats;
            if (stats.turn_count == 0) continue;
            try writer.print("\n{s}─── {s} ───{s}\n", .{ ansi.dim, entry.model_key, ansi.reset });
            try writer.print("  Turns:               {d}\n", .{stats.turn_count});
            try writer.print("  Input tokens:        {d}\n", .{stats.input_tokens});
            try writer.print("  Output tokens:       {d} (reasoning: {d})\n", .{ stats.output_tokens, stats.reasoning_output_tokens });
            try writer.print("  Total tokens:        {d}\n", .{stats.input_tokens + stats.output_tokens});
            if (stats.tps_count > 0) {
                try writer.print("  Avg tokens/sec:      {d:.1}\n", .{stats.tps_sum / @as(f64, @floatFromInt(stats.tps_count))});
            }
            if (stats.ttft_count > 0) {
                try writer.print("  Avg TTFT:            {d:.2}s\n", .{stats.ttft_sum / @as(f64, @floatFromInt(stats.ttft_count))});
            }
        }
        try writer.print("\n  Session duration:    {d:.1}s\n", .{elapsed_s});
        try writer.flush();
    }
};

const PartialToolCall = struct {
    id: []const u8,
    name: []const u8,
    args: std.array_list.Managed(u8),
};

pub const OpenAiAccumulator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: ?*std.Io.Writer,
    session_stats: *SessionStats,
    has_header: bool,
    lines_printed: usize,
    content: std.array_list.Managed(u8),
    partial_calls: std.array_hash_map.Auto(usize, PartialToolCall),
    tool_calls: std.array_list.Managed(openai.ToolCall),
    usage: ?openai.TurnUsage,
    turn_start: std.Io.Clock.Timestamp,
    first_token_recorded: bool,
    has_streamed_output: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stdout: ?*std.Io.Writer, session_stats: *SessionStats) OpenAiAccumulator {
        return .{
            .allocator = allocator,
            .io = io,
            .stdout = stdout,
            .session_stats = session_stats,
            .has_header = false,
            .lines_printed = 0,
            .content = std.array_list.Managed(u8).init(allocator),
            .partial_calls = .{},
            .tool_calls = std.array_list.Managed(openai.ToolCall).init(allocator),
            .usage = null,
            .turn_start = std.Io.Clock.Timestamp.now(io, .awake),
            .first_token_recorded = false,
            .has_streamed_output = false,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.content.deinit();
        var it = self.partial_calls.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.args.deinit();
        }
        self.partial_calls.deinit(self.allocator);
        self.tool_calls.deinit();
    }

    pub fn hasToolCalls(self: *const @This()) bool {
        return self.tool_calls.items.len > 0;
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
                self.session_stats.addStreamingOutput(@intCast(@divFloor(text.len, 4)), null);
                if (self.stdout) |stdout| {
                    if (!self.has_header) {
                        self.has_header = true;
                        try stdout.print("\n", .{});
                    }
                    try stdout.print("{s}{s}{s}", .{ ansi.dim, text, ansi.reset });
                    try stdout.flush();
                }
                self.lines_printed += countNewlines(text);
                try self.content.appendSlice(text);
            },
            .tool_call_start => |tc| {
                const gop = try self.partial_calls.getOrPut(self.allocator, tc.index);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .id = try self.allocator.dupe(u8, tc.id),
                        .name = try self.allocator.dupe(u8, tc.name),
                        .args = std.array_list.Managed(u8).init(self.allocator),
                    };
                }
            },
            .tool_call_delta => |tc| {
                self.has_streamed_output = true;
                self.recordFirstToken();
                self.session_stats.addStreamingOutput(@intCast(@divFloor(tc.arguments.len, 4)), null);
                if (self.partial_calls.getPtr(tc.index)) |partial| {
                    try partial.args.appendSlice(tc.arguments);
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
            try self.tool_calls.append(.{
                .id = entry.value_ptr.id,
                .function = .{
                    .name = entry.value_ptr.name,
                    .arguments = try tools.ownedSliceOrEmpty(&entry.value_ptr.args),
                },
            });
        }
        self.partial_calls.clearRetainingCapacity();
    }

    pub fn replaceWithRendered(self: *@This(), stdout: *std.Io.Writer) !usize {
        if (self.lines_printed == 0 or self.content.items.len == 0) return 0;

        try stdout.print("\x1b[{}A\x1b[J", .{self.lines_printed});
        try stdout.flush();

        try stdout.print("{s}\n", .{self.content.items});
        try stdout.flush();

        self.lines_printed = 0;
        return countNewlines(self.content.items) + 1;
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
            },
        };
    }
};

pub const TurnResult = struct {
    turn_complete: bool,
    usage: ?openai.TurnUsage,
    was_cancelled: bool = false,
    had_error: bool = false,
};

pub fn runTurn(
    prov: *provider.Provider,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    session_stats: *SessionStats,
    random: std.Random,
    model_key: []const u8,
    messages: *std.array_list.Managed(openai.Message),
    tool_definitions: []const openai.ToolDefinition,
    indicator_opt: ?*indicator.ThinkingIndicator,
) !TurnResult {
    const request = openai.ChatRequest{
        .model = model_key,
        .messages = messages.items,
        .tools = tool_definitions,
        .stream = true,
    };

    const input_estimate = usage_estimator.estimateUsage(request.messages, 0).input_tokens;
    session_stats.beginTurn(model_key, input_estimate);

    var accumulator = OpenAiAccumulator.init(arena, io, stdout_writer, session_stats);
    defer accumulator.deinit();
    const callback = accumulator.streamCallback();

    var retry_count: usize = 0;
    const cfg = retry.default_config;

    var cancel_stderr_buf: [128]u8 = undefined;
    var cancel_stderr_fw: std.Io.File.Writer = .init(.stderr(), io, &cancel_stderr_buf);
    const cancel_stderr = &cancel_stderr_fw.interface;

    while (true) {
        cancel.reset();
        cancel.start(io, cancel_stderr) catch {};

        if (prov.chatStreaming(request, callback)) |_| {
            cancel.stop();
            break;
        } else |err| {
            cancel.stop();

            const provider_ttft = if (accumulator.usage) |u| u.time_to_first_token_seconds else null;
            const has_streamed_content = accumulator.has_streamed_output or accumulator.hasToolCalls();
            const indicator_offset = 0;

            if (err == error.Canceled) {
                if (indicator_opt) |i| try i.finish(io, stdout_writer, indicator_offset, false, has_streamed_content, .cancelled, provider_ttft);
                return .{ .turn_complete = true, .usage = accumulator.usage, .was_cancelled = true };
            }

            if (!retry.isTransientError(err)) {
                if (indicator_opt) |i| try i.finish(io, stdout_writer, indicator_offset, false, has_streamed_content, .error_, provider_ttft);
                try stdout_writer.print("\nChat failed: {}\n", .{err});
                try stdout_writer.flush();
                return .{ .turn_complete = true, .usage = accumulator.usage, .had_error = true };
            }

            retry_count += 1;
            if (retry_count >= cfg.max_retries) {
                if (indicator_opt) |i| try i.finish(io, stdout_writer, indicator_offset, false, has_streamed_content, .error_, provider_ttft);
                try stdout_writer.print("\nChat failed after {d} retries: {}\n", .{ cfg.max_retries, err });
                try stdout_writer.flush();
                return .{ .turn_complete = true, .usage = accumulator.usage, .had_error = true };
            }

            var delay_ms: u64 = cfg.base_delay_ms;
            var i: usize = 1;
            while (i < retry_count) : (i += 1) delay_ms *= 2;
            delay_ms += random.intRangeAtMost(u64, 0, cfg.jitter_max_ms);

            try stdout_writer.print("\n{s}Connection error ({}), retrying in {}ms ({d}/{d})...{s}\n", .{ ansi.dim, err, delay_ms, retry_count, cfg.max_retries, ansi.reset });
            try stdout_writer.flush();
            io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
        }
    }

    const turn_usage = if (accumulator.usage) |u| u else usage_estimator.estimateUsage(messages.items, accumulator.content.items.len);

    const provider_ttft = if (accumulator.usage) |u| u.time_to_first_token_seconds else null;
    const has_content = accumulator.content.items.len > 0;
    const has_streamed_content = accumulator.has_streamed_output or accumulator.hasToolCalls() or has_content;

    var content_cursor_offset: usize = 0;
    var content_ends_with_newline = false;
    var final_lines_printed: usize = 0;
    if (has_content) {
        if (accumulator.lines_printed > 0) {
            final_lines_printed = try accumulator.replaceWithRendered(stdout_writer);
            content_cursor_offset = final_lines_printed;
            content_ends_with_newline = true;
        } else {
            content_cursor_offset = 1;
            content_ends_with_newline = false;
        }
    }

    if (accumulator.hasToolCalls()) {
        const assistant_content = try accumulator.cloneAssistantContent(arena) orelse return .{ .turn_complete = true, .usage = turn_usage };
        try messages.append(.{ .assistant = assistant_content });

        var tool_output_lines: usize = 0;
        for (assistant_content.tool_calls.?) |tc| {
            try printToolCall(arena, stdout_writer, tc);
            try stdout_writer.flush();
            tool_output_lines += 1;
            const result = try executeTool(arena, io, tc);
            try messages.append(.{ .tool = .{ .tool_call_id = tc.id, .content = result } });
        }

        const cursor_offset = content_cursor_offset + tool_output_lines;
        if (indicator_opt) |i| try i.finish(io, stdout_writer, cursor_offset, false, has_streamed_content, .done, provider_ttft);
        return .{ .turn_complete = false, .usage = turn_usage };
    }

    if (indicator_opt) |i| try i.finish(io, stdout_writer, content_cursor_offset, content_ends_with_newline, has_streamed_content, .done, provider_ttft);

    if (has_content) {
        const content = try tools.dupeString(arena, accumulator.content.items);
        try messages.append(.{ .assistant = .{ .content = content } });
    }

    return .{ .turn_complete = true, .usage = turn_usage };
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
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try printToolCall(
        std.testing.allocator,
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
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .content = " world" });
    try acc.onEvent(.{ .finish = null });

    try std.testing.expectEqualStrings("Hello world", acc.content.items);
    try std.testing.expect(!acc.hasToolCalls());
}

test "OpenAiAccumulator updates SessionStats while streaming" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 10);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .content = " world" });
    try acc.onEvent(.{ .finish = "stop" });

    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 10), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 2), model_stats.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), model_stats.ttft_count);
}

test "OpenAiAccumulator keeps partial stats on cancellation" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 16);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &stats);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Partial" });
    try acc.onEvent(.{ .content = " output" });

    cancel.reset();
    cancel.setCancelled();
    const result = acc.onEvent(.{ .content = " ignored" });
    try std.testing.expectError(error.Canceled, result);

    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 16), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 3), model_stats.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), model_stats.ttft_count);
}

test "OpenAiAccumulator assembles tool call" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 0);
    var acc = OpenAiAccumulator.init(std.testing.allocator, std.testing.io, null, &stats);
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

test "SessionStats begins turn with input tokens" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 100);
    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 100), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), model_stats.output_tokens);
    try std.testing.expectEqual(@as(usize, 0), model_stats.turn_count);
}

test "SessionStats accumulates streaming output" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 10);
    stats.addStreamingOutput(5, null);
    stats.addStreamingOutput(3, 2);
    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 10), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 8), model_stats.output_tokens);
    try std.testing.expectEqual(@as(i64, 2), model_stats.reasoning_output_tokens);
}

test "SessionStats records TTFT once" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 10);
    stats.addFirstTokenTiming(0.5);
    stats.addFirstTokenTiming(0.7);
    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(usize, 1), model_stats.ttft_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), model_stats.ttft_sum, 0.001);
}

test "SessionStats finalizes turn and reconciles usage" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 10);
    stats.addStreamingOutput(5, null);
    stats.addFirstTokenTiming(0.5);
    stats.finalizeTurn(.{
        .input_tokens = 12,
        .output_tokens = 8,
        .reasoning_output_tokens = 1,
        .tokens_per_second = 10.0,
        .time_to_first_token_seconds = 0.4,
    }, true);

    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(usize, 1), model_stats.turn_count);
    try std.testing.expectEqual(@as(i64, 12), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 8), model_stats.output_tokens);
    try std.testing.expectEqual(@as(i64, 1), model_stats.reasoning_output_tokens);
    try std.testing.expectEqual(@as(usize, 1), model_stats.ttft_count);
    try std.testing.expectEqual(@as(usize, 1), model_stats.tps_count);
}

test "SessionStats keeps partial tokens on cancelled turn" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 20);
    stats.addStreamingOutput(7, null);
    stats.finalizeTurn(null, false);

    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(usize, 0), model_stats.turn_count);
    try std.testing.expectEqual(@as(i64, 20), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 7), model_stats.output_tokens);
}

test "SessionStats attributes usage to correct model" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    stats.beginTurn("model-a", 10);
    stats.addStreamingOutput(5, null);
    stats.finalizeTurn(.{ .input_tokens = 12, .output_tokens = 8 }, true);

    stats.beginTurn("model-b", 20);
    stats.addStreamingOutput(4, null);
    stats.finalizeTurn(.{ .input_tokens = 22, .output_tokens = 6 }, true);

    try std.testing.expectEqual(@as(usize, 2), stats.models.items.len);
    try std.testing.expectEqualStrings("model-a", stats.models.items[0].model_key);
    try std.testing.expectEqualStrings("model-b", stats.models.items[1].model_key);

    const model_a = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(usize, 1), model_a.turn_count);
    try std.testing.expectEqual(@as(i64, 12), model_a.input_tokens);
    try std.testing.expectEqual(@as(i64, 8), model_a.output_tokens);

    const model_b = &stats.models.items[1].stats;
    try std.testing.expectEqual(@as(usize, 1), model_b.turn_count);
    try std.testing.expectEqual(@as(i64, 22), model_b.input_tokens);
    try std.testing.expectEqual(@as(i64, 6), model_b.output_tokens);

    try std.testing.expectEqual(@as(usize, 2), stats.totalTurns());
}

test "SessionStats reuses existing model entry" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    stats.beginTurn("model-a", 10);
    stats.finalizeTurn(.{ .input_tokens = 10, .output_tokens = 5 }, true);

    stats.beginTurn("model-a", 8);
    stats.finalizeTurn(.{ .input_tokens = 8, .output_tokens = 4 }, true);

    try std.testing.expectEqual(@as(usize, 1), stats.models.items.len);
    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(usize, 2), model_stats.turn_count);
    try std.testing.expectEqual(@as(i64, 18), model_stats.input_tokens);
    try std.testing.expectEqual(@as(i64, 9), model_stats.output_tokens);
}

test "SessionStats skips models without finalized turns" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    stats.beginTurn("model-a", 10);
    stats.finalizeTurn(.{ .input_tokens = 10, .output_tokens = 5 }, true);

    stats.beginTurn("model-b", 8);
    stats.finalizeTurn(null, false);

    try std.testing.expectEqual(@as(usize, 2), stats.models.items.len);
    try std.testing.expectEqual(@as(usize, 1), stats.totalTurns());
}
