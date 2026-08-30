const std = @import("std");
const builtin = @import("builtin");

const FileContains = struct {
    path: []const u8,
    patterns: []const []const u8,
};

const SkillFixture = struct {
    name: []const u8,
    body: []const u8,
};

const Evidence = struct {
    file_exists: []const []const u8 = &.{},
    file_not_exists: []const []const u8 = &.{},
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
    /// Skills to materialize under `<cwd>/.agents/skills/<name>/SKILL.md`
    /// before the test runs, so the binary under test discovers them as
    /// repository skills. Removed after the test.
    skills: []const SkillFixture = &.{},
    /// Optional isolated Git repository shape used by review-mode cases.
    git_fixture: ?GitFixtureKind = null,
};

// Names of skill fixtures materialized by the harness, tracked so stale
// scaffolding from a failed or final test can be removed. Slices are
// borrowed from the parsed test spec, which outlives the whole run.
var created_skill_names: std.ArrayList([]const u8) = .empty;

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
    environ_map: *const std.process.Environ.Map,
};

/// Resolves the parent directory for temporary files, mirroring the fallback
/// chain in `src/upgrade.zig`.
fn tempParentDir(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("TMPDIR")) |t| return try allocator.dupe(u8, t);
    if (environ_map.get("TEMP")) |t| return try allocator.dupe(u8, t);
    if (environ_map.get("TMP")) |t| return try allocator.dupe(u8, t);
    if (comptime builtin.os.tag == .windows) return try allocator.dupe(u8, "C:\\Windows\\Temp");
    return try allocator.dupe(u8, "/tmp");
}

/// Ensures `dir` exists, creating it and any missing ancestors.
fn ensureDirExists(io: std.Io, dir: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, dir, @enumFromInt(0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            if (std.fs.path.dirname(dir)) |parent| {
                try ensureDirExists(io, parent);
                std.Io.Dir.createDirAbsolute(io, dir, @enumFromInt(0o755)) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            } else return err;
        },
        else => return err,
    };
}

/// Creates a unique throwaway directory under the OS temp dir and returns its
/// absolute path, owned by `allocator`. Used to isolate child-process config
/// and session storage from the real one.
fn makeTempDir(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const parent = try tempParentDir(allocator, environ_map);
    defer allocator.free(parent);

    try ensureDirExists(io, parent);

    var random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    while (true) {
        const unique = random.int(u64);
        const name = try std.fmt.allocPrint(allocator, "puny-regression-{x}", .{unique});
        defer allocator.free(name);

        const path = try std.fs.path.join(allocator, &.{ parent, name });
        std.Io.Dir.createDirAbsolute(io, path, @enumFromInt(0o755)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                return err;
            },
        };
        return path;
    }
}

/// A child environment whose config-dir variable is redirected to a unique
/// temp dir, so mock regression runs never touch the real session history.
const IsolatedEnv = struct {
    allocator: std.mem.Allocator,
    environ_map: std.process.Environ.Map,
    temp_dir_path: []const u8,

    fn init(allocator: std.mem.Allocator, io: std.Io, parent_env: *const std.process.Environ.Map) !IsolatedEnv {
        var child_env = try parent_env.clone(allocator);
        errdefer child_env.deinit();

        const temp_dir_path = try makeTempDir(allocator, io, parent_env);
        errdefer allocator.free(temp_dir_path);

        // Matches the config-dir resolution in `src/core/session.zig`:
        // Windows reads APPDATA, POSIX reads XDG_CONFIG_HOME.
        if (comptime builtin.os.tag == .windows) {
            try child_env.put("APPDATA", temp_dir_path);
        } else {
            try child_env.put("XDG_CONFIG_HOME", temp_dir_path);
        }

        return .{
            .allocator = allocator,
            .environ_map = child_env,
            .temp_dir_path = temp_dir_path,
        };
    }

    fn deinit(self: *IsolatedEnv, io: std.Io) void {
        self.environ_map.deinit();
        std.Io.Dir.cwd().deleteTree(io, self.temp_dir_path) catch |err| {
            std.log.warn("failed to remove regression temp dir {s}: {s}", .{ self.temp_dir_path, @errorName(err) });
        };
        self.allocator.free(self.temp_dir_path);
        self.* = undefined;
    }
};

const GitFixtureKind = enum {
    feature,
    empty,
    main,
    missing_origin,
};

