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

pub fn getMemoryStats(allocator: std.mem.Allocator, io: std.Io) !MemoryStats {
    if (is_linux) return linux.getMemoryStats(allocator, io);
    if (is_macos) return macos.getMemoryStats();
    if (is_windows) return windows.getMemoryStats();
    return error.UnsupportedPlatform;
}
