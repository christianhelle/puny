const std = @import("std");
const local_time = @import("../local_time.zig");

const libc = struct {
    pub const time_t = i64;

    pub const tm = extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
        tm_gmtoff: c_long,
        tm_zone: ?[*:0]const u8,
    };

    pub const LC_TIME: c_int = 5;

    pub extern "libSystem" fn time(tloc: ?*time_t) time_t;
    pub extern "libSystem" fn localtime_r(timep: *const time_t, result: *tm) ?*tm;
    pub extern "libSystem" fn setlocale(category: c_int, locale: [*:0]const u8) ?[*:0]const u8;
    pub extern "libSystem" fn strftime(s: [*]u8, maxsize: usize, format: [*:0]const u8, timeptr: *const tm) usize;
};

var locale_loaded = std.atomic.Value(bool).init(false);

/// Formats the current local time with the date and time formats of the
/// user's locale (LC_ALL, LC_TIME or LANG).
pub fn format(buf: *local_time.Buffer) []const u8 {
    if (!locale_loaded.swap(true, .acq_rel)) {
        _ = libc.setlocale(libc.LC_TIME, "");
    }

    const now = libc.time(null);
    var parts: libc.tm = undefined;
    if (libc.localtime_r(&now, &parts) == null) return "";

    const len = libc.strftime(buf, buf.len, "%x %X", &parts);
    return buf[0..len];
}
