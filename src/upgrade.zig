const std = @import("std");
const helpers = @import("tools/helpers.zig");
const retry = @import("core/retry.zig");
const version = @import("version.zig");
const release = @import("upgrade/release.zig");

pub const latest_release_url = release.latest_release_url;
pub const LatestRelease = release.LatestRelease;
pub const latestTagFromRelease = release.latestTagFromRelease;
pub const latestReleaseVersion = release.latestReleaseVersion;

pub fn cleanupOldBackup(allocator: std.mem.Allocator, io: std.Io) void {
    const exe_path = std.process.executablePathAlloc(io, allocator) catch return;
    defer allocator.free(exe_path);
    const old_path = std.fmt.allocPrint(allocator, "{s}.old", .{exe_path}) catch return;
    defer allocator.free(old_path);
    std.Io.Dir.deleteFileAbsolute(io, old_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            var buf: [512]u8 = undefined;
            var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
            w.interface.print("warning: failed to remove old backup: {s}\n", .{@errorName(err)}) catch {};
            w.interface.flush() catch {};
        },
    };
}

fn archiveNameForTarget() []const u8 {
    const target = @import("builtin").target;
    const aarch = target.cpu.arch;
    const os = target.os.tag;
    if (aarch == .aarch64) {
        return switch (os) {
            .windows => "puny-windows-aarch64.zip",
            .linux => "puny-linux-aarch64.tar.gz",
            .macos => "puny-macos-aarch64.tar.gz",
            else => @compileError("unsupported OS for upgrade"),
        };
    } else if (aarch == .x86_64) {
        return switch (os) {
            .windows => "puny-windows-x86_64.zip",
            .linux => "puny-linux-x86_64.tar.gz",
            .macos => "puny-macos-x86_64.tar.gz",
            else => @compileError("unsupported OS for upgrade"),
        };
    }
    @compileError("unsupported CPU architecture for upgrade");
}

fn upgradeTempParent(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("TMPDIR")) |t| return try arena.dupe(u8, t);
    if (environ_map.get("TEMP")) |t| return try arena.dupe(u8, t);
    if (environ_map.get("TMP")) |t| return try arena.dupe(u8, t);
    if (comptime @import("builtin").os.tag == .windows) return try arena.dupe(u8, "C:\\Windows\\Temp");
    return try arena.dupe(u8, "/tmp");
}

fn findInDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !?[]const u8 {
    var walk = try dir.walk(allocator);
    defer walk.deinit();
    while (try walk.next(io)) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.basename, name)) {
            return try allocator.dupe(u8, entry.path);
        }
    }
    return null;
}

fn retryExtract(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_dir: std.Io.Dir,
    archive_name: []const u8,
    binary_name: []const u8,
    download_url: []const u8,
    expected_size: ?u64,
    random: std.Random,
    progress_writer: *std.Io.Writer,
    comptime download_fn: fn (std.mem.Allocator, std.Io, []const u8, std.Io.Dir, []const u8) anyerror!void,
    comptime extract_fn: fn (std.mem.Allocator, std.Io, std.Io.Dir, []const u8, []const u8) anyerror![]const u8,
) ![]const u8 {
    const cfg = retry.default_config;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (attempt > 0) {
            try progress_writer.print("Retrying download...\n", .{});
            try progress_writer.flush();
            try clearDirContents(io, tmp_dir);
        } else {
            try progress_writer.print("Downloading {s}...\n", .{archive_name});
            try progress_writer.flush();
        }

        download_fn(allocator, io, download_url, tmp_dir, archive_name) catch |err| {
            if (!retry.isDownloadTransientError(err)) return err;
            if (attempt >= cfg.max_retries) return err;
            retryDelay(io, random, cfg, attempt);
            continue;
        };

        if (expected_size) |expected| {
            verifyDownloadSize(io, tmp_dir, archive_name, expected) catch |err| {
                if (!retry.isDownloadTransientError(err)) return err;
                if (attempt >= cfg.max_retries) return err;
                retryDelay(io, random, cfg, attempt);
                continue;
            };
        }

        try progress_writer.print("Extracting...\n", .{});
        try progress_writer.flush();

        const result = extract_fn(allocator, io, tmp_dir, archive_name, binary_name) catch |err| {
            if (!retry.isDownloadTransientError(err)) return err;
            if (attempt >= cfg.max_retries) return err;
            retryDelay(io, random, cfg, attempt);
            continue;
        };
        return result;
    }
}

