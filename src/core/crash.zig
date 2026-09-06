//! Crash report capture and submission.
//!
//! A run that fails writes a markdown report into the puny config directory.
//! The next interactive startup finds it and offers to file it as a GitHub
//! issue.

const std = @import("std");
const builtin = @import("builtin");
const core_session = @import("session.zig");
const version = @import("../version.zig");
const run_command = @import("../tools/run_command.zig");

/// Directory holding pending crash reports, inside the puny config directory.
/// The returned slice is owned by `allocator`.
pub fn crashDir(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = try core_session.configPunyDir(allocator, environ_map);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "crashes" });
}

test "crashDir places reports under the puny config dir" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    if (comptime builtin.os.tag == .windows) {
        try env.put("APPDATA", "C:\\Users\\test\\AppData\\Roaming");
        const dir = try crashDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("C:\\Users\\test\\AppData\\Roaming\\puny\\crashes", dir);
    } else {
        try env.put("XDG_CONFIG_HOME", "/tmp/test-xdg");
        const dir = try crashDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("/tmp/test-xdg/puny/crashes", dir);
    }
}

/// File name prefix shared by every crash report.
pub const file_prefix = "puny_crash_";

/// Absolute path of the crash report for `session_id`. The returned slice is
/// owned by `allocator`.
pub fn reportPath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    session_id: []const u8,
) ![]const u8 {
    const dir = try crashDir(allocator, environ_map);
    defer allocator.free(dir);
    const name = try std.fmt.allocPrint(allocator, file_prefix ++ "{s}.md", .{session_id});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ dir, name });
}

test "reportPath names the file after the session id inside the crash dir" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    if (comptime builtin.os.tag == .windows) {
        try env.put("APPDATA", "C:/Users/test");
    } else {
        try env.put("XDG_CONFIG_HOME", "/tmp/test-xdg");
    }

    const dir = try crashDir(allocator, &env);
    defer allocator.free(dir);

    const path = try reportPath(allocator, &env, "8f14e45f-ceea-467a-9dc3-0f0e0b1e1e1e");
    defer allocator.free(path);

    try std.testing.expectEqualStrings(dir, std.fs.path.dirname(path).?);
    try std.testing.expectEqualStrings(
        "puny_crash_8f14e45f-ceea-467a-9dc3-0f0e0b1e1e1e.md",
        std.fs.path.basename(path),
    );
}

/// What the run knows about itself, recorded as it starts up so the failure
/// path can describe the crash without threading state through every call.
/// The slices live in the process arena, which outlives any failure.
const Context = struct {
    session_id: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Static string naming what puny is doing, e.g. "startup".
    phase: []const u8 = "startup",
};

var context: Context = .{};

/// Records the session the run belongs to and the model it talks to.
pub fn setContext(ctx: struct {
    session_id: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
}) void {
    context.session_id = ctx.session_id;
    context.provider = ctx.provider;
    context.model = ctx.model;
}

/// Records what puny is doing now. Pass a static string.
pub fn setPhase(phase: []const u8) void {
    context.phase = phase;
}

/// Clears the recorded context. Only tests need this.
pub fn resetContext() void {
    context = .{};
}

/// Describes a failure with `error_name` using the recorded context.
pub fn detailsFor(error_name: []const u8) Details {
    return .{
        .session_id = context.session_id orelse "unknown",
        .error_name = error_name,
        .phase = context.phase,
        .provider = context.provider,
        .model = context.model,
    };
}

/// What a crash report says about the failed run. Deliberately narrow: no
/// prompts, conversation content, file paths, argv values or credentials, so a
/// report can be pasted into a public issue as-is.
pub const Details = struct {
    session_id: []const u8,
    /// Error name without the `error.` prefix, as `@errorName` returns it.
    error_name: []const u8,
    /// What puny was doing when it failed, e.g. "startup" or "chat turn".
    phase: []const u8,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

/// Renders `details` as the markdown body of a crash report. The returned
/// slice is owned by `allocator`.
pub fn formatReport(allocator: std.mem.Allocator, details: Details) ![]const u8 {
    var body = std.Io.Writer.Allocating.init(allocator);
    errdefer body.deinit();
    const w = &body.writer;

    try w.print("# puny crash report\n\n", .{});
    try w.print("- **Error**: error.{s}\n", .{details.error_name});
    try w.print("- **Phase**: {s}\n", .{details.phase});
    try w.print("- **Version**: {s}\n", .{version.version});
    try w.print("- **Commit**: {s}\n", .{version.git_commit});
    try w.print("- **Platform**: {s}-{s}\n", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
    });
    try w.print("- **Build**: {s}\n", .{@tagName(builtin.mode)});
    try w.print("- **Session**: {s}\n", .{details.session_id});
    if (details.provider) |p| try w.print("- **Provider**: {s}\n", .{p});
    if (details.model) |m| try w.print("- **Model**: {s}\n", .{m});
    try w.print(
        "\nThis report was generated by puny. It contains no prompts, conversation\n" ++
            "content, file paths or credentials.\n",
        .{},
    );

    return body.toOwnedSlice();
}

