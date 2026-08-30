const std = @import("std");
const helpers = @import("../tools/helpers.zig");
const atomic_write = @import("../sessions/atomic_write.zig");

pub const base_ref = "origin/main";
pub const report_filename = "review-results.md";
pub const request_prompt = "Perform the branch review now and save the final review results.";

pub const Scope = struct {
    repo_root: []const u8,
    branch: []const u8,
    base_ref: []const u8,
    base_sha: []const u8,
    head_sha: []const u8,
    merge_base_sha: []const u8,
    commit_count: usize,
    changed_files: []const u8,
    diff_stat: []const u8,
    dirty_worktree: []const u8,
};

pub const Failure = struct {
    repo_root: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    message: []const u8,
};

pub const Preparation = union(enum) {
    ready: Scope,
    no_changes: Scope,
    invalid: Failure,
    operational_failure: Failure,
};

pub const Outcome = enum {
    merge_worthy,
    rejected,
    operational_failure,

    pub fn exitCode(self: Outcome) u8 {
        return switch (self) {
            .merge_worthy => 0,
            .rejected => 1,
            .operational_failure => 2,
        };
    }
};

pub const ReportInput = struct {
    analysis_markdown: []const u8,
    conclusion: []const u8,
    evidence_complete: bool,
    merge_worthy: bool,
};

pub const SavedReport = struct {
    path: []const u8,
    outcome: Outcome,
};

const ActiveReview = struct {
    scope: Scope,
    saved: ?SavedReport = null,
};

var active_review: ?ActiveReview = null;

const GitResult = union(enum) {
    ok: []const u8,
    failed: []const u8,
};

pub fn prepare(allocator: std.mem.Allocator, io: std.Io) !Preparation {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return prepareAt(allocator, io, cwd);
}

pub fn prepareAt(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) !Preparation {
    const root_result = try runGit(allocator, io, start_dir, &.{ "rev-parse", "--show-toplevel" }, 30 * std.time.ns_per_s);
    const repo_root = switch (root_result) {
        .ok => |value| value,
        .failed => return .{ .invalid = .{ .message = "Review mode requires a Git repository." } },
    };

    const branch_result = try runGit(allocator, io, repo_root, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" }, 30 * std.time.ns_per_s);
    const branch = switch (branch_result) {
        .ok => |value| value,
        .failed => return .{ .invalid = .{
            .repo_root = repo_root,
            .message = "Review mode requires a named branch; detached HEAD is not supported.",
        } },
    };
    if (std.mem.eql(u8, branch, "main")) {
        return .{ .invalid = .{
            .repo_root = repo_root,
            .branch = branch,
            .message = "Review mode cannot run on main.",
        } };
    }

    const fetch_result = try runGit(
        allocator,
        io,
        repo_root,
        &.{ "fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main" },
        120 * std.time.ns_per_s,
    );
    if (fetch_result == .failed) {
        return .{ .operational_failure = .{
            .repo_root = repo_root,
            .branch = branch,
            .message = "Failed to fetch origin/main.",
        } };
    }

    const base_result = try runGit(allocator, io, repo_root, &.{ "rev-parse", "--verify", "refs/remotes/origin/main" }, 30 * std.time.ns_per_s);
    const base_sha = switch (base_result) {
        .ok => |value| value,
        .failed => |message| return operationalFailure(repo_root, branch, message),
    };
    const head_result = try runGit(allocator, io, repo_root, &.{ "rev-parse", "--verify", "HEAD" }, 30 * std.time.ns_per_s);
    const head_sha = switch (head_result) {
        .ok => |value| value,
        .failed => |message| return operationalFailure(repo_root, branch, message),
    };
    const merge_base_result = try runGit(allocator, io, repo_root, &.{ "merge-base", base_sha, head_sha }, 30 * std.time.ns_per_s);
    const merge_base_sha = switch (merge_base_result) {
        .ok => |value| value,
        .failed => |message| return operationalFailure(repo_root, branch, message),
    };

    const revision_range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base_sha, head_sha });
    const commit_count_result = try runGit(allocator, io, repo_root, &.{ "rev-list", "--count", revision_range }, 30 * std.time.ns_per_s);
    const commit_count_text = switch (commit_count_result) {
        .ok => |value| value,
        .failed => |message| return operationalFailure(repo_root, branch, message),
    };
    const commit_count = std.fmt.parseInt(usize, commit_count_text, 10) catch {
        return operationalFailure(repo_root, branch, "Git returned an invalid commit count.");
    };

    const files_result = try runGit(allocator, io, repo_root, &.{ "diff", "--name-status", "--find-renames", revision_range }, 30 * std.time.ns_per_s);
    const changed_files = switch (files_result) {
        .ok => |value| value,
        .failed => |message| return operationalFailure(repo_root, branch, message),
    };
    const stat_result = try runGit(allocator, io, repo_root, &.{ "diff", "--stat", revision_range }, 30 * std.time.ns_per_s);
    const diff_stat = switch (stat_result) {
        .ok => |value| value,
        .failed => |message| return operationalFailure(repo_root, branch, message),
    };
    const status_result = try runGit(allocator, io, repo_root, &.{ "status", "--porcelain=v1", "--untracked-files=all" }, 30 * std.time.ns_per_s);
    const dirty_worktree = switch (status_result) {
        .ok => |value| try withoutGeneratedReport(allocator, value),
        .failed => |message| return operationalFailure(repo_root, branch, message),
    };

    const scope = Scope{
        .repo_root = repo_root,
        .branch = branch,
        .base_ref = base_ref,
        .base_sha = base_sha,
        .head_sha = head_sha,
        .merge_base_sha = merge_base_sha,
        .commit_count = commit_count,
        .changed_files = changed_files,
        .diff_stat = diff_stat,
        .dirty_worktree = dirty_worktree,
    };
    return if (changed_files.len == 0) .{ .no_changes = scope } else .{ .ready = scope };
}