fn retryDelay(io: std.Io, random: std.Random, cfg: retry.Config, attempt: usize) void {
    const delay_ms = retry.computeDelay(cfg, attempt, random);
    io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
}

fn verifyDownloadSize(io: std.Io, dir: std.Io.Dir, name: []const u8, expected: u64) !void {
    const stat = try dir.statFile(io, name, .{});
    if (stat.size != expected) return error.TruncatedDownload;
}

fn clearDirContents(io: std.Io, dir: std.Io.Dir) !void {
    var iterable = dir.iterate();
    while (try iterable.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try dir.deleteTree(io, entry.name),
            else => try dir.deleteFile(io, entry.name),
        }
    }
}

fn extractAndFindBinary(
    arena: std.mem.Allocator,
    io: std.Io,
    tmp_dir: std.Io.Dir,
    archive_name: []const u8,
    binary_name: []const u8,
    download_url: []const u8,
    expected_size: ?u64,
    random: std.Random,
) ![]const u8 {
    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    return retryExtract(
        arena,
        io,
        tmp_dir,
        archive_name,
        binary_name,
        download_url,
        expected_size,
        random,
        stderr_writer,
        helpers.httpDownloadFile,
        extractArchiveAndFindBinary,
    );
}

fn extractArchiveAndFindBinary(
    arena: std.mem.Allocator,
    io: std.Io,
    tmp_dir: std.Io.Dir,
    archive_name: []const u8,
    binary_name: []const u8,
) ![]const u8 {
    const extract_result = if (@import("builtin").os.tag == .windows) extract_zip: {
        var archive_buf: [4096]u8 = undefined;
        var archive_file = tmp_dir.openFile(io, archive_name, .{}) catch |err| break :extract_zip err;
        defer archive_file.close(io);
        var archive_reader = archive_file.reader(io, &archive_buf);
        std.zip.extract(tmp_dir, &archive_reader, .{}) catch |err| break :extract_zip err;
        break :extract_zip {};
    } else extract_tar: {
        var archive_buf: [4096]u8 = undefined;
        var tar_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var archive_file = tmp_dir.openFile(io, archive_name, .{}) catch |err| break :extract_tar err;
        defer archive_file.close(io);
        var archive_reader = archive_file.reader(io, &archive_buf);
        var decompress = std.compress.flate.Decompress.init(&archive_reader.interface, .gzip, &tar_buf);
        std.tar.extract(io, tmp_dir, &decompress.reader, .{}) catch |err| break :extract_tar err;
        break :extract_tar {};
    };

    if (extract_result) |_| {
        const found = try findInDir(arena, io, tmp_dir, binary_name);
        return found orelse error.BinaryNotFoundInArchive;
    } else |err| {
        return err;
    }
}

