const std = @import("std");
const core_session = @import("../core/session.zig");

/// Returns a dedicated test directory under `zig-out/test-sessions-index` and
/// wipes any leftovers from an interrupted run so tests start from a clean
/// state.
pub fn testBaseDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const dir = try std.fs.path.join(allocator, &.{ cwd, "zig-out", "test-sessions-index", name });
    cleanupTestDir(io, dir);
    return dir;
}

pub fn cleanupTestDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

pub fn createSessionDir(io: std.Io, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
}

pub fn createTestSessionDir(io: std.Io, base_dir: []const u8, uuid: []const u8, has_prd: bool) !void {
    try createTestSessionDirFull(io, base_dir, uuid, has_prd, false);
}

pub fn createTestSessionDirFull(io: std.Io, base_dir: []const u8, uuid: []const u8, has_prd: bool, has_conversation: bool) !void {
    const dir = try std.fs.path.join(std.testing.allocator, &.{ base_dir, "sessions", uuid });
    defer std.testing.allocator.free(dir);
    try createSessionDir(io, dir);
    if (has_prd) {
        const prd_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "plan.md" });
        defer std.testing.allocator.free(prd_path);
        var file = try std.Io.Dir.cwd().createFile(io, prd_path, .{});
        file.close(io);
    }
    if (has_conversation) {
        const msg_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "messages.json" });
        defer std.testing.allocator.free(msg_path);
        var file = try std.Io.Dir.cwd().createFile(io, msg_path, .{});
        file.close(io);
        const meta_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "session.json" });
        defer std.testing.allocator.free(meta_path);
        var meta_file = try std.Io.Dir.cwd().createFile(io, meta_path, .{});
        defer meta_file.close(io);
        try meta_file.writeStreamingAll(io, "{\"planning_mode\":false,\"first_prompt\":\"hello\"}");
    }
}

pub fn setFileMtime(io: std.Io, path: []const u8, ts: std.Io.Timestamp) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = ts } });
}

/// Test allocator that records the peak number of live bytes it has been asked
/// to hold. Lets a test assert that transient work (like reading each session
/// meta file) is released instead of accumulating in a shared arena.
pub const PeakTrackingAllocator = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *PeakTrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += len;
        if (self.live > self.peak) self.peak = self.live;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live -= memory.len;
        self.live += new_len;
        if (self.live > self.peak) self.peak = self.live;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live -= memory.len;
        self.live += new_len;
        if (self.live > self.peak) self.peak = self.live;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