test "formatReport records the failure and the session it came from" {
    const allocator = std.testing.allocator;
    const report = try formatReport(allocator, .{
        .session_id = "abc-123",
        .error_name = "OutOfMemory",
        .phase = "chat turn",
        .provider = "GitHub Copilot",
        .model = "gpt-5",
    });
    defer allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "error.OutOfMemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "abc-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "chat turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "GitHub Copilot") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "gpt-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, version.version) != null);
}

test "formatReport omits provider and model when they are unknown" {
    const allocator = std.testing.allocator;
    const report = try formatReport(allocator, .{
        .session_id = "abc-123",
        .error_name = "AccessDenied",
        .phase = "startup",
    });
    defer allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "Provider") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Model") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "error.AccessDenied") != null);
}

/// Writes a crash report for `details` into the crash directory, creating it
/// when missing. Callers on the failure path should ignore errors: a crash
/// report that cannot be written must not replace the original failure.
pub fn write(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    details: Details,
) !void {
    const path = try reportPath(allocator, environ_map, details.session_id);
    defer allocator.free(path);
    const body = try formatReport(allocator, details);
    defer allocator.free(body);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

/// A crash report waiting to be submitted or discarded.
pub const Report = struct {
    /// Absolute path of the report file.
    path: []const u8,
    /// Session the crashed run belonged to, taken from the file name.
    session_id: []const u8,
    modified_ns: i96,
};

/// Frees a slice returned by `list`.
pub fn freeReports(allocator: std.mem.Allocator, reports: []const Report) void {
    for (reports) |r| {
        allocator.free(r.path);
        allocator.free(r.session_id);
    }
    allocator.free(reports);
}

fn newerFirst(_: void, a: Report, b: Report) bool {
    return a.modified_ns > b.modified_ns;
}

/// Lists the pending crash reports, most recent first. A missing crash
/// directory yields an empty slice. The result is owned by `allocator`; free it
/// with `freeReports`.
pub fn list(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const Report {
    const dir_path = try crashDir(allocator, environ_map);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &[_]Report{},
        else => |e| return e,
    };
    defer dir.close(io);

    var reports: std.ArrayList(Report) = .empty;
    errdefer {
        for (reports.items) |r| {
            allocator.free(r.path);
            allocator.free(r.session_id);
        }
        reports.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = sessionIdFromFileName(entry.name) orelse continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        const session_id = try allocator.dupe(u8, id);
        errdefer allocator.free(session_id);

        try reports.append(allocator, .{
            .path = path,
            .session_id = session_id,
            .modified_ns = stat.mtime.nanoseconds,
        });
    }

    const owned = try reports.toOwnedSlice(allocator);
    std.mem.sort(Report, owned, {}, newerFirst);
    return owned;
}

/// How a submission actually runs the command. Injected so the submission
/// flow can be tested without spawning `gh`.
pub const Runner = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) anyerror![]const u8,
};

/// What came of handing a report to `gh`.
pub const SubmitOutcome = union(enum) {
    /// The issue was created; holds its URL.
    submitted: []const u8,
    /// Submission failed; holds what gh said, or a short explanation.
    failed: []const u8,
};

/// Interprets `runCommand` output from `gh issue create`. Slices in the result
/// borrow from `output`.
pub fn parseSubmitOutput(output: []const u8) SubmitOutcome {
    const succeeded = std.mem.startsWith(u8, output, "Exit code: 0");
    if (succeeded) {
        if (std.mem.indexOf(u8, output, "https://")) |start| {
            const rest = output[start..];
            const end = std.mem.indexOfAny(u8, rest, " \n\r") orelse rest.len;
            return .{ .submitted = rest[0..end] };
        }
        return .{ .failed = "gh reported success but printed no issue URL" };
    }

    if (std.mem.indexOf(u8, output, "STDERR:\n")) |start| {
        const rest = std.mem.trim(u8, output[start + "STDERR:\n".len ..], " \n\r");
        if (rest.len > 0) return .{ .failed = rest };
    }
    return .{ .failed = "gh could not create the issue" };
}

