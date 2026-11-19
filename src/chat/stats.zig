const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const memory = @import("../core/memory.zig");
const pricing = @import("../providers/pricing.zig");
const token_stats = @import("../tui/token_stats.zig");
const openai = @import("../providers/openai.zig");

pub const PerModelStats = struct {
    turn_count: usize = 0,
    /// Model calls made, several per turn when the model uses tools.
    request_count: usize = 0,
    input_tokens: i64 = 0,
    /// Portion of input_tokens the provider served from its prompt cache.
    cached_input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    ttft_sum: f64 = 0,
    ttft_count: usize = 0,
    tps_sum: f64 = 0,
    tps_count: usize = 0,
    /// AI Credits the provider billed, in billionths of a credit, summed over
    /// the requests that report them.
    nano_ai_credits: i64 = 0,
    /// Requests whose usage carried AI Credits (GitHub Copilot only).
    ai_credit_requests: usize = 0,
    /// US dollars the priced requests cost, in billionths of a dollar.
    nano_usd: i64 = 0,
    /// Requests priced in US dollars.
    priced_requests: usize = 0,
    /// Requests whose provider bills in US dollars (OpenCode Zen only),
    /// priced or not.
    usd_requests: usize = 0,
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

    /// What is known about the USD prices of the model being called.
    current_prices: pricing.ModelPrices = .not_billed,
    /// What the last finalized request cost, in billionths of a dollar, or
    /// null when it was not priced.
    last_request_usd: ?i64 = null,

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

    /// Set what is known about the prices of the model about to be called.
    /// `.not_billed` leaves costs quiet, which is how providers that do not
    /// bill in USD behave.
    pub fn setPrices(self: *@This(), prices: pricing.ModelPrices) void {
        self.current_prices = prices;
    }

    /// Whether the model being called bills in US dollars, whether or not its
    /// price is known.
    pub fn billsUsd(self: *const @This()) bool {
        return std.meta.activeTag(self.current_prices) != .not_billed;
    }

    /// What the last finalized request cost, in billionths of a dollar, or
    /// null when it was not priced.
    pub fn lastRequestUsd(self: *const @This()) ?i64 {
        return self.last_request_usd;
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

        self.activeModelStats().request_count += 1;
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
        self.last_request_usd = null;
        // A USD-billed request with no usage reported cannot be priced either.
        if (usage == null and self.billsUsd()) stats.usd_requests += 1;
        if (usage) |u| {
            stats.input_tokens += u.input_tokens - self.current_turn_input;
            stats.cached_input_tokens += u.cached_input_tokens orelse 0;
            if (u.nano_ai_credits) |nano| {
                stats.nano_ai_credits += nano;
                stats.ai_credit_requests += 1;
            }
            switch (self.current_prices) {
                .not_billed => {},
                .unknown => stats.usd_requests += 1,
                .priced => |rates| {
                    const cost = rates.cost(
                        u.input_tokens,
                        u.cached_input_tokens orelse 0,
                        u.cache_write_input_tokens orelse 0,
                        u.output_tokens,
                    );
                    stats.usd_requests += 1;
                    stats.nano_usd += cost;
                    stats.priced_requests += 1;
                    self.last_request_usd = cost;
                },
            }

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

    /// AI Credits billed this session across all models, or null when no
    /// request reported any (every provider but GitHub Copilot). Partial when
    /// a billed model has requests that reported no cost.
    pub fn totalAiCredits(self: *const @This()) ?token_stats.AiCredits {
        var total: token_stats.AiCredits = .{ .nano = 0 };
        var reported = false;
        for (self.models.items) |entry| {
            if (entry.stats.ai_credit_requests == 0) continue;
            total.nano += entry.stats.nano_ai_credits;
            total.partial = total.partial or entry.stats.ai_credit_requests < entry.stats.request_count;
            reported = true;
        }
        return if (reported) total else null;
    }

    /// US dollars billed this session across all models, or null when no
    /// request was billed in USD (every provider but OpenCode Zen). Partial
    /// when a USD-billed model has requests that could not be priced, even if
    /// none of its requests were priced at all.
    pub fn totalUsd(self: *const @This()) ?token_stats.Usd {
        var total: token_stats.Usd = .{ .nano = 0 };
        var reported = false;
        for (self.models.items) |entry| {
            if (entry.stats.usd_requests == 0) continue;
            total.nano += entry.stats.nano_usd;
            total.partial = total.partial or entry.stats.priced_requests < entry.stats.usd_requests;
            reported = true;
        }
        return if (reported) total else null;
    }

    /// Whether any request this session could be priced in US dollars.
    fn anyPricedUsd(self: *const @This()) bool {
        for (self.models.items) |entry| {
            if (entry.stats.priced_requests > 0) return true;
        }
        return false;
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
        try writer.print("\n{s}{s}{s}\n", .{ ansi.dim, session_label, ansi.reset });
        var session_turns_buf: [32]u8 = undefined;
        try writer.print("  Turns:               {s}\n", .{token_stats.formatGrouped(&session_turns_buf, self.totalTurns())});
        if (self.totalAiCredits()) |credits| {
            var credits_buf: [40]u8 = undefined;
            try writer.print("  AI credits:          {s}\n", .{token_stats.formatCredits(&credits_buf, credits.nano)});
        }
        if (self.totalUsd()) |usd| {
            var usd_buf: [40]u8 = undefined;
            // Without a single priced request the total is unknown, not free.
            const amount = if (self.anyPricedUsd()) token_stats.formatUsd(&usd_buf, usd.nano) else "n/a";
            try writer.print("  Cost (USD):          {s}{s}\n", .{
                amount,
                if (usd.partial) "+" else "",
            });
        }
        for (self.models.items) |entry| {
            const stats = entry.stats;
            if (stats.turn_count == 0 and stats.input_tokens == 0 and stats.output_tokens == 0) continue;
            try writer.print("\n{s}─── {s} ───{s}\n", .{ ansi.dim, entry.model_key, ansi.reset });
            var turns_buf: [32]u8 = undefined;
            const turns = token_stats.formatGrouped(&turns_buf, stats.turn_count);
            if (stats.turn_count == 0) {
                try writer.print("  Turns:               {s} (no completed turns)\n", .{turns});
            } else {
                try writer.print("  Turns:               {s}\n", .{turns});
            }
            var requests_buf: [32]u8 = undefined;
            try writer.print("  Requests:            {s}\n", .{token_stats.formatGrouped(&requests_buf, stats.request_count)});
            var input_buf: [32]u8 = undefined;
            var output_buf: [32]u8 = undefined;
            var reasoning_buf: [32]u8 = undefined;
            var total_buf: [32]u8 = undefined;
            const input = token_stats.formatGrouped(&input_buf, stats.input_tokens);
            if (stats.cached_input_tokens > 0) {
                var cached_buf: [32]u8 = undefined;
                try writer.print("  Input tokens:        {s} (cached: {s})\n", .{
                    input,
                    token_stats.formatGrouped(&cached_buf, stats.cached_input_tokens),
                });
            } else {
                try writer.print("  Input tokens:        {s}\n", .{input});
            }
            try writer.print("  Output tokens:       {s} (reasoning: {s})\n", .{
                token_stats.formatGrouped(&output_buf, stats.output_tokens),
                token_stats.formatGrouped(&reasoning_buf, stats.reasoning_output_tokens),
            });
            try writer.print("  Total tokens:        {s}\n", .{token_stats.formatGrouped(
                &total_buf,
                stats.input_tokens + stats.output_tokens + stats.reasoning_output_tokens,
            )});
            if (stats.ai_credit_requests > 0) {
                var credits_buf: [40]u8 = undefined;
                const credits = token_stats.formatCredits(&credits_buf, stats.nano_ai_credits);
                if (stats.ai_credit_requests < stats.request_count) {
                    try writer.print("  AI credits:          {s} (reported for {d} of {d} requests)\n", .{ credits, stats.ai_credit_requests, stats.request_count });
                } else {
                    try writer.print("  AI credits:          {s}\n", .{credits});
                }
            }
            if (stats.usd_requests > 0) {
                var usd_buf: [40]u8 = undefined;
                const usd = if (stats.priced_requests > 0)
                    token_stats.formatUsd(&usd_buf, stats.nano_usd)
                else
                    "n/a";
                if (stats.priced_requests < stats.usd_requests) {
                    try writer.print("  Cost (USD):          {s} (reported for {d} of {d} requests)\n", .{ usd, stats.priced_requests, stats.usd_requests });
                } else {
                    try writer.print("  Cost (USD):          {s}\n", .{usd});
                }
            }
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

test "SessionStats.print groups large token counts with commas" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 1_234_567);
    stats.finalizeTurn(.{ .input_tokens = 1_234_567, .output_tokens = 89_012, .reasoning_output_tokens = 2_345 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "Input tokens:        1,234,567") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Output tokens:       86,667 (reasoning: 2,345)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Total tokens:        1,323,579") != null);
}

test "SessionStats.print shows cached share of input tokens" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 900);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 5, .cached_input_tokens = 800 }, true);
    stats.beginTurn("model-a", 1_900);
    stats.finalizeTurn(.{ .input_tokens = 2_000, .output_tokens = 5, .cached_input_tokens = 1_000 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Input tokens:        3,000 (cached: 1,800)") != null);
}

test "SessionStats.print groups large turn counts with commas" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 1);
    stats.models.items[0].stats.turn_count = 12_345;

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "Turns:               12,345") != null);
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

