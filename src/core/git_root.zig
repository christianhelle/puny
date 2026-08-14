const std = @import("std");

/// Maximum number of parent directories to walk upward when looking for a
/// repository root. Bounds the search so an unusual mount point cannot stall
/// startup.
const max_git_repo_depth = 64;

/// Builds the path to the `.git` entry inside `dir`. A separator is only
/// inserted when `dir` does not already end in one, so a bare root like "/"
/// probes "/.git" instead of the implementation-defined "//.git". Returns
/// null when the path does not fit in `buf`.
fn gitMarkerPath(dir: []const u8, buf: []u8) ?[]const u8 {
    if (dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) {
        return std.fmt.bufPrint(buf, "{s}.git", .{dir}) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}{c}.git", .{ dir, std.fs.path.sep }) catch null;
}

/// Returns true when `dir` contains a `.git` entry. The entry is a directory
/// in a regular clone, a file in a linked worktree, or a symlink to either;
/// existence alone marks the root, which matches how git locates the top
/// level of a worktree.
fn isGitRepoRoot(io: std.Io, dir: []const u8) bool {
    var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const marker = gitMarkerPath(dir, &marker_buf) orelse return false;
    std.Io.Dir.cwd().access(io, marker, .{}) catch return false;
    return true;
}

/// Strips trailing path separators while preserving the root prefix, so a
/// bare root like "/" or "C:\" is never reduced to a relative path.
fn trimTrailingSeparators(path: []const u8) []const u8 {
    const root_len = std.fs.path.parsePath(path).root.len;
    var end = path.len;
    while (end > root_len and (path[end - 1] == '/' or path[end - 1] == '\\')) {
        end -= 1;
    }
    return path[0..end];
}

/// Walks upward from `start_dir` and returns the path of the nearest ancestor
/// that contains a `.git` entry, or null when no ancestor is a repository
/// root. `start_dir` may be absolute or relative; relative paths are resolved
/// from the process working directory and the walk can climb above it. The
/// result is written into `out_buf` and stays valid until the next call that
/// reuses the buffer.
fn findRepoRootUpward(io: std.Io, start_dir: []const u8, out_buf: []u8) ?[]const u8 {
    // Strip trailing separators while preserving a bare root like "/" or
    // "C:\" (trimming a drive root would turn an absolute path into a
    // relative one and search the wrong locations).
    var dir = trimTrailingSeparators(start_dir);
    if (dir.len == 0) return null;
    const is_absolute = std.fs.path.isAbsolute(dir);

    // Scratch space for building relative parent chains such as "../..".
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    // Number of levels climbed above the working directory (relative starts).
    var hops: usize = 0;

    var depth: usize = 0;
    while (true) {
        if (depth >= max_git_repo_depth) return null;
        depth += 1;

        if (isGitRepoRoot(io, dir)) {
            // Prefer the canonical path, matching `git rev-parse
            // --show-toplevel`. `realPathFile` opens the directory and
            // resolves it through a real file descriptor, so unlike
            // `Dir.cwd().realPath` it works on every platform (the cwd handle
            // on POSIX is AT.FDCWD, which is not a real descriptor). Fall back
            // to the literal path when canonicalization fails.
            if (std.Io.Dir.cwd().realPathFile(io, dir, out_buf)) |n| {
                return out_buf[0..n];
            } else |_| {
                if (dir.len > out_buf.len) return null;
                @memcpy(out_buf[0..dir.len], dir);
                return out_buf[0..dir.len];
            }
        }

        if (is_absolute) {
            dir = std.fs.path.dirname(dir) orelse return null;
            if (dir.len == 0) return null;
        } else if (hops > 0) {
            // Climb above the working directory: extend the "../.." chain.
            hops += 1;
            const chain_len = 2 + (hops - 1) * 3;
            if (chain_len > scratch.len) return null;
            var i: usize = 0;
            for (0..hops) |_| {
                if (i > 0) {
                    scratch[i] = std.fs.path.sep;
                    i += 1;
                }
                scratch[i] = '.';
                scratch[i + 1] = '.';
                i += 2;
            }
            dir = scratch[0..i];
        } else {
            // Descend toward the working directory one level at a time.
            if (std.mem.eql(u8, dir, ".")) {
                hops = 1;
                dir = "..";
            } else {
                // A relative path with a single component has no dirname; its
                // parent is the working directory itself.
                dir = std.fs.path.dirname(dir) orelse ".";
            }
        }
    }
}

pub fn findGitRepoRoot(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    // Spawning `git rev-parse --show-toplevel` used to cost tens of
    // milliseconds per process start (and up to its 5 s timeout when git
    // hung). Detecting the repository by walking up the working directory for
    // a `.git` entry is microseconds and needs no external process, so
    // startup stays fast even on huge or slow repositories.
    //
    // The walk starts from the relative path "." because the absolute working
    // directory cannot be resolved portably: on POSIX `Dir.cwd().realPath()`
    // reads /proc/self/fd/{handle}, but the cwd handle is AT.FDCWD, which is
    // not a real file descriptor.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(io, ".", &root_buf) orelse return null;
    return try allocator.dupe(u8, root);
}

test "findGitRepoRoot does not crash" {
    const result = try findGitRepoRoot(std.testing.allocator, std.testing.io);
    if (result) |r| std.testing.allocator.free(r);
}
test "findGitRepoRoot finds the repository when run inside one" {
    // The test runner's working directory is this repository's root, so the
    // lookup must find a repo root (the same outcome `git rev-parse
    // --show-toplevel` produced before the walk-based implementation).
    const result = try findGitRepoRoot(std.testing.allocator, std.testing.io);
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expect(result != null);
}

