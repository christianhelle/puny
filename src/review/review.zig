const std = @import("std");
const run_command = @import("../tools/run_command.zig");

// ─── Git command runner ──────────────────────────────────────────────────────

pub const ReviewError = error{
    NotInGitRepo,
    OnMainBranch,
    DetachedHead,
    NoCommitsInScope,
    FetchFailed,
    OutOfMemory,
};

/// Extracts the STDOUT section from a runCommand output string.
/// runCommand returns: "Exit code: N\nSTDOUT:\n...\nSTDERR:\n..."
fn extractStdout(result: []const u8) []const u8 {
    const stdout_marker = "STDOUT:\n";
    const idx = std.mem.indexOf(u8, result, stdout_marker) orelse return "";
    const start = idx + stdout_marker.len;
    // Find the end — either STDERR:\n or end of string
    const stderr_marker = "STDERR:\n";
    const end = if (std.mem.indexOf(u8, result[start..], stderr_marker)) |e| start + e else result.len;
    // Trim trailing newline
    var trimmed = result[start..end];
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

/// Checks if the command exited with code 0.
fn exitCode(result: []const u8) ?u32 {
    const marker = "Exit code: ";
    const idx = std.mem.indexOf(u8, result, marker) orelse return null;
    const num_str = result[idx + marker.len ..];
    const end = std.mem.indexOfAny(u8, num_str, "\n\r ") orelse num_str.len;
    return std.fmt.parseInt(u32, num_str[0..end], 10) catch null;
}

/// Runs a git command and returns the trimmed stdout, or an error.
fn runGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ReviewError![]const u8 {
    const result = run_command.runCommandTimed(allocator, io, argv, null, 30 * std.time.ns_per_s) catch |err| switch (err) {
        error.TimedOut => return error.FetchFailed,
        else => return error.FetchFailed,
    };
    defer allocator.free(result);

    const code = exitCode(result);
    if (code != 0) return error.FetchFailed;

    return try allocator.dupe(u8, extractStdout(result));
}

// ─── Required report sections ────────────────────────────────────────────────

const required_sections = [_][]const u8{
    "## Branch Under Review",
    "## Branch Commits",
    "## Other Commits",
    "## Diff",
    "## Test Failures",
    "## Files Touched",
    "## Conclusion",
};

// ─── Report validation ───────────────────────────────────────────────────────

pub const Verdict = enum { yes, @"no", warning };

pub const ValidationResult = struct {
    verdict: Verdict,
    missing_sections: []const []const u8,
    has_conclusion_marker: bool,
};

/// Checks whether `report` contains every required section heading.
fn hasSection(report: []const u8, section: []const u8) bool {
    return std.mem.indexOf(u8, report, section) != null;
}

/// Extracts the Conclusion line and returns whether it contains a valid marker.
fn extractVerdict(report: []const u8) ?Verdict {
    const conclusion_marker = "## Conclusion";
    const idx = std.mem.indexOf(u8, report, conclusion_marker) orelse return null;
    const rest = report[idx..];

    // Scan for YES or NO after the heading
    if (std.mem.indexOf(u8, rest, "NO (WARNING)") != null) return .warning;
    if (std.mem.indexOf(u8, rest, "NO") != null) return .@"no";
    if (std.mem.indexOf(u8, rest, "YES") != null) return .yes;
    return null;
}

/// Validates the model report against the required sections and conclusion.
pub fn validateReport(report: []const u8) ValidationResult {
    var missing: [required_sections.len][]const u8 = undefined;
    var missing_count: usize = 0;

    for (required_sections) |section| {
        if (!hasSection(report, section)) {
            missing[missing_count] = section;
            missing_count += 1;
        }
    }

    const verdict = extractVerdict(report) orelse .@"no";
    return .{
        .verdict = verdict,
        .missing_sections = missing[0..missing_count],
        .has_conclusion_marker = extractVerdict(report) != null,
    };
}

// ─── Git context ─────────────────────────────────────────────────────────────

pub const ReviewScope = struct {
    branch: []const u8,
    base_ref_sha: []const u8,
    merge_base_sha: []const u8,
    head_sha: []const u8,
    commit_count: u32,
    changed_files: []const u8,
    worktree_dirty: bool,
    dirty_note: []const u8,
};

pub const ReviewScopeResult = struct {
    scope: ReviewScope,
    context_string: []const u8,
};

/// Returns true if the current branch is the given branch name.
fn isOnMain(branch: []const u8) bool {
    return std.mem.eql(u8, branch, "main") or std.mem.eql(u8, branch, "master");
}

/// Captures the full review scope by running git commands.
pub fn captureScope(allocator: std.mem.Allocator, io: std.Io) ReviewError!ReviewScope {
    // 1. Get current branch name
    const branch_raw = try runGit(allocator, io, &.{ "git", "branch", "--show-current" });
    defer allocator.free(branch_raw);
    if (branch_raw.len == 0) return error.DetachedHead;
    const branch = try allocator.dupe(u8, branch_raw);
    errdefer allocator.free(branch);

    if (isOnMain(branch)) {
        allocator.free(branch);
        return error.OnMainBranch;
    }

    // 2. Get HEAD SHA
    const head_raw = try runGit(allocator, io, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head_sha = try allocator.dupe(u8, head_raw);
    errdefer allocator.free(head_sha);

    // 3. Fetch origin (best-effort, don't fail the review if it can't fetch)
    const fetch_result = runGit(allocator, io, &.{ "git", "fetch", "origin", "main" }) catch null;
    if (fetch_result) |fetched| allocator.free(fetched);

    // 4. Get merge-base between HEAD and origin/main
    const base_ref = "origin/main";
    const mb_raw = runGit(allocator, io, &.{ "git", "merge-base", "HEAD", base_ref }) catch blk: {
        // If origin/main doesn't exist, try main
        const mb2 = runGit(allocator, io, &.{ "git", "merge-base", "HEAD", "main" }) catch {
            return error.NoCommitsInScope;
        };
        break :blk mb2;
    };
    defer allocator.free(mb_raw);
    const merge_base_sha = try allocator.dupe(u8, mb_raw);
    errdefer allocator.free(merge_base_sha);

    // 5. Get base ref SHA (the tip of origin/main)
    const base_raw = runGit(allocator, io, &.{ "git", "rev-parse", base_ref }) catch blk: {
        const b2 = runGit(allocator, io, &.{ "git", "rev-parse", "main" }) catch return error.FetchFailed;
        break :blk b2;
    };
    defer allocator.free(base_raw);
    const base_ref_sha = try allocator.dupe(u8, base_raw);
    errdefer allocator.free(base_ref_sha);

    // 6. Count commits in scope (merge-base..HEAD)
    const count_raw = try runGit(allocator, io, &.{ "git", "rev-list", "--count", "merge-base..HEAD" });
    defer allocator.free(count_raw);
    // Trim trailing whitespace/newlines manually (std.mem.trimRight not available in 0.16)
    var count_end = count_raw.len;
    while (count_end > 0 and (count_raw[count_end - 1] == '\n' or count_raw[count_end - 1] == '\r' or count_raw[count_end - 1] == ' ')) {
        count_end -= 1;
    }
    const commit_count = std.fmt.parseInt(u32, count_raw[0..count_end], 10) catch 0;

    // 7. Changed files summary (stat)
    const files_raw = try runGit(allocator, io, &.{ "git", "diff", "--stat", "merge-base..HEAD" });
    defer allocator.free(files_raw);
    const changed_files = try allocator.dupe(u8, files_raw);
    errdefer allocator.free(changed_files);

    // 8. Check dirty worktree
    const status_raw = try runGit(allocator, io, &.{ "git", "status", "--porcelain" });
    defer allocator.free(status_raw);
    const dirty = status_raw.len > 0;
    const dirty_note = if (dirty) try allocator.dupe(u8, status_raw) else "";

    return .{
        .branch = branch,
        .base_ref_sha = base_ref_sha,
        .merge_base_sha = merge_base_sha,
        .head_sha = head_sha,
        .commit_count = commit_count,
        .changed_files = changed_files,
        .worktree_dirty = dirty,
        .dirty_note = dirty_note,
    };
}

/// Builds a context block that can be injected into the model prompt.
pub fn buildContextString(allocator: std.mem.Allocator, scope: ReviewScope) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# Review scope
        \\
        \\| Field | Value |
        \\|---|---|
        \\| Branch under review | {s} |
        \\| HEAD SHA | {s} |
        \\| Base ref SHA | {s} |
        \\| Merge-base SHA | {s} |
        \\| Commits in scope | {d} |
        \\| Changed files | {s} |
        \\| Dirty worktree | {s} |
        \\
        \\Use this scope to complete the review.
    , .{
        scope.branch,
        scope.head_sha,
        scope.base_ref_sha,
        scope.merge_base_sha,
        scope.commit_count,
        scope.changed_files,
        if (scope.worktree_dirty) scope.dirty_note else "false",
    });
}

