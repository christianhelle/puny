const std = @import("std");
const ansi = @import("../tui/ansi.zig");
const config = @import("../config/config.zig");
const effort_picker = @import("../tui/effort_picker.zig");
const client = @import("../providers/client.zig");
const model_picker = @import("../tui/model_picker.zig");
const openai = @import("../providers/openai.zig");
const provider = @import("../providers/provider.zig");
const retry = @import("../core/retry.zig");
const test_support = @import("../test_support.zig");

pub const SelectionResult = struct {
    model_key: []const u8,
    reasoning_effort: ?openai.ReasoningEffort,
};

pub fn select(
    prov: *provider.Provider,
    model_id: ?[]const u8,
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    skip_validation: bool,
    cfg: ?*config.Config,
    current_provider: provider.ModelProvider,
    environ_map: *const std.process.Environ.Map,
    random: std.Random,
) !?SelectionResult {
    if (model_id) |id| {
        if (skip_validation) {
            return .{ .model_key = try arena.dupe(u8, id), .reasoning_effort = null };
        }
        var models = try listModelsWithRetry(prov, io, random, 0);
        defer models.deinit();
        const found = for (models.value().models) |m| {
            if (std.mem.eql(u8, m.id, id)) break true;
        } else false;
        if (found) {
            return .{ .model_key = try arena.dupe(u8, id), .reasoning_effort = null };
        }
        return null;
    }
    var models = try listModelsWithRetry(prov, io, random, 1);
    defer models.deinit();
    model_picker.setModels(models.value().models);
    const key = (try selectModelInteractive(models.value().models, arena, io, init)) orelse return null;
    const effort = (try effort_picker.pickEffort(arena, io)) orelse return null;

    if (cfg) |c| {
        if (client.isValidUtf8(key) and current_provider != .mock) {
            c.providerEntry(current_provider).model = key;
            const effort_str = if (effort != .default) @tagName(effort) else null;
            c.providerEntry(current_provider).reasoning_effort = if (effort_str) |e| try arena.dupe(u8, e) else null;
            config.save(arena, io, c.*, environ_map) catch |err| {
                var stderr_buffer: [1024]u8 = undefined;
                var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
                const stderr_writer = &stderr_file_writer.interface;
                stderr_writer.print("Warning: failed to save selected model to config: {s}\n", .{@errorName(err)}) catch {};
                stderr_writer.flush() catch {};
            };
        }
    }

    return .{ .model_key = key, .reasoning_effort = effort };
}

fn selectModelInteractive(
    models: []const client.Model,
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
) !?[]const u8 {
    _ = init;
    model_picker.setModels(models);
    return model_picker.pickModel(arena, io);
}

pub fn switchModel(
    prov: *provider.Provider,
    model_id: ?[]const u8,
    current_key: []const u8,
    current_effort: ?openai.ReasoningEffort,
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    skip_validation: bool,
    stdout_writer: *std.Io.Writer,
    cfg: ?*config.Config,
    current_provider: provider.ModelProvider,
    environ_map: *const std.process.Environ.Map,
    random: std.Random,
) !?SelectionResult {
    const result = (try select(prov, model_id, arena, io, init, skip_validation, cfg, current_provider, environ_map, random)) orelse {
        if (model_id != null) {
            try stdout_writer.print("\nModel not found.\n", .{});
            try stdout_writer.flush();
        }
        return null;
    };
    const effort_suffix = if (result.reasoning_effort) |effort| if (effort != .default) @tagName(effort) else null else null;
    const same_effort = if (result.reasoning_effort) |new_effort| if (current_effort) |cur| new_effort == cur else false else current_effort == null;
    if (std.mem.eql(u8, result.model_key, current_key) and same_effort) {
        try stdout_writer.print("\nAlready using model {s}", .{result.model_key});
        if (effort_suffix) |suffix| {
            try stdout_writer.print(" - {s}{s}{s}", .{ ansi.bold_start, suffix, ansi.bold_end });
        }
        try stdout_writer.print(".\n", .{});
        try stdout_writer.flush();
        return null;
    }
    try stdout_writer.print("\nSwitched to model {s}", .{result.model_key});
    if (effort_suffix) |suffix| {
        try stdout_writer.print(" - {s}{s}{s}", .{ ansi.bold_start, suffix, ansi.bold_end });
    }
    try stdout_writer.print(".\n", .{});
    try stdout_writer.flush();
    return result;
}

pub fn listModelsWithRetry(prov: anytype, io: std.Io, random: std.Random, comptime retries: usize) !client.Owned(client.ModelsList) {
    var retry_count: usize = 0;
    const cfg = retry.default_config;
    while (true) {
        if (prov.listModels()) |models| return models else |err| {
            retry_count += 1;
            if (retry_count > retries or !retry.isTransientError(err)) return err;

            var delay_ms: u64 = cfg.base_delay_ms;
            var i: usize = 1;
            while (i < retry_count) : (i += 1) delay_ms *= 2;
            delay_ms += random.intRangeAtMost(u64, 0, cfg.jitter_max_ms);

            io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
        }
    }
}

