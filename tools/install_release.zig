//! Copies a built puny binary into the user's install directory.
//!
//! Zig 0.17 no longer supports custom build steps, and the install prefix is
//! only known at make time, so the `install-release*` steps run this helper
//! to pick the destination and copy the binary there.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    if (argv.len != 5) {
        std.log.err("Usage: {s} <binary> <install-prefix> <default-prefix> <dest-name>", .{argv[0]});
        return 1;
    }

    const source = argv[1];
    const install_prefix = argv[2];
    const default_prefix = argv[3];
    const dest_name = argv[4];

    const dest_dir = resolveDestDir(arena, init.environ_map, install_prefix, default_prefix) orelse {
        std.log.err("unable to determine install directory: set HOME, USERPROFILE, or INSTALL_DIR", .{});
        return 1;
    };

    const dest_path = try std.fs.path.join(arena, &.{ dest_dir, dest_name });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest_dir);
    try std.Io.Dir.copyFile(cwd, source, cwd, dest_path, io, .{});
    return 0;
}

fn resolveDestDir(
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    install_prefix: []const u8,
    default_prefix: []const u8,
) ?[]const u8 {
    // Honor an explicit `--prefix` flag.
    if (!std.mem.eql(u8, install_prefix, default_prefix)) return install_prefix;

    // Honor the INSTALL_DIR environment variable used by the install scripts.
    if (environ_map.get("INSTALL_DIR")) |install_dir| {
        if (install_dir.len > 0) return install_dir;
    }

    // Default to $HOME/.local/bin, falling back to %USERPROFILE% on Windows.
    if (environ_map.get("HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(arena, &.{ home, ".local", "bin" }) catch null;
    }
    if (environ_map.get("USERPROFILE")) |home| {
        if (home.len > 0) return std.fs.path.join(arena, &.{ home, ".local", "bin" }) catch null;
    }

    return null;
}