pub fn runUpgrade(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, force: bool) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    try stderr_writer.print("\nChecking for updates...\n", .{});
    try stderr_writer.flush();

    const release_url = latest_release_url;
    const json_bytes = try helpers.httpGet(arena, io, release_url);
    defer arena.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{});
    defer parsed.deinit();

    const latest = try latestTagFromRelease(parsed.value);
    const latest_tag = latest.tag;
    const latest_ver_str = latest.version;

    const current_ver = try std.SemanticVersion.parse(version.version);
    const latest_ver = try std.SemanticVersion.parse(latest_ver_str);

    if (!force and current_ver.order(latest_ver) != .lt) {
        try stderr_writer.print("Already up to date (v{s}). Use --force to upgrade anyway.\n", .{version.version});
        try stderr_writer.flush();
        return;
    }

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();
    const unique = random.int(u64);
    var unique_buf: [32]u8 = undefined;
    const unique_str = try std.fmt.bufPrint(&unique_buf, "{x}", .{unique});
    const tmp_parent = try upgradeTempParent(arena, environ_map);
    defer arena.free(tmp_parent);
    const tmp_rel_name = try std.fmt.allocPrint(arena, "puny-upgrade-{s}", .{unique_str});
    defer arena.free(tmp_rel_name);
    const tmp_dir_path = try std.fs.path.join(arena, &.{ tmp_parent, tmp_rel_name });
    defer arena.free(tmp_dir_path);

    try std.Io.Dir.createDirAbsolute(io, tmp_dir_path, @enumFromInt(0o755));
    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp_dir_path, .{ .iterate = true });
    errdefer {
        tmp_dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, tmp_dir_path) catch {};
    }

    const archive_name = archiveNameForTarget();
    const download_url = try std.fmt.allocPrint(arena, "https://github.com/christianhelle/puny/releases/download/{s}/{s}", .{ latest_tag, archive_name });
    defer arena.free(download_url);

    const expected_size: ?u64 = blk: {
        const assets = parsed.value.object.get("assets") orelse break :blk null;
        if (assets != .array) break :blk null;
        for (assets.array.items) |asset| {
            if (asset != .object) continue;
            const name = asset.object.get("name") orelse continue;
            if (name != .string or !std.mem.eql(u8, name.string, archive_name)) continue;
            const size = asset.object.get("size") orelse continue;
            if (size != .integer) continue;
            break :blk @intCast(size.integer);
        }
        break :blk null;
    };

    const binary_name = if (@import("builtin").os.tag == .windows) "puny.exe" else "puny";

    const extracted_path = try extractAndFindBinary(arena, io, tmp_dir, archive_name, binary_name, download_url, expected_size, random);
    defer arena.free(extracted_path);

    try stderr_writer.print("Installing...\n", .{});
    try stderr_writer.flush();

    const exe_path = try std.process.executablePathAlloc(io, arena);
    defer arena.free(exe_path);
    const exe_dir_path = std.fs.path.dirname(exe_path) orelse ".";
    const exe_name = std.fs.path.basename(exe_path);

    var exe_dir = try std.Io.Dir.cwd().openDir(io, exe_dir_path, .{});
    defer exe_dir.close(io);

    if (@import("builtin").os.tag == .windows) {
        const update_name = try std.fmt.allocPrint(arena, "{s}.update", .{exe_name});
        defer arena.free(update_name);
        try std.Io.Dir.copyFile(tmp_dir, extracted_path, exe_dir, update_name, io, .{});

        const full_update_path = try std.fs.path.join(arena, &.{ exe_dir_path, update_name });
        defer arena.free(full_update_path);

        const batch_name = try std.fmt.allocPrint(arena, "puny-upgrade-{s}.bat", .{unique_str});
        defer arena.free(batch_name);
        const batch_path = try std.fs.path.join(arena, &.{ exe_dir_path, batch_name });
        defer arena.free(batch_path);

        const batch_body = try std.fmt.allocPrint(arena, "@echo off\r\n" ++
            ":retry\r\n" ++
            "del \"{s}\" > nul 2>&1\r\n" ++
            "if exist \"{s}\" (\r\n" ++
            "  ping 127.0.0.1 -n 3 > nul\r\n" ++
            "  goto retry\r\n" ++
            ")\r\n" ++
            "copy /Y \"{s}\" \"{s}\" > nul\r\n" ++
            "del \"{s}\" > nul\r\n" ++
            "rmdir /S /Q \"{s}\" > nul 2>&1\r\n" ++
            "del /Q \"{s}\" > nul 2>&1\r\n", .{ exe_path, exe_path, full_update_path, exe_path, full_update_path, tmp_dir_path, batch_path });
        defer arena.free(batch_body);

        var batch_file = try exe_dir.createFile(io, batch_name, .{});
        defer batch_file.close(io);
        try batch_file.writeStreamingAll(io, batch_body);

        _ = try std.process.spawn(io, .{
            .argv = &[_][]const u8{ "cmd", "/c", batch_path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
    } else {
        const new_name = try std.fmt.allocPrint(arena, "{s}.new", .{exe_name});
        defer arena.free(new_name);
        const old_name = try std.fmt.allocPrint(arena, "{s}.old", .{exe_name});
        defer arena.free(old_name);

        try std.Io.Dir.copyFile(tmp_dir, extracted_path, exe_dir, new_name, io, .{});
        std.Io.Dir.setFilePermissions(exe_dir, io, new_name, @enumFromInt(0o755), .{}) catch {};

        try std.Io.Dir.rename(exe_dir, exe_name, exe_dir, old_name, io);
        errdefer std.Io.Dir.rename(exe_dir, old_name, exe_dir, exe_name, io) catch {};

        std.Io.Dir.rename(exe_dir, new_name, exe_dir, exe_name, io) catch |err| {
            std.Io.Dir.rename(exe_dir, old_name, exe_dir, exe_name, io) catch {};
            std.Io.Dir.deleteFile(exe_dir, io, new_name) catch {};
            return err;
        };

        std.Io.Dir.deleteFile(exe_dir, io, old_name) catch {};
    }

    tmp_dir.close(io);
    if (@import("builtin").os.tag != .windows) {
        std.Io.Dir.cwd().deleteTree(io, tmp_dir_path) catch {};
    }

    try stderr_writer.print("Upgraded to v{s}. Restart to use the new version.\n", .{latest_ver_str});
    try stderr_writer.flush();
}

test "upgradeTempParent prefers TMPDIR over TEMP and TMP" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/custom/tmp");
    try env.put("TEMP", "/other/temp");
    try env.put("TMP", "/third/tmp");

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/custom/tmp", result);
}

test "upgradeTempParent falls back to TEMP when TMPDIR is unset" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TEMP", "C:\\Temp");

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("C:\\Temp", result);
}