fn operationalFailure(repo_root: []const u8, branch: []const u8, message: []const u8) Preparation {
    return .{ .operational_failure = .{
        .repo_root = repo_root,
        .branch = branch,
        .message = message,
    } };
}

fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const []const u8,
    timeout_ns: i96,
) !GitResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    const output = helpers.runCommandTimed(allocator, io, argv.items, cwd, timeout_ns) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Git command failed: {s}", .{@errorName(err)}) };
    };
    defer allocator.free(output);

    const succeeded = std.mem.startsWith(u8, output, "Exit code: 0");
    const content = commandSection(output, if (succeeded) "STDOUT:\n" else "STDERR:\n");
    const detail = if (succeeded or content.len > 0) content else output;
    return if (succeeded)
        .{ .ok = try allocator.dupe(u8, std.mem.trimEnd(u8, detail, &std.ascii.whitespace)) }
    else
        .{ .failed = try allocator.dupe(u8, std.mem.trim(u8, detail, &std.ascii.whitespace)) };
}

fn commandSection(output: []const u8, marker: []const u8) []const u8 {
    const start_index = std.mem.indexOf(u8, output, marker) orelse return "";
    const start = start_index + marker.len;
    const end = if (std.mem.indexOfPos(u8, output, start, "\nSTDERR:\n")) |index| index else output.len;
    return output[start..end];
}

fn withoutGeneratedReport(allocator: std.mem.Allocator, status: []const u8) ![]const u8 {
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(allocator);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const path = if (line.len > 3) std.mem.trim(u8, line[3..], &std.ascii.whitespace) else "";
        if (std.mem.eql(u8, path, report_filename)) continue;
        if (filtered.items.len > 0) try filtered.append(allocator, '\n');
        try filtered.appendSlice(allocator, line);
    }
    return helpers.ownedSliceOrEmpty(&filtered, allocator);
}