const GitFixture = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    remote: []const u8,
    worktree: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        kind: GitFixtureKind,
    ) !GitFixture {
        const root = try makeTempDir(allocator, io, environ_map);
        errdefer {
            std.Io.Dir.cwd().deleteTree(io, root) catch {};
            allocator.free(root);
        }
        const remote = try std.fs.path.join(allocator, &.{ root, "remote.git" });
        errdefer allocator.free(remote);
        const worktree = try std.fs.path.join(allocator, &.{ root, "worktree" });
        errdefer allocator.free(worktree);

        try runGitOk(allocator, io, null, &.{ "init", "--bare", remote });
        try runGitOk(allocator, io, null, &.{ "init", "-b", "main", worktree });
        try runGitOk(allocator, io, worktree, &.{ "config", "user.email", "puny@example.test" });
        try runGitOk(allocator, io, worktree, &.{ "config", "user.name", "Puny Test" });
        const initial_path = try std.fs.path.join(allocator, &.{ worktree, "initial.txt" });
        defer allocator.free(initial_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = initial_path, .data = "initial\n" });
        try runGitOk(allocator, io, worktree, &.{ "add", "initial.txt" });
        try runGitOk(allocator, io, worktree, &.{ "commit", "-m", "initial" });
        try runGitOk(allocator, io, worktree, &.{ "remote", "add", "origin", remote });
        try runGitOk(allocator, io, worktree, &.{ "push", "-u", "origin", "main" });

        switch (kind) {
            .main => {},
            .empty => try runGitOk(allocator, io, worktree, &.{ "checkout", "-b", "feature/empty" }),
            .feature, .missing_origin => {
                try runGitOk(allocator, io, worktree, &.{ "checkout", "-b", "feature/review" });
                const feature_path = try std.fs.path.join(allocator, &.{ worktree, "feature.txt" });
                defer allocator.free(feature_path);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = feature_path, .data = "feature\n" });
                try runGitOk(allocator, io, worktree, &.{ "add", "feature.txt" });
                try runGitOk(allocator, io, worktree, &.{ "commit", "-m", "feature" });
                if (kind == .missing_origin) {
                    try runGitOk(allocator, io, worktree, &.{ "remote", "remove", "origin" });
                }
            },
        }

        return .{
            .allocator = allocator,
            .root = root,
            .remote = remote,
            .worktree = worktree,
        };
    }

    fn deinit(self: *GitFixture, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
        self.allocator.free(self.worktree);
        self.allocator.free(self.remote);
        self.allocator.free(self.root);
        self.* = undefined;
    }
};

fn runGitOk(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: ?[]const u8,
    args: []const []const u8,
) !void {
    const output = try gitOutput(allocator, io, cwd, args);
    allocator.free(output);
}

fn gitOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: ?[]const u8,
    args: []const []const u8,
) ![]const u8 {
    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "git";
    @memcpy(argv[1..], args);
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        std.debug.print("git fixture command failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.GitFixtureFailed;
    }
    return result.stdout;
}

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

    // Redirect each mock run's config dir to a throwaway temp dir so the
    // regression tests never pollute the real session history.
    var isolated_env = try IsolatedEnv.init(allocator, init.io, init.environ_map);
    defer isolated_env.deinit(init.io);

    const params = RunParams{
        .allocator = allocator,
        .io = init.io,
        .binary_path = binary_path,
        .fixture_body = fixture_body,
        .environ_map = &isolated_env.environ_map,
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

    // Remove any skill fixtures left behind by the last test.
    cleanupSkillFixtures(std.Io.Dir.cwd(), allocator, init.io);
    created_skill_names.deinit(allocator);

    const total = passed + failed;
    std.debug.print("\n{d} passed, {d} failed (of {d})\n", .{
        passed,
        failed,
        total,
    });

    return if (failed == 0) 0 else 1;
}

fn removeEvidenceFiles(dir: std.Io.Dir, allocator: std.mem.Allocator, io: std.Io, test_case: TestCase) void {
    if (test_case.evidence) |evidence| {
        for (evidence.file_exists) |path| {
            dir.deleteFile(io, path) catch {};
        }
        for (evidence.file_not_exists) |path| {
            dir.deleteFile(io, path) catch {};
        }
        if (evidence.file_contains) |fc| {
            dir.deleteFile(io, fc.path) catch {};
        }
    }
    cleanupSkillFixtures(dir, allocator, io);
}

fn skillDirPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ ".agents", "skills", name });
}

