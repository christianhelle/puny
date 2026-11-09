//! End-to-end checks for typing while a response streams.
//!
//! Regression tests run puny without a terminal, where the cancel monitor
//! never starts, so this drives the real binary through a pseudo-terminal.
//!
//! Usage: enqueue_pty <path to puny>

const std = @import("std");
const c = std.c;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn _exit(status: c_int) noreturn;

const timeout_seconds = 15;
const rows = 24;
const columns = 80;
const set_region = std.fmt.comptimePrint("\x1b[1;{d}r", .{rows - 2});
const reset_region = "\x1b[r";
const bar_row = std.fmt.comptimePrint("\x1b[{d};1H", .{rows});
const short_stream = "slow\r";
// Takes far longer than a test should, so only for turns the test cancels.
const long_stream = "slow long story\r";

const Winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

const Puny = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pid: c.pid_t,
    fd: c_int,
    raw: std.ArrayList(u8) = .empty,
    /// `raw` without its escape sequences.
    output: std.ArrayList(u8) = .empty,
    filter: enum { text, escape, csi } = .text,

    fn start(allocator: std.mem.Allocator, io: std.Io, binary: [:0]const u8, home: []const u8, path: []const u8) !Puny {
        const home_z = try allocator.dupeSentinel(u8, home, 0);
        const argv = [_:null]?[*:0]const u8{ binary, "--mock", "--model", "mock-model" };
        const envp = [_:null]?[*:0]const u8{
            try std.fmt.allocPrintSentinel(allocator, "HOME={s}", .{home}, 0),
            try std.fmt.allocPrintSentinel(allocator, "XDG_CONFIG_HOME={s}/.config", .{home}, 0),
            try std.fmt.allocPrintSentinel(allocator, "PATH={s}", .{path}, 0),
            "TERM=xterm-256color",
        };

        const flags: c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
        const master = posix_openpt(@bitCast(flags));
        if (master < 0 or grantpt(master) != 0 or unlockpt(master) != 0) return error.NoPseudoTerminal;
        const follower = ptsname(master) orelse return error.NoPseudoTerminal;

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) runChild(master, follower, home_z, binary, &argv, &envp);
        return .{ .allocator = allocator, .io = io, .pid = pid, .fd = master };
    }

    /// Runs between fork and exec, so it must not allocate or return.
    fn runChild(
        master: c_int,
        follower: [*:0]const u8,
        home: [*:0]const u8,
        binary: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) noreturn {
        _ = c.close(master);
        _ = c.setsid();
        const fd = c.open(follower, .{ .ACCMODE = .RDWR });
        if (fd < 0) _exit(127);
        _ = c.ioctl(fd, c.T.IOCSCTTY, @as(c_int, 0));
        const size: Winsize = .{ .row = rows, .col = columns };
        _ = c.ioctl(fd, c.T.IOCSWINSZ, &size);
        for ([_]c_int{ 0, 1, 2 }) |target| _ = c.dup2(fd, target);
        if (fd > 2) _ = c.close(fd);
        if (c.chdir(home) != 0) _exit(127);
        _ = c.execve(binary, argv, envp);
        _exit(127);
    }

    fn now(self: *const Puny) std.Io.Clock.Timestamp {
        return std.Io.Clock.Timestamp.now(self.io, .awake);
    }

    fn millisSince(self: *const Puny, from: std.Io.Clock.Timestamp) i64 {
        const elapsed = from.raw.durationTo(self.now().raw).nanoseconds;
        return @intCast(@divTrunc(elapsed, std.time.ns_per_ms));
    }

    /// Reads whatever arrives for `millis`, stopping early if the output
    /// goes quiet or the program exits.
    fn pump(self: *Puny, millis: i64) !void {
        const started = self.now();
        var buffer: [65536]u8 = undefined;
        while (true) {
            const remaining = millis - self.millisSince(started);
            if (remaining <= 0) return;
            var fds = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&fds, 1, @intCast(remaining)) <= 0) return;
            const count = c.read(self.fd, &buffer, buffer.len);
            if (count <= 0) return;
            try self.record(buffer[0..@intCast(count)]);
        }
    }

    fn record(self: *Puny, bytes: []const u8) !void {
        try self.raw.appendSlice(self.allocator, bytes);
        for (bytes) |byte| switch (self.filter) {
            .text => {
                if (byte == 0x1b) {
                    self.filter = .escape;
                } else {
                    try self.output.append(self.allocator, byte);
                }
            },
            .escape => self.filter = if (byte == '[') .csi else .text,
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) self.filter = .text;
            },
        };
    }

    fn waitIn(self: *Puny, stream: *std.ArrayList(u8), text: []const u8, start_at: usize) !usize {
        const started = self.now();
        while (self.millisSince(started) < timeout_seconds * std.time.ms_per_s) {
            if (std.mem.indexOfPos(u8, stream.items, @min(start_at, stream.items.len), text)) |index| return index;
            try self.pump(50);
        }
        std.debug.print("timed out waiting for {f}; output was:\n{s}\n", .{ std.zig.fmtString(text), stream.items });
        return error.TimedOut;
    }

    fn waitFor(self: *Puny, text: []const u8, start_at: usize) !usize {
        return self.waitIn(&self.output, text, start_at);
    }

    fn waitForRaw(self: *Puny, text: []const u8, start_at: usize) !usize {
        return self.waitIn(&self.raw, text, start_at);
    }

    fn send(self: *Puny, bytes: []const u8) !void {
        if (c.write(self.fd, bytes.ptr, bytes.len) != bytes.len) return error.WriteFailed;
    }

    fn resize(self: *Puny, height: u16) void {
        const size: Winsize = .{ .row = height, .col = columns };
        _ = c.ioctl(self.fd, c.T.IOCSWINSZ, &size);
    }

    fn doubleEsc(self: *Puny) !void {
        try self.send("\x1b");
        try self.pump(50);
        try self.send("\x1b");
    }

    fn stop(self: *Puny) void {
        _ = c.kill(self.pid, .KILL);
        _ = c.waitpid(self.pid, null, 0);
        _ = c.close(self.fd);
    }
};

