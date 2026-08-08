const std = @import("std");
const retry = @import("../core/retry.zig");

pub fn dupeString(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

pub fn ownedSliceOrEmpty(list: *std.ArrayList(u8), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    if (list.items.len == 0) return "";
    return try list.toOwnedSlice(allocator);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_size: usize) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_size));
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try list.appendSlice(allocator, entry.name);
        try list.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&list, allocator);
}

pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    _ = try drainPipes(allocator, io, &child, &stdout, &stderr, null);

    const term = try child.wait(io);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    switch (term) {
        .exited => |code| {
            try result.appendSlice(allocator, "Exit code: ");
            var buf: [32]u8 = undefined;
            const n = try std.fmt.bufPrint(&buf, "{d}", .{code});
            try result.appendSlice(allocator, n);
        },
        else => {
            try result.appendSlice(allocator, "Terminated\n");
        },
    }

    if (stdout.items.len > 0) {
        try result.appendSlice(allocator, "STDOUT:\n");
        try result.appendSlice(allocator, stdout.items);
        try result.append(allocator, '\n');
    }
    if (stderr.items.len > 0) {
        try result.appendSlice(allocator, "STDERR:\n");
        try result.appendSlice(allocator, stderr.items);
        try result.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&result, allocator);
}

/// Reads a single child pipe into `out`, stopping early when `cancel` is set.
fn drainPipe(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    out: *std.ArrayList(u8),
    cancel: ?*const std.atomic.Value(bool),
) !void {
    // The sink is separate from the reader's backing buffer: passing the
    // backing buffer to readSliceShort aliases when a single read returns
    // more than the buffer size (the reader stores the overflow in its own
    // buffer, then memcpys between overlapping slices).
    var backing: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    var reader = file.reader(io, &backing);
    while (true) {
        if (cancel) |c| {
            if (c.load(.acquire)) return;
        }
        const n = try reader.interface.readSliceShort(&sink);
        if (n == 0) break;
        try out.appendSlice(allocator, sink[0..n]);
    }
}

const PipeDrain = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    out: *std.ArrayList(u8),
    cancel: ?*const std.atomic.Value(bool),
    result: anyerror!void = {},

    fn run(self: *PipeDrain) void {
        self.result = drainPipe(self.allocator, self.io, self.file, self.out, self.cancel);
    }
};

/// Drains stdout and stderr concurrently so a child that fills one pipe
/// (more than a pipe buffer's worth of output) while the other is still open
/// can never deadlock against a sequential read order. When `cancel` is
/// observed the child process tree is killed before joining the other drain,
/// so a reader blocked in a pipe read is unblocked by the kill closing the
/// pipes. drainPipes owns process termination on the cancellation path: the
/// caller must not kill the tree again when the returned value is true.
/// Returns true when cancellation was observed (caller treats it as a
/// timeout), false when both pipes reached EOF normally.
fn drainPipes(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    cancel: ?*const std.atomic.Value(bool),
) !bool {
    var stderr_drain: ?PipeDrain = null;
    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |file| {
        stderr_drain = .{ .allocator = allocator, .io = io, .file = file, .out = stderr, .cancel = cancel };
        stderr_thread = try std.Thread.spawn(.{}, PipeDrain.run, .{&stderr_drain.?});
    }

    var timed_out = false;
    var stdout_result: anyerror!void = {};
    if (child.stdout) |file| {
        var stdout_drain = PipeDrain{ .allocator = allocator, .io = io, .file = file, .out = stdout, .cancel = cancel };
        stdout_drain.run();
        stdout_result = stdout_drain.result;
        if (cancel) |c| timed_out = c.load(.acquire);
    }

    if (timed_out) {
        killProcessTree(io, child);
    }

    if (stderr_thread) |t| t.join();
    if (stderr_drain) |*d| {
        if (d.result) |_| {} else |err| return err;
    }
    if (cancel) |c| timed_out = timed_out or c.load(.acquire);
    try stdout_result;
    return timed_out;
}

/// Timeout applied to shell-backed tools that do not accept a model-supplied
/// timeout parameter (git_status, git_diff, grep_search).
pub const run_command_timeout_ns: i96 = 30 * std.time.ns_per_s;