pub fn writeReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: Scope,
    input: ReportInput,
) !SavedReport {
    const analysis = std.mem.trim(u8, input.analysis_markdown, &std.ascii.whitespace);
    const conclusion = std.mem.trim(u8, input.conclusion, &std.ascii.whitespace);
    if (analysis.len == 0) return error.EmptyReviewAnalysis;
    if (conclusion.len == 0) return error.EmptyReviewConclusion;
    const required_sections = [_][]const u8{
        "## Change Summary",
        "## Quality and Regression Assessment",
        "## Validation Performed",
        "## Findings",
    };
    var previous_section_end: usize = 0;
    for (required_sections) |heading| {
        const section_start = std.mem.indexOf(u8, analysis, heading) orelse return error.MissingReviewSection;
        if (section_start < previous_section_end) return error.InvalidReviewSectionOrder;
        previous_section_end = section_start + heading.len;
    }
    if (std.mem.indexOf(u8, analysis, "# Review Results") != null or
        std.mem.indexOf(u8, analysis, "## Review Scope") != null or
        std.mem.indexOf(u8, analysis, "## Conclusion") != null or
        std.mem.indexOf(u8, analysis, "MERGE WORTHY:") != null or
        std.mem.indexOf(u8, conclusion, "# Review Results") != null or
        std.mem.indexOf(u8, conclusion, "## Conclusion") != null or
        std.mem.indexOf(u8, conclusion, "MERGE WORTHY:") != null or
        try containsFormattedVerdict(allocator, analysis) or
        try containsFormattedVerdict(allocator, conclusion))
    {
        return error.ReservedReviewSection;
    }

    const outcome: Outcome = if (input.merge_worthy and input.evidence_complete) .merge_worthy else .rejected;
    const verdict = if (outcome == .merge_worthy) "YES" else "NO";
    const dirty = if (scope.dirty_worktree.len == 0) "Clean (excluding the generated review report)." else scope.dirty_worktree;

    var rendered = std.Io.Writer.Allocating.init(allocator);
    defer rendered.deinit();
    try rendered.writer.print(
        \\# Review Results
        \\
        \\## Review Scope
        \\
        \\- **Branch:** `{s}`
        \\- **Base ref:** `{s}`
        \\- **Base SHA:** `{s}`
        \\- **Merge base:** `{s}`
        \\- **HEAD SHA:** `{s}`
        \\- **Commits reviewed:** {d}
        \\- **Changed files:**
        \\
        \\```text
        \\{s}
        \\```
        \\
        \\- **Diff stat:**
        \\
        \\```text
        \\{s}
        \\```
        \\
        \\- **Worktree outside review scope:**
        \\
        \\```text
        \\{s}
        \\```
        \\
        \\{s}
        \\
        \\## Conclusion
        \\
        \\{s}
        \\
        \\**MERGE WORTHY: {s}**
    , .{
        scope.branch,
        scope.base_ref,
        scope.base_sha,
        scope.merge_base_sha,
        scope.head_sha,
        scope.commit_count,
        scope.changed_files,
        scope.diff_stat,
        dirty,
        analysis,
        conclusion,
        verdict,
    });

    try atomic_write.writeAtomically(io, allocator, scope.repo_root, report_filename, rendered.written(), .{});
    return .{
        .path = try std.fs.path.join(allocator, &.{ scope.repo_root, report_filename }),
        .outcome = outcome,
    };
}

fn containsFormattedVerdict(allocator: std.mem.Allocator, text: []const u8) !bool {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try normalized.append(allocator, std.ascii.toLower(char));
        }
    }
    return std.mem.indexOf(u8, normalized.items, "mergeworthyyes") != null or
        std.mem.indexOf(u8, normalized.items, "mergeworthyno") != null;
}

pub fn buildPromptContext(allocator: std.mem.Allocator, scope: Scope) ![]const u8 {
    const dirty = if (scope.dirty_worktree.len == 0) "Clean." else scope.dirty_worktree;
    return std.fmt.allocPrint(
        allocator,
        \\Review invocation context:
        \\- Repository root: {s}
        \\- Branch: {s}
        \\- Base ref: {s}
        \\- Base SHA: {s}
        \\- Merge base SHA: {s}
        \\- HEAD SHA: {s}
        \\- Immutable review range: {s}..{s}
        \\- Commits in scope: {d}
        \\- Changed files:
        \\{s}
        \\- Diff stat:
        \\{s}
        \\- Worktree outside review scope:
        \\{s}
        \\
        \\Review committed changes only in the immutable range above. Do not include
        \\staged, modified, or untracked work in the merge-worthiness verdict.
        \\Repository checks run in the current worktree, so disclose any way its
        \\dirty state could affect their reliability. Do not edit source files.
        \\Save the final report as {s} through the dedicated report tool.
    , .{
        scope.repo_root,
        scope.branch,
        scope.base_ref,
        scope.base_sha,
        scope.merge_base_sha,
        scope.head_sha,
        scope.merge_base_sha,
        scope.head_sha,
        scope.commit_count,
        scope.changed_files,
        scope.diff_stat,
        dirty,
        report_filename,
    });
}

