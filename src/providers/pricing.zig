const std = @import("std");

/// Prices are US dollars per million tokens, kept whole: one unit is a
/// billionth of a dollar (a nano-USD) per million tokens.
pub const nano_usd_per_million_tokens = 1_000_000_000;
const tokens_per_million = 1_000_000;

/// The price of one million tokens of each kind.
pub const Rate = struct {
    input: i64,
    output: i64,
    /// Null when the model lists no cache price, in which case cached tokens
    /// cost the same as uncached input.
    cache_read: ?i64 = null,
    cache_write: ?i64 = null,
};

pub const Tier = struct {
    /// The tier applies when a request's prompt is longer than this.
    prompt_tokens_gt: i64,
    rate: Rate,
};

pub const ModelPricing = struct {
    base: Rate,
    /// Long-context tiers, cheapest threshold first.
    tiers: []const Tier = &.{},

    pub fn deinit(self: ModelPricing, allocator: std.mem.Allocator) void {
        if (self.tiers.len > 0) allocator.free(self.tiers);
    }

    /// The rate for a request whose prompt is `prompt_tokens` long. A tier
    /// only applies once the prompt is over its threshold.
    pub fn rateFor(self: ModelPricing, prompt_tokens: i64) Rate {
        var rate = self.base;
        var threshold: ?i64 = null;
        for (self.tiers) |tier| {
            if (prompt_tokens <= tier.prompt_tokens_gt) continue;
            if (threshold) |best| {
                if (tier.prompt_tokens_gt <= best) continue;
            }
            threshold = tier.prompt_tokens_gt;
            rate = tier.rate;
        }
        return rate;
    }

    /// What a request cost, in nano-USD. `prompt_tokens` covers the whole
    /// prompt; the cache counts are parts of it, not additions. An estimate
    /// is fine: the caller passes whatever usage it has.
    pub fn cost(
        self: ModelPricing,
        prompt_tokens: i64,
        cached_input_tokens: i64,
        cache_write_input_tokens: i64,
        output_tokens: i64,
    ) i64 {
        const prompt = @max(prompt_tokens, 0);
        const cached = std.math.clamp(cached_input_tokens, 0, prompt);
        const written = std.math.clamp(cache_write_input_tokens, 0, prompt - cached);
        const uncached = prompt - cached - written;
        const output = @max(output_tokens, 0);

        const rate = self.rateFor(prompt);
        var total: i128 = 0;
        total += @as(i128, uncached) * rate.input;
        total += @as(i128, cached) * (rate.cache_read orelse rate.input);
        total += @as(i128, written) * (rate.cache_write orelse rate.input);
        total += @as(i128, output) * rate.output;
        return roundDiv(total, tokens_per_million);
    }
};

/// Divides half up, so a sub-token charge never rounds to free by accident.
fn roundDiv(numerator: i128, denominator: i128) i64 {
    if (numerator <= 0) return 0;
    const rounded = @divFloor(numerator + @divFloor(denominator, 2), denominator);
    return std.math.cast(i64, rounded) orelse std.math.maxInt(i64);
}

/// What a session knows about the US dollar prices of the model it is calling.
pub const ModelPrices = union(enum) {
    /// The provider does not bill in USD, so costs stay quiet.
    not_billed,
    /// The provider bills in USD but the model's price is not known, so its
    /// cost can only be reported as missing.
    unknown,
    priced: ModelPricing,
};

/// The largest price, in US dollars per million tokens, whose nano-USD value
/// still fits in an i64.
const max_price_usd = 9.0e9;

/// Reads a USD-per-million-token price into nano-USD. Null when the model
/// has no such price or the value cannot be represented, so one odd number in
/// a remote model list cannot abort the CLI.
fn readPrice(value: std.json.Value) ?i64 {
    const usd = switch (value) {
        .integer => |n| @as(f64, @floatFromInt(n)),
        .float => |n| n,
        else => return null,
    };
    // Also rejects NaN and infinity, which would make the cast illegal.
    if (!(usd >= 0 and usd < max_price_usd)) return null;
    return @intFromFloat(@round(usd * @as(f64, @floatFromInt(nano_usd_per_million_tokens))));
}

fn objectField(object: std.json.Value, key: []const u8) ?std.json.Value {
    if (object != .object) return null;
    return object.object.get(key);
}

/// The prices a `{ "price": ..., "cache": ... }` object lists, when it
/// lists them. Missing fields stay null so a tier can fall back.
const Prices = struct {
    price: ?i64 = null,
    cache_read: ?i64 = null,
    cache_write: ?i64 = null,
};

