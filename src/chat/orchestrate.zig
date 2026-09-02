const std = @import("std");
const branch_review = @import("../review/review.zig");
const core_session = @import("../core/session.zig");
const prompts = @import("../prompts/prompts.zig");
const sigint = @import("../core/sigint.zig");
const context = @import("context.zig");
const cli = @import("../cli/args.zig");

const ChatLoopContext = context.ChatLoopContext;

pub const default_max_iterations = cli.default_max_iterations;

/// The plan file is read straight out of the session directory, so it is bounded
/// by the same limit `--prompt-file` applies to a task loaded from disk.
const max_plan_bytes = 10 * 1024 * 1024;

pub const Phase = enum {
    implement,
    review,
    fix,
};

pub const Status = enum {
    merge_worthy,
    rejected,
    operational_failure,
    aborted,

    /// Orchestrate reports through the same exit codes as `--review`, so an
    /// aborted run is a failure to reach a verdict rather than a fourth code.
    pub fn toOutcome(self: Status) branch_review.Outcome {
        return switch (self) {
            .merge_worthy => .merge_worthy,
            .rejected => .rejected,
            .operational_failure, .aborted => .operational_failure,
        };
    }
};

pub const Spec = struct {
    /// Empty means "implement the plan this session already saved".
    task: []const u8 = "",
    max_iterations: usize = default_max_iterations,
    plan: bool = false,
};

pub const ParseError = error{
    UnknownFlag,
    MissingIterations,
    InvalidIterations,
    PlanRequiresTask,
};

/// Emitted so the chat loop and the tests agree on the wording without
/// duplicating string literals.
pub const usage =
    "Usage: /orchestrate [--plan] [--iterations <n>] [task]\n" ++
    "       /orchestrate with no task implements the plan saved in this session.\n";

pub fn parseError(err: ParseError) []const u8 {
    return switch (err) {
        error.UnknownFlag => "Unknown orchestrate flag.",
        error.MissingIterations => "--iterations needs a number.",
        error.InvalidIterations => "--iterations must be a positive number.",
        error.PlanRequiresTask => "--plan needs a task to plan.",
    };
}

/// Parses the argument text of `/orchestrate`. Flags are recognised only while
/// they lead the text; the first token that is not a flag starts the task, so a
/// task may itself mention `--anything` without being misread.
pub fn parseCommand(text: []const u8) ParseError!Spec {
    var spec = Spec{};
    var rest = std.mem.trim(u8, text, &std.ascii.whitespace);

    while (std.mem.startsWith(u8, rest, "--")) {
        const flag_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const flag = rest[0..flag_end];
        var after = std.mem.trimStart(u8, rest[flag_end..], &std.ascii.whitespace);

        if (std.mem.eql(u8, flag, "--plan")) {
            spec.plan = true;
        } else if (std.mem.eql(u8, flag, "--iterations") or std.mem.eql(u8, flag, "--max-iterations")) {
            if (after.len == 0) return error.MissingIterations;
            const value_end = std.mem.indexOfAny(u8, after, " \t") orelse after.len;
            const value = after[0..value_end];
            spec.max_iterations = std.fmt.parseInt(usize, value, 10) catch return error.InvalidIterations;
            if (spec.max_iterations == 0) return error.InvalidIterations;
            after = std.mem.trimStart(u8, after[value_end..], &std.ascii.whitespace);
        } else {
            return error.UnknownFlag;
        }

        rest = after;
    }

    spec.task = rest;
    if (spec.plan and spec.task.len == 0) return error.PlanRequiresTask;
    return spec;
}

/// Message the fix phase sends to the model.
///
/// Deliberately avoids the words the mock provider treats as tool-call
/// keywords — `read`, `search`, `shell`, `fail`, `error`, `timeout` and the
/// rest — because `containsWord` matches them as whole words and would make
/// every mocked fix phase fire spurious tool calls. `file-reading` is safe
/// where `read` is not, since the trailing `i` blocks the word boundary.
pub fn fixPrompt(allocator: std.mem.Allocator, report_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "The branch review rejected this branch. Open {s} with the file-reading tool, " ++
            "resolve every finding it lists, and confirm the existing tests still pass. " ++
            "Never edit {s}. Change source files only, and commit as you go.",
        .{ report_path, branch_review.report_filename },
    );
}