pub fn begin(scope: Scope) void {
    active_review = .{ .scope = scope };
}

pub fn reset() void {
    active_review = null;
}

pub fn isActive() bool {
    return active_review != null;
}

pub fn saveActiveReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: ReportInput,
) !SavedReport {
    if (active_review == null) return error.NoActiveReview;
    const saved = try writeReport(allocator, io, active_review.?.scope, input);
    active_review.?.saved = saved;
    return saved;
}

pub fn finish(
    allocator: std.mem.Allocator,
    io: std.Io,
    missing_report_reason: []const u8,
) !SavedReport {
    if (active_review == null) return error.NoActiveReview;
    if (active_review.?.saved) |saved| return saved;
    const saved = try writeFallbackReport(
        allocator,
        io,
        active_review.?.scope,
        missing_report_reason,
    );
    active_review.?.saved = saved;
    return saved;
}

pub fn failActive(
    allocator: std.mem.Allocator,
    io: std.Io,
    reason: []const u8,
) !SavedReport {
    if (active_review == null) return error.NoActiveReview;
    const saved = try writeFallbackReport(allocator, io, active_review.?.scope, reason);
    active_review.?.saved = saved;
    return saved;
}

pub fn writeNoChanges(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: Scope,
) !SavedReport {
    return writeReport(allocator, io, scope, .{
        .analysis_markdown =
        \\## Change Summary
        \\The branch has no committed file changes relative to `origin/main`.
        \\
        \\## Quality and Regression Assessment
        \\The branch introduces no assessable code-quality change or regression.
        \\
        \\## Validation Performed
        \\Git fetch, branch resolution, merge-base calculation, and committed diff inspection completed.
        \\
        \\## Findings
        \\There is nothing to merge.
        ,
        .conclusion = "The branch is not merge worthy because it contains no committed changes.",
        .evidence_complete = true,
        .merge_worthy = false,
    });
}

pub fn writeOperationalFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    failure: Failure,
) !SavedReport {
    const repo_root = failure.repo_root orelse return error.ReviewRepositoryUnavailable;
    const scope = Scope{
        .repo_root = repo_root,
        .branch = failure.branch orelse "unavailable",
        .base_ref = base_ref,
        .base_sha = "unavailable",
        .head_sha = "unavailable",
        .merge_base_sha = "unavailable",
        .commit_count = 0,
        .changed_files = "Unavailable because review preflight failed.",
        .diff_stat = "Unavailable because review preflight failed.",
        .dirty_worktree = "Unavailable because review preflight failed.",
    };
    const reason = try std.fmt.allocPrint(allocator, "Operational failure: {s}", .{failure.message});
    return writeFallbackReport(allocator, io, scope, reason);
}

