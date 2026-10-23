const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

const linux = if (is_linux) @import("local_time/linux.zig") else void{};
const macos = if (is_macos) @import("local_time/macos.zig") else void{};
const windows = if (is_windows) @import("local_time/windows.zig") else void{};

pub const Buffer = [128]u8;

/// Formats the current local date and time. Windows and macOS follow the
/// user's regional settings; Linux has no libc to read the locale from, so it
/// prints ISO 8601 in the zone from /etc/localtime. Returns an empty string
/// when the time cannot be formatted, so callers can leave it out.
pub fn format(io: std.Io, buf: *Buffer) []const u8 {
    if (is_linux) return linux.format(io, buf);
    if (is_macos) return macos.format(buf);
    if (is_windows) return windows.format(buf);
    return "";
}

test "format returns the local time on supported platforms" {
    if (!is_linux and !is_macos and !is_windows) return error.SkipZigTest;
    var buf: Buffer = undefined;
    const text = format(std.testing.io, &buf);
    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test {
    if (is_linux) _ = linux;
}