/// Backstop commit messages. These land in the user's history, so they follow
/// the same one-line, no-prefix, no-trailer discipline the orchestrate prompt
/// asks of the model.
pub fn commitMessageFor(allocator: std.mem.Allocator, phase: Phase, iteration: usize) ![]const u8 {
    return switch (phase) {
        .implement => allocator.dupe(u8, "Commit remaining implement work"),
        .fix => std.fmt.allocPrint(allocator, "Commit remaining fixes from review round {d}", .{iteration}),
        .review => allocator.dupe(u8, "Commit remaining work"),
    };
}

/// Drops the porcelain lines that name a file Puny generated itself. Matches
/// on the exact path the way review mode does, so a real `docs/puny_chat.log`
/// still counts as work.
pub fn withoutGeneratedFiles(allocator: std.mem.Allocator, status: []const u8) ![]const u8 {
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(allocator);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const path = if (line.len > 3) std.mem.trim(u8, line[3..], &std.ascii.whitespace) else "";
        var generated = false;
        for (generated_paths) |candidate| {
            if (std.mem.eql(u8, path, candidate)) {
                generated = true;
                break;
            }
        }
        if (generated) continue;
        if (filtered.items.len > 0) try filtered.append(allocator, '\n');
        try filtered.appendSlice(allocator, line);
    }
    return filtered.toOwnedSlice(allocator);
}

/// Returns the worktree status with Puny's own generated files filtered out,
/// or null when nothing else is pending.
pub fn dirtyStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !?[]const u8 {
    const result = try branch_review.runGit(
        allocator,
        io,
        repo_root,
        &.{ "status", "--porcelain=v1", "--untracked-files=all" },
        30 * std.time.ns_per_s,
    );
    const status = switch (result) {
        .ok => |value| value,
        .failed => return error.GitStatusFailed,
    };
    const filtered = try withoutGeneratedFiles(allocator, status);
    if (filtered.len == 0) return null;
    return filtered;
}

/// Files Puny generates itself. They are never the user's work, so the
/// backstop commit unstages them even when the repository does not ignore
/// them. `review-results.md` leads the list because the review phase rewrites
/// it on every iteration.
pub const generated_paths = [_][]const u8{
    branch_review.report_filename,
    "puny_http.log",
    "puny_chat.log",
};

/// Stages everything except Puny's own generated files and commits it. The
/// model is asked to commit its own work in small slices; this only sweeps up
/// whatever it left behind, because `--review` scopes to committed changes and
/// would otherwise pass judgement on an incomplete diff.
pub fn autoCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    message: []const u8,
) !void {
    const add = try branch_review.runGit(allocator, io, repo_root, &.{ "add", "-A" }, 60 * std.time.ns_per_s);
    if (add == .failed) return error.GitAddFailed;

    // Unstage rather than excluding with a pathspec: the pathspec form needs
    // shell-level quoting and a fallback for older git.
    for (generated_paths) |path| {
        _ = try branch_review.runGit(
            allocator,
            io,
            repo_root,
            &.{ "reset", "-q", "HEAD", "--", path },
            30 * std.time.ns_per_s,
        );
    }

    // `git status` can report entries that stage to nothing: a submodule with
    // dirty content only, or a file whose change is normalized away (e.g. CRLF
    // via .gitattributes). Committing then fails, so treat an empty index as
    // "nothing left to sweep" rather than a phase failure.
    const staged = try branch_review.runGit(
        allocator,
        io,
        repo_root,
        &.{ "diff", "--cached", "--quiet" },
        30 * std.time.ns_per_s,
    );
    if (staged == .ok) return;

    const commit = try branch_review.runGit(
        allocator,
        io,
        repo_root,
        &.{ "commit", "-m", message },
        60 * std.time.ns_per_s,
    );
    if (commit == .failed) return error.GitCommitFailed;
}

pub const Preflight = union(enum) {
    ok: struct {
        repo_root: []const u8,
        branch: []const u8,
    },
    invalid: []const u8,
};