/// Largest report body read back for submission. Reports are a few hundred
/// bytes; anything beyond this is not one puny wrote.
const max_report_bytes = 64 * 1024;

const ProcessRunner = struct {
    io: std.Io,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) anyerror![]const u8 {
        const self: *ProcessRunner = @ptrCast(@alignCast(ctx));
        return run_command.runCommand(allocator, self.io, argv, null);
    }
};

/// Files the report at `path` as a GitHub issue using the `gh` CLI. Slices in
/// the outcome are owned by `allocator`.
pub fn submit(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !SubmitOutcome {
    const body = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(max_report_bytes),
    );
    defer allocator.free(body);

    var process_runner = ProcessRunner{ .io = io };
    return submitWithRunner(allocator, path, body, .{
        .ctx = &process_runner,
        .run = ProcessRunner.run,
    });
}

/// Frees the strings in an outcome returned by `submitWithRunner`.
pub fn freeOutcome(allocator: std.mem.Allocator, outcome: SubmitOutcome) void {
    switch (outcome) {
        .submitted => |url| allocator.free(url),
        .failed => |msg| allocator.free(msg),
    }
}

/// Files `path` as a GitHub issue through `runner`, titling it from `body`.
/// Slices in the outcome are owned by `allocator`.
pub fn submitWithRunner(
    allocator: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
    runner: Runner,
) !SubmitOutcome {
    const title = try titleFromReport(allocator, body);
    defer allocator.free(title);

    const argv = try submitArgv(allocator, path, title);
    defer allocator.free(argv);

    const output = runner.run(runner.ctx, allocator, argv) catch |err| switch (err) {
        error.FileNotFound => return .{
            .failed = try allocator.dupe(u8, "the GitHub CLI (gh) is not installed or not on PATH"),
        },
        else => return .{
            .failed = try std.fmt.allocPrint(allocator, "could not run gh: {s}", .{@errorName(err)}),
        },
    };
    defer allocator.free(output);

    return switch (parseSubmitOutput(output)) {
        .submitted => |url| .{ .submitted = try allocator.dupe(u8, url) },
        .failed => |msg| .{ .failed = try allocator.dupe(u8, msg) },
    };
}

/// Repository crash reports are filed against.
pub const repo = "christianhelle/puny";

/// Command that files `path` as an issue. Submission goes through the `gh`
/// CLI so it uses the user's own GitHub credentials; puny never ships or asks
/// for a token. The returned slice is owned by `allocator`; the strings inside
/// borrow from `title` and `path`.
pub fn submitArgv(
    allocator: std.mem.Allocator,
    path: []const u8,
    title: []const u8,
) ![]const []const u8 {
    return allocator.dupe([]const u8, &[_][]const u8{
        "gh",     "issue",       "create",
        "--repo", repo,          "--title",
        title,    "--body-file", path,
    });
}

/// Reads the value of a `- **Field**: value` line out of a report body.
fn reportField(body: []const u8, field: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "- **{s}**: ", .{field}) catch return null;
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const rest = body[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..end], " " ++ "\r");
    return if (value.len == 0) null else value;
}

/// Builds the GitHub issue title for a report body. The returned slice is
/// owned by `allocator`.
pub fn titleFromReport(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const err = reportField(body, "Error") orelse
        return allocator.dupe(u8, "crash: unknown failure");
    const phase = reportField(body, "Phase") orelse "an unknown phase";
    if (reportField(body, "Version")) |ver| {
        return std.fmt.allocPrint(allocator, "crash: {s} during {s} (v{s})", .{ err, phase, ver });
    }
    return std.fmt.allocPrint(allocator, "crash: {s} during {s}", .{ err, phase });
}

/// How many pending reports are kept. A crash that repeats every startup must
/// not fill the config directory.
pub const max_pending_reports: usize = 5;

/// Deletes all but the `keep` most recent reports.
pub fn prune(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    keep: usize,
) !void {
    const reports = try list(io, allocator, environ_map);
    defer freeReports(allocator, reports);
    if (reports.len <= keep) return;
    for (reports[keep..]) |r| try discard(io, r.path);
}

/// Deletes a crash report. A file that is already gone is not an error.
pub fn discard(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

/// Extracts the session id from a crash report file name, or null when the
/// name does not belong to puny.
fn sessionIdFromFileName(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, file_prefix)) return null;
    if (!std.mem.endsWith(u8, name, ".md")) return null;
    const id = name[file_prefix.len .. name.len - ".md".len];
    return if (id.len == 0) null else id;
}

