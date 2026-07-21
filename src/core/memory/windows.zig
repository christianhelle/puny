const std = @import("std");
const memory = @import("../memory.zig");

const windows = struct {
    pub const HANDLE = *opaque {};
    pub const BOOL = i32;
    pub const DWORD = u32;
    pub const SIZE_T = usize;

    pub const PROCESS_MEMORY_COUNTERS_EX = extern struct {
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
        PrivateUsage: SIZE_T,
    };

    pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    pub extern "psapi" fn GetProcessMemoryInfo(
        Process: HANDLE,
        ppsmemCounters: *PROCESS_MEMORY_COUNTERS_EX,
        cb: DWORD,
    ) callconv(.winapi) BOOL;
};

/// Returns WorkingSetSize (matches Task Manager's default "Memory" column)
/// and PrivateUsage (commit charge, matches Process Explorer's "Private Bytes")
/// via GetProcessMemoryInfo.
pub fn getMemoryStats() !memory.MemoryStats {
    var counters: windows.PROCESS_MEMORY_COUNTERS_EX = .{
        .cb = @sizeOf(windows.PROCESS_MEMORY_COUNTERS_EX),
        .PageFaultCount = 0,
        .PeakWorkingSetSize = 0,
        .WorkingSetSize = 0,
        .QuotaPeakPagedPoolUsage = 0,
        .QuotaPagedPoolUsage = 0,
        .QuotaPeakNonPagedPoolUsage = 0,
        .QuotaNonPagedPoolUsage = 0,
        .PagefileUsage = 0,
        .PeakPagefileUsage = 0,
        .PrivateUsage = 0,
    };
    const ret = windows.GetProcessMemoryInfo(
        windows.GetCurrentProcess(),
        &counters,
        @sizeOf(windows.PROCESS_MEMORY_COUNTERS_EX),
    );
    if (ret == 0) return error.GetProcessMemoryInfoFailed;

    return .{
        .resident = @intCast(counters.WorkingSetSize),
        .private = @intCast(counters.PrivateUsage),
    };
}

test "getMemoryStats returns positive values on Windows" {
    const result = try getMemoryStats();
    try std.testing.expect(result.resident > 0);
    try std.testing.expect(result.private > 0);
}