/// Checks the branch preconditions without paying for the `git fetch` that a
/// full `branch_review.prepare` performs; the review phase does that per
/// iteration anyway.
pub fn preflight(allocator: std.mem.Allocator, io: std.Io) !Preflight {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const checked = try branch_review.checkRepoPreconditions(allocator, io, cwd, "Orchestrate");
    return switch (checked) {
        .ok => |value| .{ .ok = .{ .repo_root = value.repo_root, .branch = value.branch } },
        .invalid => |failure| .{ .invalid = failure.message },
    };
}

/// Resolves the text the implement phase works from: the task given on the
/// command line, or the PRD this session already saved. The plan is read
/// straight from the session directory — there is no copy into the repository.
pub fn resolveTask(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec: Spec,
    prd_path: []const u8,
) ![]const u8 {
    const task = std.mem.trim(u8, spec.task, &std.ascii.whitespace);
    if (task.len > 0) return allocator.dupe(u8, task);
    if (prd_path.len == 0) return error.NoTask;

    const content = std.Io.Dir.cwd().readFileAlloc(io, prd_path, allocator, .limited(max_plan_bytes)) catch {
        return error.NoTask;
    };
    if (std.mem.trim(u8, content, &std.ascii.whitespace).len == 0) {
        allocator.free(content);
        return error.NoTask;
    }
    return content;
}

pub const TurnReport = struct {
    cancelled: bool = false,
    had_error: bool = false,
    exited: bool = false,
};

/// The chat loop injects these so this module never imports `session.zig`,
/// which imports it. `reset_context` gives the next phase a clean conversation
/// while keeping the session directory, and `run_turn` drives one agentic turn
/// without honouring `--oneshot`, which would otherwise end the run after the
/// implement phase.
pub const Hooks = struct {
    run_turn: *const fn (ctx: *ChatLoopContext) anyerror!TurnReport,
    reset_context: *const fn (ctx: *ChatLoopContext) anyerror!void,
};

fn enterBuildPhase(ctx: *ChatLoopContext) void {
    ctx.mode.* = .build;
    core_session.setWriteBlocked(false);
}

fn enterReviewPhase(ctx: *ChatLoopContext) !void {
    ctx.mode.* = .review;
    core_session.setWriteBlocked(true);
    const alloc = ctx.messages_arena.allocator();
    const review_prompt = try ctx.cfg.resolvePrompt(alloc, "review", prompts.review);
    try ctx.messages.append(alloc, .{ .system = review_prompt });
}

/// Leaves the session in a state a later `/resume` can use: build mode, writes
/// unblocked, and no review scope still pinned in the review module globals.
fn settle(ctx: *ChatLoopContext) void {
    if (branch_review.isActive()) branch_review.reset();
    enterBuildPhase(ctx);
}

fn announce(ctx: *ChatLoopContext, comptime fmt: []const u8, args: anytype) !void {
    try ctx.stdout_writer.print(fmt, args);
    try ctx.stdout_writer.flush();
}

/// Starts a phase from a clean conversation. Build phases also carry the
/// orchestrate prompt, which the review phase must never see: commits go
/// through the shell tool, and review mode blocks it.
fn beginPhase(ctx: *ChatLoopContext, hooks: Hooks, phase: Phase) !void {
    try hooks.reset_context(ctx);
    switch (phase) {
        .review => try enterReviewPhase(ctx),
        .implement, .fix => {
            enterBuildPhase(ctx);
            const alloc = ctx.messages_arena.allocator();
            const prompt = try ctx.cfg.resolvePrompt(alloc, "orchestrate", prompts.orchestrate);
            try ctx.messages.append(alloc, .{ .system = prompt });
        },
    }
}

/// Commits whatever the model left behind. The review only sees committed
/// changes, so skipping this would let it return a verdict on a partial diff.
fn sweepWorktree(
    ctx: *ChatLoopContext,
    repo_root: []const u8,
    phase: Phase,
    iteration: usize,
) !void {
    const alloc = ctx.messages_arena.allocator();
    const pending = try dirtyStatus(alloc, ctx.io, repo_root);
    if (pending == null) {
        try announce(ctx, "Worktree clean - nothing to commit\n", .{});
        return;
    }
    try announce(ctx, "Committing dirty worktree...\n", .{});
    const message = try commitMessageFor(alloc, phase, iteration);
    try autoCommit(alloc, ctx.io, repo_root, message);
}