/// Default timeout applied to execute_shell when the model does not provide
/// one. Generous for real work (builds, test suites) while still a hard bound
/// so the agent can never hang on a single command.
pub const execute_shell_timeout_ns: i96 = 120 * std.time.ns_per_s;

/// Default timeout applied to web_fetch when the model does not provide one.
pub const web_fetch_timeout_ns: i96 = 15 * std.time.ns_per_s;

/// How long the caller waits after requesting a timed-out command be
/// terminated before abandoning the worker thread. Long enough for a kill to
/// land while still bounding the total wall time of a timed-out tool call.
const kill_grace_ns: i96 = 2 * std.time.ns_per_s;

/// Floor applied to a model-supplied `timeout_seconds` value, in seconds.
const min_timeout_s = 1;

/// Ceiling applied to a model-supplied `timeout_seconds` value, in seconds.
/// Keeps the guard in force even when the model asks for a huge deadline.
const max_timeout_s = 300;

/// Resolves the effective timeout for a tool call. When the model supplies a
/// `timeout_seconds` value it is clamped to [min_timeout_s, max_timeout_s] and
/// converted to nanoseconds; otherwise `default_ns` (a trusted compile-time
/// constant) is returned unchanged.
pub fn resolveTimeoutSeconds(model_value: ?i64, default_ns: i96) i96 {
    const value = model_value orelse return default_ns;
    const seconds: i96 = @intCast(value);
    const clamped: i96 = std.math.clamp(seconds, min_timeout_s, max_timeout_s);
    return clamped * std.time.ns_per_s;
}

const RunCommandShared = struct {
    io: std.Io,
    child: *std.process.Child,
    done: *std.Io.Event,
    ack: *std.Io.Event,
    cancel: std.atomic.Value(bool),
    result: anyerror![]const u8,
    arena: std.heap.ArenaAllocator,
};

/// Number of timed-out `runCommandTimed` calls whose worker thread was
/// abandoned because the child could not be terminated within the grace
/// period. Test-only observability; production code never reads it.
var test_run_command_worker_detached: usize = 0;

fn runCommandThread(shared: *RunCommandShared) void {
    shared.result = runCommandInArena(shared.arena.allocator(), shared.io, shared.child, &shared.cancel);
    shared.done.set(shared.io);
    shared.ack.waitUncancelable(shared.io);
    shared.arena.deinit();
}

fn runCommandInArena(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    cancel: *std.atomic.Value(bool),
) anyerror![]const u8 {
    errdefer child.kill(io);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try drainPipes(allocator, io, child, &stdout, &stderr, cancel);

    // drainPipes already terminated the process tree when timed_out is true.
    if (timed_out) return error.TimedOut;

    const term = try child.wait(io);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    switch (term) {
        .exited => |code| {
            try result.appendSlice(allocator, "Exit code: ");
            var buf: [32]u8 = undefined;
            const n = try std.fmt.bufPrint(&buf, "{d}", .{code});
            try result.appendSlice(allocator, n);
        },
        else => {
            try result.appendSlice(allocator, "Terminated\n");
        },
    }

    if (stdout.items.len > 0) {
        try result.appendSlice(allocator, "STDOUT:\n");
        try result.appendSlice(allocator, stdout.items);
        try result.append(allocator, '\n');
    }
    if (stderr.items.len > 0) {
        try result.appendSlice(allocator, "STDERR:\n");
        try result.appendSlice(allocator, stderr.items);
        try result.append(allocator, '\n');
    }

    return ownedSliceOrEmpty(&result, allocator);
}