test "upgradeTempParent falls back to TMP when TEMP is unset" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TMP", "C:\\Windows\\Temp");

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("C:\\Windows\\Temp", result);
}

test "upgradeTempParent falls back to the platform default temp dir" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const result = try upgradeTempParent(std.testing.allocator, &env);
    defer std.testing.allocator.free(result);
    const expected = if (@import("builtin").os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    try std.testing.expectEqualStrings(expected, result);
}

fn testTmpSubDir() !struct { std.testing.TmpDir, std.Io.Dir } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(std.testing.io, "upgrade", .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(std.testing.io);
    return .{ tmp, dir };
}

test "testTmpSubDir creates upgrade dir inside the tmp dir" {
    var tmp, var dir = try testTmpSubDir();
    defer {
        dir.close(std.testing.io);
        tmp.cleanup();
    }

    var probe = try dir.createFile(std.testing.io, "probe.txt", .{});
    defer probe.close(std.testing.io);

    var probe_via_tmp = try tmp.dir.openFile(std.testing.io, "upgrade/probe.txt", .{});
    probe_via_tmp.close(std.testing.io);
}

test "verifyDownloadSize accepts a download of the expected size" {
    var tmp, var dir = try testTmpSubDir();
    defer {
        dir.close(std.testing.io);
        tmp.cleanup();
    }

    var file = try dir.createFile(std.testing.io, "archive.zip", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "12345");

    try verifyDownloadSize(std.testing.io, dir, "archive.zip", 5);
}

test "verifyDownloadSize rejects a truncated download" {
    var tmp, var dir = try testTmpSubDir();
    defer {
        dir.close(std.testing.io);
        tmp.cleanup();
    }

    var file = try dir.createFile(std.testing.io, "archive.zip", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "12345");

    try std.testing.expectError(error.TruncatedDownload, verifyDownloadSize(std.testing.io, dir, "archive.zip", 6));
}

test "clearDirContents removes files and subdirectories" {
    var tmp, var dir = try testTmpSubDir();
    defer {
        dir.close(std.testing.io);
        tmp.cleanup();
    }

    var file = try dir.createFile(std.testing.io, "stale.zip", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "partial download");

    _ = try dir.createDir(std.testing.io, "nested", @enumFromInt(0o755));

    try clearDirContents(std.testing.io, dir);

    var iterable = dir.iterate();
    try std.testing.expect((try iterable.next(std.testing.io)) == null);
}

var test_retry_extract_attempts: usize = 0;

fn testRetryExtractDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_dir: std.Io.Dir,
    dest_name: []const u8,
) anyerror!void {
    _ = allocator;
    _ = url;
    var file = try dest_dir.createFile(io, dest_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "test-archive");
}

