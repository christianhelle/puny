const std = @import("std");
const builtin = @import("builtin");

pub const WriteOptions = struct {
    /// When set, the staging file's mtime is stamped strictly newer than the
    /// mtime of the file or directory at this path (plus a one-second margin).
    /// This keeps a freshly written file from being judged stale by an mtime
    /// comparison against a directory on filesystems with coarse timestamp
    /// granularity. The rename carries the stamped timestamp to the target.
    newer_than: ?[]const u8 = null,
    /// Tighten the staging file to owner-only (0600) before writing, so a
    /// permissive umask cannot leak the contents while they are staged.
    restrict_permissions: bool = false,
};

/// Staging files younger than this are left alone. A staging file that has
/// only just appeared may belong to a concurrent writer that is still filling
/// it in, and deleting that one would break a write that is going fine.
const stale_staging_age_ns: i96 = 5 * std.time.ns_per_min;

/// Whether `name` is a staging file this module would have created for
/// `filename`, i.e. `<filename>.<digits>.tmp`. The digit check keeps the sweep
/// off unrelated `.tmp` files that happen to share the directory.
fn isStagingName(name: []const u8, filename: []const u8) bool {
    const suffix = ".tmp";
    if (!std.mem.startsWith(u8, name, filename)) return false;
    if (!std.mem.endsWith(u8, name, suffix)) return false;
    const middle = name[filename.len .. name.len - suffix.len];
    if (middle.len < 2 or middle[0] != '.') return false;
    for (middle[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Deletes staging files in `dir_path` left over from earlier writes of
/// `filename` that never reached their rename, which is what a process killed
/// mid-write leaves behind and no errdefer can cover. Only files older than
/// `stale_staging_age_ns` are removed, so an in-flight write by another
/// process is never disturbed. Best-effort throughout: a directory that cannot
/// be opened, scanned, or pruned must not stop the write that follows.
fn sweepStaleStagingFiles(io: std.Io, scratch: std.mem.Allocator, dir_path: []const u8, filename: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // Compared against mtime, so this needs the wall clock the filesystem
    // stamps with, not the monotonic clock used for staging-name uniqueness.
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

    // Names are collected first because the iterator's `name` points into a
    // buffer the next step reuses, and because deleting entries from a
    // directory while iterating it is not portable.
    var stale: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (true) {
        const entry = (it.next(io) catch break) orelse break;
        if (entry.kind != .file) continue;
        if (!isStagingName(entry.name, filename)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (now_ns - stat.mtime.nanoseconds < stale_staging_age_ns) continue;
        const name = scratch.dupe(u8, entry.name) catch continue;
        stale.append(scratch, name) catch continue;
    }

    for (stale.items) |name| {
        dir.deleteFile(io, name) catch |err| {
            std.log.warn("failed to sweep stale staging file {s}: {s}", .{ name, @errorName(err) });
            continue;
        };
        std.log.debug("swept stale staging file {s}", .{name});
    }
}

/// Atomically writes `contents` to `<dir_path>/<filename>` through a
/// uniquely-named temporary file and a rename, so an interrupted write never
/// leaves the target empty or truncated. A trailing newline is appended to
/// match the project's JSON writers. The staging file is removed on failure,
/// and staging files orphaned by earlier interrupted writes are swept first.
pub fn writeAtomically(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    filename: []const u8,
    contents: []const u8,
    options: WriteOptions,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    // A unique temp name per write keeps concurrent writes (or a stale .tmp
    // from a crashed run) from colliding on the same staging file.
    const ts = std.Io.Timestamp.now(io, .awake);
    const tmp_name = try std.fmt.allocPrint(scratch, "{s}.{d}.tmp", .{ filename, ts.nanoseconds });
    const tmp_path = try std.fs.path.join(scratch, &.{ dir_path, tmp_name });
    const final_path = try std.fs.path.join(scratch, &.{ dir_path, filename });

    // Reclaim staging files abandoned by an earlier run before adding another,
    // so a write interrupted between create and rename is cleaned up by the
    // next write rather than accumulating in the directory forever.
    sweepStaleStagingFiles(io, scratch, dir_path, filename);

    var file = cwd.createFile(io, tmp_path, .{}) catch |err| {
        std.log.warn("failed to create temp file {s}: {s}", .{ tmp_path, @errorName(err) });
        return err;
    };
    var file_open = true;
    errdefer {
        if (file_open) file.close(io);
        // A cleanup that cannot delete its own staging file is the only way a
        // still-running process leaks one, so say so rather than dropping the
        // error and leaving an unexplained file behind.
        cwd.deleteFile(io, tmp_path) catch |err| {
            std.log.warn("failed to remove staging file {s} after a failed write: {s}", .{ tmp_path, @errorName(err) });
        };
    }

    file.writeStreamingAll(io, contents) catch |err| {
        std.log.warn("failed to write {s}: {s}", .{ tmp_path, @errorName(err) });
        return err;
    };
    file.writeStreamingAll(io, "\n") catch |err| {
        std.log.warn("failed to write newline to {s}: {s}", .{ tmp_path, @errorName(err) });
        return err;
    };
    file.close(io);
    file_open = false;

    if (options.newer_than) |reference_path| {
        if (cwd.statFile(io, reference_path, .{}) catch null) |ref_stat| {
            const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
            const desired = std.Io.Timestamp.fromNanoseconds(@max(now_ns, ref_stat.mtime.nanoseconds) + std.time.ns_per_s);
            var stamp_file = cwd.openFile(io, tmp_path, .{ .mode = .read_write }) catch null;
            if (stamp_file) |*f| {
                defer f.close(io);
                f.setTimestamps(io, .{ .modify_timestamp = .{ .new = desired } }) catch {};
            }
        }
    }

    if (options.restrict_permissions) {
        if (comptime builtin.os.tag != .windows) {
            cwd.setFilePermissions(io, tmp_path, @enumFromInt(0o600), .{}) catch {};
        }
    }

    std.Io.Dir.renameAbsolute(tmp_path, final_path, io) catch |err| {
        std.log.warn("failed to rename {s} into place: {s}", .{ final_path, @errorName(err) });
        return err;
    };
}

fn testDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const dir = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    return dir;
}

test "writeAtomically writes contents and a trailing newline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-write");
    defer std.testing.allocator.free(dir);

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "{\"a\":1}", .{});

    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, std.Io.Limit.limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"a\":1}\n", data);
}

