const std = @import("std");
const local_time = @import("../local_time.zig");

const windows = struct {
    pub const DWORD = u32;
    pub const WCHAR = u16;

    pub const WORD = u16;

    pub const SYSTEMTIME = extern struct {
        wYear: WORD,
        wMonth: WORD,
        wDayOfWeek: WORD,
        wDay: WORD,
        wHour: WORD,
        wMinute: WORD,
        wSecond: WORD,
        wMilliseconds: WORD,
    };

    pub const DATE_SHORTDATE: DWORD = 0x00000001;

    pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
    // A null locale name is LOCALE_NAME_USER_DEFAULT.
    pub extern "kernel32" fn GetDateFormatEx(
        lpLocaleName: ?[*:0]const WCHAR,
        dwFlags: DWORD,
        lpDate: ?*const SYSTEMTIME,
        lpFormat: ?[*:0]const WCHAR,
        lpDateStr: [*]WCHAR,
        cchDate: c_int,
        lpCalendar: ?[*:0]const WCHAR,
    ) callconv(.winapi) c_int;
    pub extern "kernel32" fn GetTimeFormatEx(
        lpLocaleName: ?[*:0]const WCHAR,
        dwFlags: DWORD,
        lpTime: ?*const SYSTEMTIME,
        lpFormat: ?[*:0]const WCHAR,
        lpTimeStr: [*]WCHAR,
        cchTime: c_int,
    ) callconv(.winapi) c_int;
};

/// Formats the current local time with the user's short date and time
/// formats from the Region settings.
pub fn format(buf: *local_time.Buffer) []const u8 {
    // A UTF-16 code unit takes at most 3 bytes in UTF-8, so this many units
    // always fit in `buf` once converted.
    var wide: [buf.len / 3]windows.WCHAR = undefined;

    // Format one snapshot, so a midnight between the two calls can't pair
    // one day's date with the next day's time.
    var now: windows.SYSTEMTIME = undefined;
    windows.GetLocalTime(&now);

    // Both calls count the null terminator in their return value.
    const date_len = windows.GetDateFormatEx(null, windows.DATE_SHORTDATE, &now, null, &wide, wide.len, null);
    if (date_len <= 0) return "";
    var len: usize = @intCast(date_len - 1);

    // Leave room for the space and at least one character of the time;
    // a zero-length buffer would make GetTimeFormatEx return the size it
    // needs instead of writing.
    if (len + 2 >= wide.len) return "";
    wide[len] = ' ';
    len += 1;
    const time_len = windows.GetTimeFormatEx(null, 0, &now, null, wide[len..].ptr, @intCast(wide.len - len));
    if (time_len <= 0 or time_len > wide.len - len) return "";
    len += @intCast(time_len - 1);

    const written = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch return "";
    return buf[0..written];
}