fn readPrices(value: std.json.Value) Prices {
    var prices = Prices{};
    if (objectField(value, "price")) |v| prices.price = readPrice(v);
    if (objectField(value, "cache")) |cache| {
        if (objectField(cache, "read")) |v| prices.cache_read = readPrice(v);
        if (objectField(cache, "write")) |v| prices.cache_write = readPrice(v);
    }
    return prices;
}

/// The token count an override applies above, when it names one.
fn overrideThreshold(override: std.json.Value) ?i64 {
    const when = objectField(override, "when") orelse return null;
    const context = objectField(when, "context") orelse return null;
    const gt = objectField(context, "gt") orelse return null;
    return switch (gt) {
        .integer => |n| if (n > 0) n else null,
        // A threshold outside the i64 range can never be exceeded.
        .float => |n| if (n > 0 and n < 9.0e18) @as(i64, @intFromFloat(n)) else null,
        else => null,
    };
}

fn overridePrices(price: std.json.Value, threshold: i64) Prices {
    const overrides = objectField(price, "overrides") orelse return .{};
    if (overrides != .array) return .{};
    for (overrides.array.items) |override| {
        const tokens = overrideThreshold(override) orelse continue;
        if (tokens == threshold) return readPrices(override);
    }
    return .{};
}

fn collectThresholds(
    allocator: std.mem.Allocator,
    thresholds: *std.ArrayList(i64),
    price: std.json.Value,
) !void {
    const overrides = objectField(price, "overrides") orelse return;
    if (overrides != .array) return;
    for (overrides.array.items) |override| {
        const tokens = overrideThreshold(override) orelse continue;
        if (tokens > 0) try thresholds.append(allocator, tokens);
    }
}

/// Reads a models.dev/OpenCode `cost` object (`cost.text...`), including
/// long-context overrides. Null when the model lists no text prices.
pub fn parseCost(allocator: std.mem.Allocator, cost: std.json.Value) !?ModelPricing {
    const text = objectField(cost, "text") orelse return null;
    const input = objectField(text, "input") orelse return null;
    const output = objectField(text, "output") orelse return null;
    const input_prices = readPrices(input);
    const output_prices = readPrices(output);

    const base = Rate{
        .input = input_prices.price orelse return null,
        .output = output_prices.price orelse return null,
        .cache_read = input_prices.cache_read,
        .cache_write = input_prices.cache_write,
    };

    var thresholds: std.ArrayList(i64) = .empty;
    defer thresholds.deinit(allocator);
    try collectThresholds(allocator, &thresholds, input);
    try collectThresholds(allocator, &thresholds, output);
    if (thresholds.items.len == 0) return .{ .base = base };

    std.mem.sort(i64, thresholds.items, {}, std.sort.asc(i64));
    var tiers: std.ArrayList(Tier) = .empty;
    errdefer tiers.deinit(allocator);
    for (thresholds.items) |threshold| {
        if (tiers.items.len > 0 and tiers.items[tiers.items.len - 1].prompt_tokens_gt == threshold) continue;
        const tier_input = overridePrices(input, threshold);
        const tier_output = overridePrices(output, threshold);
        try tiers.append(allocator, .{
            .prompt_tokens_gt = threshold,
            .rate = .{
                .input = tier_input.price orelse base.input,
                .output = tier_output.price orelse base.output,
                .cache_read = tier_input.cache_read orelse base.cache_read,
                .cache_write = tier_input.cache_write orelse base.cache_write,
            },
        });
    }
    return .{ .base = base, .tiers = try tiers.toOwnedSlice(allocator) };
}

// ── Tests ────────────────────────────────────────────────────────────

fn parseOne(allocator: std.mem.Allocator, json: []const u8) !?ModelPricing {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return parseCost(allocator, parsed.value);
}

test "parseCost reads input output and cache prices as nano-USD" {
    const allocator = std.testing.allocator;
    const pricing = (try parseOne(allocator,
        \\{"text":{"input":{"price":1.74,"cache":{"read":0.145}},"output":{"price":3.48}}}
    )).?;
    defer pricing.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 1_740_000_000), pricing.base.input);
    try std.testing.expectEqual(@as(i64, 3_480_000_000), pricing.base.output);
    try std.testing.expectEqual(@as(?i64, 145_000_000), pricing.base.cache_read);
    try std.testing.expectEqual(@as(?i64, null), pricing.base.cache_write);
    try std.testing.expectEqual(@as(usize, 0), pricing.tiers.len);
}