test "SessionStats.print starts one blank line below the output before it" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    try std.testing.expect(std.mem.startsWith(u8, output.written(), "\n" ++ ansi.dim ++ "─── Session Stats ───"));
}

test "SessionStats.print counts every request a turn makes" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    // One turn: a tool call, then the reply that follows its result.
    stats.beginTurn("model-a", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5 }, false);
    stats.beginTurn("model-a", 200);
    stats.finalizeTurn(.{ .input_tokens = 200, .output_tokens = 5 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "  Turns:               1\n  Requests:            2\n") != null);
}

test "SessionStats sums the AI Credits each request reports" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5, .nano_ai_credits = 250_000_000 }, false);
    stats.beginTurn("model-a", 200);
    stats.finalizeTurn(.{ .input_tokens = 200, .output_tokens = 5, .nano_ai_credits = 500_000_000 }, true);
    stats.beginTurn("model-a", 300);
    stats.finalizeTurn(null, false);

    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 750_000_000), model_stats.nano_ai_credits);
    try std.testing.expectEqual(@as(usize, 2), model_stats.ai_credit_requests);
}

test "SessionStats.print shows AI Credits per model and for the session" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5, .nano_ai_credits = 1_234_500_000_000 }, true);
    stats.beginTurn("model-b", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5, .nano_ai_credits = 71_277_500 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "  Turns:               2\n  AI credits:          1,234.57\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "  AI credits:          1,234.50\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "  AI credits:          0.07\n") != null);
}