/// Forcibly terminates the child and every process it spawned. Killing only
/// the direct child leaves grandchildren running (e.g. `cmd /c zig build`
/// where zig.exe is a grandchild of cmd.exe), which keeps the output pipes
/// open and can block the worker forever. On Windows the whole tree is
/// terminated with `taskkill /T`; on POSIX the child is spawned as a process
/// group leader so a group kill reaches everything it started.
fn killProcessTree(io: std.Io, child: *std.process.Child) void {
    if (@import("builtin").os.tag == .windows) {
        const handle = child.id orelse return;
        // Resolve the OS process id from the hProcess handle, then kill the
        // whole tree with taskkill /T.
        var info: std.os.windows.PROCESS.BASIC_INFORMATION = undefined;
        const pid = switch (std.os.windows.ntdll.NtQueryInformationProcess(
            handle,
            .BasicInformation,
            &info,
            @sizeOf(std.os.windows.PROCESS.BASIC_INFORMATION),
            null,
        )) {
            .SUCCESS => info.UniqueProcessId,
            else => return,
        };
        var buf: [64]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return;
        const argv = [_][]const u8{ "taskkill", "/PID", pid_str, "/T", "/F" };
        var killer = std.process.spawn(io, .{
            .argv = &argv,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        }) catch return;
        _ = killer.wait(io) catch {};
    } else {
        const pid = child.id orelse return;
        std.posix.kill(-pid, .KILL) catch {};
    }
}

/// Runs `argv` in a worker thread and waits up to `timeout_ns` for it to
/// finish. If the deadline passes, the child process tree is terminated and
/// `error.TimedOut` is returned. The returned output is caller-owned.
pub fn runCommandTimed(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ns: i96,
) ![]const u8 {
    const spawn_ctx = blk: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // Only active during setup below: once the worker thread starts it owns
        // the arena and frees it when it finishes, so the caller must never
        // deinit it again on the timeout path.
        errdefer arena.deinit();

        // The worker owns everything the command touches from here on: the
        // child, the events, and the result all live in `arena`, which the
        // worker releases when it finishes, so a timed-out call never reads or
        // writes caller-owned memory after returning.
        const shared = arena.allocator().create(RunCommandShared) catch return error.OutOfMemory;
        const child = arena.allocator().create(std.process.Child) catch return error.OutOfMemory;

        child.* = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (cwd) |p| .{ .path = p } else .inherit,
            .stdout = .pipe,
            .stderr = .pipe,
            // On POSIX the child leads its own process group so a group kill
            // reaches the whole tree. On Windows process groups do not exist;
            // the tree is handled by `taskkill /T` instead.
            .pgid = if (@import("builtin").os.tag == .windows) null else 0,
        });

        shared.* = .{
            .io = io,
            .child = child,
            .done = undefined,
            .ack = undefined,
            .cancel = .init(false),
            .result = undefined,
            .arena = arena,
        };

        shared.done = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.ack = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.done.* = .unset;
        shared.ack.* = .unset;

        const thread = std.Thread.spawn(.{}, runCommandThread, .{shared}) catch |err| {
            child.kill(io);
            return err;
        };
        break :blk .{ .thread = thread, .shared = shared, .child = child };
    };
    const thread = spawn_ctx.thread;
    const shared = spawn_ctx.shared;
    const child = spawn_ctx.child;

    const timeout = std.Io.Timeout{ .duration = .{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake,
    } };
    shared.done.waitTimeout(io, timeout) catch |wait_err| switch (wait_err) {
        error.Timeout => {
            // The worker may be blocked reading the child's pipes and unable
            // to observe `cancel`, so terminate the whole process tree from
            // here. Killing the tree closes the pipes, which unblocks the
            // worker; it then finishes and can be joined.
            shared.cancel.store(true, .release);
            killProcessTree(io, child);
            const grace = std.Io.Timeout{ .duration = .{
                .raw = .{ .nanoseconds = kill_grace_ns },
                .clock = .awake,
            } };
            shared.done.waitTimeout(io, grace) catch {
                shared.ack.set(io);
                thread.detach();
                test_run_command_worker_detached += 1;
                return error.TimedOut;
            };
            shared.ack.set(io);
            thread.join();
            return error.TimedOut;
        },
        else => {
            shared.ack.set(io);
            thread.detach();
            test_run_command_worker_detached += 1;
            return error.TimedOut;
        },
    };

    const transferred = if (shared.result) |bytes|
        allocator.dupe(u8, bytes) catch return error.OutOfMemory
    else |err|
        err;
    shared.ack.set(io);
    thread.join();
    return transferred;
}

