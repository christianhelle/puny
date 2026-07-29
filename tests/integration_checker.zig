const std = @import("std");

const Spec = struct {
    default_args: []const []const u8 = &.{},
    tests: []const TestCase,
};

const FileContainsEvidence = struct {
    path: []const u8,
    patterns: []const []const u8,
};

const Evidence = struct {
    file_exists: []const []const u8 = &.{},
    file_contains: ?FileContainsEvidence = null,
    extract_paths_from_output: bool = false,
};

const TestCase = struct {
    name: []const u8,
    args: []const []const u8,
    min_output_length: usize = 0,
    expect: []const []const u8 = &.{},
    not_expect: []const []const u8 = &.{},
    evidence: ?Evidence = null,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const argv = try argsToSlice(arena, init.minimal.args);

    if (argv.len != 3) {
        std.log.err("Usage: {s} <puny-binary> <test-spec.json>", .{argv[0]});
        return 1;
    }

    const binary_path = argv[1];
    const spec_path = argv[2];

    const spec_text = try std.Io.Dir.cwd().readFileAlloc(io, spec_path, allocator, .limited(1024 * 1024));
    defer allocator.free(spec_text);

    const parsed = try std.json.parseFromSlice(Spec, allocator, spec_text, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const spec = parsed.value;

    var passed: usize = 0;
    var failed: usize = 0;

    for (spec.tests) |test_case| {
        std.debug.print("  {s}... ", .{test_case.name});

        const result = runTest(allocator, io, binary_path, spec.default_args, test_case) catch |err| {
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

fn runTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    binary_path: []const u8,
    default_args: []const []const u8,
    test_case: TestCase,
) !bool {
    removeEvidenceFiles(io, test_case);
    const child_argv = try buildArgv(allocator, binary_path, default_args, test_case.args);
    defer allocator.free(child_argv);

    const result = std.process.run(allocator, io, .{
        .argv = child_argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(120),
            .clock = .real,
        }},
    }) catch |err| {
        std.debug.print("FAILED (error: {s})\n", .{@errorName(err)});
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("FAILED (exit {d})\n", .{code});
                printStderr(result.stderr);
                return false;
            }
        },
        .signal => |sig| {
            std.debug.print("FAILED (signal {s})\n", .{@tagName(sig)});
            printStderr(result.stderr);
            return false;
        },
        .stopped => |sig| {
            std.debug.print("FAILED (stopped {s})\n", .{@tagName(sig)});
            printStderr(result.stderr);
            return false;
        },
        .unknown => |code| {
            std.debug.print("FAILED (unknown {d})\n", .{code});
            printStderr(result.stderr);
            return false;
        },
    }

    if (test_case.min_output_length > 0 and result.stdout.len < test_case.min_output_length) {
        std.debug.print("FAILED\n    stdout too short: {d} bytes (min {d})\n", .{
            result.stdout.len,
            test_case.min_output_length,
        });
        printStderr(result.stderr);
        return false;
    }

    for (test_case.expect) |expected| {
        if (std.mem.indexOf(u8, result.stdout, expected) == null) {
            std.debug.print("FAILED\n    missing: '{s}'\n", .{expected});
            printStderr(result.stderr);
            return false;
        }
    }

    for (test_case.not_expect) |not_expected| {
        if (std.mem.indexOf(u8, result.stdout, not_expected) != null) {
            std.debug.print("FAILED\n    unexpected: '{s}'\n", .{not_expected});
            printStderr(result.stderr);
            return false;
        }
    }

    if (test_case.evidence) |evidence| {
        for (evidence.file_exists) |path| {
            if (!fileExists(io, path)) {
                std.debug.print("FAILED\n    evidence file not found: '{s}'\n", .{path});
                printStderr(result.stderr);
                return false;
            }
        }
        if (evidence.file_contains) |fc| {
            const content = std.Io.Dir.cwd().readFileAlloc(io, fc.path, allocator, .limited(1024 * 1024)) catch {
                std.debug.print("FAILED\n    could not read evidence file: '{s}'\n", .{fc.path});
                printStderr(result.stderr);
                return false;
            };
            defer allocator.free(content);
            for (fc.patterns) |pattern| {
                if (std.mem.indexOf(u8, content, pattern) == null) {
                    std.debug.print("FAILED\n    missing pattern in '{s}': '{s}'\n", .{ fc.path, pattern });
                    printStderr(result.stderr);
                    return false;
                }
            }
        }
        if (evidence.extract_paths_from_output) {
            const clean_stdout = try stripAnsi(allocator, result.stdout);
            defer allocator.free(clean_stdout);
            var lines_iter = std.mem.splitScalar(u8, clean_stdout, '\n');
            while (lines_iter.next()) |line| {
                if (std.mem.indexOf(u8, line, " - ")) |idx| {
                    const path = std.mem.trim(u8, line[idx + 3 ..], " \t\r");
                    if (path.len > 0 and looksLikeAbsolutePath(path) and !fileExists(io, path)) {
                        std.debug.print("FAILED\n    evidence file not found: '{s}'\n", .{path});
                        printStderr(result.stderr);
                        return false;
                    }
                }
            }
        }
    }

    return true;
}

fn printStderr(stderr: []const u8) void {
    if (stderr.len > 0) {
        std.debug.print("  stderr: {s}\n", .{stderr});
    }
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Strip ANSI escape sequences from a string.
fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len) {
                const c = input[i];
                i += 1;
                if ((c >= 0x40 and c <= 0x5a) or (c >= 0x61 and c <= 0x7a)) break;
            }
        } else {
            out_len += 1;
            i += 1;
        }
    }
    var result = try allocator.alloc(u8, out_len);
    out_len = 0;
    i = 0;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len) {
                const c = input[i];
                i += 1;
                if ((c >= 0x40 and c <= 0x5a) or (c >= 0x61 and c <= 0x7a)) break;
            }
        } else {
            result[out_len] = input[i];
            out_len += 1;
            i += 1;
        }
    }
    return result;
}
fn looksLikeAbsolutePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    if (path.len >= 3) {
        const c = path[0];
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
            if (path[1] == ':') return true;
        }
    }
    return false;
}

fn buildArgv(
    allocator: std.mem.Allocator,
    binary_path: []const u8,
    default_args: []const []const u8,
    test_args: []const []const u8,
) ![]const []const u8 {
    const total_len = 1 + default_args.len + test_args.len;
    const argv = try allocator.alloc([]const u8, total_len);
    argv[0] = binary_path;
    @memcpy(argv[1..][0..default_args.len], default_args);
    @memcpy(argv[1..][default_args.len..], test_args);
    return argv;
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const slice = try args.toSlice(arena);
    return slice;
}