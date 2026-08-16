//! Slow listModelsWithRetry retry tests, run only as part of the regression
//! suite (`zig build test-regression`) so that `zig build test` stays fast.
//! The retry path performs real io.sleep backoff between attempts.
const std = @import("std");
const select = @import("select.zig");
const client = @import("../providers/client.zig");

const TestProvider = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,
    fail_count: usize = 0,

    pub fn listModels(self: *@This()) !client.Owned(client.ModelsList) {
        self.calls += 1;
        if (self.calls <= self.fail_count) return error.ConnectionRefused;
        const json = "{\"models\":[]}";
        const body = try self.allocator.dupe(u8, json);
        errdefer self.allocator.free(body);
        const parsed = try std.json.parseFromSlice(client.ModelsList, self.allocator, body, .{ .ignore_unknown_fields = true });
        return .{
            .allocator = self.allocator,
            .body = body,
            .parsed = parsed,
        };
    }
};

fn testRandom() std.Random {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    return random_source.interface();
}

test "listModelsWithRetry recovers after a transient error" {
    var prov = TestProvider{
        .allocator = std.testing.allocator,
        .fail_count = 1,
    };
    var result = try select.listModelsWithRetry(&prov, std.testing.io, testRandom(), 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), prov.calls);
    try std.testing.expectEqual(@as(usize, 0), result.value().models.len);
}

test "listModelsWithRetry exhausts retries on repeated transient errors" {
    var prov = TestProvider{
        .allocator = std.testing.allocator,
        .fail_count = 3,
    };
    const result = select.listModelsWithRetry(&prov, std.testing.io, testRandom(), 1);
    try std.testing.expectError(error.ConnectionRefused, result);
    try std.testing.expectEqual(@as(usize, 2), prov.calls);
}