fn writeFallbackReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: Scope,
    reason: []const u8,
) !SavedReport {
    const analysis = try std.fmt.allocPrint(
        allocator,
        \\## Change Summary
        \\The review could not complete, so the committed changes were not fully assessed.
        \\
        \\## Quality and Regression Assessment
        \\Code-quality degradation and regressions could not be ruled out.
        \\
        \\## Validation Performed
        \\{s}
        \\
        \\## Findings
        \\Incomplete review evidence is a blocking finding.
    ,
        .{reason},
    );
    const rejected = try writeReport(allocator, io, scope, .{
        .analysis_markdown = analysis,
        .conclusion = "The branch is not merge worthy because the review did not complete.",
        .evidence_complete = false,
        .merge_worthy = false,
    });
    return .{ .path = rejected.path, .outcome = .operational_failure };
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    remote: []const u8,
    worktree: []const u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const allocator = std.testing.allocator;
        const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
        defer allocator.free(cwd);
        const root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
        errdefer allocator.free(root);
        const remote = try std.fs.path.join(allocator, &.{ root, "remote.git" });
        errdefer allocator.free(remote);
        const worktree = try std.fs.path.join(allocator, &.{ root, "worktree" });
        errdefer allocator.free(worktree);

        try runFixtureGit(null, &.{ "init", "--bare", remote });
        try runFixtureGit(null, &.{ "init", "-b", "main", worktree });
        try runFixtureGit(worktree, &.{ "config", "user.email", "puny@example.test" });
        try runFixtureGit(worktree, &.{ "config", "user.name", "Puny Test" });

        const initial_path = try std.fs.path.join(allocator, &.{ worktree, "initial.txt" });
        defer allocator.free(initial_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = initial_path, .data = "initial\n" });
        try runFixtureGit(worktree, &.{ "add", "initial.txt" });
        try runFixtureGit(worktree, &.{ "commit", "-m", "initial" });
        try runFixtureGit(worktree, &.{ "remote", "add", "origin", remote });
        try runFixtureGit(worktree, &.{ "push", "-u", "origin", "main" });

        return .{
            .tmp = tmp,
            .root = root,
            .remote = remote,
            .worktree = worktree,
        };
    }

    fn addFeatureCommit(self: Fixture) !void {
        try runFixtureGit(self.worktree, &.{ "checkout", "-b", "feature/review" });
        const feature_path = try std.fs.path.join(std.testing.allocator, &.{ self.worktree, "feature.txt" });
        defer std.testing.allocator.free(feature_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = feature_path, .data = "feature\n" });
        try runFixtureGit(self.worktree, &.{ "add", "feature.txt" });
        try runFixtureGit(self.worktree, &.{ "commit", "-m", "feature" });
    }

    fn advanceRemoteMain(self: Fixture) ![]const u8 {
        const updater = try std.fs.path.join(std.testing.allocator, &.{ self.root, "updater" });
        defer std.testing.allocator.free(updater);
        try runFixtureGit(null, &.{ "clone", self.remote, updater });
        try runFixtureGit(updater, &.{ "checkout", "-b", "main", "origin/main" });
        try runFixtureGit(updater, &.{ "config", "user.email", "puny@example.test" });
        try runFixtureGit(updater, &.{ "config", "user.name", "Puny Test" });
        const upstream_path = try std.fs.path.join(std.testing.allocator, &.{ updater, "upstream.txt" });
        defer std.testing.allocator.free(upstream_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = upstream_path, .data = "upstream\n" });
        try runFixtureGit(updater, &.{ "add", "upstream.txt" });
        try runFixtureGit(updater, &.{ "commit", "-m", "upstream" });
        try runFixtureGit(updater, &.{ "push", "origin", "main" });
        const result = try runGit(std.testing.allocator, std.testing.io, updater, &.{ "rev-parse", "HEAD" }, 30 * std.time.ns_per_s);
        return switch (result) {
            .ok => |sha| sha,
            .failed => |message| {
                std.debug.print("failed to resolve updater HEAD: {s}\n", .{message});
                return error.GitFixtureFailed;
            },
        };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.worktree);
        std.testing.allocator.free(self.remote);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn runFixtureGit(cwd: ?[]const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try argv.append(std.testing.allocator, "git");
    try argv.appendSlice(std.testing.allocator, args);
    const output = try helpers.runCommandTimed(
        std.testing.allocator,
        std.testing.io,
        argv.items,
        cwd,
        30 * std.time.ns_per_s,
    );
    defer std.testing.allocator.free(output);
    if (!std.mem.startsWith(u8, output, "Exit code: 0")) {
        std.debug.print("git fixture command failed: {s}\n", .{output});
        return error.GitFixtureFailed;
    }
}

test "prepareAt captures a committed feature branch scope" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.addFeatureCommit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try prepareAt(arena_state.allocator(), std.testing.io, fixture.worktree);
    switch (result) {
        .ready => |scope| {
            try std.testing.expectEqualStrings("feature/review", scope.branch);
            try std.testing.expectEqualStrings("origin/main", scope.base_ref);
            try std.testing.expectEqual(@as(usize, 1), scope.commit_count);
            try std.testing.expect(std.mem.indexOf(u8, scope.changed_files, "feature.txt") != null);
            try std.testing.expectEqual(@as(usize, 40), scope.base_sha.len);
            try std.testing.expectEqual(@as(usize, 40), scope.head_sha.len);
            try std.testing.expectEqual(@as(usize, 40), scope.merge_base_sha.len);
        },
        else => return error.ExpectedReadyReview,
    }
}

