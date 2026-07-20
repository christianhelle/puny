const std = @import("std");
const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

/// Returns the current Resident Set Size (RSS) of the process in bytes.
/// Supported platforms: Linux, macOS, Windows.
/// On unsupported platforms or on error, returns `error.UnsupportedPlatform`.
pub fn getRssBytes(allocator: std.mem.Allocator, io: std.Io) !u64 {
    if (is_linux) {
        return getRssBytesLinux(allocator, io);
    } else if (is_macos) {
        return getRssBytesMacos();
    } else if (is_windows) {
        return getRssBytesWindows();
    }
    return error.UnsupportedPlatform;
}

// ── Linux ────────────────────────────────────────────────────────────

fn getRssBytesLinux(allocator: std.mem.Allocator, io: std.Io) !u64 {
    const data = try std.fs.openFileAbsolute("/proc/self/status", .{}).readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const marker = "VmRSS:";
    const start = std.mem.indexOf(u8, data, marker) orelse return error.MissingVmRSS;
    const after_marker = std.mem.trimLeft(u8, data[start + marker.len..], " \t");
    const kb_end = std.mem.indexOfAny(u8, after_marker, " \t\n\r") orelse after_marker.len;
    const kb_str = after_marker[0..kb_end];
    const kb = try std.fmt.parseInt(u64, kb_str, 10);
    return kb * 1024;
}

// ── macOS ────────────────────────────────────────────────────────────

const mach = if (is_macos) struct {
    pub const mach_port_t = u32;
    pub const kern_return_t = i32;
    pub const natural_t = u32;

    pub const task_vm_info = extern struct {
        virtual_size: u64,
        region_count: u32,
        page_size: u32,
        resident_size: u64,
        resident_size_peak: u64,
        device: u64,
        device_peak: u64,
        internal: u64,
        internal_peak: u64,
        external: u64,
        external_peak: u64,
        reusable: u64,
        reusable_peak: u64,
        purgeable_volatile_pmap: u64,
        purgeable_volatile_resident: u64,
        purgeable_volatile_virtual: u64,
        compressed: u64,
        compressed_peak: u64,
        compressed_lifetime: u64,
        phys_footprint: u64,
        min_address: u64,
        max_address: u64,
        ledger_phys_footprint_peak: u64,
        ledger_phys_footprint_lifetime: u64,
    };

    pub const TASK_VM_INFO: u32 = 4;
    pub const KERN_SUCCESS: kern_return_t = 0;

    pub extern "libSystem" fn mach_task_self() mach_port_t;
    pub extern "libSystem" fn task_info(
        task: mach_port_t,
        flavor: u32,
        info: *task_vm_info,
        info_count: *natural_t,
    ) kern_return_t;
} else void {};

fn getRssBytesMacos() !u64 {
    const self = mach.mach_task_self();
    var info: mach.task_vm_info = undefined;
    var count: mach.natural_t = @sizeOf(mach.task_vm_info) / @sizeOf(mach.natural_t);
    const ret = mach.task_info(self, mach.TASK_VM_INFO, &info, &count);
    if (ret != mach.KERN_SUCCESS) return error.TaskInfoFailed;
    return info.resident_size;
}

// ── Windows ──────────────────────────────────────────────────────────

const windows = if (is_windows) struct {
    pub const HANDLE = *opaque {};
    pub const BOOL = i32;
    pub const DWORD = u32;
    pub const SIZE_T = usize;

    pub const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: DWORD,
        PageFaultCount: DWORD,
        PeakWorkingSetSize: SIZE_T,
        WorkingSetSize: SIZE_T,
        QuotaPeakPagedPoolUsage: SIZE_T,
        QuotaPagedPoolUsage: SIZE_T,
        QuotaPeakNonPagedPoolUsage: SIZE_T,
        QuotaNonPagedPoolUsage: SIZE_T,
        PagefileUsage: SIZE_T,
        PeakPagefileUsage: SIZE_T,
    };

    pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    pub extern "psapi" fn GetProcessMemoryInfo(
        Process: HANDLE,
        ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
        cb: DWORD,
    ) callconv(.winapi) BOOL;
} else void {};

fn getRssBytesWindows() !u64 {
    var counters: windows.PROCESS_MEMORY_COUNTERS = .{ .cb = @sizeOf(windows.PROCESS_MEMORY_COUNTERS) };
    const ret = windows.GetProcessMemoryInfo(
        windows.GetCurrentProcess(),
        &counters,
        @sizeOf(windows.PROCESS_MEMORY_COUNTERS),
    );
    if (ret == 0) return error.GetProcessMemoryInfoFailed;
    return @intCast(counters.WorkingSetSize);
}

// ── Formatting helper ────────────────────────────────────────────────

/// Formats a byte count into a human-friendly string (B, KB, MB, GB).
/// The result is written into `buf` and returned as a slice.
pub fn formatBytes(buf: *[32]u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };
    const thresholds = [_]u64{ 1024, 1024 * 1024, 1024 * 1024 * 1024, std.math.maxInt(u64) };

    var idx: usize = 0;
    while (idx < 3 and bytes >= thresholds[idx + 1]) : (idx += 1) {}

    const value: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(thresholds[idx]));
    const formatted = std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch unreachable;

    // Trim trailing ".0" for integer-friendly display
    const trimmed = if (std.mem.endsWith(u8, formatted, ".0"))
        formatted[0 .. formatted.len - 2]
    else
        formatted;

    return std.fmt.bufPrint(buf, "{s} {s}", .{ trimmed, units[idx] }) catch unreachable;
}

test "getRssBytes returns positive value" {
    const result = try getRssBytes(std.testing.allocator, std.testing.io);
    try std.testing.expect(result > 0);
}

test "formatBytes formats various sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
    try std.testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
    try std.testing.expectEqualStrings("1 KB", formatBytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 KB", formatBytes(&buf, 1536));
    try std.testing.expectEqualStrings("1 MB", formatBytes(&buf, 1024 * 1024));
    try std.testing.expectEqualStrings("2.5 MB", formatBytes(&buf, 2_621_440)); // 2.5 * 1024^2
    try std.testing.expectEqualStrings("1 GB", formatBytes(&buf, 1024 * 1024 * 1024));
}
