const std = @import("std");
const config = @import("config.zig");
const lmstudio = @import("providers/lmstudio.zig");
const model_picker = @import("tui/model_picker.zig");
const provider = @import("providers/provider.zig");
const retry = @import("retry.zig");
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
) !?[]const u8 {
    if (model_id) |id| {
        if (skip_validation) {
            return try arena.dupe(u8, id);
        }
        var models = try listModelsWithRetry(prov, io, 0);
        defer models.deinit();
        const found = for (models.value().models) |m| {
            if (std.mem.eql(u8, m.key, id)) break true;
        } else false;
        if (found) {
            return try arena.dupe(u8, id);
        }
        return null;
    }
    var models = try listModelsWithRetry(prov, io, 1);
    defer models.deinit();
    model_picker.setModels(models.value().models);
    var program = zz.Program(ModelPicker).init(init.gpa, io, init.environ_map);
    try program.run();
    const picked = program.model.selected orelse {
        program.deinit();
        return null;
    };
    const key = try arena.dupe(u8, picked);
    program.deinit();

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
) !?[]const u8 {
    const new_key = (try select(prov, model_id, arena, io, init, skip_validation, cfg, environ_map)) orelse {
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

pub fn listModelsWithRetry(prov: anytype, io: std.Io, comptime retries: usize) !lmstudio.Owned(lmstudio.ListModelsResponse) {
    var retry_count: usize = 0;
    while (true) {
        if (prov.listModels()) |models| return models else |err| {
            retry_count += 1;
            if (retry_count > retries or !retry.isTransientError(err)) return err;
            io.sleep(.{ .nanoseconds = @as(i96, @intCast(200 * retry_count * std.time.ns_per_ms)) }, .awake) catch {};
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

test "listModelsWithRetry succeeds on first call" {
    var prov = TestProvider{ .allocator = std.testing.allocator };
    var result = try listModelsWithRetry(&prov, undefined, 0);
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
    const result = listModelsWithRetry(&prov, undefined, 0);
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 1), prov.calls);
}

test "listModelsWithRetry gives up when retries exhausted" {
    var prov = TestProvider{
        .allocator = std.testing.allocator,
        .fail_count = 2,
        .err = error.ConnectionRefused,
    };
    const result = listModelsWithRetry(&prov, undefined, 0);
    try std.testing.expectError(error.ConnectionRefused, result);
    try std.testing.expectEqual(@as(usize, 1), prov.calls);
}
