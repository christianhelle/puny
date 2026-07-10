const std = @import("std");
const ansi = @import("ansi.zig");
const lmstudio = @import("providers/lmstudio.zig");
const openai = @import("providers/openai.zig");
const provider = @import("providers/provider.zig");
const retry = @import("retry.zig");
const tools = @import("tools");
const usage_estimator = @import("usage.zig");
const cancel = @import("cancel.zig");
const zz = @import("zigzag");

fn parseStats(obj: std.json.ObjectMap) ?lmstudio.ChatStats {
    const stats_val = obj.get("stats") orelse return null;
    if (stats_val != .object) return null;
    return lmstudio.ChatStats{
        .input_tokens = stats_val.object.get("input_tokens").?.integer,
        .total_output_tokens = stats_val.object.get("total_output_tokens").?.integer,
        .reasoning_output_tokens = stats_val.object.get("reasoning_output_tokens").?.integer,
        .tokens_per_second = @floatCast(stats_val.object.get("tokens_per_second").?.float),
        .time_to_first_token_seconds = @floatCast(stats_val.object.get("time_to_first_token_seconds").?.float),
        .model_load_time_seconds = if (stats_val.object.get("model_load_time_seconds")) |v| @floatCast(v.float) else null,
    };
}

pub const StreamCallback = struct {
    stdout: *std.Io.Writer,
    arena: std.mem.Allocator,
    has_header: bool,
    stats: ?lmstudio.ChatStats,
    response_id: ?[]const u8 = null,

    pub fn event(self: *@This(), data: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.arena, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;

        if (root.object.get("type")) |event_type| {
            if (event_type != .string)
                return;
            if (std.mem.eql(u8, event_type.string, "reasoning.start")) {
                if (!self.has_header) {
                    self.has_header = true;
                }
            } else if (std.mem.eql(u8, event_type.string, "reasoning.delta")) {
                const content = root.object.get("content") orelse return;
                if (content != .string) return;
                try self.stdout.print("{s}{s}{s}", .{ ansi.gray, content.string, ansi.reset });
                try self.stdout.flush();
            } else if (std.mem.eql(u8, event_type.string, "reasoning.end")) {
                try self.stdout.print("\n{s}Done reasoning...{s}\n", .{ ansi.gray, ansi.reset });
                try self.stdout.flush();
            } else if (std.mem.eql(u8, event_type.string, "message.delta")) {
                if (!self.has_header) {
                    self.has_header = true;
                }
                const content = root.object.get("content") orelse return;
                if (content != .string) return;
                try self.stdout.print("{s}{s}{s}", .{ ansi.bright, content.string, ansi.reset });
                try self.stdout.flush();
            } else if (std.mem.eql(u8, event_type.string, "chat.end")) {
                if (root.object.get("result")) |result_val| {
                    if (result_val == .object) {
                        if (parseStats(result_val.object)) |s| {
                            self.stats = s;
                        }

                        if (result_val.object.get("response_id")) |rid| {
                            if (rid == .string) {
                                self.response_id = try self.arena.dupe(u8, rid.string);
                            }
                        }
                    }
                } else if (parseStats(root.object)) |s| {
                    self.stats = s;
                }
            }
        }
    }
};

fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

pub fn printStats(writer: *std.Io.Writer, stats: lmstudio.ChatStats) !void {
    try writer.print("\n\n{s}─── Stats ───{s}\n", .{ ansi.dim, ansi.reset });
    try writer.print("  Input tokens:        {d}\n", .{stats.input_tokens});
    try writer.print("  Output tokens:       {d} (reasoning: {d})\n", .{ stats.total_output_tokens, stats.reasoning_output_tokens });
    try writer.print("  Tokens per second:   {d:.1}\n", .{stats.tokens_per_second});
    try writer.print("  Time to first token: {d:.2}s\n", .{stats.time_to_first_token_seconds});
    if (stats.model_load_time_seconds) |load_time| {
        try writer.print("  Model load time:     {d:.2}s\n", .{load_time});
    }
    try writer.flush();
}