fn testRetryExtractUnpack(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    archive_name: []const u8,
    binary_name: []const u8,
) anyerror![]const u8 {
    _ = archive_name;
    test_retry_extract_attempts += 1;
    if (test_retry_extract_attempts == 1) {
        var stale = try dir.createFile(io, "stale.bin", .{});
        defer stale.close(io);
        try stale.writeStreamingAll(io, "leftover from partial extraction");
        return error.CorruptInput;
    }
    if (dir.openFile(io, "stale.bin", .{})) |f| {
        f.close(io);
        return error.StaleFileNotCleaned;
    } else |_| {}
    var bin = try dir.createFile(io, binary_name, .{});
    defer bin.close(io);
    try bin.writeStreamingAll(io, "new binary");
    return try allocator.dupe(u8, binary_name);
}

test "retryExtract clears the temp dir so stale files do not block a retry" {
    test_retry_extract_attempts = 0;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var tmp, var tmp_dir = try testTmpSubDir();
    defer {
        tmp_dir.close(std.testing.io);
        tmp.cleanup();
    }

    var progress_buf: [128]u8 = undefined;
    var progress_writer = std.Io.Writer.fixed(&progress_buf);

    const result = try retryExtract(
        std.testing.allocator,
        std.testing.io,
        tmp_dir,
        "archive.zip",
        "puny",
        "http://example.com/archive.zip",
        null,
        random,
        &progress_writer,
        testRetryExtractDownload,
        testRetryExtractUnpack,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("puny", result);
    try std.testing.expectEqual(@as(usize, 2), test_retry_extract_attempts);
}

var test_size_download_attempts: usize = 0;

fn testSizeRetryExtractDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_dir: std.Io.Dir,
    dest_name: []const u8,
) anyerror!void {
    _ = allocator;
    _ = url;
    test_size_download_attempts += 1;
    var file = try dest_dir.createFile(io, dest_name, .{});
    defer file.close(io);
    const content = if (test_size_download_attempts == 1) "abc" else "abcd";
    try file.writeStreamingAll(io, content);
}

fn testSimpleRetryExtractUnpack(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    archive_name: []const u8,
    binary_name: []const u8,
) anyerror![]const u8 {
    _ = archive_name;
    var bin = try dir.createFile(io, binary_name, .{});
    defer bin.close(io);
    try bin.writeStreamingAll(io, "new binary");
    return try allocator.dupe(u8, binary_name);
}

test "retryExtract re-downloads when archive size does not match expected" {
    test_size_download_attempts = 0;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var tmp, var tmp_dir = try testTmpSubDir();
    defer {
        tmp_dir.close(std.testing.io);
        tmp.cleanup();
    }

    var progress_buf: [128]u8 = undefined;
    var progress_writer = std.Io.Writer.fixed(&progress_buf);

    const result = try retryExtract(
        std.testing.allocator,
        std.testing.io,
        tmp_dir,
        "archive.zip",
        "puny",
        "http://example.com/archive.zip",
        4,
        random,
        &progress_writer,
        testSizeRetryExtractDownload,
        testSimpleRetryExtractUnpack,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("puny", result);
    try std.testing.expectEqual(@as(usize, 2), test_size_download_attempts);
}

test "archiveNameForTarget names match the current platform" {
    const name = archiveNameForTarget();
    try std.testing.expect(std.mem.startsWith(u8, name, "puny-"));

    const builtin = @import("builtin");
    const os_tag = switch (builtin.target.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => return, // platform does not support upgrade
    };
    // Mirror the arch set supported by archiveNameForTarget: anything else
    // would raise a compile error there, so asserting on it here would be
    // misleading.
    const arch_tag = switch (builtin.target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return, // platform does not support upgrade
    };
    try std.testing.expect(std.mem.indexOf(u8, name, os_tag) != null);
    try std.testing.expect(std.mem.indexOf(u8, name, arch_tag) != null);
    // Windows releases ship as zips; Linux and macOS releases as tarballs.
    const expected_suffix = if (builtin.target.os.tag == .windows) ".zip" else ".tar.gz";
    try std.testing.expect(std.mem.endsWith(u8, name, expected_suffix));
}

test "findInDir locates a file by name" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var f = try tmp.dir.createFile(std.testing.io, "puny", .{});
    f.close(std.testing.io);

    const found = try findInDir(std.testing.allocator, std.testing.io, tmp.dir, "puny");
    defer if (found) |p| std.testing.allocator.free(p);
    try std.testing.expect(found != null);

    // findInDir also descends into nested directories: a file named puny
    // inside a subdirectory is located by the recursive walk.
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    var nested_dir = try tmp.dir.openDir(std.testing.io, "nested", .{});
    defer nested_dir.close(std.testing.io);
    var nested_file = try nested_dir.createFile(std.testing.io, "puny", .{});
    nested_file.close(std.testing.io);
    // Drop the root-level file so the walk must descend to find the nested one.
    try tmp.dir.deleteFile(std.testing.io, "puny");

    const nested_found = try findInDir(std.testing.allocator, std.testing.io, tmp.dir, "puny");
    defer if (nested_found) |p| std.testing.allocator.free(p);
    try std.testing.expect(nested_found != null);
    try std.testing.expect(std.mem.indexOf(u8, nested_found.?, "nested") != null);

    const missing = try findInDir(std.testing.allocator, std.testing.io, tmp.dir, "does-not-exist");
    try std.testing.expect(missing == null);
}

