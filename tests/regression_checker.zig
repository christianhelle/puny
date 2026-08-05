const std = @import("std");

const FileContains = struct {
    path: []const u8,
    patterns: []const []const u8,
};

const Evidence = struct {
    file_exists: []const []const u8 = &.{},
    file_contains: ?FileContains = null,
};

const TestCase = struct {
    name: []const u8,
    args: []const []const u8,
    expect: []const []const u8,
    not_expect: []const []const u8,
    evidence: ?Evidence = null,
    /// When true, the checker serves `tests/fixtures/prompt.md` from an
    /// in-process HTTP server and replaces `{port}` in the test args with the
    /// actual port.
    serve_fixture: bool = false,
    /// Expected exit code; null means 0.
    exit_code: ?u8 = null,
    expect_stderr: []const []const u8 = &.{},
};

const ServerCtx = struct {
    io: std.Io,
    server: std.Io.net.Server,
    body: []const u8,
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
        var req = http_server.receiveHead() catch return;
        req.respond(self.body, .{}) catch return;
    }
};

/// Makes a `serve` thread stuck in `accept()` return so it can always be
/// joined. The child process may exit without ever connecting, leaving `accept`
/// blocked; a probe connection and immediate close makes it return, after which
/// `serve` fails reading the closed connection and exits.
fn unblockAccept(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.server.socket.address.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

const RunParams = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    binary_path: []const u8,
    fixture_body: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const argv = try argsToSlice(arena, init.minimal.args);

    if (argv.len != 3) {
        std.log.err("Usage: {s} <puny-binary> <test-spec.json>", .{argv[0]});
        return 1;
    }

    const binary_path = argv[1];
    const spec_path = argv[2];

    const spec_text = try std.Io.Dir.cwd().readFileAlloc(init.io, spec_path, allocator, .limited(1024 * 1024));
    defer allocator.free(spec_text);

    const parsed = try std.json.parseFromSlice([]TestCase, allocator, spec_text, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const tests = parsed.value;

    const fixture_body = try std.Io.Dir.cwd().readFileAlloc(init.io, "tests/fixtures/prompt.md", arena, .limited(1024 * 1024));

    const params = RunParams{
        .allocator = allocator,
        .io = init.io,
        .binary_path = binary_path,
        .fixture_body = fixture_body,
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (tests) |test_case| {
        std.debug.print("  {s}... ", .{test_case.name});

        const result = runTest(params, test_case) catch |err| {
            std.debug.print("FAILED ({s})\n", .{@errorName(err)});
            failed += 1;
            continue;
        };

        if (result) {
            std.debug.print("PASSED\n", .{});
            passed += 1;
        } else {
            failed += 1;
        }
    }

    const total = passed + failed;
    std.debug.print("\n{d} passed, {d} failed (of {d})\n", .{
        passed,
        failed,
        total,
    });

    return if (failed == 0) 0 else 1;
}

fn removeEvidenceFiles(io: std.Io, test_case: TestCase) void {
    if (test_case.evidence) |evidence| {
        for (evidence.file_exists) |path| {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
        }
        if (evidence.file_contains) |fc| {
            std.Io.Dir.cwd().deleteFile(io, fc.path) catch {};
        }
    }
}

fn runTest(params: RunParams, test_case: TestCase) !bool {
    const allocator = params.allocator;
    const io = params.io;

    removeEvidenceFiles(io, test_case);

    // Optionally start an in-process HTTP server and substitute the port.
    var server_ctx: ?ServerCtx = null;
    var server_thread: ?std.Thread = null;
    var port_str: ?[]u8 = null;
    // Install teardown before any fallible setup below so a failed listen,
    // spawn, or port format can never bypass the thread join and socket
    // deinit.
    defer {
        if (server_ctx) |*ctx| {
            if (server_thread) |t| {
                unblockAccept(ctx, io);
                t.join();
            }
            ctx.server.deinit(io);
        }
        if (port_str) |p| allocator.free(p);
    }
    if (test_case.serve_fixture) {
        const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        var server = try std.Io.net.IpAddress.listen(&address, io, .{});
        const port = server.socket.address.getPort();
        server_ctx = .{ .io = io, .server = server, .body = params.fixture_body };
        server_thread = try std.Thread.spawn(.{}, ServerCtx.serve, .{&server_ctx.?});
        port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    }

    const child_argv = try allocator.alloc([]const u8, test_case.args.len + 1);
    defer allocator.free(child_argv);
    child_argv[0] = params.binary_path;
    for (test_case.args, 0..) |arg, i| {
        if (port_str) |p| {
            child_argv[i + 1] = try std.mem.replaceOwned(u8, allocator, arg, "{port}", p);
        } else {
            child_argv[i + 1] = arg;
        }
    }
    defer for (child_argv[1..]) |arg| {
        if (port_str != null) allocator.free(arg);
    };

    const result = try std.process.run(allocator, io, .{
        .argv = child_argv,
        // Generous capture limits. Crossing the limit triggers the
        // StreamTooLong error path in std.process.run, which deadlocks on
        // Windows (the child blocks writing to a full pipe), so the limits
        // must stay far above any realistic output.
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const expected_exit: u8 = test_case.exit_code orelse 0;
    switch (result.term) {
        .exited => |code| {
            if (code != expected_exit) {
                std.debug.print("FAILED (exit {d}, expected {d})\n", .{ code, expected_exit });
                return false;
            }
        },
        .signal => |sig| {
            std.debug.print("FAILED (signal {s})\n", .{@tagName(sig)});
            return false;
        },
        .stopped => |sig| {
            std.debug.print("FAILED (stopped {s})\n", .{@tagName(sig)});
            return false;
        },
        .unknown => |code| {
            std.debug.print("FAILED (unknown {d})\n", .{code});
            return false;
        },
    }

    for (test_case.expect) |expected| {
        if (std.mem.indexOf(u8, result.stdout, expected) == null) {
            std.debug.print("FAILED\n    missing: '{s}'\n", .{expected});
            return false;
        }
    }

    for (test_case.not_expect) |not_expected| {
        if (std.mem.indexOf(u8, result.stdout, not_expected) != null) {
            std.debug.print("FAILED\n    unexpected: '{s}'\n", .{not_expected});
            return false;
        }
    }

    for (test_case.expect_stderr) |expected| {
        if (std.mem.indexOf(u8, result.stderr, expected) == null) {
            std.debug.print("FAILED\n    missing in stderr: '{s}'\n", .{expected});
            return false;
        }
    }

    if (test_case.evidence) |evidence| {
        for (evidence.file_exists) |path| {
            const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
                std.debug.print("FAILED\n    evidence file not found: '{s}'\n", .{path});
                return false;
            };
            file.close(io);
        }
        if (evidence.file_contains) |fc| {
            const content = std.Io.Dir.cwd().readFileAlloc(io, fc.path, allocator, .limited(1024 * 1024)) catch {
                std.debug.print("FAILED\n    could not read evidence file: '{s}'\n", .{fc.path});
                return false;
            };
            defer allocator.free(content);
            for (fc.patterns) |pattern| {
                if (std.mem.indexOf(u8, content, pattern) == null) {
                    std.debug.print("FAILED\n    missing pattern in '{s}': '{s}'\n", .{ fc.path, pattern });
                    return false;
                }
            }
        }
    }

    return true;
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const slice = try args.toSlice(arena);
    return slice;
}
