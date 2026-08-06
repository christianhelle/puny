const std = @import("std");
const tools = @import("root.zig");
const helpers = @import("helpers.zig");

const WebFetchParams = struct {
    url: []const u8,
    timeout_seconds: ?i64 = null,
};

fn webFetch(allocator: std.mem.Allocator, io: std.Io, params: WebFetchParams) ![]const u8 {
    const timeout_ns = helpers.resolveTimeoutSeconds(params.timeout_seconds, helpers.web_fetch_timeout_ns);
    return helpers.httpGetTimed(allocator, io, params.url, timeout_ns) catch |err| switch (err) {
        error.TimedOut => std.fmt.allocPrint(
            allocator,
            "Tool web_fetch timed out after {d} seconds. If the page legitimately takes longer, retry with a larger timeout_seconds (max 300).",
            .{@divTrunc(timeout_ns, std.time.ns_per_s)},
        ),
        else => return err,
    };
}

pub const web_fetch = tools.defineTool(
    "web_fetch",
    "Fetch the contents of a URL using HTTP GET.",
    WebFetchParams,
    webFetch,
);