test "SessionStats.print says when some requests reported no AI Credits" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5, .nano_ai_credits = 2_000_000_000 }, false);
    stats.beginTurn("model-a", 200);
    stats.finalizeTurn(null, false);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "  AI credits:          2.00 (reported for 1 of 2 requests)\n") != null);
}

test "SessionStats.totalAiCredits is partial only when a billed model missed a cost" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("billed", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5, .nano_ai_credits = 2_000_000_000 }, true);
    // A model that never reports credits leaves the total complete.
    stats.beginTurn("unbilled", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5 }, true);
    try std.testing.expectEqual(token_stats.AiCredits{ .nano = 2_000_000_000 }, stats.totalAiCredits().?);

    stats.beginTurn("billed", 200);
    stats.finalizeTurn(null, false);
    try std.testing.expectEqual(token_stats.AiCredits{ .nano = 2_000_000_000, .partial = true }, stats.totalAiCredits().?);
}

test "SessionStats.print omits AI Credits when no request reports them" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 100);
    stats.finalizeTurn(.{ .input_tokens = 100, .output_tokens = 5 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "AI credits") == null);
}

// ── USD costs ────────────────────────────────────────────────────────

/// $1 per million input tokens and $2 per million output tokens.
const cheap_pricing = pricing.ModelPricing{
    .base = .{ .input = 1_000_000_000, .output = 2_000_000_000 },
};