test "prepareAt excludes the generated report from dirty worktree details" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.addFeatureCommit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const report_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.worktree, report_filename });
    defer std.testing.allocator.free(report_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = report_path, .data = "old report\n" });
    const local_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.worktree, "local.txt" });
    defer std.testing.allocator.free(local_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = local_path, .data = "local\n" });

    const result = try prepareAt(arena_state.allocator(), std.testing.io, fixture.worktree);
    switch (result) {
        .ready => |scope| {
            try std.testing.expect(std.mem.indexOf(u8, scope.dirty_worktree, "local.txt") != null);
            try std.testing.expect(std.mem.indexOf(u8, scope.dirty_worktree, report_filename) == null);
        },
        else => return error.ExpectedReadyReview,
    }
}

test "prepareAt preserves Git porcelain status columns" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.addFeatureCommit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const initial_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.worktree, "initial.txt" });
    defer std.testing.allocator.free(initial_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = initial_path, .data = "modified\n" });

    const prepared = try prepareAt(arena_state.allocator(), std.testing.io, fixture.worktree);
    const scope = switch (prepared) {
        .ready => |value| value,
        else => return error.ExpectedReadyReview,
    };
    try std.testing.expect(std.mem.startsWith(u8, scope.dirty_worktree, " M initial.txt"));
}

test "prepareAt fetches the latest origin main before fixing scope" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.addFeatureCommit();
    const expected_base = try fixture.advanceRemoteMain();
    defer std.testing.allocator.free(expected_base);
    try runFixtureGit(fixture.worktree, &.{ "config", "--unset-all", "remote.origin.fetch" });
    try runFixtureGit(fixture.worktree, &.{ "config", "--add", "remote.origin.fetch", "+refs/heads/unrelated:refs/remotes/origin/unrelated" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const prepared = try prepareAt(arena_state.allocator(), std.testing.io, fixture.worktree);
    const scope = switch (prepared) {
        .ready => |value| value,
        else => return error.ExpectedReadyReview,
    };
    try std.testing.expectEqualStrings(expected_base, scope.base_sha);
    try std.testing.expect(!std.mem.eql(u8, scope.base_sha, scope.merge_base_sha));
}

test "writeReport forces a canonical rejection when evidence is incomplete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena);
    const repo_root = try std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const scope = Scope{
        .repo_root = repo_root,
        .branch = "feature/report",
        .base_ref = base_ref,
        .base_sha = "1111111111111111111111111111111111111111",
        .head_sha = "2222222222222222222222222222222222222222",
        .merge_base_sha = "1111111111111111111111111111111111111111",
        .commit_count = 1,
        .changed_files = "M\tfeature.zig",
        .diff_stat = " feature.zig | 1 +",
        .dirty_worktree = "",
    };
    const analysis =
        \\## Change Summary
        \\Added review behavior.
        \\## Quality and Regression Assessment
        \\No known degradation, but validation is incomplete.
        \\## Validation Performed
        \\Tests could not run.
        \\## Findings
        \\No code finding; missing validation blocks approval.
    ;

    const saved = try writeReport(arena, std.testing.io, scope, .{
        .analysis_markdown = analysis,
        .conclusion = "Approval requires complete validation.",
        .evidence_complete = false,
        .merge_worthy = true,
    });

    try std.testing.expectEqual(Outcome.rejected, saved.outcome);
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, saved.path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "# Review Results") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Review Scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**MERGE WORTHY: NO**") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**MERGE WORTHY: YES**") == null);
}