test "writeAtomically leaves no temp file behind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-clean");
    defer std.testing.allocator.free(dir);

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "payload", .{});

    var out_dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir, .{ .iterate = true });
    defer out_dir.close(std.testing.io);
    var it = out_dir.iterate();
    var names: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
        names += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), names);
}

test "writeAtomically does not clobber a stale temp file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-stale");
    defer std.testing.allocator.free(dir);

    const stale_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json.1.tmp" });
    defer std.testing.allocator.free(stale_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stale_path, .data = "STALE" });

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "fresh", .{});

    const stale = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stale_path, std.testing.allocator, std.Io.Limit.limited(1024));
    defer std.testing.allocator.free(stale);
    try std.testing.expectEqualStrings("STALE", stale);
}

test "writeAtomically restricts permissions to owner-only" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-perm");
    defer std.testing.allocator.free(dir);

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "secret", .{ .restrict_permissions = true });

    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "writeAtomically stamps the target newer than the reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-stamp");
    defer std.testing.allocator.free(dir);

    const reference = try std.fs.path.join(std.testing.allocator, &.{ dir, "reference" });
    defer std.testing.allocator.free(reference);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, reference);

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "payload", .{ .newer_than = reference });

    const ref_stat = try std.Io.Dir.cwd().statFile(std.testing.io, reference, .{});
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(path);
    const out_stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expect(out_stat.mtime.nanoseconds >= ref_stat.mtime.nanoseconds);
}

test "writeAtomically overwrites an existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-overwrite");
    defer std.testing.allocator.free(dir);

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "old", .{});
    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "new", .{});

    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, std.Io.Limit.limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("new\n", data);
}

test "writeAtomically appends a newline to empty contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-empty");
    defer std.testing.allocator.free(dir);

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "", .{});

    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, std.Io.Limit.limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("\n", data);
}

test "writeAtomically fails when the target directory is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try testDir(std.testing.allocator, &tmp, "atomic-missing-parent");
    defer std.testing.allocator.free(base);
    const dir = try std.fs.path.join(std.testing.allocator, &.{ base, "no-such-subdir" });
    defer std.testing.allocator.free(dir);

    try std.testing.expectError(error.FileNotFound, writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "payload", .{}));
}

test "writeAtomically ignores a missing newer_than reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-missing-ref");
    defer std.testing.allocator.free(dir);

    const reference = try std.fs.path.join(std.testing.allocator, &.{ dir, "no-such-reference" });
    defer std.testing.allocator.free(reference);

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "payload", .{ .newer_than = reference });

    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, std.Io.Limit.limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("payload\n", data);
}

test "writeAtomically fails when a directory blocks the target path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-dir-target");
    defer std.testing.allocator.free(dir);

    const target = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(target);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, target);

    try std.testing.expectError(error.IsDir, writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "payload", .{}));
}

test "writeAtomically stamps the target newer than a file reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try testDir(std.testing.allocator, &tmp, "atomic-stamp-file");
    defer std.testing.allocator.free(dir);

    const reference = try std.fs.path.join(std.testing.allocator, &.{ dir, "reference.txt" });
    defer std.testing.allocator.free(reference);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = reference, .data = "ref" });
    var ref_file = try std.Io.Dir.cwd().openFile(std.testing.io, reference, .{ .mode = .read_write });
    defer ref_file.close(std.testing.io);
    try ref_file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(1_000_000_000_000) } });

    try writeAtomically(std.testing.io, std.testing.allocator, dir, "out.json", "payload", .{ .newer_than = reference });

    const ref_stat = try std.Io.Dir.cwd().statFile(std.testing.io, reference, .{});
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "out.json" });
    defer std.testing.allocator.free(path);
    const out_stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expect(out_stat.mtime.nanoseconds >= ref_stat.mtime.nanoseconds);
}