const PhaseResult = union(enum) {
    ok,
    aborted,
    failed: ?[]const u8,
};

/// Runs `[implement] -> (review -> fix)*` until the branch is merge worthy, the
/// iteration budget runs out, or something fails. Every phase starts from a
/// fresh conversation and hands off through artifacts: the saved plan into
/// implement, commits into review, and the review report back into fix.
pub fn run(ctx: *ChatLoopContext, spec: Spec, hooks: Hooks) !Status {
    // Survives the per-phase arena resets, unlike anything from messages_arena.
    const durable = ctx.arena;

    const checked = try preflight(durable, ctx.io);
    const repo_root = switch (checked) {
        .ok => |value| value.repo_root,
        .invalid => |message| {
            try announce(ctx, "\nOrchestrate could not start: {s}\n", .{message});
            return .operational_failure;
        },
    };

    const task = resolveTask(durable, ctx.io, spec, ctx.session.prd_path) catch {
        try announce(
            ctx,
            "\nOrchestrate could not start: no task given and this session has no saved plan.\n",
            .{},
        );
        return .operational_failure;
    };

    const report_path = try std.fs.path.join(durable, &.{ repo_root, branch_review.report_filename });

    if (sigint.isTriggered()) return finishAborted(ctx);

    try announce(ctx, "\nOrchestrate: implement\n", .{});
    switch (try runBuildPhase(ctx, hooks, .implement, task, repo_root, 0)) {
        .ok => {},
        .aborted => return finishAborted(ctx),
        .failed => |message| return finishFailed(ctx, message),
    }

    var iteration: usize = 1;
    while (iteration <= spec.max_iterations) : (iteration += 1) {
        if (sigint.isTriggered()) return finishAborted(ctx);

        try announce(ctx, "\nOrchestrate: review (iteration {d}/{d})\n", .{ iteration, spec.max_iterations });
        switch (try runReviewPhase(ctx, hooks)) {
            .merge_worthy => {
                settle(ctx);
                try announce(ctx, "\nOrchestrate finished: MERGE WORTHY: YES\n", .{});
                return .merge_worthy;
            },
            .operational_failure => return finishFailed(ctx, null),
            .aborted => return finishAborted(ctx),
            .rejected => {},
        }

        if (iteration == spec.max_iterations) break;
        if (sigint.isTriggered()) return finishAborted(ctx);

        try announce(ctx, "\nOrchestrate: fix (iteration {d}/{d})\n", .{ iteration, spec.max_iterations });
        const instruction = try fixPrompt(durable, report_path);
        switch (try runBuildPhase(ctx, hooks, .fix, instruction, repo_root, iteration)) {
            .ok => {},
            .aborted => return finishAborted(ctx),
            .failed => |message| return finishFailed(ctx, message),
        }
    }

    settle(ctx);
    try announce(
        ctx,
        "\nOrchestrate finished: not merge worthy after {d} iteration(s)\n",
        .{spec.max_iterations},
    );
    return .rejected;
}

fn runBuildPhase(
    ctx: *ChatLoopContext,
    hooks: Hooks,
    phase: Phase,
    instruction: []const u8,
    repo_root: []const u8,
    iteration: usize,
) !PhaseResult {
    try beginPhase(ctx, hooks, phase);
    const alloc = ctx.messages_arena.allocator();
    try ctx.messages.append(alloc, .{ .user = try alloc.dupe(u8, instruction) });

    const report = hooks.run_turn(ctx) catch return .{ .failed = "the model turn failed" };
    if (report.cancelled or sigint.isTriggered()) return .aborted;
    if (report.had_error) return .{ .failed = "the provider failed during the turn" };

    sweepWorktree(ctx, repo_root, phase, iteration) catch |err| {
        return .{ .failed = switch (err) {
            error.GitStatusFailed => "could not inspect the worktree",
            error.GitAddFailed => "could not stage the remaining changes",
            error.GitCommitFailed => "could not commit the remaining changes",
            else => "could not commit the remaining changes",
        } };
    };
    return .ok;
}