// ─── Fallback reports ────────────────────────────────────────────────────────

/// Generates a structured fallback report when the model fails.
pub fn fallbackReport(allocator: std.mem.Allocator, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# Review report
        \\
        \\## Branch Under Review
        \\
        \\No review was performed.
        \\
        \\## Branch Commits
        \\
        \\No review was performed.
        \\
        \\## Other Commits
        \\
        \\No review was performed.
        \\
        \\## Diff
        \\
        \\No review was performed.
        \\
        \\## Test Failures
        \\
        \\No review was performed.
        \\
        \\## Files Touched
        \\
        \\No review was performed.
        \\
        \\## Conclusion
        \\
        \\NO - {s}
    , .{reason});
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "validateReport detects all required sections" {
    const report =
        \\# Review report
        \\
        \\## Branch Under Review
        \\
        \\feature/xyz
        \\
        \\## Branch Commits
        \\
        \\1. abc1234 fix foo
        \\
        \\## Other Commits
        \\
        \\None
        \\
        \\## Diff
        \\
        \\+10 -5
        \\
        \\## Test Failures
        \\
        \\None
        \\
        \\## Files Touched
        \\
        \\src/foo.zig
        \\
        \\## Conclusion
        \\
        \\YES - LGTM
    ;
    const result = validateReport(report);
    try std.testing.expectEqual(Verdict.yes, result.verdict);
    try std.testing.expectEqual(@as(usize, 0), result.missing_sections.len);
    try std.testing.expect(result.has_conclusion_marker);
}