test "finish writes an operational failure report when the model does not save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena);
    const repo_root = try std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const scope = Scope{
        .repo_root = repo_root,
        .branch = "feature/missing-report",
        .base_ref = base_ref,
        .base_sha = "1111111111111111111111111111111111111111",
        .head_sha = "2222222222222222222222222222222222222222",
        .merge_base_sha = "1111111111111111111111111111111111111111",
        .commit_count = 1,
        .changed_files = "M\tfeature.zig",
        .diff_stat = " feature.zig | 1 +",
        .dirty_worktree = "",
    };

    begin(scope);
    defer reset();
    const saved = try finish(arena, std.testing.io, "The model returned without saving a report.");

    try std.testing.expectEqual(Outcome.operational_failure, saved.outcome);
    try std.testing.expectEqual(@as(u8, 2), saved.outcome.exitCode());
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, saved.path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "The model returned without saving a report.") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**MERGE WORTHY: NO**") != null);
}

test "writeNoChanges rejects a branch with no committed changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try runFixtureGit(fixture.worktree, &.{ "checkout", "-b", "feature/empty" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prepared = try prepareAt(arena, std.testing.io, fixture.worktree);
    const scope = switch (prepared) {
        .no_changes => |value| value,
        else => return error.ExpectedNoChangesReview,
    };
    const saved = try writeNoChanges(arena, std.testing.io, scope);

    try std.testing.expectEqual(Outcome.rejected, saved.outcome);
    try std.testing.expectEqual(@as(u8, 1), saved.outcome.exitCode());
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, saved.path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "no committed changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**MERGE WORTHY: NO**") != null);
}

test "writeOperationalFailure records a retryable fetch failure" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.addFeatureCommit();
    try runFixtureGit(fixture.worktree, &.{ "remote", "remove", "origin" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prepared = try prepareAt(arena, std.testing.io, fixture.worktree);
    const failure = switch (prepared) {
        .operational_failure => |value| value,
        else => return error.ExpectedOperationalFailure,
    };
    try std.testing.expectEqualStrings("Failed to fetch origin/main.", failure.message);
    const saved = try writeOperationalFailure(arena, std.testing.io, failure);

    try std.testing.expectEqual(Outcome.operational_failure, saved.outcome);
    try std.testing.expectEqual(@as(u8, 2), saved.outcome.exitCode());
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, saved.path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "Operational failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**MERGE WORTHY: NO**") != null);
}

test "prepareAt rejects main without creating a report" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const prepared = try prepareAt(arena_state.allocator(), std.testing.io, fixture.worktree);
    const failure = switch (prepared) {
        .invalid => |value| value,
        else => return error.ExpectedInvalidReview,
    };
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "cannot run on main") != null);
    const report_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.worktree, report_filename });
    defer std.testing.allocator.free(report_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, report_path, .{}));
}

test "prepareAt rejects detached HEAD" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.addFeatureCommit();
    try runFixtureGit(fixture.worktree, &.{ "checkout", "--detach" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const prepared = try prepareAt(arena_state.allocator(), std.testing.io, fixture.worktree);
    const failure = switch (prepared) {
        .invalid => |value| value,
        else => return error.ExpectedInvalidReview,
    };
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "detached HEAD") != null);
}

test "prepareAt rejects a directory outside a Git repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena_state.allocator());
    const path = try std.fs.path.join(arena_state.allocator(), &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const git_marker = try std.fs.path.join(arena_state.allocator(), &.{ path, ".git" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = git_marker, .data = "gitdir: missing\n" });

    const prepared = try prepareAt(arena_state.allocator(), std.testing.io, path);
    const failure = switch (prepared) {
        .invalid => |value| value,
        else => return error.ExpectedInvalidReview,
    };
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "requires a Git repository") != null);
}

test "buildPromptContext fixes the model review to immutable commits" {
    const scope = Scope{
        .repo_root = "C:\\repo",
        .branch = "feature/context",
        .base_ref = base_ref,
        .base_sha = "1111111111111111111111111111111111111111",
        .head_sha = "2222222222222222222222222222222222222222",
        .merge_base_sha = "3333333333333333333333333333333333333333",
        .commit_count = 2,
        .changed_files = "M\tsrc/main.zig",
        .diff_stat = " src/main.zig | 4 ++--",
        .dirty_worktree = " M README.md",
    };

    const context = try buildPromptContext(std.testing.allocator, scope);
    defer std.testing.allocator.free(context);
    try std.testing.expect(std.mem.indexOf(u8, context, "feature/context") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "3333333333333333333333333333333333333333..2222222222222222222222222222222222222222") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "committed changes only") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "review-results.md") != null);
}