test "SessionStats prices a request with the rates set for the model" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.setPrices(.{ .priced = cheap_pricing });
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, true);

    // 1,000 in * $1/M + 500 out * $2/M = $0.002.
    try std.testing.expectEqual(@as(?i64, 2_000_000), stats.lastRequestUsd());
    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(i64, 2_000_000), model_stats.nano_usd);
    try std.testing.expectEqual(@as(usize, 1), model_stats.priced_requests);
}

test "SessionStats prices a long prompt with the rates above its tier" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    // $1/M below 200K tokens, $3/M above it.
    stats.setPrices(.{ .priced = .{
        .base = .{ .input = 1_000_000_000, .output = 2_000_000_000 },
        .tiers = &.{.{
            .prompt_tokens_gt = 200_000,
            .rate = .{ .input = 3_000_000_000, .output = 2_000_000_000 },
        }},
    } });
    stats.beginTurn("model-a", 300_000);
    stats.finalizeTurn(.{ .input_tokens = 300_000, .output_tokens = 0 }, true);

    // 300,000 * $3/M = $0.90.
    try std.testing.expectEqual(@as(?i64, 900_000_000), stats.lastRequestUsd());
}

test "SessionStats leaves costs out when the model has no prices" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, true);

    try std.testing.expectEqual(@as(?i64, null), stats.lastRequestUsd());
    try std.testing.expectEqual(@as(i64, 0), stats.models.items[0].stats.nano_usd);
    try std.testing.expectEqual(@as(usize, 0), stats.models.items[0].stats.priced_requests);
    try std.testing.expectEqual(@as(?token_stats.Usd, null), stats.totalUsd());
}

test "SessionStats.totalUsd sums priced requests and marks a partial total" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.setPrices(.{ .priced = cheap_pricing });
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, false);
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(null, true);

    try std.testing.expectEqual(token_stats.Usd{ .nano = 2_000_000, .partial = true }, stats.totalUsd().?);
}

test "SessionStats marks a total partial when a USD model has no prices" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.setPrices(.unknown);
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, true);

    try std.testing.expect(stats.billsUsd());
    try std.testing.expectEqual(@as(?i64, null), stats.lastRequestUsd());
    const model_stats = &stats.models.items[0].stats;
    try std.testing.expectEqual(@as(usize, 1), model_stats.usd_requests);
    try std.testing.expectEqual(@as(usize, 0), model_stats.priced_requests);
    // Zen billed the request even though its price is unknown, so the zero
    // total must not read as complete.
    try std.testing.expectEqual(token_stats.Usd{ .nano = 0, .partial = true }, stats.totalUsd().?);
}

test "SessionStats.print shows an unknown cost as n/a with a plus" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.setPrices(.unknown);
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "  Cost (USD):          n/a+\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "  Cost (USD):          n/a (reported for 0 of 1 requests)\n") != null);
}

test "SessionStats.print shows the cost per model and for the session" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.setPrices(.{ .priced = .{ .base = .{ .input = 1_000_000_000, .output = 2_000_000_000 } } });
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "  Turns:               1\n  Cost (USD):          $0.002\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "  Cost (USD):          $0.002\n") != null);
}

test "SessionStats.print says when some requests were unpriced" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.setPrices(.{ .priced = cheap_pricing });
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, false);
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(null, false);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "  Cost (USD):          $0.002 (reported for 1 of 2 requests)\n") != null);
}

test "SessionStats.print omits cost when no request was priced" {
    var stats = SessionStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();
    stats.beginTurn("model-a", 1_000);
    stats.finalizeTurn(.{ .input_tokens = 1_000, .output_tokens = 500 }, true);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try stats.print(std.testing.io, &output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Cost (USD)") == null);
}
