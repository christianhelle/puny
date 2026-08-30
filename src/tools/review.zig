const std = @import("std");
const tools = @import("root.zig");
const review = @import("../review/review.zig");

fn saveReviewResults(
    allocator: std.mem.Allocator,
    io: std.Io,
    params: review.ReportInput,
) ![]const u8 {
    const saved = try review.saveActiveReport(allocator, io, params);
    const verdict = if (saved.outcome == .merge_worthy) "YES" else "NO";
    return std.fmt.allocPrint(
        allocator,
        "Review results saved to {s}\nMERGE WORTHY: {s}",
        .{ saved.path, verdict },
    );
}

pub const save_review_results = tools.defineTool(
    "save_review_results",
    "Save the final branch review. Provide the four required analysis sections without the title, scope, or conclusion headings; the host adds trusted scope and the canonical verdict. Incomplete evidence always forces a NO verdict.",
    review.ReportInput,
    saveReviewResults,
);