/// One review pass. Mirrors the `/review` command arm: every `Preparation`
/// variant is handled, and the turn runner finalizes the report and sets
/// `review_outcome` when the scope is ready.
fn runReviewPhase(ctx: *ChatLoopContext, hooks: Hooks) !Status {
    // Guarantees no scope from the previous iteration is still pinned.
    if (branch_review.isActive()) branch_review.reset();

    try beginPhase(ctx, hooks, .review);
    const alloc = ctx.messages_arena.allocator();

    const prepared = try branch_review.prepare(alloc, ctx.io);
    switch (prepared) {
        .invalid => |failure| {
            try announce(ctx, "\nReview could not start: {s}\n", .{failure.message});
            return .operational_failure;
        },
        .operational_failure => |failure| {
            const saved = branch_review.writeOperationalFailure(alloc, ctx.io, failure) catch {
                return .operational_failure;
            };
            ctx.review_outcome.* = saved.outcome;
            try announce(ctx, "\nReview report: {s}\nMERGE WORTHY: NO\n", .{saved.path});
            return .operational_failure;
        },
        .no_changes => |scope| {
            const saved = branch_review.writeNoChanges(alloc, ctx.io, scope) catch {
                return .operational_failure;
            };
            ctx.review_outcome.* = saved.outcome;
            try announce(ctx, "\nReview report: {s}\nMERGE WORTHY: NO\n", .{saved.path});
            return .rejected;
        },
        .ready => |scope| {
            branch_review.begin(scope);
            const review_context = try branch_review.buildPromptContext(alloc, scope);
            try ctx.messages.append(alloc, .{ .system = review_context });
            try ctx.messages.append(alloc, .{ .user = branch_review.request_prompt });
            try announce(ctx, "\nReviewing {s} against {s}.\n", .{ scope.branch, scope.base_ref });

            const report = hooks.run_turn(ctx) catch {
                if (branch_review.isActive()) branch_review.reset();
                return .operational_failure;
            };
            if (branch_review.isActive()) branch_review.reset();
            if (report.cancelled or sigint.isTriggered()) return .aborted;

            const outcome = ctx.review_outcome.* orelse return .operational_failure;
            return switch (outcome) {
                .merge_worthy => .merge_worthy,
                .rejected => .rejected,
                .operational_failure => .operational_failure,
            };
        },
    }
}

fn finishFailed(ctx: *ChatLoopContext, message: ?[]const u8) !Status {
    settle(ctx);
    if (message) |text| {
        try announce(ctx, "\nOrchestrate stopped: {s}.\n", .{text});
    }
    return .operational_failure;
}

/// Interrupted runs keep whatever was already committed. Nothing is reset or
/// stashed, so the branch is exactly as far along as its commits say.
fn finishAborted(ctx: *ChatLoopContext) !Status {
    settle(ctx);
    try announce(
        ctx,
        "\nOrchestrate aborted.\nWork committed so far is kept; anything still in the worktree is left for you - check git status.\n",
        .{},
    );
    return .aborted;
}

test "parseCommand reads a bare task" {
    const spec = try parseCommand("add csv export");
    try std.testing.expectEqualStrings("add csv export", spec.task);
    try std.testing.expectEqual(default_max_iterations, spec.max_iterations);
    try std.testing.expect(!spec.plan);
}

test "parseCommand accepts an empty argument" {
    const spec = try parseCommand("");
    try std.testing.expectEqualStrings("", spec.task);
    try std.testing.expect(!spec.plan);
}

test "parseCommand reads leading flags" {
    const plan = try parseCommand("--plan add csv export");
    try std.testing.expect(plan.plan);
    try std.testing.expectEqualStrings("add csv export", plan.task);

    const short = try parseCommand("--iterations 3 tidy up");
    try std.testing.expectEqual(@as(usize, 3), short.max_iterations);
    try std.testing.expectEqualStrings("tidy up", short.task);

    const long = try parseCommand("--max-iterations 2 tidy up");
    try std.testing.expectEqual(@as(usize, 2), long.max_iterations);

    const both = try parseCommand("--plan --iterations 7 add csv export");
    try std.testing.expect(both.plan);
    try std.testing.expectEqual(@as(usize, 7), both.max_iterations);
    try std.testing.expectEqualStrings("add csv export", both.task);
}