pub fn httpDownloadFile(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_dir: std.Io.Dir, dest_name: []const u8) !void {
    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var file = try dest_dir.createFile(io, dest_name, .{});
    errdefer {
        file.close(io);
        dest_dir.deleteFile(io, dest_name) catch {};
    }

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(io, &buf);

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &file_writer.interface,
    }) catch |err| return err;

    try file_writer.interface.flush();

    if (result.status != .ok) {
        return error.HttpNotOk;
    }

    const stat = try dest_dir.statFile(io, dest_name, .{});
    if (stat.size == 0) return error.TruncatedDownload;

    file.close(io);
}

pub fn httpGet(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    _ = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &response_body.writer,
    });
    if (response_body.written().len == 0) return "";
    return response_body.toOwnedSlice();
}

const HttpGetShared = struct {
    io: std.Io,
    /// Worker-owned copy of the URL: it, the events, and the result all live
    /// in `arena`, which the worker releases when it finishes, so a timed-out
    /// call never reads or writes caller-owned memory after returning.
    url: []const u8,
    done: *std.Io.Event,
    ack: *std.Io.Event,
    result: anyerror![]const u8,
    arena: std.heap.ArenaAllocator,
};

fn httpGetThread(shared: *HttpGetShared) void {
    shared.result = httpGet(shared.arena.allocator(), shared.io, shared.url);
    shared.done.set(shared.io);
    shared.ack.waitUncancelable(shared.io);
    shared.arena.deinit();
}

/// Fetches `url` in a worker thread and waits up to `timeout_ns` for the
/// request to finish. If the deadline passes, `error.TimedOut` is returned and
/// the in-flight request is abandoned: it cannot be aborted mid-flight, so the
/// worker thread keeps running until the socket settles, then releases
/// everything it owns. The returned body is caller-owned.
pub fn httpGetTimed(allocator: std.mem.Allocator, io: std.Io, url: []const u8, timeout_ns: i96) ![]const u8 {
    const spawn_ctx = blk: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // Only active during setup below: once the worker thread starts it owns
        // the arena and frees it when it finishes, so the caller must never
        // deinit it again on the timeout path.
        errdefer arena.deinit();

        const shared = arena.allocator().create(HttpGetShared) catch return error.OutOfMemory;
        shared.* = .{
            .io = io,
            .url = &.{},
            .done = undefined,
            .ack = undefined,
            .result = undefined,
            .arena = arena,
        };
        shared.url = arena.allocator().dupe(u8, url) catch return error.OutOfMemory;

        shared.done = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.ack = arena.allocator().create(std.Io.Event) catch return error.OutOfMemory;
        shared.done.* = .unset;
        shared.ack.* = .unset;

        const thread = std.Thread.spawn(.{}, httpGetThread, .{shared}) catch |err| return err;
        break :blk .{ .thread = thread, .shared = shared };
    };
    const thread = spawn_ctx.thread;
    const shared = spawn_ctx.shared;

    const timeout = std.Io.Timeout{ .duration = .{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake,
    } };
    shared.done.waitTimeout(io, timeout) catch |wait_err| switch (wait_err) {
        error.Timeout => {
            // The request cannot be aborted mid-flight. The worker owns
            // everything it touches and tears it down when the fetch settles,
            // so abandoning the wait never reads or writes caller-owned memory.
            shared.ack.set(io);
            thread.detach();
            return error.TimedOut;
        },
        else => {
            shared.ack.set(io);
            thread.detach();
            return error.TimedOut;
        },
    };

    const transferred = if (shared.result) |bytes|
        allocator.dupe(u8, bytes) catch return error.OutOfMemory
    else |err|
        err;
    shared.ack.set(io);
    thread.join();
    return transferred;
}

var test_download_attempts: usize = 0;
var test_download_fail_until: usize = 0;
var test_download_error: anyerror = error.ConnectionTimedOut;

fn testDownload(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_dir: std.Io.Dir, dest_name: []const u8) anyerror!void {
    _ = allocator;
    _ = url;
    test_download_attempts += 1;
    if (test_download_attempts <= test_download_fail_until) return test_download_error;
    var file = try dest_dir.createFile(io, dest_name, .{});
    file.close(io);
}