fn emptyListModelsResponse(allocator: std.mem.Allocator) !client.Owned(client.ModelsList) {
    const json = "{\"models\":[]}";
    const body = try allocator.dupe(u8, json);
    errdefer allocator.free(body);
    const parsed = try std.json.parseFromSlice(client.ModelsList, allocator, body, .{ .ignore_unknown_fields = true });
    return .{
        .allocator = allocator,
        .body = body,
        .parsed = parsed,
    };
}

const TestProvider = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,
    fail_count: usize = 0,
    err: anyerror = error.ConnectionRefused,

    pub fn listModels(self: *@This()) !client.Owned(client.ModelsList) {
        self.calls += 1;
        if (self.calls <= self.fail_count) return self.err;
        return emptyListModelsResponse(self.allocator);
    }
};

fn testRandom() std.Random {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    return random_source.interface();
}

test "listModelsWithRetry succeeds on first call" {
    var prov = TestProvider{ .allocator = std.testing.allocator };
    var result = try listModelsWithRetry(&prov, undefined, testRandom(), 0);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), prov.calls);
    try std.testing.expectEqual(@as(usize, 0), result.value().models.len);
}

test "listModelsWithRetry fails fast on non-transient error" {
    var prov = TestProvider{
        .allocator = std.testing.allocator,
        .fail_count = 1,
        .err = error.OutOfMemory,
    };
    const result = listModelsWithRetry(&prov, undefined, testRandom(), 0);
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 1), prov.calls);
}

test "listModelsWithRetry gives up when retries exhausted" {
    var prov = TestProvider{
        .allocator = std.testing.allocator,
        .fail_count = 2,
        .err = error.ConnectionRefused,
    };
    const result = listModelsWithRetry(&prov, undefined, testRandom(), 0);
    try std.testing.expectError(error.ConnectionRefused, result);
    try std.testing.expectEqual(@as(usize, 1), prov.calls);
}

test "listModelsWithRetry sleeps the canonical backoff delay between retries" {
    var recorder: test_support.RecordingIo = undefined;
    recorder.init(std.testing.allocator);
    defer recorder.deinit();

    var prov = TestProvider{
        .allocator = std.testing.allocator,
        .fail_count = 2,
        .err = error.ConnectionRefused,
    };
    var prng = std.Random.DefaultPrng.init(42);
    var result = try listModelsWithRetry(&prov, recorder.io, prng.random(), 2);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), prov.calls);

    var expect_prng = std.Random.DefaultPrng.init(42);
    const expected_1: i96 = @intCast(retry.computeDelay(retry.default_config, 1, expect_prng.random()) * std.time.ns_per_ms);
    const expected_2: i96 = @intCast(retry.computeDelay(retry.default_config, 2, expect_prng.random()) * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(usize, 2), recorder.sleeps.items.len);
    try std.testing.expectEqual(expected_1, recorder.sleeps.items[0]);
    try std.testing.expectEqual(expected_2, recorder.sleeps.items[1]);
}

test "select skips validation when requested" {
    var prov = provider.Provider{ .mock = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer prov.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try select(&prov, "any-model", arena.allocator(), std.testing.io, undefined, true, null, .mock, undefined, testRandom());
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("any-model", result.?.model_key);
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, null), result.?.reasoning_effort);
}

test "select returns the validated model id when it exists" {
    var prov = provider.Provider{ .mock = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer prov.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try select(&prov, "mock-model", arena.allocator(), std.testing.io, undefined, false, null, .mock, undefined, testRandom());
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("mock-model", result.?.model_key);
    try std.testing.expectEqual(@as(?openai.ReasoningEffort, null), result.?.reasoning_effort);
}

test "select returns null when the model id is unknown" {
    var prov = provider.Provider{ .mock = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer prov.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try select(&prov, "no-such-model", arena.allocator(), std.testing.io, undefined, false, null, .mock, undefined, testRandom());
    try std.testing.expect(result == null);
}

test "switchModel reports when the requested model is not found" {
    var prov = provider.Provider{ .mock = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer prov.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const result = try switchModel(&prov, "no-such-model", "mock-model", null, arena.allocator(), std.testing.io, undefined, false, &output.writer, null, .mock, undefined, testRandom());
    try std.testing.expect(result == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Model not found.") != null);
}

test "switchModel returns the new selection when the model changes" {
    var prov = provider.Provider{ .mock = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer prov.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const result = try switchModel(&prov, "mock-model-fast", "mock-model", null, arena.allocator(), std.testing.io, undefined, false, &output.writer, null, .mock, undefined, testRandom());
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("mock-model-fast", result.?.model_key);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Switched to model mock-model-fast") != null);
}

test "switchModel rejects switching to the current model and effort" {
    var prov = provider.Provider{ .mock = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer prov.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const result = try switchModel(&prov, "mock-model", "mock-model", null, arena.allocator(), std.testing.io, undefined, true, &output.writer, null, .mock, undefined, testRandom());
    try std.testing.expect(result == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Already using model mock-model") != null);
}

test "switchModel switches when only the effort matches" {
    var prov = provider.Provider{ .mock = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer prov.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const result = try switchModel(&prov, "mock-model", "mock-model", .medium, arena.allocator(), std.testing.io, undefined, true, &output.writer, null, .mock, undefined, testRandom());
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("mock-model", result.?.model_key);
}