test "parseCommand stops reading flags once the task starts" {
    const spec = try parseCommand("document the --iterations flag");
    try std.testing.expectEqualStrings("document the --iterations flag", spec.task);
    try std.testing.expectEqual(default_max_iterations, spec.max_iterations);
}

test "parseCommand rejects malformed flags" {
    try std.testing.expectError(error.UnknownFlag, parseCommand("--wat tidy up"));
    try std.testing.expectError(error.MissingIterations, parseCommand("--iterations"));
    try std.testing.expectError(error.InvalidIterations, parseCommand("--iterations abc tidy"));
    try std.testing.expectError(error.InvalidIterations, parseCommand("--iterations 0 tidy"));
    try std.testing.expectError(error.PlanRequiresTask, parseCommand("--plan"));
}

test "fixPrompt names the report and avoids mock tool-call keywords" {
    const prompt = try fixPrompt(std.testing.allocator, "/repo/review-results.md");
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "/repo/review-results.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Never edit review-results.md") != null);

    // Whole-word keywords the mock provider dispatches on. Matching any of them
    // would turn every mocked fix phase into spurious tool calls.
    const keywords = [_][]const u8{
        "long",      "fast", "slow", "echo",   "empty", "partial", "usage",
        "error",     "fail", "read", "search", "shell", "table",   "markdown",
        "reasoning",
    };
    for (keywords) |keyword| {
        try std.testing.expect(!containsWord(prompt, keyword));
    }
}

test "commitMessageFor stays within the one-line commit discipline" {
    const implement = try commitMessageFor(std.testing.allocator, .implement, 1);
    defer std.testing.allocator.free(implement);
    const fix = try commitMessageFor(std.testing.allocator, .fix, 3);
    defer std.testing.allocator.free(fix);

    for ([_][]const u8{ implement, fix }) |message| {
        try std.testing.expect(message.len <= 72);
        try std.testing.expect(std.mem.indexOfScalar(u8, message, '\n') == null);
        try std.testing.expect(!std.mem.endsWith(u8, message, "."));
        try std.testing.expect(std.mem.indexOfScalar(u8, message, ':') == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, fix, "round 3") != null);
}

test "withoutGeneratedFiles drops only exact generated paths" {
    const alloc = std.testing.allocator;

    const only_generated = try withoutGeneratedFiles(alloc, " M review-results.md\n?? puny_http.log\n?? puny_chat.log");
    defer alloc.free(only_generated);
    try std.testing.expectEqual(@as(usize, 0), only_generated.len);

    const nested = try withoutGeneratedFiles(alloc, " M review-results.md\n?? docs/review-results.md");
    defer alloc.free(nested);
    try std.testing.expectEqualStrings("?? docs/review-results.md", nested);

    const real = try withoutGeneratedFiles(alloc, "?? a.txt\n?? puny_http.log");
    defer alloc.free(real);
    try std.testing.expectEqualStrings("?? a.txt", real);
}

test "resolveTask prefers the explicit task over the saved plan" {
    const alloc = std.testing.allocator;
    const task = try resolveTask(alloc, std.testing.io, .{ .task = "  do the thing  " }, "");
    defer alloc.free(task);
    try std.testing.expectEqualStrings("do the thing", task);
}

test "resolveTask fails when there is no task and no plan" {
    try std.testing.expectError(
        error.NoTask,
        resolveTask(std.testing.allocator, std.testing.io, .{}, ""),
    );
}

test "Status maps onto the review exit codes" {
    try std.testing.expectEqual(@as(u8, 0), Status.merge_worthy.toOutcome().exitCode());
    try std.testing.expectEqual(@as(u8, 1), Status.rejected.toOutcome().exitCode());
    try std.testing.expectEqual(@as(u8, 2), Status.operational_failure.toOutcome().exitCode());
    try std.testing.expectEqual(@as(u8, 2), Status.aborted.toOutcome().exitCode());
}

/// Local copy of the mock provider's word matcher, used only by the fix-prompt
/// test above so it does not depend on a test-only export from the provider.
fn containsWord(text: []const u8, word: []const u8) bool {
    if (text.len < word.len) return false;
    var i: usize = 0;
    while (i <= text.len - word.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) {
            const before_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
            const after_ok = i + word.len >= text.len or !std.ascii.isAlphanumeric(text[i + word.len]);
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}
