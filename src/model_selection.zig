const std = @import("std");
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
    return key;
}

pub fn listModelsWithRetry(prov: *provider.Provider, io: std.Io, comptime retries: usize) !lmstudio.Owned(lmstudio.ListModelsResponse) {
    var retry_count: usize = 0;
    while (true) {
        if (prov.listModels()) |models| return models else |err| {
            retry_count += 1;
            if (retry_count > retries or !retry.isTransientError(err)) return err;
            io.sleep(.{ .nanoseconds = @as(i96, @intCast(200 * retry_count * std.time.ns_per_ms)) }, .awake) catch {};
        }
    }
}
