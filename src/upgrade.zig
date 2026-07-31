const std = @import("std");
const helpers = @import("tools/helpers.zig");
const retry = @import("core/retry.zig");

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

pub fn archiveNameForTarget() []const u8 {
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

pub fn upgradeTempParent(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
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

pub fn extractAndFindBinary(
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

fn testTmpSubDir() !struct { std.testing.TmpDir, std.Io.Dir, []const u8 } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const sub_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.sub_path[0..], "upgrade" });
    errdefer std.testing.allocator.free(sub_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sub_path);
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, sub_path, .{ .iterate = true });
    errdefer dir.close(std.testing.io);
    return .{ tmp, dir, sub_path };
}

test "verifyDownloadSize accepts a download of the expected size" {
    var tmp, var dir, const sub_path = try testTmpSubDir();
    defer {
        dir.close(std.testing.io);
        std.testing.allocator.free(sub_path);
        tmp.cleanup();
    }

    var file = try dir.createFile(std.testing.io, "archive.zip", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "12345");

    try verifyDownloadSize(std.testing.io, dir, "archive.zip", 5);
}

test "verifyDownloadSize rejects a truncated download" {
    var tmp, var dir, const sub_path = try testTmpSubDir();
    defer {
        dir.close(std.testing.io);
        std.testing.allocator.free(sub_path);
        tmp.cleanup();
    }

    var file = try dir.createFile(std.testing.io, "archive.zip", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "12345");

    try std.testing.expectError(error.TruncatedDownload, verifyDownloadSize(std.testing.io, dir, "archive.zip", 6));
}

test "clearDirContents removes files and subdirectories" {
    var tmp, var dir, const sub_path = try testTmpSubDir();
    defer {
        dir.close(std.testing.io);
        std.testing.allocator.free(sub_path);
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sub_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.sub_path[0..], "upgrade" });
    defer std.testing.allocator.free(sub_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sub_path);
    var tmp_dir = try std.Io.Dir.cwd().openDir(std.testing.io, sub_path, .{ .iterate = true });
    defer tmp_dir.close(std.testing.io);

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sub_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.sub_path[0..], "upgrade" });
    defer std.testing.allocator.free(sub_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sub_path);
    var tmp_dir = try std.Io.Dir.cwd().openDir(std.testing.io, sub_path, .{ .iterate = true });
    defer tmp_dir.close(std.testing.io);

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