fn setupSkillFixtures(dir: std.Io.Dir, allocator: std.mem.Allocator, io: std.Io, test_case: TestCase) !void {
    for (test_case.skills) |skill| {
        const dir_path = try skillDirPath(allocator, skill.name);
        defer allocator.free(dir_path);
        // Refuse to overwrite a skill directory that already exists: it may
        // hold a developer's real skill, and cleanup would later delete it.
        if (dir.openDir(io, dir_path, .{})) |existing| {
            existing.close(io);
            return error.SkillFixtureCollision;
        } else |_| {}
        try dir.createDirPath(io, dir_path);
        const skill_path = try std.fs.path.join(allocator, &.{ dir_path, "SKILL.md" });
        defer allocator.free(skill_path);
        try dir.writeFile(io, .{ .sub_path = skill_path, .data = skill.body });
        try created_skill_names.append(allocator, skill.name);
    }
}

fn cleanupSkillFixtures(dir: std.Io.Dir, allocator: std.mem.Allocator, io: std.Io) void {
    for (created_skill_names.items) |name| {
        const dir_path = skillDirPath(allocator, name) catch continue;
        dir.deleteTree(io, dir_path) catch {};
        allocator.free(dir_path);
    }
    created_skill_names.clearRetainingCapacity();
    // Remove the scaffolding directories only if they are now empty, so a
    // developer's real `.agents/skills` directory is never touched.
    dir.deleteDir(io, ".agents/skills") catch {};
    dir.deleteDir(io, ".agents") catch {};
}

fn runTest(params: RunParams, test_case: TestCase) !bool {
    const allocator = params.allocator;
    const io = params.io;

    var git_fixture: ?GitFixture = if (test_case.git_fixture) |kind|
        try GitFixture.init(allocator, io, params.environ_map, kind)
    else
        null;
    defer if (git_fixture) |*fixture| fixture.deinit(io);

    var target_dir = if (git_fixture) |fixture|
        try std.Io.Dir.cwd().openDir(io, fixture.worktree, .{})
    else
        std.Io.Dir.cwd();
    defer if (git_fixture != null) target_dir.close(io);

    removeEvidenceFiles(target_dir, allocator, io, test_case);
    defer removeEvidenceFiles(target_dir, allocator, io, test_case);
    try setupSkillFixtures(target_dir, allocator, io, test_case);

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

    const binary_path = if (std.fs.path.isAbsolute(params.binary_path))
        params.binary_path
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, params.binary_path });
    };
    defer if (!std.fs.path.isAbsolute(params.binary_path)) allocator.free(binary_path);

    const child_argv = try allocator.alloc([]const u8, test_case.args.len + 1);
    defer allocator.free(child_argv);
    child_argv[0] = binary_path;
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
        .environ_map = params.environ_map,
        .cwd = if (git_fixture) |fixture| .{ .path = fixture.worktree } else .inherit,
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
            const file = target_dir.openFile(io, path, .{}) catch {
                std.debug.print("FAILED\n    evidence file not found: '{s}'\n", .{path});
                return false;
            };
            file.close(io);
        }
        for (evidence.file_not_exists) |path| {
            if (target_dir.openFile(io, path, .{})) |file| {
                file.close(io);
                std.debug.print("FAILED\n    unexpected evidence file found: '{s}'\n", .{path});
                return false;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    std.debug.print("FAILED\n    could not inspect absent evidence file: '{s}'\n", .{path});
                    return false;
                },
            }
        }
        if (evidence.file_contains) |fc| {
            const content = target_dir.readFileAlloc(io, fc.path, allocator, .limited(1024 * 1024)) catch {
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

test "skill fixtures materialize in the target directory and clean up" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer created_skill_names.clearAndFree(std.testing.allocator);

    const test_case = TestCase{
        .name = "fixture-lifecycle",
        .args = &.{},
        .expect = &.{},
        .not_expect = &.{},
        .skills = &.{.{ .name = "mock-skill", .body = "mock-skill-body" }},
    };

    try setupSkillFixtures(tmp.dir, std.testing.allocator, std.testing.io, test_case);

    const content = try tmp.dir.readFileAlloc(std.testing.io, ".agents/skills/mock-skill/SKILL.md", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("mock-skill-body", content);

    cleanupSkillFixtures(tmp.dir, std.testing.allocator, std.testing.io);

    // The fixture and the scaffolding parents are gone.
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(std.testing.io, ".agents", .{}));
}

test "skill fixtures refuse to overwrite an existing skill directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer created_skill_names.clearAndFree(std.testing.allocator);

    // A developer's real skill living in the scanned repository path.
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/mock-skill");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/mock-skill/SKILL.md", .data = "real skill content" });

    const test_case = TestCase{
        .name = "fixture-collision",
        .args = &.{},
        .expect = &.{},
        .not_expect = &.{},
        .skills = &.{.{ .name = "mock-skill", .body = "mock-skill-body" }},
    };

    try std.testing.expectError(error.SkillFixtureCollision, setupSkillFixtures(tmp.dir, std.testing.allocator, std.testing.io, test_case));

    // The real skill is untouched.
    const content = try tmp.dir.readFileAlloc(std.testing.io, ".agents/skills/mock-skill/SKILL.md", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("real skill content", content);
}

