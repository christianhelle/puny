const std = @import("std");
const memory = @import("../memory.zig");

const mach = struct {
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
};

/// Returns phys_footprint (matches Activity Monitor's "Memory" column) and
/// internal (private, non-file-backed pages) via task_info(TASK_VM_INFO).
pub fn getMemoryStats() !memory.MemoryStats {
    const self = mach.mach_task_self();
    var info: mach.task_vm_info = undefined;
    var count: mach.natural_t = @sizeOf(mach.task_vm_info) / @sizeOf(mach.natural_t);
    const ret = mach.task_info(self, mach.TASK_VM_INFO, &info, &count);
    if (ret != mach.KERN_SUCCESS) return error.TaskInfoFailed;

    return .{
        .resident = info.phys_footprint,
        .private = info.internal,
    };
}

test "getMemoryStats returns positive values on macOS" {
    const result = try getMemoryStats();
    try std.testing.expect(result.resident > 0);
    try std.testing.expect(result.private > 0);
}
