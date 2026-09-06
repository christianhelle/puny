//! Startup prompt offering to file a pending crash report as a GitHub issue.

const std = @import("std");
const crash = @import("../core/crash.zig");
const list_picker = @import("list_picker.zig");

const submit_choice = "submit";
const view_choice = "view";
const delete_choice = "delete";

const choices = [_]list_picker.Item{
    .{ .value = submit_choice, .label = "Submit it as a GitHub issue" },
    .{ .value = view_choice, .label = "Show me the report first" },
    .{ .value = delete_choice, .label = "Delete it" },
    .{ .value = "later", .label = "Not now" },
};

/// Offers every pending crash report to the user, one at a time. Automated
/// runs are left alone. Failures are swallowed: a startup must never break
/// because a crash report could not be read or filed.
pub fn offer(
    arena: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    session: crash.Session,
    writer: *std.Io.Writer,
) void {
    if (!crash.shouldPrompt(session)) return;

    const reports = crash.list(io, arena, environ_map) catch return;
    defer crash.freeReports(arena, reports);

    for (reports) |report| {
        const keep_asking = offerOne(arena, io, report, writer) catch return;
        if (!keep_asking) return;
    }
}

/// Asks about one report. Returns false when the user wants to be left alone
/// for the rest of them.
fn offerOne(
    arena: std.mem.Allocator,
    io: std.Io,
    report: crash.Report,
    writer: *std.Io.Writer,
) !bool {
    const title = try std.fmt.allocPrint(
        arena,
        "puny crashed in session {s}. File it as an issue on {s}?",
        .{ shortId(report.session_id), crash.repo },
    );

    while (true) {
        const picked = try list_picker.selectFromList(arena, io, title, &choices) orelse return false;

        if (std.mem.eql(u8, picked, view_choice)) {
            try printReport(arena, io, report, writer);
            continue;
        }
        if (std.mem.eql(u8, picked, delete_choice)) {
            crash.discard(io, report.path) catch {};
            try writer.print("\nCrash report deleted.\n", .{});
            try writer.flush();
            return true;
        }
        if (std.mem.eql(u8, picked, submit_choice)) {
            try submitReport(arena, io, report, writer);
            return true;
        }
        return false;
    }
}

fn printReport(
    arena: std.mem.Allocator,
    io: std.Io,
    report: crash.Report,
    writer: *std.Io.Writer,
) !void {
    const body = std.Io.Dir.cwd().readFileAlloc(
        io,
        report.path,
        arena,
        std.Io.Limit.limited(crash.max_report_bytes),
    ) catch {
        try writer.print("\nCould not read {s}\n", .{report.path});
        try writer.flush();
        return;
    };
    defer arena.free(body);
    try writer.print("\n{s}\n{s}\n", .{ body, report.path });
    try writer.flush();
}

fn submitReport(
    arena: std.mem.Allocator,
    io: std.Io,
    report: crash.Report,
    writer: *std.Io.Writer,
) !void {
    const outcome = crash.submit(io, arena, report.path) catch |err| {
        try writer.print("\nCrash report not submitted: {s}\nIt is kept at {s}\n", .{ @errorName(err), report.path });
        try writer.flush();
        return;
    };
    defer crash.freeOutcome(arena, outcome);

    switch (outcome) {
        .submitted => |url| {
            crash.discard(io, report.path) catch {};
            try writer.print("\nThanks. Crash report filed at {s}\n", .{url});
        },
        .failed => |message| {
            try writer.print("\nCrash report not submitted: {s}\nIt is kept at {s}\n", .{ message, report.path });
        },
    }
    try writer.flush();
}

/// First segment of a session uuid, enough to recognise the run.
fn shortId(session_id: []const u8) []const u8 {
    return if (session_id.len > 8) session_id[0..8] else session_id;
}

test "shortId abbreviates a session uuid for the prompt" {
    try std.testing.expectEqualStrings("8f14e45f", shortId("8f14e45f-ceea-467a-9dc3-0f0e0b1e1e1e"));
}

test "shortId leaves a short id alone" {
    try std.testing.expectEqualStrings("abc", shortId("abc"));
}
