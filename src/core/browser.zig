const std = @import("std");
const builtin = @import("builtin");

/// Fixed-capacity argv for spawning a file opener. `len` is the number of
/// leading entries in `items` that are used.
pub const Argv = struct {
    items: [3][]const u8,
    len: usize,

    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.len];
    }
};

/// Returns the argv that opens `path` with the default handler for `os`.
pub fn command(os: std.Target.Os.Tag, path: []const u8) Argv {
    return switch (os) {
        .windows => .{ .items = .{ "rundll32", "url.dll,FileProtocolHandler", path }, .len = 3 },
        .macos => .{ .items = .{ "open", path, "" }, .len = 2 },
        else => .{ .items = .{ "xdg-open", path, "" }, .len = 2 },
    };
}

/// Opens `path` in the default browser without waiting for it. Errors are
/// swallowed: failing to open a browser must never break a session.
pub fn open(io: std.Io, path: []const u8) void {
    const argv = command(builtin.os.tag, path);
    _ = std.process.spawn(io, .{
        .argv = argv.slice(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {};
}

fn expectArgv(expected: []const []const u8, actual: Argv) !void {
    const items = actual.slice();
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "command uses rundll32 to open files on windows" {
    try expectArgv(
        &.{ "rundll32", "url.dll,FileProtocolHandler", "C:\\plan.html" },
        command(.windows, "C:\\plan.html"),
    );
}

test "command uses open on macos" {
    try expectArgv(&.{ "open", "/tmp/plan.html" }, command(.macos, "/tmp/plan.html"));
}

test "command uses xdg-open on linux" {
    try expectArgv(&.{ "xdg-open", "/tmp/plan.html" }, command(.linux, "/tmp/plan.html"));
}
