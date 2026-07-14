const std = @import("std");
const config = @import("../config/config.zig");
const input = @import("../tui/input.zig");
const lmstudio = @import("../providers/lmstudio.zig");
const model_picker = @import("../tui/model_picker.zig");
const provider = @import("../providers/provider.zig");
const retry = @import("../core/retry.zig");
const zz = @import("zigzag");

const ModelPicker = model_picker.Widget;

pub fn select(
    prov: *provider.Provider,
    model_id: ?[]const u8,
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    skip_validation: bool,
    cfg: ?*config.Config,
    environ_map: *const std.process.Environ.Map,
    random: std.Random,
) !?[]const u8 {
    if (model_id) |id| {
        if (skip_validation) {
            return try arena.dupe(u8, id);
        }
        var models = try listModelsWithRetry(prov, io, random, 0);
        defer models.deinit();
        const found = for (models.value().models) |m| {
            if (std.mem.eql(u8, m.key, id)) break true;
        } else false;
        if (found) {
            return try arena.dupe(u8, id);
        }
        return null;
    }
    var models = try listModelsWithRetry(prov, io, random, 1);
    defer models.deinit();
    const key = (try selectModelInteractive(models.value().models, arena, io, init)) orelse return null;

    if (cfg) |c| {
        c.model = key;
        config.save(arena, io, c.*, environ_map) catch |err| {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
            const stderr_writer = &stderr_file_writer.interface;
            stderr_writer.print("Warning: failed to save selected model to config: {s}\n", .{@errorName(err)}) catch {};
            stderr_writer.flush() catch {};
        };
    }

    return key;
}

fn selectModelInteractive(
    models: []const lmstudio.ModelInfo,
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
) !?[]const u8 {
    model_picker.setModels(models);
    var program = zz.Program(ModelPicker).init(init.gpa, io, init.environ_map);

    program.run() catch |err| {
        program.deinit();

        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        stderr_writer.print("\nCould not open the interactive model picker ({s}). Falling back to text selection.\n", .{@errorName(err)}) catch {};
        stderr_writer.flush() catch {};

        return try selectModelText(models, arena, io);
    };

    const picked = program.model.selected orelse {
        program.deinit();
        return null;
    };
    const key = try arena.dupe(u8, picked);
    program.deinit();
    return key;
}

fn selectModelText(
    models: []const lmstudio.ModelInfo,
    arena: std.mem.Allocator,
    io: std.Io,
) !?[]const u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("\nAvailable models:\n", .{});
    for (models, 0..) |m, i| {
        try stdout_writer.print("  {d}. {s} — {s}\n", .{ i + 1, m.key, m.display_name });
    }
    try stdout_writer.print("\nEnter model number or key: ", .{});
    try stdout_writer.flush();

    var line_alloc: std.Io.Writer.Allocating = .init(arena);
    defer line_alloc.deinit();
    var stdin_buffer: [4096]u8 = undefined;
    const line = try input.readLineSimple(io, &line_alloc, &stdin_buffer) orelse return null;
    if (line.len == 0) return null;

    const idx = std.fmt.parseInt(usize, line, 10) catch null;
    if (idx) |i| {
        if (i > 0 and i <= models.len) return try arena.dupe(u8, models[i - 1].key);
        try stdout_writer.print("Invalid model number.\n", .{});
        try stdout_writer.flush();
        return null;
    }

    return try arena.dupe(u8, line);
}

pub fn switchModel(
    prov: *provider.Provider,
    model_id: ?[]const u8,
    current_key: []const u8,
    arena: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    skip_validation: bool,
    stdout_writer: *std.Io.Writer,
    cfg: ?*config.Config,
    environ_map: *const std.process.Environ.Map,
    random: std.Random,
) !?[]const u8 {
    const new_key = (try select(prov, model_id, arena, io, init, skip_validation, cfg, environ_map, random)) orelse {
        if (model_id != null) {
            try stdout_writer.print("\nModel not found.\n", .{});
            try stdout_writer.flush();
        }
        return null;
    };
    if (std.mem.eql(u8, new_key, current_key)) {
        try stdout_writer.print("\nAlready using model {s}.\n", .{new_key});
        try stdout_writer.flush();
        return null;
    }
    try stdout_writer.print("\nSwitched to model {s}.\n", .{new_key});
    try stdout_writer.flush();
    return new_key;
}

pub fn listModelsWithRetry(prov: anytype, io: std.Io, random: std.Random, comptime retries: usize) !lmstudio.Owned(lmstudio.ListModelsResponse) {
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

fn emptyListModelsResponse(allocator: std.mem.Allocator) !lmstudio.Owned(lmstudio.ListModelsResponse) {
    const json = "{\"models\":[]}";
    const body = try allocator.dupe(u8, json);
    errdefer allocator.free(body);
    const parsed = try std.json.parseFromSlice(lmstudio.ListModelsResponse, allocator, body, .{ .ignore_unknown_fields = true });
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

    pub fn listModels(self: *@This()) !lmstudio.Owned(lmstudio.ListModelsResponse) {
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