fn testTempParentDirPath() ![]const u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const parent = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", "regression-checker-isolation" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
    return parent;
}

test "temp parent dir honors TMPDIR and falls back to the platform default" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    // No temp vars set: falls back to the platform default.
    const fallback = try tempParentDir(std.testing.allocator, &env);
    defer std.testing.allocator.free(fallback);
    if (comptime builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\Windows\\Temp", fallback);
    } else {
        try std.testing.expectEqualStrings("/tmp", fallback);
    }

    const parent = try testTempParentDirPath();
    defer std.testing.allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, parent) catch {};
    try env.put("TMPDIR", parent);
    const resolved = try tempParentDir(std.testing.allocator, &env);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(parent, resolved);
}

test "make temp dir creates a unique directory under the temp parent" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const parent = try testTempParentDirPath();
    defer std.testing.allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, parent) catch {};
    try env.put("TMPDIR", parent);

    const path = try makeTempDir(std.testing.allocator, std.testing.io, &env);
    defer std.testing.allocator.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};

    // The directory exists and lives under the configured temp parent.
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
    defer dir.close(std.testing.io);
    try std.testing.expect(std.mem.startsWith(u8, path, parent));
}

test "make temp dir creates missing parent directories" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var random_source: std.Random.IoSource = .{ .io = std.testing.io };
    const random = random_source.interface();
    const unique = random.int(u64);
    const missing_leaf = try std.fmt.allocPrint(std.testing.allocator, "regression-checker-missing-parent-{x}", .{unique});
    defer std.testing.allocator.free(missing_leaf);
    const parent = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", missing_leaf });
    defer std.testing.allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, parent) catch {};

    // Ensure the path is not present at the start.
    std.Io.Dir.cwd().deleteTree(std.testing.io, parent) catch {};

    try env.put("TMPDIR", parent);

    const path = try makeTempDir(std.testing.allocator, std.testing.io, &env);
    defer std.testing.allocator.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};

    // The directory exists and lives under the configured temp parent.
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
    defer dir.close(std.testing.io);
    try std.testing.expect(std.mem.startsWith(u8, path, parent));
}

test "isolated env redirects the config dir to a temp dir and cleans up" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const parent = try testTempParentDirPath();
    defer std.testing.allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, parent) catch {};
    try env.put("TMPDIR", parent);

    var isolated = try IsolatedEnv.init(std.testing.allocator, std.testing.io, &env);
    errdefer isolated.deinit(std.testing.io);

    const config_var = if (comptime builtin.os.tag == .windows) "APPDATA" else "XDG_CONFIG_HOME";
    const redirected = isolated.environ_map.get(config_var) orelse return error.MissingConfigVar;
    try std.testing.expectEqualStrings(isolated.temp_dir_path, redirected);

    // The redirected config dir exists while the env is alive.
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, isolated.temp_dir_path, .{});
    dir.close(std.testing.io);

    // Deinit removes the temp dir again.
    const temp_dir_path = try std.testing.allocator.dupe(u8, isolated.temp_dir_path);
    defer std.testing.allocator.free(temp_dir_path);
    isolated.deinit(std.testing.io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, temp_dir_path, .{}));
}

test "review git fixture creates an isolated committed feature branch" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const parent = try testTempParentDirPath();
    defer std.testing.allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, parent) catch {};
    try env.put("TMPDIR", parent);

    var fixture = try GitFixture.init(std.testing.allocator, std.testing.io, &env, .feature);
    defer fixture.deinit(std.testing.io);
    const branch = try gitOutput(std.testing.allocator, std.testing.io, fixture.worktree, &.{ "branch", "--show-current" });
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings("feature/review", std.mem.trim(u8, branch, &std.ascii.whitespace));
}