test "writeReport rejects a verdict marker in model-authored conclusion text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena);
    const repo_root = try std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const scope = Scope{
        .repo_root = repo_root,
        .branch = "feature/contradiction",
        .base_ref = base_ref,
        .base_sha = "1111111111111111111111111111111111111111",
        .head_sha = "2222222222222222222222222222222222222222",
        .merge_base_sha = "1111111111111111111111111111111111111111",
        .commit_count = 1,
        .changed_files = "M\tfeature.zig",
        .diff_stat = " feature.zig | 1 +",
        .dirty_worktree = "",
    };

    try std.testing.expectError(error.ReservedReviewSection, writeReport(arena, std.testing.io, scope, .{
        .analysis_markdown =
        \\## Change Summary
        \\Change.
        \\## Quality and Regression Assessment
        \\Assessment.
        \\## Validation Performed
        \\Validation.
        \\## Findings
        \\None.
        ,
        .conclusion = "Contradiction: MERGE WORTHY: YES",
        .evidence_complete = false,
        .merge_worthy = false,
    }));
    try std.testing.expectError(error.ReservedReviewSection, writeReport(arena, std.testing.io, scope, .{
        .analysis_markdown =
        \\## Change Summary
        \\Change.
        \\## Quality and Regression Assessment
        \\Assessment.
        \\## Validation Performed
        \\Validation.
        \\## Findings
        \\None.
        ,
        .conclusion = "Contradiction: **Merge Worthy:** YES",
        .evidence_complete = false,
        .merge_worthy = false,
    }));
}

test "writeReport requires analysis sections in canonical order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena);
    const repo_root = try std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const scope = Scope{
        .repo_root = repo_root,
        .branch = "feature/order",
        .base_ref = base_ref,
        .base_sha = "1111111111111111111111111111111111111111",
        .head_sha = "2222222222222222222222222222222222222222",
        .merge_base_sha = "1111111111111111111111111111111111111111",
        .commit_count = 1,
        .changed_files = "M\tfeature.zig",
        .diff_stat = " feature.zig | 1 +",
        .dirty_worktree = "",
    };

    try std.testing.expectError(error.InvalidReviewSectionOrder, writeReport(arena, std.testing.io, scope, .{
        .analysis_markdown =
        \\## Findings
        \\None.
        \\## Change Summary
        \\Change.
        \\## Quality and Regression Assessment
        \\Assessment.
        \\## Validation Performed
        \\Validation.
        ,
        .conclusion = "The branch is not ready.",
        .evidence_complete = true,
        .merge_worthy = false,
    }));
}

test "failActive replaces an earlier approval with an operational rejection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena);
    const repo_root = try std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const scope = Scope{
        .repo_root = repo_root,
        .branch = "feature/provider-failure",
        .base_ref = base_ref,
        .base_sha = "1111111111111111111111111111111111111111",
        .head_sha = "2222222222222222222222222222222222222222",
        .merge_base_sha = "1111111111111111111111111111111111111111",
        .commit_count = 1,
        .changed_files = "M\tfeature.zig",
        .diff_stat = " feature.zig | 1 +",
        .dirty_worktree = "",
    };

    begin(scope);
    defer reset();
    _ = try saveActiveReport(arena, std.testing.io, .{
        .analysis_markdown =
        \\## Change Summary
        \\Change.
        \\## Quality and Regression Assessment
        \\No regression.
        \\## Validation Performed
        \\Checks passed.
        \\## Findings
        \\None.
        ,
        .conclusion = "Ready.",
        .evidence_complete = true,
        .merge_worthy = true,
    });
    const failed = try failActive(arena, std.testing.io, "Provider failed after the tool call.");

    try std.testing.expectEqual(Outcome.operational_failure, failed.outcome);
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, failed.path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, content, "Provider failed after the tool call.") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**MERGE WORTHY: NO**") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**MERGE WORTHY: YES**") == null);
}