fn retryDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_dir: std.Io.Dir,
    dest_name: []const u8,
    random: std.Random,
    comptime download_fn: fn (std.mem.Allocator, std.Io, []const u8, std.Io.Dir, []const u8) anyerror!void,
) !void {
    const cfg = retry.default_config;
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        download_fn(allocator, io, url, dest_dir, dest_name) catch |err| {
            dest_dir.deleteFile(io, dest_name) catch {};
            if (attempt > cfg.max_retries) return err;
            if (!retry.isDownloadTransientError(err)) return err;
            const delay_ms = retry.computeDelay(cfg, attempt, random);
            io.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms * std.time.ns_per_ms)) }, .awake) catch {};
            continue;
        };
        return;
    }
}

test "retryDownload retries transient errors" {
    test_download_attempts = 0;
    test_download_fail_until = 2;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectEqual(@as(usize, 3), test_download_attempts);
    // Verify file exists after successful retry
    var f = try tmp_dir.dir.openFile(std.testing.io, "test.zip", .{});
    f.close(std.testing.io);
}

test "retryDownload fails after exhausting retries" {
    test_download_attempts = 0;
    test_download_fail_until = 999;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const result = retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectError(error.ConnectionTimedOut, result);
}

test "retryDownload fails immediately on non-transient error" {
    test_download_attempts = 0;
    test_download_fail_until = 1;
    test_download_error = error.InvalidArgument;
    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const result = retryDownload(std.testing.allocator, std.testing.io, "http://example.com/test", tmp_dir.dir, "test.zip", random, testDownload);
    try std.testing.expectEqual(@as(usize, 1), test_download_attempts);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "runCommandTimed returns output for a command that finishes within the deadline" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    const output = try runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "hello"));
}

fn fullStderrArgv() []const []const u8 {
    return if (@import("builtin").os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-Command", "1..20000 | ForEach-Object { [Console]::Error.WriteLine(\"stderr line $_\"); Write-Output \"stdout line $_\" }" }
    else
        &.{ "sh", "-c", "i=0; while [ $i -lt 20000 ]; do echo \"stderr line $i\" >&2; echo \"stdout line $i\"; i=$((i+1)); done" };
}

test "runCommand drains a full stderr pipe without deadlocking stdout" {
    // A child that writes more than one pipe buffer's worth to stderr while
    // also keeping stdout active would deadlock a sequential stdout-then-
    // stderr drain: the child blocks on the full stderr pipe and can never
    // close stdout, so the parent never sees EOF. The concurrent drain must
    // let the command complete.
    const output = try runCommand(std.testing.allocator, std.testing.io, fullStderrArgv(), null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stderr line 19999") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stdout line 19999") != null);
}

test "runCommandTimed drains a full stderr pipe without deadlocking stdout" {
    // The same scenario through the timed path, which drives
    // runCommandInArena; the timeout bounds the test if a regression
    // reintroduces the deadlock.
    const output = try runCommandTimed(std.testing.allocator, std.testing.io, fullStderrArgv(), null, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stderr line 19999") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stdout line 19999") != null);
}

test "runCommandTimed returns TimedOut and terminates a command that never exits" {
    const before = test_run_command_worker_detached;
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-Command", "while ($true) { 'x'; Start-Sleep -Milliseconds 10 }" }
    else
        &.{ "sh", "-c", "while true; do echo x; sleep 0.01; done" };

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const result = runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 200 * std.time.ns_per_ms);
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.nanoseconds;

    try std.testing.expectError(error.TimedOut, result);
    // The worker must have been joined, not abandoned: the hung child was
    // terminated in-process rather than left running in the background.
    try std.testing.expectEqual(before, test_run_command_worker_detached);
    // Must return long before the child could ever finish on its own.
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}

test "resolveTimeoutSeconds falls back to the default when no value is supplied" {
    try std.testing.expectEqual(run_command_timeout_ns, resolveTimeoutSeconds(null, run_command_timeout_ns));
    try std.testing.expectEqual(web_fetch_timeout_ns, resolveTimeoutSeconds(null, web_fetch_timeout_ns));
}

