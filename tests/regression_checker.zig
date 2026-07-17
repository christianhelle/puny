const std = @import("std");

const TestCase = struct {
    name: []const u8,
    args: []const []const u8,
    expect: []const []const u8,
    not_expect: []const []const u8,
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

    var passed: usize = 0;
    var failed: usize = 0;

    for (tests) |test_case| {
        std.debug.print("  {s}... ", .{test_case.name});

        const result = runTest(allocator, init.io, binary_path, test_case) catch |err| {
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

fn runTest(allocator: std.mem.Allocator, io: std.Io, binary_path: []const u8, test_case: TestCase) !bool {
    const child_argv = try allocator.alloc([]const u8, test_case.args.len + 1);
    defer allocator.free(child_argv);
    child_argv[0] = binary_path;
    @memcpy(child_argv[1..], test_case.args);

    const result = try std.process.run(allocator, io, .{
        .argv = child_argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("FAILED (exit {d})\n", .{code});
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

    return true;
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const slice = try args.toSlice(arena);
    return slice;
}
