const std = @import("std");

pub fn ownedSliceOrEmpty(list: *std.ArrayList(u8), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    if (list.items.len == 0) return "";
    return try list.toOwnedSlice(allocator);
}

pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    // stderr is drained on a separate thread inside drainPipes, so the drain
    // buffers must come from a thread-safe allocator; page_allocator is.
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.heap.page_allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.heap.page_allocator);

    _ = try drainPipes(std.heap.page_allocator, io, &child, &stdout, &stderr, null);

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
/// The allocator must be thread-safe: stderr is drained on a spawned thread
/// while stdout is drained on the caller's thread.
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

/// How long the caller waits after requesting a timed-out command be
/// terminated before abandoning the worker thread. Long enough for a kill to
/// land while still bounding the total wall time of a timed-out tool call.
const kill_grace_ns: i96 = 2 * std.time.ns_per_s;

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
pub var test_run_command_worker_detached: usize = 0;

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
    var kill_child = true;
    errdefer if (kill_child) child.kill(io);

    // stderr is drained on a separate thread inside drainPipes, so the drain
    // buffers must come from a thread-safe allocator; page_allocator is.
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.heap.page_allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.heap.page_allocator);

    const timed_out = try drainPipes(std.heap.page_allocator, io, child, &stdout, &stderr, cancel);

    // drainPipes already terminated the process tree when timed_out is true,
    // so the errdefer must not kill the child a second time.
    if (timed_out) {
        kill_child = false;
        return error.TimedOut;
    }

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

fn selfKillArgv() []const []const u8 {
    return if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "exit 1" }
    else
        &.{ "sh", "-c", "kill -9 $$" };
}

test "runCommand reports Terminated for a signal-killed child" {
    const argv = selfKillArgv();
    const output = try runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 1") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output, "Terminated") != null);
    }
}

test "runCommandTimed reports Terminated for a signal-killed child" {
    const argv = selfKillArgv();
    const output = try runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 1") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output, "Terminated") != null);
    }
}

test "runCommandTimed runs the command in the given working directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker.txt", .data = "cwd-marker" });

    const cwd = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(cwd);

    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "type marker.txt" }
    else
        &.{ "cat", "marker.txt" };
    const output = try runCommandTimed(std.testing.allocator, std.testing.io, argv, cwd, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "cwd-marker") != null);
}

test "runCommand formats the exit code, stdout, and stderr of a completed child" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo out line & echo err line 1>&2 & exit 7" }
    else
        &.{ "sh", "-c", "echo out line; echo err line >&2; exit 7" };
    const output = try runCommand(std.testing.allocator, std.testing.io, argv, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDOUT:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "out line") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STDERR:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "err line") != null);
}

test "runCommandTimed formats the exit code and stdout of a fast child" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo timed ok" }
    else
        &.{ "sh", "-c", "echo timed ok" };
    const output = try runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 30 * std.time.ns_per_s);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Exit code: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "timed ok") != null);
}

test "runCommand propagates a spawn failure for a missing executable" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{"C:\\nonexistent-puny-binary-xyz.exe"}
    else
        &.{"/nonexistent-puny-binary-xyz"};
    try std.testing.expectError(error.FileNotFound, runCommand(std.testing.allocator, std.testing.io, argv, null));
}

test "runCommandTimed propagates a spawn failure for a missing executable" {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{"C:\\nonexistent-puny-binary-xyz.exe"}
    else
        &.{"/nonexistent-puny-binary-xyz"};
    try std.testing.expectError(error.FileNotFound, runCommandTimed(std.testing.allocator, std.testing.io, argv, null, 30 * std.time.ns_per_s));
}
