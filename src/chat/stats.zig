const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const memory = @import("../core/memory.zig");
const openai = @import("../providers/openai.zig");

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
    models: std.ArrayList(ModelEntry),
    active_model_index: ?usize = null,
    start_time: std.Io.Clock.Timestamp,
    session_id: []const u8 = "",

    // Per-turn streaming state used to reconcile estimates with final usage.
    current_turn_input: i64 = 0,
    current_turn_output: i64 = 0,
    current_turn_reasoning: i64 = 0,
    current_turn_ttft: ?f64 = null,
    current_turn_tps: ?f64 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SessionStats {
        return .{
            .allocator = allocator,
            .models = .empty,
            .start_time = std.Io.Clock.Timestamp.now(io, .awake),
        };
    }

    pub fn deinit(self: *SessionStats) void {
        self.models.deinit(self.allocator);
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
            self.models.append(self.allocator, .{ .model_key = model_key, .stats = .{} }) catch unreachable;
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

            // Providers count reasoning tokens inside the output total; track
            // them separately so totals are not double-counted.
            const reasoning = u.reasoning_output_tokens orelse 0;
            const plain_output = @max(@as(i64, 0), u.output_tokens - reasoning);
            stats.output_tokens += plain_output - self.current_turn_output;

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

    /// Total tokens consumed this session across all models, with reasoning
    /// tokens added back so the sum matches the per-turn `in + out` semantics
    /// (SessionStats.output_tokens excludes reasoning).
    pub fn totalTokens(self: *const @This()) i64 {
        var total: i64 = 0;
        for (self.models.items) |entry| {
            total += entry.stats.input_tokens + entry.stats.output_tokens + entry.stats.reasoning_output_tokens;
        }
        return total;
    }
    pub fn print(self: *const @This(), io: std.Io, writer: *std.Io.Writer) !void {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed_ns = self.start_time.raw.durationTo(now.raw).nanoseconds;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;

        const session_label = if (self.session_id.len > 0)
            try std.fmt.allocPrint(self.allocator, "─── Session: {s} ───", .{self.session_id})
        else
            try std.fmt.allocPrint(self.allocator, "─── Session Stats ───", .{});
        defer self.allocator.free(session_label);
        try writer.print("\n\n{s}{s}{s}\n", .{ ansi.dim, session_label, ansi.reset });
        try writer.print("  Turns:               {d}\n", .{self.totalTurns()});
        for (self.models.items) |entry| {
            const stats = entry.stats;
            if (stats.turn_count == 0 and stats.input_tokens == 0 and stats.output_tokens == 0) continue;
            try writer.print("\n{s}─── {s} ───{s}\n", .{ ansi.dim, entry.model_key, ansi.reset });
            if (stats.turn_count == 0) {
                try writer.print("  Turns:               {d} (no completed turns)\n", .{stats.turn_count});
            } else {
                try writer.print("  Turns:               {d}\n", .{stats.turn_count});
            }
            try writer.print("  Input tokens:        {d}\n", .{stats.input_tokens});
            try writer.print("  Output tokens:       {d} (reasoning: {d})\n", .{ stats.output_tokens, stats.reasoning_output_tokens });
            try writer.print("  Total tokens:        {d}\n", .{stats.input_tokens + stats.output_tokens + stats.reasoning_output_tokens});
            if (stats.tps_count > 0) {
                try writer.print("  Avg tokens/sec:      {d:.1}\n", .{stats.tps_sum / @as(f64, @floatFromInt(stats.tps_count))});
            }
            if (stats.ttft_count > 0) {
                try writer.print("  Avg TTFT:            {d:.2}s\n", .{stats.ttft_sum / @as(f64, @floatFromInt(stats.ttft_count))});
            }
        }
        try writer.print("\n  Session duration:    {d:.1}s\n", .{elapsed_s});

        try writer.print("\n{s}─── Memory ───{s}\n", .{ ansi.dim, ansi.reset });
        if (memory.getMemoryStats(self.allocator, io)) |stats| {
            var buf_a: [32]u8 = undefined;
            var buf_b: [32]u8 = undefined;
            try writer.print("  {s:<21}{s}\n", .{ memory.resident_label, memory.formatBytes(&buf_a, stats.resident) });
            try writer.print("  {s:<21}{s}\n", .{ memory.private_label, memory.formatBytes(&buf_b, stats.private) });
        } else |_| {
            try writer.print("  {s:<21}N/A\n", .{memory.resident_label});
            try writer.print("  {s:<21}N/A\n", .{memory.private_label});
        }

        try writer.flush();
    }
};

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
    try std.testing.expectEqual(@as(i64, 7), model_stats.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), model_stats.ttft_count);
    try std.testing.expectEqual(@as(usize, 1), model_stats.tps_count);
    try std.testing.expectEqual(@as(i64, 1), model_stats.reasoning_output_tokens);
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

test "SessionStats.print per-model total includes reasoning tokens" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 10);
    stats.addStreamingOutput(5, 3);
    stats.finalizeTurn(.{ .input_tokens = 12, .output_tokens = 8, .reasoning_output_tokens = 3 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    // 12 in + 5 plain out + 3 reasoning = 20.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Total tokens:        20") != null);
}

test "SessionStats.print shows model with partial turn" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    stats.beginTurn("model-a", 10);
    stats.addStreamingOutput(2, null);
    stats.finalizeTurn(null, false);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "model-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no completed turns") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Input tokens:        10") != null);
}

test "SessionStats.print includes memory section" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "─── Memory ───") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, memory.resident_label) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, memory.private_label) != null);
}

test "SessionStats totalTokens sums input output and reasoning across models" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    stats.beginTurn("model-a", 10);
    stats.addStreamingOutput(5, null);
    stats.finalizeTurn(.{ .input_tokens = 12, .output_tokens = 8, .reasoning_output_tokens = 1 }, true);

    stats.beginTurn("model-b", 20);
    stats.addStreamingOutput(4, null);
    stats.finalizeTurn(.{ .input_tokens = 22, .output_tokens = 6 }, true);

    // model-a: 12 in + 7 plain out + 1 reasoning = 20; model-b: 22 + 6 = 28.
    try std.testing.expectEqual(@as(i64, 48), stats.totalTokens());
}

test "SessionStats totalTokens is zero for an empty session" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    try std.testing.expectEqual(@as(i64, 0), stats.totalTokens());
}

test "SessionStats totalTokens includes reasoning tokens" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 10);
    stats.addStreamingOutput(5, 3);
    stats.finalizeTurn(.{ .input_tokens = 12, .output_tokens = 8, .reasoning_output_tokens = 3 }, true);

    // 12 in + 5 plain out (8 - 3) + 3 reasoning = 20.
    try std.testing.expectEqual(@as(i64, 20), stats.totalTokens());
}