/// Environment map pointing the config dir at a scratch directory, wiped so a
/// crashed run's leftovers cannot leak into the next test run.
fn testEnv(allocator: std.mem.Allocator, io: std.Io, base: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const dir = try std.fs.path.join(allocator, &.{ cwd, "zig-out", base });
    defer allocator.free(dir);
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    if (comptime builtin.os.tag == .windows) {
        try env.put("APPDATA", dir);
    } else {
        try env.put("XDG_CONFIG_HOME", dir);
    }
    return env;
}

fn testEnvCleanup(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) void {
    if (crashDir(allocator, env)) |dir| {
        defer allocator.free(dir);
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    } else |_| {}
    env.deinit();
}

test "write stores the report at the path reportPath resolves" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(allocator, io, "test-crash-write");
    defer testEnvCleanup(allocator, io, &env);

    try write(io, allocator, &env, .{
        .session_id = "write-1",
        .error_name = "OutOfMemory",
        .phase = "chat turn",
    });

    const path = try reportPath(allocator, &env, "write-1");
    defer allocator.free(path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "error.OutOfMemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "write-1") != null);
}

fn writeTestReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    session_id: []const u8,
    modified_ns: i96,
) !void {
    try write(io, allocator, env, .{
        .session_id = session_id,
        .error_name = "OutOfMemory",
        .phase = "chat turn",
    });
    const path = try reportPath(allocator, env, session_id);
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(modified_ns) } });
}

test "list returns pending reports newest first and ignores other files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(allocator, io, "test-crash-list");
    defer testEnvCleanup(allocator, io, &env);

    try writeTestReport(allocator, io, &env, "older", 1_000_000_000_000);
    try writeTestReport(allocator, io, &env, "newer", 2_000_000_000_000);

    const dir = try crashDir(allocator, &env);
    defer allocator.free(dir);
    const stray = try std.fs.path.join(allocator, &.{ dir, "notes.txt" });
    defer allocator.free(stray);
    var stray_file = try std.Io.Dir.cwd().createFile(io, stray, .{});
    stray_file.close(io);

    const reports = try list(io, allocator, &env);
    defer freeReports(allocator, reports);

    try std.testing.expectEqual(@as(usize, 2), reports.len);
    try std.testing.expectEqualStrings("newer", reports[0].session_id);
    try std.testing.expectEqualStrings("older", reports[1].session_id);
}

test "list is empty when no crash directory exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(allocator, io, "test-crash-empty");
    defer testEnvCleanup(allocator, io, &env);

    const reports = try list(io, allocator, &env);
    defer freeReports(allocator, reports);
    try std.testing.expectEqual(@as(usize, 0), reports.len);
}

test "discard removes a report and tolerates a missing file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(allocator, io, "test-crash-discard");
    defer testEnvCleanup(allocator, io, &env);

    try writeTestReport(allocator, io, &env, "gone", 1_000_000_000_000);
    const path = try reportPath(allocator, &env, "gone");
    defer allocator.free(path);

    try discard(io, path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
    try discard(io, path);
}

test "prune keeps only the newest reports" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env = try testEnv(allocator, io, "test-crash-prune");
    defer testEnvCleanup(allocator, io, &env);

    try writeTestReport(allocator, io, &env, "oldest", 1_000_000_000_000);
    try writeTestReport(allocator, io, &env, "middle", 2_000_000_000_000);
    try writeTestReport(allocator, io, &env, "newest", 3_000_000_000_000);

    try prune(io, allocator, &env, 2);

    const reports = try list(io, allocator, &env);
    defer freeReports(allocator, reports);
    try std.testing.expectEqual(@as(usize, 2), reports.len);
    try std.testing.expectEqualStrings("newest", reports[0].session_id);
    try std.testing.expectEqualStrings("middle", reports[1].session_id);
}

test "titleFromReport summarises the failure for the issue title" {
    const allocator = std.testing.allocator;
    const body =
        "# puny crash report\n\n" ++
        "- **Error**: error.ConnectionRefused\n" ++
        "- **Phase**: chat turn\n" ++
        "- **Version**: 0.3.5\n";

    const title = try titleFromReport(allocator, body);
    defer allocator.free(title);
    try std.testing.expectEqualStrings("crash: error.ConnectionRefused during chat turn (v0.3.5)", title);
}

test "titleFromReport falls back when the report is unrecognised" {
    const allocator = std.testing.allocator;
    const title = try titleFromReport(allocator, "not a puny crash report");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("crash: unknown failure", title);
}