var test_flaky_download_attempts: usize = 0;

fn testFlakyDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_dir: std.Io.Dir,
    dest_name: []const u8,
) anyerror!void {
    _ = allocator;
    _ = url;
    test_flaky_download_attempts += 1;
    if (test_flaky_download_attempts == 1) return error.ConnectionRefused;
    var file = try dest_dir.createFile(io, dest_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "test-archive");
}

fn testFlakyExtractUnpack(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    archive_name: []const u8,
    binary_name: []const u8,
) anyerror![]const u8 {
    _ = archive_name;
    var bin = try dir.createFile(io, binary_name, .{});
    defer bin.close(io);
    try bin.writeStreamingAll(io, "new binary");
    return try allocator.dupe(u8, binary_name);
}

test "retryExtract retries a transient download failure" {
    test_flaky_download_attempts = 0;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var tmp, var tmp_dir = try testTmpSubDir();
    defer {
        tmp_dir.close(std.testing.io);
        tmp.cleanup();
    }

    var progress_buf: [128]u8 = undefined;
    var progress_writer = std.Io.Writer.fixed(&progress_buf);

    const result = try retryExtract(
        std.testing.allocator,
        std.testing.io,
        tmp_dir,
        "archive.zip",
        "puny",
        "http://example.com/archive.zip",
        null,
        random,
        &progress_writer,
        testFlakyDownload,
        testFlakyExtractUnpack,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("puny", result);
    try std.testing.expectEqual(@as(usize, 2), test_flaky_download_attempts);
}

fn testFailingDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_dir: std.Io.Dir,
    dest_name: []const u8,
) anyerror!void {
    _ = allocator;
    _ = io;
    _ = url;
    _ = dest_dir;
    _ = dest_name;
    return error.OutOfMemory;
}

fn testFailingExtract(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    archive_name: []const u8,
    binary_name: []const u8,
) anyerror![]const u8 {
    _ = allocator;
    _ = io;
    _ = dir;
    _ = archive_name;
    _ = binary_name;
    return error.OutOfMemory;
}

test "retryExtract fails immediately on a non-transient download error" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var tmp, var tmp_dir = try testTmpSubDir();
    defer {
        tmp_dir.close(std.testing.io);
        tmp.cleanup();
    }

    var progress_buf: [128]u8 = undefined;
    var progress_writer = std.Io.Writer.fixed(&progress_buf);

    try std.testing.expectError(error.OutOfMemory, retryExtract(
        std.testing.allocator,
        std.testing.io,
        tmp_dir,
        "archive.zip",
        "puny",
        "http://example.com/archive.zip",
        null,
        random,
        &progress_writer,
        testFailingDownload,
        testFailingExtract,
    ));
}

test "retryExtract fails immediately on a non-transient extract error" {
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();

    var tmp, var tmp_dir = try testTmpSubDir();
    defer {
        tmp_dir.close(std.testing.io);
        tmp.cleanup();
    }

    var progress_buf: [128]u8 = undefined;
    var progress_writer = std.Io.Writer.fixed(&progress_buf);

    try std.testing.expectError(error.OutOfMemory, retryExtract(
        std.testing.allocator,
        std.testing.io,
        tmp_dir,
        "archive.zip",
        "puny",
        "http://example.com/archive.zip",
        null,
        random,
        &progress_writer,
        testRetryExtractDownload,
        testFailingExtract,
    ));
}