test "validateReport detects missing sections" {
    const report =
        \\# Review report
        \\
        \\## Branch Under Review
        \\
        \\feature/xyz
        \\
        \\## Conclusion
        \\
        \\NO - missing everything else
    ;
    const result = validateReport(report);
    try std.testing.expectEqual(Verdict.@"no", result.verdict);
    try std.testing.expectEqual(@as(usize, 5), result.missing_sections.len);
}

test "validateReport defaults to NO when conclusion marker is absent" {
    const report =
        \\# Review report
        \\
        \\## Branch Under Review
        \\
        \\feature/xyz
        \\
        \\## Branch Commits
        \\
        \\## Other Commits
        \\
        \\## Diff
        \\
        \\## Test Failures
        \\
        \\## Files Touched
        \\
        \\## Conclusion
        \\
        \\Looks good overall but no explicit YES/NO marker.
    ;
    const result = validateReport(report);
    try std.testing.expectEqual(Verdict.@"no", result.verdict);
}

test "validateReport canonicalizes NO (WARNING)" {
    const report =
        \\# Review report
        \\
        \\## Branch Under Review
        \\## Branch Commits
        \\## Other Commits
        \\## Diff
        \\## Test Failures
        \\## Files Touched
        \\## Conclusion
        \\
        \\NO (WARNING) - minor issues
    ;
    const result = validateReport(report);
    try std.testing.expectEqual(Verdict.warning, result.verdict);
}

test "buildContextString formats scope metadata" {
    const scope = ReviewScope{
        .branch = "feature/xyz",
        .base_ref_sha = "abc1234",
        .merge_base_sha = "def5678",
        .head_sha = "1112223",
        .commit_count = 5,
        .changed_files = "3 files",
        .worktree_dirty = false,
        .dirty_note = "",
    };
    const result = try buildContextString(std.testing.allocator, scope);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "feature/xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "abc1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "def5678") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1112223") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "5") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "false") != null);
}

test "buildContextString shows dirty worktree note" {
    const scope = ReviewScope{
        .branch = "fix/bug",
        .base_ref_sha = "aaa1111",
        .merge_base_sha = "bbb2222",
        .head_sha = "ccc3333",
        .commit_count = 1,
        .changed_files = "1 file",
        .worktree_dirty = true,
        .dirty_note = "3 uncommitted changes",
    };
    const result = try buildContextString(std.testing.allocator, scope);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "3 uncommitted changes") != null);
}

test "fallbackReport contains all required sections and NO verdict" {
    const result = try fallbackReport(std.testing.allocator, "network timeout");
    defer std.testing.allocator.free(result);

    for (required_sections) |section| {
        try std.testing.expect(hasSection(result, section));
    }
    try std.testing.expectEqual(Verdict.@"no", extractVerdict(result).?);
    try std.testing.expect(std.mem.indexOf(u8, result, "network timeout") != null);
}

test "isOnMain detects main and master branches" {
    try std.testing.expect(isOnMain("main"));
    try std.testing.expect(isOnMain("master"));
    try std.testing.expect(!isOnMain("feature/xyz"));
    try std.testing.expect(!isOnMain("fix/bug"));
}

test "extractStdout parses stdout from runCommand output" {
    const result = "Exit code: 0\nSTDOUT:\nhello world\nSTDERR:\n";
    try std.testing.expectEqualStrings("hello world", extractStdout(result));
}

test "extractStdout handles no stderr" {
    const result = "Exit code: 0\nSTDOUT:\noutput only\n";
    try std.testing.expectEqualStrings("output only", extractStdout(result));
}

test "extractStdout handles empty stdout" {
    const result = "Exit code: 0\nSTDOUT:\nSTDERR:\n";
    try std.testing.expectEqualStrings("", extractStdout(result));
}

test "exitCode parses numeric exit code" {
    try std.testing.expectEqual(@as(?u32, 0), exitCode("Exit code: 0\nSTDOUT:\n"));
    try std.testing.expectEqual(@as(?u32, 1), exitCode("Exit code: 1\nSTDOUT:\n"));
    try std.testing.expectEqual(@as(?u32, 128), exitCode("Exit code: 128\nSTDOUT:\n"));
}

test "exitCode returns null for malformed output" {
    try std.testing.expectEqual(@as(?u32, null), exitCode("not an exit code"));
}