test "submitArgv builds a gh issue create command for the report file" {
    const allocator = std.testing.allocator;
    const argv = try submitArgv(allocator, "/tmp/puny_crash_x.md", "crash: error.X during startup");
    defer allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 9), argv.len);
    try std.testing.expectEqualStrings("gh", argv[0]);
    try std.testing.expectEqualStrings("issue", argv[1]);
    try std.testing.expectEqualStrings("create", argv[2]);
    try std.testing.expectEqualStrings("--repo", argv[3]);
    try std.testing.expectEqualStrings("christianhelle/puny", argv[4]);
    try std.testing.expectEqualStrings("--title", argv[5]);
    try std.testing.expectEqualStrings("crash: error.X during startup", argv[6]);
    try std.testing.expectEqualStrings("--body-file", argv[7]);
    try std.testing.expectEqualStrings("/tmp/puny_crash_x.md", argv[8]);
}

test "parseSubmitOutput reports the issue url gh printed" {
    const output = "Exit code: 0\nSTDOUT:\nhttps://github.com/christianhelle/puny/issues/42\n";
    const outcome = parseSubmitOutput(output);
    try std.testing.expectEqualStrings(
        "https://github.com/christianhelle/puny/issues/42",
        outcome.submitted,
    );
}

test "parseSubmitOutput surfaces the failure gh reported" {
    const output = "Exit code: 1\nSTDERR:\ngh: not authenticated\n";
    const outcome = parseSubmitOutput(output);
    try std.testing.expectEqualStrings("gh: not authenticated", outcome.failed);
}

test "parseSubmitOutput fails when gh succeeded without printing a url" {
    const outcome = parseSubmitOutput("Exit code: 0\n");
    try std.testing.expect(outcome == .failed);
}

const FakeRunner = struct {
    output: []const u8 = "",
    fail_with: ?anyerror = null,
    /// Copy of the title argv slot: submitWithRunner frees argv before it
    /// returns, so the test cannot hold on to the original slices.
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) anyerror![]const u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(ctx));
        if (argv.len > 6) {
            @memcpy(self.title_buf[0..argv[6].len], argv[6]);
            self.title_len = argv[6].len;
        }
        if (self.fail_with) |err| return err;
        return allocator.dupe(u8, self.output);
    }

    fn title(self: *const FakeRunner) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn runner(self: *FakeRunner) Runner {
        return .{ .ctx = self, .run = FakeRunner.run };
    }
};

test "submitWithRunner returns the created issue url" {
    const allocator = std.testing.allocator;
    var fake = FakeRunner{ .output = "Exit code: 0\nSTDOUT:\nhttps://github.com/christianhelle/puny/issues/7\n" };

    const outcome = try submitWithRunner(
        allocator,
        "/tmp/puny_crash_x.md",
        "- **Error**: error.X\n- **Phase**: startup\n",
        fake.runner(),
    );
    defer freeOutcome(allocator, outcome);

    try std.testing.expectEqualStrings("https://github.com/christianhelle/puny/issues/7", outcome.submitted);
    try std.testing.expectEqualStrings("crash: error.X during startup", fake.title());
}

test "submitWithRunner explains a missing gh instead of failing the startup" {
    const allocator = std.testing.allocator;
    var fake = FakeRunner{ .fail_with = error.FileNotFound };

    const outcome = try submitWithRunner(allocator, "/tmp/puny_crash_x.md", "", fake.runner());
    defer freeOutcome(allocator, outcome);

    try std.testing.expect(std.mem.indexOf(u8, outcome.failed, "gh") != null);
}

test "detailsFor describes the failure using the recorded context" {
    setContext(.{ .session_id = "ctx-1", .provider = "GitHub Copilot", .model = "gpt-5" });
    defer resetContext();
    setPhase("chat turn");

    const details = detailsFor("ConnectionRefused");
    try std.testing.expectEqualStrings("ctx-1", details.session_id);
    try std.testing.expectEqualStrings("ConnectionRefused", details.error_name);
    try std.testing.expectEqualStrings("chat turn", details.phase);
    try std.testing.expectEqualStrings("GitHub Copilot", details.provider.?);
    try std.testing.expectEqualStrings("gpt-5", details.model.?);
}

test "detailsFor works before a session exists" {
    resetContext();
    const details = detailsFor("NoConfigDir");
    try std.testing.expectEqualStrings("unknown", details.session_id);
    try std.testing.expectEqualStrings("startup", details.phase);
    try std.testing.expect(details.provider == null);
}
