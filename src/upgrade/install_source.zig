const std = @import("std");

/// Where the running binary came from. Only `standalone` installs (the
/// install script, a manual copy, or a source build) may replace themselves;
/// package-managed binaries must be upgraded through their package manager.
pub const InstallSource = enum {
    standalone,
    snap,
    pacman,

    /// Tells the user how to upgrade a package-managed install, or null when
    /// `puny --upgrade` is the right tool.
    pub fn upgradeHint(self: InstallSource) ?[]const u8 {
        return switch (self) {
            .standalone => null,
            .snap => "puny was installed with snap. Upgrade it with `sudo snap refresh puny`.\n",
            .pacman => "puny was installed with pacman from the AUR. Upgrade it with your AUR helper, e.g. `yay -Syu`.\n",
        };
    }
};

pub const pacman_local_db = "/var/lib/pacman/local";

/// Detects how the binary at `exe_path` was installed.
pub fn detect(io: std.Io, allocator: std.mem.Allocator, exe_path: []const u8, environ_map: *const std.process.Environ.Map) InstallSource {
    if (isSnap(exe_path, environ_map)) return .snap;
    if (@import("builtin").os.tag != .linux) return .standalone;

    var db = std.Io.Dir.openDirAbsolute(io, pacman_local_db, .{ .iterate = true }) catch return .standalone;
    defer db.close(io);
    if (pacmanOwns(io, allocator, db, exe_path)) return .pacman;
    return .standalone;
}

fn isSnap(exe_path: []const u8, environ_map: *const std.process.Environ.Map) bool {
    return environ_map.get("SNAP") != null or std.mem.startsWith(u8, exe_path, "/snap/");
}

/// Reports whether any `puny*` package in a pacman local database lists
/// `exe_path` among its files. Only puny packages are read, so this stays cheap.
fn pacmanOwns(io: std.Io, allocator: std.mem.Allocator, db: std.Io.Dir, exe_path: []const u8) bool {
    if (!std.fs.path.isAbsolute(exe_path)) return false;
    const rel_path = exe_path[1..];

    var it = db.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "puny")) continue;
        const files_path = std.fs.path.join(allocator, &.{ entry.name, "files" }) catch continue;
        defer allocator.free(files_path);
        const files = db.readFileAlloc(io, files_path, allocator, .limited(1024 * 1024)) catch continue;
        defer allocator.free(files);
        if (filesListContains(files, rel_path)) return true;
    }
    return false;
}

/// Reports whether a pacman `files` database entry lists `rel_path`.
fn filesListContains(files: []const u8, rel_path: []const u8) bool {
    var lines = std.mem.splitScalar(u8, files, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), rel_path)) return true;
    }
    return false;
}

test "filesListContains matches a listed path exactly" {
    const files = "%FILES%\nusr/\nusr/bin/\nusr/bin/puny\nusr/share/licenses/puny-bin/LICENSE\n";
    try std.testing.expect(filesListContains(files, "usr/bin/puny"));
    try std.testing.expect(!filesListContains(files, "usr/bin/pun"));
    try std.testing.expect(!filesListContains(files, "usr/local/bin/puny"));
}

test "isSnap detects the SNAP environment variable and snap paths" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!isSnap("/home/user/.local/bin/puny", &env));
    try std.testing.expect(isSnap("/snap/puny/12/bin/puny", &env));
    try env.put("SNAP", "/snap/puny/12");
    try std.testing.expect(isSnap("/home/user/.local/bin/puny", &env));
}

fn testPacmanDb(tmp: *std.testing.TmpDir, package: []const u8, files: []const u8) !void {
    try tmp.dir.createDirPath(std.testing.io, package);
    const files_path = try std.fs.path.join(std.testing.allocator, &.{ package, "files" });
    defer std.testing.allocator.free(files_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = files_path, .data = files });
}

test "pacmanOwns finds the binary in an installed puny package" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testPacmanDb(&tmp, "acl-2.4.0-1", "%FILES%\nusr/bin/chacl\n");
    try testPacmanDb(&tmp, "puny-bin-0.4.2-1", "%FILES%\nusr/\nusr/bin/\nusr/bin/puny\n");

    try std.testing.expect(pacmanOwns(std.testing.io, std.testing.allocator, tmp.dir, "/usr/bin/puny"));
    try std.testing.expect(!pacmanOwns(std.testing.io, std.testing.allocator, tmp.dir, "/home/user/.local/bin/puny"));
}

test "pacmanOwns ignores binaries owned by packages other than puny" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testPacmanDb(&tmp, "other-1.0-1", "%FILES%\nusr/bin/puny\n");

    try std.testing.expect(!pacmanOwns(std.testing.io, std.testing.allocator, tmp.dir, "/usr/bin/puny"));
}

test "upgradeHint is null only for standalone installs" {
    try std.testing.expect(InstallSource.standalone.upgradeHint() == null);
    try std.testing.expect(InstallSource.snap.upgradeHint() != null);
    try std.testing.expect(InstallSource.pacman.upgradeHint() != null);
}