pub const SessionStats = struct {
    turn_count: usize = 0,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    ttft_sum: f64 = 0,
    ttft_count: usize = 0,
    tps_sum: f64 = 0,
    tps_count: usize = 0,
    start_time: std.Io.Clock.Timestamp,

    pub fn init(io: std.Io) SessionStats {
        return .{
            .start_time = std.Io.Clock.Timestamp.now(io, .awake),
        };
    }

    pub fn addTurn(self: *@This(), usage: ?openai.TurnUsage, is_final: bool) void {
        if (is_final) self.turn_count += 1;
        if (usage) |u| {
            self.input_tokens += u.input_tokens;
            self.output_tokens += u.output_tokens;
            if (u.reasoning_output_tokens) |r| {
                self.reasoning_output_tokens += r;
            }
            if (u.time_to_first_token_seconds) |t| {
                self.ttft_sum += t;
                self.ttft_count += 1;
            }
            if (u.tokens_per_second) |t| {
                self.tps_sum += t;
                self.tps_count += 1;
            }
        }
    }

    pub fn print(self: *const @This(), io: std.Io, writer: *std.Io.Writer) !void {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed_ns = self.start_time.raw.durationTo(now.raw).nanoseconds;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;

        try writer.print("\n{s}─── Session Stats ───{s}\n", .{ ansi.dim, ansi.reset });
        try writer.print("  Turns:               {d}\n", .{self.turn_count});
        try writer.print("  Input tokens:        {d}\n", .{self.input_tokens});
        try writer.print("  Output tokens:       {d} (reasoning: {d})\n", .{ self.output_tokens, self.reasoning_output_tokens });
        try writer.print("  Total tokens:        {d}\n", .{self.input_tokens + self.output_tokens});
        try writer.print("  Session duration:    {d:.1}s\n", .{elapsed_s});
        if (self.tps_count > 0) {
            try writer.print("  Avg tokens/sec:      {d:.1}\n", .{self.tps_sum / @as(f64, @floatFromInt(self.tps_count))});
        }
        if (self.ttft_count > 0) {
            try writer.print("  Avg TTFT:            {d:.2}s\n", .{self.ttft_sum / @as(f64, @floatFromInt(self.ttft_count))});
        }
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
    stdout: ?*std.Io.Writer,
    has_header: bool,
    lines_printed: usize,
    content: std.array_list.Managed(u8),
    partial_calls: std.array_hash_map.Auto(usize, PartialToolCall),
    tool_calls: std.array_list.Managed(openai.ToolCall),
    finish_reason: ?[]const u8,
    usage: ?openai.TurnUsage,

    pub fn init(allocator: std.mem.Allocator, stdout: ?*std.Io.Writer) OpenAiAccumulator {
        return .{
            .allocator = allocator,
            .stdout = stdout,
            .has_header = false,
            .lines_printed = 0,
            .content = std.array_list.Managed(u8).init(allocator),
            .partial_calls = .{},
            .tool_calls = std.array_list.Managed(openai.ToolCall).init(allocator),
            .finish_reason = null,
            .usage = null,
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

    pub fn onEvent(self: *@This(), ev: openai.StreamEvent) !void {
        if (cancel.isCancelled()) {
            self.content.clearRetainingCapacity();
            self.tool_calls.clearRetainingCapacity();
            self.finish_reason = null;
            return error.Canceled;
        }
        switch (ev) {
            .content => |text| {
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
                if (self.partial_calls.getPtr(tc.index)) |partial| {
                    try partial.args.appendSlice(tc.arguments);
                }
            },
            .finish => |reason| {
                self.finish_reason = reason;
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

    pub fn replaceWithRendered(self: *@This(), stdout: *std.Io.Writer) !void {
        if (self.lines_printed == 0 or self.content.items.len == 0) return;

        try stdout.print("\x1b[{}A\x1b[J", .{self.lines_printed});
        try stdout.flush();

        var md = zz.Markdown.init();
        const rendered = try md.render(self.allocator, self.content.items);
        defer self.allocator.free(rendered);

        try stdout.print("{s}\n", .{rendered});
        try stdout.flush();

        self.lines_printed = 0;
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
};

pub fn runTurn(
    prov: *provider.Provider,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    random: std.Random,
    model_key: []const u8,
    messages: *std.array_list.Managed(openai.Message),
    tool_definitions: []const openai.ToolDefinition,
) !TurnResult {
    const request = openai.ChatRequest{
        .model = model_key,
        .messages = messages.items,
        .tools = tool_definitions,
        .stream = true,
    };

    var accumulator = OpenAiAccumulator.init(arena, stdout_writer);
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

            if (err == error.Canceled) return error.Canceled;

            if (!retry.isTransientError(err)) {
                try stdout_writer.print("\nChat failed: {}\n", .{err});
                try stdout_writer.flush();
                return .{ .turn_complete = true, .usage = accumulator.usage };
            }

            retry_count += 1;
            if (retry_count >= cfg.max_retries) {
                try stdout_writer.print("\nChat failed after {d} retries: {}\n", .{ cfg.max_retries, err });
                try stdout_writer.flush();
                return .{ .turn_complete = true, .usage = accumulator.usage };
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

    if (accumulator.content.items.len > 0) {
        try accumulator.replaceWithRendered(stdout_writer);
    }

    if (accumulator.hasToolCalls()) {
        const assistant_content = try accumulator.cloneAssistantContent(arena) orelse return .{ .turn_complete = true, .usage = turn_usage };
        try messages.append(.{ .assistant = assistant_content });

        for (assistant_content.tool_calls.?) |tc| {
            try stdout_writer.print("\n{s}🔧 {s} {s}{s}", .{ ansi.dim, tc.function.name, tc.function.arguments, ansi.reset });
            try stdout_writer.flush();
            const result = try executeTool(arena, io, tc);
            try messages.append(.{ .tool = .{ .tool_call_id = tc.id, .content = result } });
        }

        return .{ .turn_complete = false, .usage = turn_usage };
    }

    if (accumulator.content.items.len > 0) {
        const content = try tools.dupeString(arena, accumulator.content.items);
        try messages.append(.{ .assistant = .{ .content = content } });
    }

    return .{ .turn_complete = true, .usage = turn_usage };
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

test "OpenAiAccumulator assembles content" {
    var acc = OpenAiAccumulator.init(std.testing.allocator, null);
    defer acc.deinit();

    try acc.onEvent(.{ .content = "Hello" });
    try acc.onEvent(.{ .content = " world" });
    try acc.onEvent(.{ .finish = null });

    try std.testing.expectEqualStrings("Hello world", acc.content.items);
    try std.testing.expect(!acc.hasToolCalls());
}

test "OpenAiAccumulator assembles tool call" {
    var acc = OpenAiAccumulator.init(std.testing.allocator, null);
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