test "parseCost returns null without text prices" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try parseOne(allocator, "{}")) == null);
    try std.testing.expect((try parseOne(allocator,
        \\{"text":{"input":{"price":1}}}
    )) == null);
}

test "cost splits cached tokens out of the prompt" {
    const pricing = ModelPricing{
        .base = .{ .input = 3_000_000_000, .output = 15_000_000_000, .cache_read = 300_000_000 },
    };
    // 100 uncached input * $3 + 900 cached * $0.30 + 20 output * $15 = $0.00087.
    try std.testing.expectEqual(@as(i64, 870_000), pricing.cost(1_000, 900, 0, 20));
}

test "cost charges cache writes at their own price" {
    const pricing = ModelPricing{
        .base = .{ .input = 3_000_000_000, .output = 15_000_000_000, .cache_read = 300_000_000, .cache_write = 3_750_000_000 },
    };
    // 100 uncached * $3 + 0 cached + 200 written * $3.75 + 0 output = $0.00105.
    try std.testing.expectEqual(@as(i64, 1_050_000), pricing.cost(300, 0, 200, 0));
}

test "cost falls back to the input price when a cache price is missing" {
    const pricing = ModelPricing{ .base = .{ .input = 2_000_000_000, .output = 10_000_000_000 } };
    // Cached and written tokens are charged as ordinary input: 1,000 * $2.
    try std.testing.expectEqual(pricing.cost(1_000, 0, 0, 0), pricing.cost(1_000, 700, 100, 0));
}

test "cost is free for a free model" {
    const pricing = ModelPricing{ .base = .{ .input = 0, .output = 0 } };
    try std.testing.expectEqual(@as(i64, 0), pricing.cost(1_000_000, 500_000, 0, 100_000));
}

test "parseCost ignores prices that cannot be represented" {
    const allocator = std.testing.allocator;
    // A price far outside the i64 nano-USD range leaves the model unpriced
    // instead of aborting on the cast.
    try std.testing.expect((try parseOne(allocator,
        \\{"text":{"input":{"price":1e30},"output":{"price":1}}}
    )) == null);
    try std.testing.expect((try parseOne(allocator,
        \\{"text":{"input":{"price":1},"output":{"price":1e30}}}
    )) == null);
    // Negative prices are not prices either.
    try std.testing.expect((try parseOne(allocator,
        \\{"text":{"input":{"price":-1},"output":{"price":1}}}
    )) == null);
}

test "parseCost ignores an override threshold that cannot be represented" {
    const allocator = std.testing.allocator;
    const pricing = (try parseOne(allocator,
        \\{"text":{
        \\  "input":{"price":1,"overrides":[{"when":{"context":{"gt":1e30}},"price":2}]},
        \\  "output":{"price":2}
        \\}}
    )).?;
    defer pricing.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), pricing.tiers.len);
}

test "cost uses the long-context tier only above its threshold" {
    const pricing = ModelPricing{
        .base = .{ .input = 3_000_000_000, .output = 15_000_000_000 },
        .tiers = &.{.{
            .prompt_tokens_gt = 200_000,
            .rate = .{ .input = 6_000_000_000, .output = 22_500_000_000 },
        }},
    };
    // At exactly 200K the base price applies: 200K * $6 per million is wrong,
    // 200K * $3 per million = $0.60.
    try std.testing.expectEqual(@as(i64, 600_000_000), pricing.cost(200_000, 0, 0, 0));
    // One token over, the whole request is priced at $6 per million.
    try std.testing.expectEqual(@as(i64, 1_200_006_000), pricing.cost(200_001, 0, 0, 0));
}

test "parseCost reads long-context overrides for input and output" {
    const allocator = std.testing.allocator;
    const pricing = (try parseOne(allocator,
        \\{"text":{
        \\  "input":{"price":3,"cache":{"read":0.3},"overrides":[
        \\    {"when":{"context":{"gt":200000}},"price":6,"cache":{"read":0.6}}]},
        \\  "output":{"price":15,"overrides":[
        \\    {"when":{"context":{"gt":200000}},"price":22.5}]}
        \\}}
    )).?;
    defer pricing.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), pricing.tiers.len);
    try std.testing.expectEqual(@as(i64, 200_000), pricing.tiers[0].prompt_tokens_gt);
    try std.testing.expectEqual(@as(i64, 6_000_000_000), pricing.tiers[0].rate.input);
    try std.testing.expectEqual(@as(i64, 22_500_000_000), pricing.tiers[0].rate.output);
    try std.testing.expectEqual(@as(?i64, 600_000_000), pricing.tiers[0].rate.cache_read);
}
