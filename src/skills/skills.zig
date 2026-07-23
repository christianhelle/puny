const std = @import("std");

pub const SkillRecord = struct {
    name: []const u8,
    description: ?[]const u8,
    dir_path: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(SkillRecord),
    fully_scanned: bool,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .records = .empty,
            .fully_scanned = false,
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.records.items) |*r| {
            self.allocator.free(r.name);
            if (r.description) |d| self.allocator.free(d);
            self.allocator.free(r.dir_path);
        }
        self.records.deinit(self.allocator);
    }
};

test "init creates empty registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.records.items.len);
    try std.testing.expect(!registry.fully_scanned);
}
