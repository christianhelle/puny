const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

const linux = if (is_linux) @import("memory/linux.zig") else void{};
const macos = if (is_macos) @import("memory/macos.zig") else void{};
const windows = if (is_windows) @import("memory/windows.zig") else void{};

pub const MemoryStats = struct {
    resident: u64,
    private: u64,
};

pub const resident_label = if (is_linux) "RSS:" else if (is_macos) "App footprint:" else "Working set:";
pub const private_label = if (is_linux) "Private data:" else if (is_macos) "Internal:" else "Private (commit):";

pub fn getMemoryStats(allocator: std.mem.Allocator, io: std.Io) !MemoryStats {
    if (is_linux) return linux.getMemoryStats(allocator, io);
    if (is_macos) return macos.getMemoryStats();
    if (is_windows) return windows.getMemoryStats();
    return error.UnsupportedPlatform;
}

pub fn formatBytes(buf: *[32]u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };

    var idx: usize = 0;
    var divisor: u64 = 1;
    while (idx < 3 and bytes >= divisor * 1024) : (idx += 1) {
        divisor *= 1024;
    }

    const value: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(divisor));

    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d:.1}", .{value}) catch unreachable;

    const trimmed = if (std.mem.endsWith(u8, num_str, ".0"))
        num_str[0 .. num_str.len - 2]
    else
        num_str;

    return std.fmt.bufPrint(buf, "{s} {s}", .{ trimmed, units[idx] }) catch unreachable;
}

test "formatBytes formats various sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
    try std.testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
    try std.testing.expectEqualStrings("1 KB", formatBytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 KB", formatBytes(&buf, 1536));
    try std.testing.expectEqualStrings("1 MB", formatBytes(&buf, 1024 * 1024));
    try std.testing.expectEqualStrings("2.5 MB", formatBytes(&buf, 2_621_440));
    try std.testing.expectEqualStrings("1 GB", formatBytes(&buf, 1024 * 1024 * 1024));
}