/// Submits a slow prompt and returns once its response is streaming.
fn startStreaming(puny: *Puny, prompt: []const u8) !usize {
    _ = try puny.waitFor(">", 0);
    try puny.pump(300);
    const mark = puny.output.items.len;
    try puny.send(prompt);
    _ = try puny.waitFor("Thinking", mark);
    return mark;
}

fn lineTypedWhileStreamingIsDelivered(puny: *Puny) !void {
    const mark = try startStreaming(puny, short_stream);
    try puny.send("say fast\r");

    const notice = "Queued: say fast";
    const queued = try puny.waitFor(notice, mark);
    // The mock echoes the message it is answering.
    _ = try puny.waitFor("say fast", queued + notice.len);
}

fn cancelHoldsTypedTextForThePrompt(puny: *Puny) !void {
    const mark = try startStreaming(puny, long_stream);
    try puny.pump(500);
    try puny.send("draft one\r");
    try puny.send("partial");
    try puny.pump(300);
    try puny.doubleEsc();

    _ = try puny.waitFor("draft one partial", mark);
    if (std.mem.indexOf(u8, puny.output.items[mark..], "Queued:") != null) {
        std.debug.print("held text was sent:\n{s}\n", .{puny.output.items[mark..]});
        return error.HeldTextWasSent;
    }
}

fn typingShowsInABarThatGoesAway(puny: *Puny) !void {
    _ = try startStreaming(puny, long_stream);
    const region = try puny.waitForRaw(set_region, 0);
    try puny.send("visible");

    const painted = try puny.waitForRaw(bar_row, region);
    _ = try puny.waitForRaw("visible", painted);
    try puny.doubleEsc();
    _ = try puny.waitForRaw(reset_region, region);
}

fn pickerGetsTheWholeScreenAndTheBarReturns(puny: *Puny) !void {
    _ = try startStreaming(puny, "give me a choice\r");
    const first = try puny.waitForRaw(set_region, 0);
    _ = try puny.waitForRaw(reset_region, first);
    try puny.pump(500);
    try puny.send("\r");
    _ = try puny.waitForRaw(set_region, first + set_region.len);
    _ = try puny.waitFor("Got your answer", 0);
}

fn barReturnsWhenASmallWindowGrowsBack(puny: *Puny) !void {
    _ = try startStreaming(puny, long_stream);
    const first = try puny.waitForRaw(set_region, 0);

    puny.resize(3);
    const released = try puny.waitForRaw(reset_region, first);
    puny.resize(rows);
    _ = try puny.waitForRaw(set_region, released);
    try puny.doubleEsc();
}

const Case = struct {
    name: []const u8,
    run: *const fn (*Puny) anyerror!void,
};

const cases = [_]Case{
    .{ .name = "line typed while streaming is delivered", .run = lineTypedWhileStreamingIsDelivered },
    .{ .name = "cancel holds typed text for the prompt", .run = cancelHoldsTypedTextForThePrompt },
    .{ .name = "typing shows in a bar that goes away", .run = typingShowsInABarThatGoesAway },
    .{ .name = "picker gets the whole screen and the bar returns", .run = pickerGetsTheWholeScreenAndTheBarReturns },
    .{ .name = "bar returns when a small window grows back", .run = barReturnsWhenASmallWindowGrowsBack },
};

fn runCase(allocator: std.mem.Allocator, io: std.Io, binary: [:0]const u8, env: *const std.process.Environ.Map, case: Case) !void {
    const parent = env.get("TMPDIR") orelse "/tmp";
    const template = try std.fmt.allocPrintSentinel(allocator, "{s}/puny-pty-XXXXXX", .{parent}, 0);
    const home = std.mem.span(mkdtemp(template) orelse return error.NoTempDir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // An existing config keeps the first-launch setup wizard away.
    const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config/puny", .{home});
    try std.Io.Dir.cwd().createDirPath(io, config_dir);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{config_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "{\"provider\":\"lmstudio\"}\n" });

    var puny = try Puny.start(allocator, io, binary, home, env.get("PATH") orelse "/usr/bin:/bin");
    defer puny.stop();
    try case.run(&puny);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("Usage: enqueue_pty <path to puny>\n", .{});
        return 2;
    }

    // Each case changes directory, so a relative path would stop resolving.
    var resolved: [c.PATH_MAX]u8 = undefined;
    const binary = c.realpath(args[1], &resolved) orelse return error.BinaryNotFound;

    var failed = false;
    for (cases) |case| {
        runCase(arena, init.io, std.mem.span(binary), init.environ_map, case) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ case.name, @errorName(err) });
            failed = true;
            continue;
        };
        std.debug.print("ok   {s}\n", .{case.name});
    }
    return if (failed) 1 else 0;
}
