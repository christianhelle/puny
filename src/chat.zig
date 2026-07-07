const std = @import("std");
const ansi = @import("ansi.zig");
const lmstudio = @import("providers/lmstudio.zig");
const openai = @import("providers/openai.zig");

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
                try self.stdout.print("\n", .{});
                try self.stdout.flush();
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
                    try self.stdout.print("\n\n{s}─── Response ───{s}\n", .{ ansi.dim, ansi.reset });
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

const PartialToolCall = struct {
    id: []const u8,
    name: []const u8,
    args: std.ArrayList(u8),
};

pub const OpenAiAccumulator = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    partial_calls: std.AutoArrayHashMap(usize, PartialToolCall),
    tool_calls: std.ArrayList(openai.ToolCall),
    finish_reason: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) OpenAiAccumulator {
        return .{
            .allocator = allocator,
            .content = std.ArrayList(u8).init(allocator),
            .partial_calls = std.AutoArrayHashMap(usize, PartialToolCall).init(allocator),
            .tool_calls = std.ArrayList(openai.ToolCall).init(allocator),
            .finish_reason = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.content.deinit();
        var it = self.partial_calls.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.args.deinit();
        }
        self.partial_calls.deinit();
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

    pub fn onEvent(self: *@This(), ev: openai.StreamEvent) !void {
        switch (ev) {
            .content => |text| try self.content.appendSlice(text),
            .tool_call_start => |tc| {
                const gop = try self.partial_calls.getOrPut(tc.index);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .id = try self.allocator.dupe(u8, tc.id),
                        .name = try self.allocator.dupe(u8, tc.name),
                        .args = std.ArrayList(u8).init(self.allocator),
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
        }
    }

    fn finalizeToolCalls(self: *@This()) !void {
        var it = self.partial_calls.iterator();
        while (it.next()) |entry| {
            try self.tool_calls.append(.{
                .id = entry.value_ptr.id,
                .function = .{
                    .name = entry.value_ptr.name,
                    .arguments = try entry.value_ptr.args.toOwnedSlice(),
                },
            });
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
            },
        };
    }
};