test "resolveTimeoutSeconds converts whole seconds to nanoseconds" {
    try std.testing.expectEqual(30 * std.time.ns_per_s, resolveTimeoutSeconds(30, run_command_timeout_ns));
    try std.testing.expectEqual(2 * std.time.ns_per_s, resolveTimeoutSeconds(2, web_fetch_timeout_ns));
}

test "resolveTimeoutSeconds clamps values below the floor to one second" {
    try std.testing.expectEqual(std.time.ns_per_s, resolveTimeoutSeconds(0, run_command_timeout_ns));
    try std.testing.expectEqual(std.time.ns_per_s, resolveTimeoutSeconds(-10, run_command_timeout_ns));
}

test "resolveTimeoutSeconds clamps values above the ceiling to five minutes" {
    try std.testing.expectEqual(300 * std.time.ns_per_s, resolveTimeoutSeconds(999999999, run_command_timeout_ns));
}

test "httpGetTimed returns TimedOut when the server never responds" {
    const Ctx = struct {
        io: std.Io,
        server: std.Io.net.Server,
        done: std.atomic.Value(bool) = .init(false),

        fn serve(self: *@This()) void {
            defer self.done.store(true, .release);
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);

            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);

            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            _ = http_server.receiveHead() catch return;
            // Hold the connection open past the client timeout, then close.
            self.io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = std.Io.net.IpAddress.listen(&address, std.testing.io, .{}) catch |err| {
        std.debug.print("listen failed: {s}\n", .{@errorName(err)});
        return error.ListenFailed;
    };
    const port = server.socket.address.getPort();

    var ctx = Ctx{ .io = std.testing.io, .server = server };
    const thread = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/never", .{port});
    defer std.testing.allocator.free(url);

    const result = httpGetTimed(std.testing.allocator, std.testing.io, url, 100 * std.time.ns_per_ms);
    try std.testing.expectError(error.TimedOut, result);

    // Wait for the server thread to finish before tearing down the socket so
    // the abandoned fetch thread can settle against a closed connection.
    var guard: usize = 0;
    while (!ctx.done.load(.acquire) and guard < 100_000_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    thread.join();
    ctx.server.deinit(std.testing.io);
}

test "dupeString returns an empty string without allocating" {
    try std.testing.expectEqualStrings("", try dupeString(std.testing.allocator, ""));
    const duped = try dupeString(std.testing.allocator, "hello");
    defer std.testing.allocator.free(duped);
    try std.testing.expectEqualStrings("hello", duped);
    try std.testing.expect(duped.ptr != "hello".ptr);
}

test "ownedSliceOrEmpty returns an empty string for an empty list" {
    var list: std.ArrayList(u8) = .empty;
    try std.testing.expectEqualStrings("", try ownedSliceOrEmpty(&list, std.testing.allocator));
}

test "ownedSliceOrEmpty takes ownership of a non-empty list" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "abc");
    const owned = try ownedSliceOrEmpty(&list, std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("abc", owned);
}

test "runCommand formats exit code and stdout" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    const output = try runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
}

test "runCommand reports a non-zero exit code" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "exit 3" }
    else
        &.{ "sh", "-c", "exit 3" };
    const output = try runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 3") != null);
}

test "runCommand captures stderr" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo oops 1>&2" }
    else
        &.{ "sh", "-c", "echo oops >&2" };
    const output = try runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "oops") != null);
}

test "writeFile readFileAlloc and listDirectory round-trip" {
    const path = "puny-test-helpers-rt.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try writeFile(std.testing.io, path, "payload");
    const content = try readFileAlloc(std.testing.allocator, std.testing.io, path, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("payload", content);

    const listing = try listDirectory(std.testing.allocator, std.testing.io, ".");
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, path) != null);
}

test "readFileAlloc rejects content larger than the limit" {
    const path = "puny-test-helpers-big.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try writeFile(std.testing.io, path, "123456789");
    try std.testing.expectError(error.StreamTooLong, readFileAlloc(std.testing.allocator, std.testing.io, path, 4));
}