test "isGitRepoRoot detects a .git directory and rejects other directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    try tmp.dir.createDir(std.testing.io, "plain", .default_dir);
    try std.testing.expect(!isGitRepoRoot(std.testing.io, base_path));

    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "repo" });
    defer std.testing.allocator.free(repo_path);
    try std.testing.expect(isGitRepoRoot(std.testing.io, repo_path));
}

test "isGitRepoRoot treats a .git file (linked worktree) as a repo root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "wt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wt/.git", .data = "gitdir: /elsewhere/.git\n" });

    const wt_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "wt" });
    defer std.testing.allocator.free(wt_path);
    try std.testing.expect(isGitRepoRoot(std.testing.io, wt_path));
}

test "findRepoRootUpward finds the nearest ancestor with a .git directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try tmp.dir.createDir(std.testing.io, "root/.git", .default_dir);
    try tmp.dir.createDirPath(std.testing.io, "root/sub/deeper");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const start_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "root", "sub", "deeper" });
    defer std.testing.allocator.free(start_path);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(std.testing.io, start_path, &out_buf).?;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "root" });
    defer std.testing.allocator.free(expected_path);
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, expected_path, &expected_buf);

    try std.testing.expectEqualStrings(expected_buf[0..n], root);
}

test "findRepoRootUpward treats a .git file (linked worktree) as a repo root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "wt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wt/.git", .data = "gitdir: /elsewhere/.git\n" });
    try tmp.dir.createDirPath(std.testing.io, "wt/sub");

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const start_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "wt", "sub" });
    defer std.testing.allocator.free(start_path);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(std.testing.io, start_path, &out_buf).?;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "wt" });
    defer std.testing.allocator.free(expected_path);
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, expected_path, &expected_buf);

    try std.testing.expectEqualStrings(expected_buf[0..n], root);
}

test "findRepoRootUpward returns null when no ancestor is a repository" {
    // A synthetic path that cannot exist anywhere in the tree, so the walk
    // reaches the filesystem root without finding a `.git` marker. The tmp
    // dirs from other tests live inside this repository, so they cannot be
    // used for a "no repo" case.
    const start = if (comptime @import("builtin").os.tag == .windows)
        "Z:\\puny-no-git-walk-test"
    else
        "/puny-no-git-walk-test";

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(findRepoRootUpward(std.testing.io, start, &out_buf) == null);
}
test "findRepoRootUpward finds the repository root from a relative start" {
    // The test runner's working directory is this repository's root, so a
    // relative start inside the tree must resolve to the repo root. This
    // covers the startup path, which walks from "." because the absolute
    // working directory cannot be resolved portably.
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(std.testing.io, "src", &out_buf).?;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, ".", &expected_buf);
    try std.testing.expectEqualStrings(expected_buf[0..n], root);
}
test "gitMarkerPath does not double the separator at a root path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const sep = std.fs.path.sep;

    // At the POSIX root, probing must be "/.git", not "//.git".
    try std.testing.expectEqualStrings("/.git", gitMarkerPath("/", &buf).?);

    // At a Windows drive root, probing must be "C:\.git".
    try std.testing.expectEqualStrings("C:\\.git", gitMarkerPath("C:\\", &buf).?);

    // Other paths get exactly one native separator inserted.
    const repo_marker = try std.fmt.bufPrint(&buf, "/repo{c}.git", .{sep});
    try std.testing.expectEqualStrings(repo_marker, gitMarkerPath("/repo", &buf).?);

    const dot_marker = try std.fmt.bufPrint(&buf, ".{c}.git", .{sep});
    try std.testing.expectEqualStrings(dot_marker, gitMarkerPath(".", &buf).?);
}

test "trimTrailingSeparators preserves the root prefix" {
    if (comptime @import("builtin").os.tag == .windows) {
        // A drive root must not lose its separator, otherwise the path is
        // misclassified as drive-relative instead of absolute.
        try std.testing.expectEqualStrings("C:\\", trimTrailingSeparators("C:\\"));
        try std.testing.expectEqualStrings("C:\\repo", trimTrailingSeparators("C:\\repo\\"));
    } else {
        try std.testing.expectEqualStrings("/", trimTrailingSeparators("/"));
        try std.testing.expectEqualStrings("/repo", trimTrailingSeparators("/repo/"));
    }
    try std.testing.expectEqualStrings(".", trimTrailingSeparators("."));
    try std.testing.expectEqualStrings("src", trimTrailingSeparators("src/"));
}

test "findRepoRootUpward finds the repo root from an absolute path with a trailing separator" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try tmp.dir.createDir(std.testing.io, "root/.git", .default_dir);

    const base_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);

    const start_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "root" });
    defer std.testing.allocator.free(start_path);
    // Append a trailing separator; the walk must still find the root and must
    // not probe a doubled-separator marker path like "//.git".
    const start_with_sep = try std.fmt.allocPrint(std.testing.allocator, "{s}{c}", .{ start_path, std.fs.path.sep });
    defer std.testing.allocator.free(start_with_sep);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = findRepoRootUpward(std.testing.io, start_with_sep, &out_buf).?;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, start_path, &expected_buf);
    try std.testing.expectEqualStrings(expected_buf[0..n], root);
}
